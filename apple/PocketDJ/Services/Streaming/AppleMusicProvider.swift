import Foundation
import Observation

// MARK: - Configuration

/// Apple Music differs from Spotify/YouTube in that there is **no client secret /
/// API key on device** — MusicKit mints a developer token automatically once the
/// app's bundle id has the *MusicKit App Service* enabled in the Apple Developer
/// portal and the target carries the `com.apple.developer.musickit` entitlement.
///
/// There is therefore nothing credential-shaped to read at runtime. What we DO
/// gate on is a build-time opt-in flag so the provider stays dormant (`.unavailable`)
/// in the default build — exactly like an absent Spotify client id — until the
/// portal toggle + entitlement actually exist. Set this in project.yml:
///
///   INFOPLIST_KEY_PocketDJAppleMusicEnabled: YES   (commented until provisioned)
///
/// Absent / not "YES" ⇒ the row shows "Connect Apple Music" disabled and
/// `MusicAuthorization.request()` is NEVER called (so a missing
/// `NSAppleMusicUsageDescription` can't crash the default build).
enum AppleMusicCredentials {
    static var isEnabled: Bool {
        guard let v = Bundle.main.object(forInfoDictionaryKey: "PocketDJAppleMusicEnabled") else {
            return false
        }
        if let b = v as? Bool { return b }
        if let s = v as? String { return ["YES", "true", "1"].contains(s.trimmingCharacters(in: .whitespaces)) }
        return false
    }
}

// ============================================================================
// MARK: - Real implementation (MusicKit)
// ============================================================================
//
// MusicKit ships with the SDK, so `canImport(MusicKit)` is essentially always
// true on Apple platforms — unlike Spotify/YouTube there is no third-party pod to
// be absent. The guard is kept anyway for symmetry and so the file is portable to
// any tooling where the framework is genuinely unavailable. The *dormancy* that
// keeps the default build inert comes from `AppleMusicCredentials.isEnabled`, not
// from the import.
#if canImport(MusicKit)
import MusicKit

/// Apple Music as an account-linked streaming source + searchable catalog +
/// `SongRecognizer`, conforming to the shared seams alongside Spotify/YouTube.
///
/// Three capabilities, all behind the one `MusicAuthorization` consent:
///   • ACCOUNT-LINK / PLAYBACK (`StreamingProvider`) — `MusicAuthorization.request()`
///     drives the system consent sheet (no web view, no redirect → `handleCallback`
///     is always a no-op for Apple Music). Playback is `ApplicationMusicPlayer.shared`.
///   • SEARCH (`StreamingSearch`) — `MusicCatalogSearchRequest` for songs.
///   • RECOGNIZE (`SongRecognizer`) — resolve one of our `IndexSong`s back to a
///     playable Apple Music track (by namespaced store id, else title/artist),
///     which is what the Shazam "no local rip" bridge calls.
///
/// `@available(iOS 16, macOS 14, *)` covers `MusicCatalogSearchRequest` /
/// `ApplicationMusicPlayer` (the latter is macOS 14+); the app's deployment targets
/// (18 / 15) clear it, so no runtime `#available` branch is needed at call sites.
@available(iOS 16.0, macOS 14.0, *)
@MainActor
@Observable
final class AppleMusicProvider: StreamingProvider, StreamingSearch, SongRecognizer {
    let kind: StreamingProviderKind = .appleMusic
    private(set) var state: StreamingConnectionState

    /// Available only when the build opted in. (MusicKit itself is always linked.)
    var isAvailable: Bool { AppleMusicCredentials.isEnabled }

    init() {
        guard AppleMusicCredentials.isEnabled else {
            state = .unavailable(reason: "Apple Music is not enabled in this build.")
            return
        }
        // Reflect any consent already granted in a previous launch without
        // prompting (prompting only happens on an explicit `login()` tap).
        switch MusicAuthorization.currentStatus {
        case .authorized: state = .connected(account: nil)
        case .denied, .restricted:
            state = .failed(message: "Apple Music access was denied. Enable it in Settings.")
        case .notDetermined: state = .loggedOut
        @unknown default: state = .loggedOut
        }
    }

    // MARK: StreamingProvider — account link

    func login() {
        guard isAvailable else {
            state = .unavailable(reason: "Apple Music is not enabled in this build."); return
        }
        state = .authorizing
        Task { @MainActor in
            // System consent sheet. No web view, no redirect.
            let status = await MusicAuthorization.request()
            switch status {
            case .authorized:
                // A linked Apple ID still needs an active subscription that can
                // play catalog content for on-demand playback; surface that.
                let label = await Self.subscriptionLabel()
                state = .connected(account: label)
            case .denied:
                state = .failed(message: "Apple Music access was denied. Enable it in Settings.")
            case .restricted:
                state = .failed(message: "Apple Music is restricted on this device.")
            case .notDetermined:
                state = .loggedOut
            @unknown default:
                state = .loggedOut
            }
        }
    }

    func logout() {
        // MusicKit authorization is a system-level grant we cannot revoke
        // programmatically; "log out" here just stops playback and drops our
        // in-app linked state. The user revokes access in Settings → Privacy.
        player.stop()
        state = .loggedOut
    }

    // Apple Music auth is a native sheet, not an OAuth redirect → never our URL.
    @discardableResult
    func handleCallback(url: URL) -> Bool { false }

    // No App-Remote concept; playback is in-process via ApplicationMusicPlayer.
    func reconnectIfNeeded() {}
    func disconnect() {}

    // MARK: StreamingProvider — playback

    private var player: ApplicationMusicPlayer { .shared }

    /// `uri` is a namespaced song id (`am:<storeID>`) or a bare store id; nil
    /// resumes. We enqueue the catalog song then play.
    func play(uri: String?) {
        guard isAvailable else { return }
        guard let uri else { resume(); return }
        let store = AppleMusicCatalog.storeID(fromSongID: uri) ?? uri
        Task { @MainActor in
            do {
                let id = MusicItemID(store)
                var req = MusicCatalogResourceRequest<MusicKit.Song>(matching: \.id, equalTo: id)
                req.limit = 1
                let resp = try await req.response()
                guard let song = resp.items.first else {
                    state = .failed(message: "That track isn’t in the Apple Music catalog."); return
                }
                player.queue = [song]
                try await player.play()
            } catch {
                state = .failed(message: error.localizedDescription)
            }
        }
    }

    func pause() { player.pause() }

    func resume() {
        Task { @MainActor in
            do { try await player.play() }
            catch { state = .failed(message: error.localizedDescription) }
        }
    }

    // MARK: StreamingSearch

    var canSearch: Bool { isAvailable && MusicAuthorization.currentStatus == .authorized }

    func search(_ query: String, limit: Int = 25) async throws -> [StreamingTrack] {
        guard isAvailable else { throw StreamingError.notConfigured }
        guard MusicAuthorization.currentStatus == .authorized else { throw StreamingError.notLinked }
        let q = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !q.isEmpty else { return [] }
        do {
            var req = MusicCatalogSearchRequest(term: q, types: [MusicKit.Song.self])
            req.limit = min(max(limit, 1), 25)
            let resp = try await req.response()
            return resp.songs.map { AppleMusicCatalog.track(from: Self.row(from: $0)) }
        } catch {
            throw StreamingError.network(error)
        }
    }

    // MARK: SongRecognizer

    /// Resolving needs an authorized, subscription-backed session.
    var canResolve: Bool { canSearch }

    func resolve(_ song: IndexSong) async -> StreamingTrack? {
        guard canResolve else { return nil }
        // 1) Our own namespaced id → direct catalog fetch by store id.
        if let store = AppleMusicCatalog.storeID(fromSongID: song.id) {
            if let row = try? await Self.fetchRow(storeID: store) {
                return AppleMusicCatalog.track(from: row)
            }
        }
        // 2) Fall back to a top-result title/artist search.
        let term = "\(song.name) \(song.artist)"
        if let hit = try? await search(term, limit: 1).first { return hit }
        return nil
    }

    // MARK: - MusicKit → row helpers

    private static func fetchRow(storeID: String) async throws -> AppleMusicSongRow? {
        var req = MusicCatalogResourceRequest<MusicKit.Song>(matching: \.id, equalTo: MusicItemID(storeID))
        req.limit = 1
        let resp = try await req.response()
        return resp.items.first.map(row(from:))
    }

    /// MusicKit.Song → the MusicKit-free `AppleMusicSongRow` the mapping consumes.
    private static func row(from s: MusicKit.Song) -> AppleMusicSongRow {
        let year: Int? = s.releaseDate.map { Calendar(identifier: .gregorian).component(.year, from: $0) }
        let art = s.artwork?.url(width: 512, height: 512)
        return AppleMusicSongRow(
            storeID: s.id.rawValue,
            title: s.title,
            artist: s.artistName,
            albumTitle: s.albumTitle,
            trackNumber: s.trackNumber,
            year: year,
            durationSeconds: s.duration,
            isExplicit: s.contentRating == .explicit,
            artworkURL: art)
    }

    /// Best-effort human label for the connected account ("Apple Music" or a note
    /// when the subscription can't play catalog content).
    private static func subscriptionLabel() async -> String? {
        guard let sub = try? await MusicSubscription.current else { return "Apple Music" }
        return sub.canPlayCatalogContent ? "Apple Music" : "Apple Music (no playback subscription)"
    }
}

#else
// ============================================================================
// MARK: - Stub (MusicKit unavailable — keeps the module compiling everywhere)
// ============================================================================

/// No-op Apple Music provider for toolchains where MusicKit genuinely can't be
/// imported. Conforms to the same seams so the registry/UI stay framework-agnostic.
@MainActor
@Observable
final class AppleMusicProvider: StreamingProvider, StreamingSearch, SongRecognizer {
    let kind: StreamingProviderKind = .appleMusic
    private(set) var state: StreamingConnectionState =
        .unavailable(reason: "MusicKit not available in this build.")
    var isAvailable: Bool { false }

    init() {}

    func login() {}
    func logout() {}
    @discardableResult func handleCallback(url: URL) -> Bool { false }
    func reconnectIfNeeded() {}
    func disconnect() {}
    func play(uri: String?) {}
    func pause() {}
    func resume() {}

    var canSearch: Bool { false }
    func search(_ query: String, limit: Int) async throws -> [StreamingTrack] {
        throw StreamingError.notConfigured
    }

    var canResolve: Bool { false }
    func resolve(_ song: IndexSong) async -> StreamingTrack? { nil }
}
#endif

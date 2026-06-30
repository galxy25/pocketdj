import Foundation
import Observation

// MARK: - Configuration

/// Apple Music needs **no client secret / API key on device** — MusicKit mints a
/// developer token automatically once the
/// app's bundle id has the *MusicKit App Service* enabled in the Apple Developer
/// portal and the target carries the `com.apple.developer.musickit` entitlement.
///
/// There is therefore nothing credential-shaped to read at runtime. What we DO
/// gate on is a build-time opt-in flag so the provider stays dormant (`.unavailable`)
/// in the default build — until the portal toggle + entitlement actually exist.
/// Set this in project.yml:
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
// true on Apple platforms — there is no third-party pod to be absent. The guard is
// kept anyway for symmetry and so the file is portable to
// any tooling where the framework is genuinely unavailable. The *dormancy* that
// keeps the default build inert comes from `AppleMusicCredentials.isEnabled`, not
// from the import.
#if canImport(MusicKit)
import MusicKit

/// Apple Music as an account-linked streaming source + searchable catalog +
/// `SongRecognizer`, conforming to the shared streaming seams.
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
        // 1) Index-resolved catalog id, when present. The indexer mints `appleMusicId`
        //    from the *public iTunes Search API* (`trackId`); we treat it only as a
        //    CANDIDATE catalog id. The iTunes `trackId` is empirically the same value
        //    MusicKit uses for `MusicItemID`, but we never trust it blindly: the
        //    `fetchRow` below issues a real `MusicCatalogResourceRequest` keyed on that
        //    id, so a hit is the verification. On a miss (nil/throw — wrong id, region
        //    gating, removed track) we fall through to (2)/(3) and ultimately let
        //    PlaybackCoordinator degrade to ripping. This is the fast path that lets
        //    "Apple Music (Local)" songs (ids shaped `sng_…`, which 2 can't decode)
        //    stream instead of always falling through to a rip.
        if let candidate = song.appleMusicId, !candidate.isEmpty {
            if let row = try? await Self.fetchRow(storeID: candidate) {
                return AppleMusicCatalog.track(from: row)
            }
        }
        // 2) Our own namespaced id (`am:<storeID>`) → direct catalog fetch by store id.
        if let store = AppleMusicCatalog.storeID(fromSongID: song.id) {
            if let row = try? await Self.fetchRow(storeID: store) {
                return AppleMusicCatalog.track(from: row)
            }
        }
        // 3) Fall back to a top-result title/artist search.
        let term = "\(song.name) \(song.artist)"
        if let hit = try? await search(term, limit: 1).first { return hit }
        // All paths failed → nil. PlaybackCoordinator reads this as "no stream" and
        // falls through to the rip provider (graceful degradation, unchanged).
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

// ============================================================================
// MARK: - MusicLibraryContributor (read + WRITE the user's Apple Music library)
// ============================================================================
//
// The Shazam "Heard it" sheet's Apple Music section drives off this: resolve a
// recognized track → is it already in the library? → deep-link to its album, else
// ＋ add it (+ burn). `MusicLibrary.shared.add(_:)` and `MusicLibrarySearchRequest`
// are iOS 16 / macOS 14+ (the app's 18 / 15 targets clear them) and need no extra
// entitlement beyond the MusicKit consent the provider already holds.
@available(iOS 16.0, macOS 14.0, *)
extension AppleMusicProvider: MusicLibraryContributor {
    /// Reading + writing the library needs the same authorized, subscription-backed
    /// session that resolving/searching does.
    var canContribute: Bool { canResolve }

    /// `MusicLibrary.add(_:)` is unavailable on macOS → the Mac can resolve + open albums
    /// but not add; it falls back to opening the track in Apple Music.
    var canAddToLibrary: Bool {
        #if os(macOS)
        return false
        #else
        return canContribute
        #endif
    }

    func resolveForLibrary(storeID: String?, title: String?, artist: String?) async -> AppleMusicResolution? {
        guard canContribute else { return nil }
        // Resolve the catalog song: by store id first (Shazam's appleMusicID), else a
        // top-result title/artist search.
        var song: MusicKit.Song?
        if let storeID, !storeID.isEmpty { song = try? await Self.fetchSong(storeID: storeID) }
        if song == nil, let term = Self.libraryTerm(title: title, artist: artist) {
            song = try? await Self.searchSong(term: term)
        }
        guard let song else { return nil }

        // Load the album relationship for deep-linking / index matching.
        let detailed = (try? await song.with([.albums])) ?? song
        let albumRef = detailed.albums?.first.map(Self.albumRef(from:))
        let inLib = await Self.isInLibrary(title: song.title, artist: song.artistName)

        return AppleMusicResolution(
            songStoreID: song.id.rawValue,
            title: song.title,
            artist: song.artistName,
            inLibrary: inLib,
            album: albumRef,
            songURL: song.url)
    }

    func addSongToLibrary(storeID: String) async throws {
        #if os(macOS)
        throw StreamingError.notConfigured   // MusicLibrary.add is unavailable on macOS
        #else
        guard let song = try await Self.fetchSong(storeID: storeID) else { throw StreamingError.notConfigured }
        _ = try await MusicLibrary.shared.add(song)
        #endif
    }

    func addAlbumToLibrary(storeID: String) async throws {
        #if os(macOS)
        throw StreamingError.notConfigured   // MusicLibrary.add is unavailable on macOS
        #else
        var req = MusicCatalogResourceRequest<MusicKit.Album>(matching: \.id, equalTo: MusicItemID(storeID))
        req.limit = 1
        guard let album = try await req.response().items.first else { throw StreamingError.notConfigured }
        _ = try await MusicLibrary.shared.add(album)
        #endif
    }

    func albumTracks(albumStoreID: String) async -> [AppleMusicSongRow] {
        guard canContribute else { return [] }
        do {
            var req = MusicCatalogResourceRequest<MusicKit.Album>(matching: \.id, equalTo: MusicItemID(albumStoreID))
            req.limit = 1
            guard let album = try await req.response().items.first else { return [] }
            let detailed = try await album.with([.tracks])
            return (detailed.tracks ?? []).map(Self.row(fromTrack:))
        } catch { return [] }
    }

    // MARK: helpers

    private static func fetchSong(storeID: String) async throws -> MusicKit.Song? {
        var req = MusicCatalogResourceRequest<MusicKit.Song>(matching: \.id, equalTo: MusicItemID(storeID))
        req.limit = 1
        return try await req.response().items.first
    }

    private static func searchSong(term: String) async throws -> MusicKit.Song? {
        var req = MusicCatalogSearchRequest(term: term, types: [MusicKit.Song.self])
        req.limit = 1
        return try await req.response().songs.first
    }

    private static func libraryTerm(title: String?, artist: String?) -> String? {
        let t = (title ?? "").trimmingCharacters(in: .whitespaces)
        let a = (artist ?? "").trimmingCharacters(in: .whitespaces)
        let term = "\(t) \(a)".trimmingCharacters(in: .whitespaces)
        return term.isEmpty ? nil : term
    }

    /// Membership test: search the user's LIBRARY (not the catalog) and look for a
    /// normalized title + compatible-artist hit — the same fuzzy match the crate uses.
    private static func isInLibrary(title: String, artist: String) async -> Bool {
        guard let term = libraryTerm(title: title, artist: artist) else { return false }
        var req = MusicLibrarySearchRequest(term: term, types: [MusicKit.Song.self])
        req.limit = 10
        guard let resp = try? await req.response() else { return false }
        let nt = ShazamCatalogMatch.norm(title)
        let na = ShazamCatalogMatch.norm(artist)
        return resp.songs.contains { s in
            guard ShazamCatalogMatch.norm(s.title) == nt else { return false }
            guard !na.isEmpty else { return true }
            let sa = ShazamCatalogMatch.norm(s.artistName)
            return sa == na || sa.contains(na) || na.contains(sa)
        }
    }

    private static func albumRef(from a: MusicKit.Album) -> AppleMusicAlbumRef {
        let year = a.releaseDate.map { Calendar(identifier: .gregorian).component(.year, from: $0) }
        return AppleMusicAlbumRef(
            storeID: a.id.rawValue,
            title: a.title,
            artist: a.artistName,
            year: year,
            artworkURL: a.artwork?.url(width: 512, height: 512),
            url: a.url)
    }

    private static func row(fromTrack t: Track) -> AppleMusicSongRow {
        AppleMusicSongRow(
            storeID: t.id.rawValue,
            title: t.title,
            artist: t.artistName,
            albumTitle: nil,
            trackNumber: t.trackNumber,
            year: nil,
            durationSeconds: t.duration,
            isExplicit: t.contentRating == .explicit,
            artworkURL: t.artwork?.url(width: 256, height: 256))
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

extension AppleMusicProvider: MusicLibraryContributor {
    var canContribute: Bool { false }
    var canAddToLibrary: Bool { false }
    func resolveForLibrary(storeID: String?, title: String?, artist: String?) async -> AppleMusicResolution? { nil }
    func addSongToLibrary(storeID: String) async throws { throw StreamingError.notConfigured }
    func addAlbumToLibrary(storeID: String) async throws { throw StreamingError.notConfigured }
    func albumTracks(albumStoreID: String) async -> [AppleMusicSongRow] { [] }
}
#endif

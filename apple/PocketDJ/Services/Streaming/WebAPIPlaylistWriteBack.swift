import Foundation

/// macOS's route to a user's Apple Music library playlists.
///
/// WHY THIS EXISTS. `MusicLibrary.add(_:to:)` — the whole basis of
/// `MusicKitPlaylistWriteBackTransport` — is `@available(macOS, unavailable)`, so the Mac has never
/// been able to deliver an add the moment the user makes it. It has always reached Apple Music
/// EVENTUALLY, via the server sync's push at the daily pass, but "eventually" is up to 24 hours and
/// the coverage is narrower: the server push can only send songs whose catalog id the indexer
/// already resolved, whereas an on-device transport can resolve one itself.
///
/// The Apple Music WEB API carries no such platform restriction, and `MusicDataRequest` — which
/// attaches the developer and user tokens for us — is available on macOS (the favorites sync
/// already relies on exactly that). So the Mac gets the same immediate add, through HTTP instead of
/// `MusicLibrary`.
///
/// WHAT IT CANNOT DO, and why `reconcile` fails closed: the Web API's library-playlist surface is
/// CREATE + APPEND ONLY. There is no route that removes a track, reorders one, or deletes a
/// playlist. So on macOS: create ✅ · append ✅ · rename ❌ · remove ❌ · reorder ❌. Removals and
/// reorders need iPhone or Vision Pro, and `reconcile` says so rather than silently doing nothing.

// MARK: - Sender seam

/// The network seam, mirroring `AppleMusicFavoritesTransport`: the real implementation runs every
/// request through `MusicDataRequest`; tests substitute a fake and drive the transport with no
/// account, no entitlement and no network.
///
/// `send` returns the STATUS alongside the body and does not throw on a non-2xx. That shape is
/// deliberate — the status is load-bearing here (a 404 on the tracks route means "empty playlist",
/// not "gone"), and `MusicDataRequest.response()` throws on non-2xx, which would otherwise destroy
/// the distinction before the caller sees it.
@MainActor
protocol AppleMusicWebSender: AnyObject {
    /// Apple Music enabled in this build AND authorized right now.
    var canSend: Bool { get }
    func send(_ request: URLRequest) async throws -> (data: Data, status: Int)
}

// MARK: - Pure request building + parsing (no MusicKit, no main actor)

/// Request builders and response parsers, kept free of MusicKit and of the main actor so they are
/// unit-testable and so a full library decode never lands on the main thread. (`PlaylistWriteBack`
/// is `@MainActor`; decoding a whole library list there is precisely the shape that has caused
/// main-thread hangs in this app before.)
enum AppleMusicWebAPI {

    static let base = "https://api.music.apple.com"

    /// One library playlist as the write-back path cares about it.
    struct LibraryPlaylist: Sendable, Equatable {
        var id: String
        var name: String
        /// `attributes.canEdit`. ABSENT means unknown, and unknown must read as EDITABLE — the
        /// field is documented as optional, and defaulting it to false would filter out every
        /// candidate on exactly the platform this transport exists to serve.
        var canEdit: Bool
    }

    static func libraryPlaylistsRequest(offset: Int = 0, limit: Int = 100) -> URLRequest {
        var c = URLComponents(string: base + "/v1/me/library/playlists")!
        c.queryItems = [.init(name: "limit", value: String(limit)),
                        .init(name: "offset", value: String(offset))]
        return URLRequest(url: c.url!)
    }

    static func playlistTracksRequest(playlistId: String, offset: Int = 0, limit: Int = 100) -> URLRequest {
        var c = URLComponents(string: base + "/v1/me/library/playlists/"
                              + pathEscaped(playlistId) + "/tracks")!
        c.queryItems = [.init(name: "limit", value: String(limit)),
                        .init(name: "offset", value: String(offset))]
        return URLRequest(url: c.url!)
    }

    /// POST the catalog ids onto the playlist. `type: "songs"` (catalog), which also adds the
    /// track to the user's library — the same side effect `MusicLibrary.add` has.
    static func addTracksRequest(playlistId: String, catalogIds: [String]) -> URLRequest {
        var r = URLRequest(url: URL(string: base + "/v1/me/library/playlists/"
                                    + pathEscaped(playlistId) + "/tracks")!)
        r.httpMethod = "POST"
        r.setValue("application/json", forHTTPHeaderField: "Content-Type")
        let body = ["data": catalogIds.map { ["id": $0, "type": "songs"] }]
        r.httpBody = try? JSONSerialization.data(withJSONObject: body)
        return r
    }

    static func storefrontRequest() -> URLRequest {
        URLRequest(url: URL(string: base + "/v1/me/storefront")!)
    }

    static func catalogSearchRequest(storefront: String, term: String, limit: Int = 10) -> URLRequest {
        var c = URLComponents(string: base + "/v1/catalog/" + pathEscaped(storefront) + "/search")!
        c.queryItems = [.init(name: "types", value: "songs"),
                        .init(name: "limit", value: String(limit)),
                        .init(name: "term", value: term)]
        return URLRequest(url: c.url!)
    }

    /// Percent-escape a single path component. Library ids are opaque and have contained `.` and
    /// `-`; escaping keeps a hostile one from splicing extra path segments into the URL.
    static func pathEscaped(_ s: String) -> String {
        s.addingPercentEncoding(withAllowedCharacters: .alphanumerics.union(.init(charactersIn: "-._~"))) ?? s
    }

    // MARK: Parsing

    static func parseLibraryPlaylists(_ data: Data) -> [LibraryPlaylist] {
        guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let rows = root["data"] as? [[String: Any]] else { return [] }
        return rows.compactMap { row in
            guard let id = row["id"] as? String else { return nil }
            let attrs = row["attributes"] as? [String: Any] ?? [:]
            let name = attrs["name"] as? String ?? ""
            // Absent ⇒ editable. See LibraryPlaylist.canEdit.
            let canEdit = attrs["canEdit"] as? Bool ?? true
            return LibraryPlaylist(id: id, name: name, canEdit: canEdit)
        }
    }

    /// A page of playlist tracks: the catalog ids found, AND the raw row count.
    ///
    /// The row count is not bookkeeping — it is the ONLY correct paging terminator. The id set is
    /// deduped and skips rows without `playParams`, so its size can be smaller than the page even
    /// when the page was full. Terminating on the SET size stopped the walk early, and a truncated
    /// membership read is what makes the add path append a duplicate to a real playlist.
    struct TrackPage: Sendable, Equatable {
        var catalogIds: Set<String>
        var rowCount: Int
        /// The API's own "there is more" cursor. Present ⇒ keep going regardless of counts.
        var hasNext: Bool
    }

    /// The CATALOG ids of a library playlist's tracks — the identity the add path dedups on.
    /// A library track carries its catalog id in `attributes.playParams.catalogId`.
    static func parseTrackPage(_ data: Data) -> TrackPage {
        guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let rows = root["data"] as? [[String: Any]] else {
            return TrackPage(catalogIds: [], rowCount: 0, hasNext: false)
        }
        var out: Set<String> = []
        for row in rows {
            let attrs = row["attributes"] as? [String: Any] ?? [:]
            if let pp = attrs["playParams"] as? [String: Any] {
                if let cid = pp["catalogId"] as? String { out.insert(cid) }
                else if let pid = pp["id"] as? String { out.insert(pid) }
            }
        }
        return TrackPage(catalogIds: out, rowCount: rows.count, hasNext: root["next"] != nil)
    }

    /// Convenience for callers that only want the ids (tests, and the tie-break).
    static func parseTrackCatalogIds(_ data: Data) -> Set<String> { parseTrackPage(data).catalogIds }

    static func parseStorefront(_ data: Data) -> String? {
        guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let rows = root["data"] as? [[String: Any]],
              let id = rows.first?["id"] as? String else { return nil }
        return id
    }

    static func parseCatalogSongs(_ data: Data) -> [WriteBackCatalogCandidate] {
        guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let results = root["results"] as? [String: Any],
              let songs = results["songs"] as? [String: Any],
              let rows = songs["data"] as? [[String: Any]] else { return [] }
        return rows.compactMap { row -> WriteBackCatalogCandidate? in
            guard let id = row["id"] as? String else { return nil }
            let a = row["attributes"] as? [String: Any] ?? [:]
            return WriteBackCatalogCandidate(
                id: id,
                title: a["name"] as? String ?? "",
                artist: a["artistName"] as? String ?? "",
                album: a["albumName"] as? String,
                // The API reports milliseconds; the candidate carries seconds.
                durationSec: (a["durationInMillis"] as? Int).map { Double($0) / 1000 })
        }
    }
}

/// The three-tier name match, lifted out of the MusicKit transport so BOTH transports decide
/// "which library playlist is this?" identically. Exact → whitespace-trimmed → case/diacritic
/// folded; the first non-empty tier wins.
enum WriteBackPlaylistMatcher {
    static func candidates(named name: String,
                           in playlists: [AppleMusicWebAPI.LibraryPlaylist]) -> [AppleMusicWebAPI.LibraryPlaylist] {
        let exact = playlists.filter { $0.name == name }
        if !exact.isEmpty { return exact }

        let target = name.trimmingCharacters(in: .whitespacesAndNewlines)
        let trimmed = playlists.filter { $0.name.trimmingCharacters(in: .whitespacesAndNewlines) == target }
        if !trimmed.isEmpty { return trimmed }

        let folded = target.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: nil)
        return playlists.filter {
            $0.name.trimmingCharacters(in: .whitespacesAndNewlines)
                .folding(options: [.caseInsensitive, .diacriticInsensitive], locale: nil) == folded
        }
    }
}

// MARK: - The transport

@MainActor
final class WebAPIPlaylistWriteBackTransport: PlaylistWriteBackTransport {

    private let sender: any AppleMusicWebSender
    private var storefront: String?

    init(sender: any AppleMusicWebSender) { self.sender = sender }

    /// TRUE on macOS: the Web API has no platform restriction. This is what turns a job from
    /// `.notApplicable` ("this device can never do it") into a real delivery.
    var isSupported: Bool { true }
    var canWrite: Bool { sender.canSend }

    private(set) var lastResolutionNote: String?

    // MARK: Resolve

    func resolvePlaylistId(name: String, expectedAppleMusicIds: [String]) async throws -> String? {
        guard canWrite else { throw PlaylistWriteBackError.notAuthorized }
        lastResolutionNote = nil

        let all = try await allLibraryPlaylists()
        let candidates = WriteBackPlaylistMatcher.candidates(named: name, in: all)
            .filter(\.canEdit)
        guard !candidates.isEmpty else { return nil }
        if candidates.count == 1 { return candidates[0].id }

        // Several playlists share the name — break the tie on track overlap, exactly as the
        // MusicKit transport does. `expectedAppleMusicIds` is a SAMPLE, never a membership test.
        let wanted = Set(expectedAppleMusicIds)
        if !wanted.isEmpty {
            var best: (id: String, hits: Int)?
            for c in candidates {
                let hits = (try? await trackCatalogIds(playlistId: c.id).intersection(wanted).count) ?? 0
                if hits > (best?.hits ?? 0) { best = (c.id, hits) }
            }
            if let best, best.hits > 0 { return best.id }
        }
        // No overlap to arbitrate with: this is a GUESS, and the note is what stops a caller from
        // treating it as authoritative (a rename off a guess is unrecoverable).
        lastResolutionNote = "Several Apple Music playlists are called “\(name)” — picked one."
        return candidates[0].id
    }

    // MARK: Write

    func addSong(appleMusicId: String, toPlaylistId playlistId: String) async throws {
        guard canWrite else { throw PlaylistWriteBackError.notAuthorized }

        // IDEMPOTENT DELIVERY, same contract as the MusicKit transport: the POST is not idempotent,
        // so a re-delivery would append a SECOND copy the user has to remove by hand.
        if try await trackCatalogIds(playlistId: playlistId).contains(appleMusicId) { return }

        let (_, status) = try await sender.send(
            AppleMusicWebAPI.addTracksRequest(playlistId: playlistId, catalogIds: [appleMusicId]))
        switch status {
        case 200...299: return
        // Only the POST route's 404 means the playlist is gone. (The GET above deliberately does
        // NOT map 404 that way — see `trackCatalogIds`.)
        case 404: throw PlaylistWriteBackError.playlistGone(playlistId)
        case 401, 403: throw PlaylistWriteBackError.notAuthorized
        default: throw StreamingError.http(status)
        }
    }

    /// `reconcile` is deliberately NOT implemented: the protocol's default returns `.unsupported`,
    /// which is the truth here. The Web API's library-playlist surface is create + append only —
    /// there is no route that removes a track or reorders one — so a Mac must report the capability
    /// as absent rather than silently doing nothing. Removals and reorders need iPhone or Vision Pro.

    // MARK: Catalog resolution

    func resolveCatalogId(for song: WriteBackSong) async throws -> String? {
        guard canWrite else { throw PlaylistWriteBackError.notAuthorized }
        guard !song.title.isEmpty, !song.artist.isEmpty else { return nil }
        let sf = try await currentStorefront()

        let term = "\(song.title) \(song.artist)"
        let (data, status) = try await sender.send(
            AppleMusicWebAPI.catalogSearchRequest(storefront: sf, term: term))
        switch status {
        case 200...299: break
        case 401, 403: throw PlaylistWriteBackError.notAuthorized
        default: throw StreamingError.http(status)
        }
        let candidates = await parse(data, AppleMusicWebAPI.parseCatalogSongs)
        // The SAME pure judge the MusicKit transport uses — so a Mac and an iPhone resolve an
        // identity-only song to the same catalog id rather than to two different ones.
        return WriteBackMatcher.bestMatch(for: song, among: candidates)
    }

    // MARK: - Internals

    private func allLibraryPlaylists() async throws -> [AppleMusicWebAPI.LibraryPlaylist] {
        var out: [AppleMusicWebAPI.LibraryPlaylist] = []
        var offset = 0
        // Bounded: a pathological account can't spin this forever.
        while offset < 5_000 {
            let (data, status) = try await sender.send(
                AppleMusicWebAPI.libraryPlaylistsRequest(offset: offset))
            switch status {
            case 200...299: break
            case 401, 403: throw PlaylistWriteBackError.notAuthorized
            default: throw StreamingError.http(status)
            }
            let page = await parse(data, AppleMusicWebAPI.parseLibraryPlaylists)
            out.append(contentsOf: page)
            if page.count < 100 { break }
            offset += page.count
        }
        return out
    }

    /// Every catalog id in the playlist. COMPLETENESS IS THE POINT: this is the membership read
    /// `addSong` dedups on, and a short read means a duplicate track in the user's real Apple Music
    /// playlist — which macOS then has no route to remove.
    private func trackCatalogIds(playlistId: String) async throws -> Set<String> {
        var out: Set<String> = []
        var offset = 0
        let pageSize = 100
        while offset < Self.maxTracksScanned {
            let (data, status) = try await sender.send(
                AppleMusicWebAPI.playlistTracksRequest(playlistId: playlistId,
                                                       offset: offset, limit: pageSize))
            switch status {
            case 200...299: break
            // A 404 HERE MEANS THE PLAYLIST IS EMPTY, NOT MISSING. Apple returns it for a playlist
            // with no tracks, and the app's own Lambda documents the same. Mapping it to
            // `playlistGone` would brick the very first add to a newly created playlist — the most
            // common case this transport serves.
            case 404: return out
            case 401, 403: throw PlaylistWriteBackError.notAuthorized
            default: throw StreamingError.http(status)
            }
            let page = await parse(data, AppleMusicWebAPI.parseTrackPage)
            out.formUnion(page.catalogIds)
            // Terminate on the ROW count (or the API's own `next` cursor) — never on the id set,
            // which is deduped and drops rows without playParams, so a full page of 100 rows can
            // yield 99 ids and would have ended the walk with tracks unread.
            if !page.hasNext, page.rowCount < pageSize { break }
            offset += page.rowCount
            // A page that returned rows we couldn't advance past would spin forever.
            if page.rowCount == 0 { break }
        }
        return out
    }

    /// Runaway bound on the membership scan — a backstop against a pathological response, not a
    /// policy. It sits above Apple's own library-playlist size limit, so a real playlist reaches
    /// the `next`/short-page terminator long before this. If a playlist ever DID exceed it the scan
    /// would be short and the add could duplicate, which is why the terminator above is the row
    /// count and not this.
    static let maxTracksScanned = 10_000

    /// THROWS on failure rather than returning nil. The distinction matters enormously: the queue
    /// reads a nil from `resolveCatalogId` as the TERMINAL verdict "this song isn't on Apple Music"
    /// and settles the job `.unresolvable` — a state `retry` won't re-arm, so the user has no way
    /// back. Returning nil here for a momentarily expired token or a 5xx would permanently mark a
    /// song that IS on Apple Music as absent. nil is reserved for "we searched and found nothing".
    private func currentStorefront() async throws -> String {
        if let storefront { return storefront }
        let (data, status) = try await sender.send(AppleMusicWebAPI.storefrontRequest())
        switch status {
        case 200...299: break
        case 401, 403: throw PlaylistWriteBackError.notAuthorized
        default: throw StreamingError.http(status)
        }
        guard let sf = AppleMusicWebAPI.parseStorefront(data) else {
            // A 200 we can't read is a transport problem, not an answer about the song.
            throw StreamingError.decoding
        }
        storefront = sf
        return sf
    }

    /// Run a parser OFF the main actor. This type is `@MainActor` (the write-back queue is), and
    /// decoding a full library list or a full playlist's tracks on the main thread is the exact
    /// shape behind this app's past main-thread hangs.
    private func parse<T: Sendable>(_ data: Data,
                                    _ body: @escaping @Sendable (Data) -> T) async -> T {
        await Task.detached(priority: .userInitiated) { body(data) }.value
    }
}

#if canImport(MusicKit)
import MusicKit

/// Production sender. `MusicDataRequest` attaches the developer + user tokens and, unlike
/// `MusicLibrary`'s write methods, carries no macOS-unavailable annotation.
@available(iOS 16.0, macOS 14.0, visionOS 1.0, *)
@MainActor
final class MusicDataRequestSender: AppleMusicWebSender {

    var canSend: Bool {
        AppleMusicCredentials.isEnabled && MusicAuthorization.currentStatus == .authorized
    }

    func send(_ request: URLRequest) async throws -> (data: Data, status: Int) {
        guard canSend else { throw PlaylistWriteBackError.notAuthorized }
        do {
            let response = try await MusicDataRequest(urlRequest: request).response()
            return (response.data, response.urlResponse.statusCode)
        } catch let e as MusicDataRequest.Error {
            // `response()` THROWS on any non-2xx, which would collapse the status distinctions this
            // transport depends on (404-means-empty above all). Recover the real status and body
            // from the error and hand them back as a normal result.
            return (e.originalResponse.data, e.originalResponse.urlResponse.statusCode)
        }
    }
}
#endif

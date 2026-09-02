import Foundation
import Observation

/// Lazily resolves cover art for albums that ship with NO bundled cover (empty
/// `artCandidates`) but DO live in a streaming catalog we can reach — by asking the
/// Apple Music provider for one of the album's tracks' artwork, keyed off the
/// indexer-resolved catalog id (`appleMusicId`) or a namespaced `am:` song id.
///
/// ON-DEMAND ONLY: `CoverImage` calls `artworkURL(forAlbum:candidates:)` from its
/// `.task` when the album is actually on-screen, so nothing is fetched at launch.
/// Results — hits AND misses — are memoized by album id so scrolling back never
/// re-resolves, and an in-flight de-dupe collapses concurrent requests for the same
/// album. When the provider isn't ready (default build / not authorized) it returns
/// nil WITHOUT marking a permanent miss, so it can resolve later once authorized.
@MainActor
@Observable
final class AlbumArtworkStore {
    /// Resolve a single song to its streaming artwork URL. Injected so the cache logic
    /// is unit-testable without MusicKit; the app passes the Apple Music provider.
    typealias Resolver = @MainActor (IndexSong) async -> URL?

    private let ready: @MainActor () -> Bool
    private let resolve: Resolver

    /// album.id → resolved artwork URL (a HIT). Misses go in `missed` so they aren't refetched.
    private var cache: [String: URL] = [:]
    private var missed: Set<String> = []
    private var inFlight: [String: Task<URL?, Never>] = [:]

    init(ready: @escaping @MainActor () -> Bool = { false },
         resolve: @escaping Resolver = { _ in nil }) {
        self.ready = ready
        self.resolve = resolve
    }

    /// The streaming artwork URL for `albumId`, trying each candidate song (a track of the
    /// album carrying a streaming catalog id) until one yields art. Memoized by albumId
    /// (hit + miss); concurrent calls for the same album are de-duped. Returns nil when the
    /// provider isn't ready or no candidate resolves to art.
    func artworkURL(forAlbum albumId: String, candidates: [IndexSong]) async -> URL? {
        if let hit = cache[albumId] { return hit }
        if missed.contains(albumId) { return nil }
        guard ready(), !candidates.isEmpty else { return nil }   // not ready ⇒ retry later (no miss)
        if let task = inFlight[albumId] { return await task.value }

        let resolve = self.resolve
        let task = Task { @MainActor () -> URL? in
            for song in candidates {
                if let url = await resolve(song) { return url }
            }
            return nil
        }
        inFlight[albumId] = task
        let url = await task.value
        inFlight[albumId] = nil
        if let url { cache[albumId] = url } else { missed.insert(albumId) }
        return url
    }

    /// True when `song` carries a streaming catalog id (an indexer-resolved Apple Music
    /// id, or one of our `am:` namespaced ids) — i.e. it's a candidate for art resolution.
    static func hasCatalogID(_ song: IndexSong) -> Bool {
        if let amid = song.appleMusicId, !amid.isEmpty { return true }
        return song.id.hasPrefix("\(AppleMusicCatalog.idPrefix):")
    }

    /// An album's art URLs WITH the streaming fallback — the complete answer, not just the
    /// bundled half. Bundled `artCandidates` when the album ships any; otherwise the memoized
    /// provider resolve above. This is the exact lane `CoverImage` walks, factored out because
    /// the Now Playing cards (both engines) and the CarPlay list rows previously consulted ONLY
    /// `artCandidates` — empty for the entire "Apple Music (Local)" catalog — which is why art
    /// showed in-app but was "usually missing" in the car and on the lock screen.
    func artURLs(for album: IndexAlbum, app: AppModel) async -> [URL] {
        if !album.artCandidates.isEmpty { return album.artCandidates }
        let candidates = album.trackList
            .compactMap { app.songsById[$0] }
            .filter { AlbumArtworkStore.hasCatalogID($0) }
        guard !candidates.isEmpty else { return [] }
        guard let url = await artworkURL(forAlbum: album.id, candidates: candidates) else { return [] }
        return [url]
    }
}

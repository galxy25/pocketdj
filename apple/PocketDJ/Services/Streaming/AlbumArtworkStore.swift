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

    /// album.id → resolved artwork URL (a HIT). Misses go in `missedAt` with a TTL — a resolve
    /// that returned nothing may mean "no art exists" OR "the network blipped", and the two are
    /// indistinguishable at this seam, so a miss is retryable after `missTTL` instead of
    /// artless-for-the-session (which the CarPlay rows and the Now Playing card, both riding
    /// this store since the art-fallback work, would make very visible on a drive that starts
    /// in a garage with no signal).
    private var cache: [String: URL] = [:]
    private var missedAt: [String: Date] = [:]
    /// Instance + internal (not a static let) so tests can shrink it to prove the retry.
    var missTTL: TimeInterval = 10 * 60
    private var inFlight: [String: Task<URL?, Never>] = [:]
    /// Resolves run at most `maxConcurrentResolves` at a time: CarPlay builds every collection
    /// row at connect, and N rows must trickle into MusicKit, not stampede it — but a strict
    /// one-at-a-time chain put the Now Playing card's art MINUTES behind a few hundred queued
    /// rows (head-of-line blocking of exactly the surface the fallback exists for). Bounded
    /// gate + a priority lane: `priority` acquires jump the wait queue, so the card's resolve
    /// runs next even mid-stampede. All @MainActor, so the counters need no locking.
    private static let maxConcurrentResolves = 3
    private var activeResolves = 0
    private var resolveWaiters: [(priority: Bool, cont: CheckedContinuation<Void, Never>)] = []

    private func acquireResolveSlot(priority: Bool) async {
        if activeResolves < Self.maxConcurrentResolves {
            activeResolves += 1
            return
        }
        await withCheckedContinuation { cont in
            if priority { resolveWaiters.insert((true, cont), at: 0) }
            else { resolveWaiters.append((false, cont)) }
        }
        // Resumed by a release — the finishing task's slot transfers, counters untouched.
    }

    private func releaseResolveSlot() {
        if !resolveWaiters.isEmpty {
            resolveWaiters.removeFirst().cont.resume()
        } else {
            activeResolves -= 1
        }
    }

    init(ready: @escaping @MainActor () -> Bool = { false },
         resolve: @escaping Resolver = { _ in nil }) {
        self.ready = ready
        self.resolve = resolve
    }

    /// The streaming artwork URL for `albumId`, trying each candidate song (a track of the
    /// album carrying a streaming catalog id) until one yields art. Memoized by albumId
    /// (hit + miss); concurrent calls for the same album are de-duped. Returns nil when the
    /// provider isn't ready or no candidate resolves to art.
    func artworkURL(forAlbum albumId: String, candidates: [IndexSong],
                    priority: Bool = false) async -> URL? {
        if let hit = cache[albumId] { return hit }
        if let at = missedAt[albumId] {
            guard Date().timeIntervalSince(at) >= missTTL else { return nil }
            missedAt[albumId] = nil               // TTL expired — eligible to retry
        }
        guard ready(), !candidates.isEmpty else { return nil }   // not ready ⇒ retry later (no miss)
        if let task = inFlight[albumId] { return await task.value }

        let resolve = self.resolve
        let task = Task { @MainActor [weak self] () -> URL? in
            await self?.acquireResolveSlot(priority: priority)
            defer { self?.releaseResolveSlot() }
            for song in candidates {
                if let url = await resolve(song) { return url }
            }
            return nil
        }
        inFlight[albumId] = task
        let url = await task.value
        inFlight[albumId] = nil
        if let url { cache[albumId] = url } else { missedAt[albumId] = Date() }
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
    /// `priority: true` is the Now Playing card's lane — it jumps the resolve queue so the
    /// currently-playing track's cover never waits behind a car-connect row stampede.
    func artURLs(for album: IndexAlbum, app: AppModel, priority: Bool = false) async -> [URL] {
        if !album.artCandidates.isEmpty { return album.artCandidates }
        let candidates = album.trackList
            .compactMap { app.songsById[$0] }
            .filter { AlbumArtworkStore.hasCatalogID($0) }
        guard !candidates.isEmpty else { return [] }
        guard let url = await artworkURL(forAlbum: album.id, candidates: candidates,
                                         priority: priority) else { return [] }
        return [url]
    }
}

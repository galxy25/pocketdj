import Foundation
import Observation

#if canImport(MusicKit)
import MusicKit
#endif

/// The "New" tile's engine: what the artists the owner actually plays have released in the last
/// 30 days.
///
/// ── WHY THIS NEEDS THE NETWORK AT ALL ────────────────────────────────────────────────────────
/// The catalog index has ZERO rows carrying a release date — only a coarse `year`. There is no
/// local answer to "did this artist put something out this month", so the feed has to ask Apple.
///
/// ── ONE ENDPOINT, ONE REQUEST SHAPE ──────────────────────────────────────────────────────────
///     GET /v1/catalog/us/artists?ids=<=50&views=latest-release,similar-artists
/// Both views ride the SAME request, so similarity costs nothing extra. 50 ids is a hard cap
/// (100 returns HTTP 400, measured). Concurrency is pinned at 2 with backoff because the edge
/// limiter is bursty — 40 parallel requests returned 24x HTTP 429.
///
/// ── AUTHENTICATION: NO NEW CREDENTIAL ────────────────────────────────────────────────────────
/// `MusicDataRequest` takes an arbitrary `URLRequest` and attaches BOTH the developer token and
/// the Music-User-Token itself (the same trick `AppleMusicFavorites` uses to reach the Web API).
/// So there is no .p8 in the binary, no Lambda, no key to rotate.
///
/// ── PLATFORM DEGRADATION ─────────────────────────────────────────────────────────────────────
/// Everything that touches MusicKit sits behind `#if canImport(MusicKit)` and the transport is
/// injected. On a platform where MusicKit is unavailable the service still compiles, still loads
/// its cache, and simply never fetches — the New tile shows what is cached (or hides itself)
/// rather than the build breaking. `canSync` is the single gate.
///
/// ── REFRESH POLICY: LAZY, ON-PLAY, NEVER SCHEDULED ───────────────────────────────────────────
/// `noteArtistPlayed` is called from the PLAY event and is the ONLY thing that starts a fetch.
/// Nothing here runs on a render path: reading the feed (`newReleases`) is a pure filter over the
/// cache. That is what keeps a scroll from firing HTTP.
///
/// Persists to Application Support `pocketdj-release-feed.json` (the PlayStatsStore durable-JSON
/// pattern: atomic save, decode-on-init, PDJ_USE_FIXTURE seam). This document is PERSONAL — it is
/// derived from the owner's play history and never goes near the shared catalog index.
/// How the feed reaches Apple Music. Injected so the TTL policy and the response parsing are
/// testable with no MusicKit and no network, and so a platform without MusicKit can supply none
/// at all (see the degradation note on `ReleaseFeedService`). File-scope because Swift does not
/// permit a protocol nested inside a type.
protocol ReleaseFeedTransport: Sendable {
    var canSync: Bool { get }
    func fetch(_ request: URLRequest) async throws -> Data
}

@MainActor
@Observable
final class ReleaseFeedService {

    typealias Transport = ReleaseFeedTransport

    struct Document: Codable {
        var schemaVersion = 1
        var entries: [ArtistReleaseEntry] = []
    }

    /// artistId → cached answer.
    private(set) var entries: [Int: ArtistReleaseEntry] = [:]
    private(set) var isFetching = false
    private(set) var lastError: String?
    /// Bumped on every cache mutation so views can memo off it instead of the dictionary.
    private(set) var revision: Int = 0

    @ObservationIgnored private let transport: Transport?
    @ObservationIgnored private let fileURL: URL
    /// Artists whose TTL has expired, waiting to ride the next batch. Keyed by id so repeated
    /// plays of the same artist coalesce into one entry.
    @ObservationIgnored private var pending: [Int: String] = [:]
    @ObservationIgnored private var drainTask: Task<Void, Never>?
    /// Play counts for the TTL math. Injected (rather than held) so this service never has to
    /// know about PlayCountService's capture lifecycle.
    @ObservationIgnored var playsForArtist: ((Int) -> Int)?

    init(transport: Transport? = ReleaseFeedService.defaultTransport(),
         fileURL: URL? = nil) {
        self.transport = transport
        self.fileURL = fileURL ?? Self.defaultFileURL()
        load()
    }

    // ── Reading (pure, render-path safe) ─────────────────────────────────────────────────────

    /// Releases inside the 30-day window, newest first. NO network, no side effects — safe to
    /// call from a view body.
    func newReleases(nowMs: Double = Date().timeIntervalSince1970 * 1000) -> [ArtistReleaseEntry] {
        entries.values
            .filter { e in
                guard let at = e.releaseAtMs else { return false }
                return ReleaseFeedPolicy.isWithinWindow(releaseAtMs: at, nowMs: nowMs)
            }
            .sorted { ($0.releaseAtMs ?? 0) > ($1.releaseAtMs ?? 0) }
    }

    /// Similar-artist ids for a set of artists — the seed for collection suggestions. Reads only
    /// the cache; a cold or stale entry contributes nothing rather than triggering a fetch.
    func similarArtistIds(for artistIds: [Int]) -> [Int] {
        var out: [Int] = []
        var seen = Set(artistIds)
        for id in artistIds {
            for s in entries[id]?.similarArtistIds ?? [] where seen.insert(s).inserted {
                out.append(s)
            }
        }
        return out
    }

    var canSync: Bool { transport?.canSync ?? false }

    // ── The ONLY trigger: a play happened ────────────────────────────────────────────────────

    /// Call from the PLAY event (never from a view body). Enqueues the artist if its TTL has
    /// expired and schedules a batched drain; cheap and non-blocking when nothing is due.
    func noteArtistPlayed(artistId: Int, name: String,
                          nowMs: Double = Date().timeIntervalSince1970 * 1000) {
        guard canSync else { return }
        let plays = playsForArtist?(artistId) ?? 0
        guard ReleaseFeedPolicy.isDue(lastCheckedAtMs: entries[artistId]?.checkedAtMs,
                                      plays: plays, nowMs: nowMs) else { return }
        pending[artistId] = name
        scheduleDrain()
    }

    private func scheduleDrain() {
        guard drainTask == nil else { return }
        drainTask = Task { [weak self] in
            // Let a burst of plays (a set list starting, a shuffle) accumulate into one batch
            // instead of firing a request per song.
            try? await Task.sleep(nanoseconds: 2_000_000_000)
            await self?.drain()
        }
    }

    /// Fetch every pending artist in batches of 50, two requests in flight.
    func drain() async {
        drainTask = nil
        guard let transport, transport.canSync, !pending.isEmpty else { return }
        let due = pending
        pending = [:]
        isFetching = true
        defer { isFetching = false }

        let ids = Array(due.keys)
        var batches: [[Int]] = []
        for i in stride(from: 0, to: ids.count, by: ReleaseFeedPolicy.idsPerRequest) {
            batches.append(Array(ids[i..<min(i + ReleaseFeedPolicy.idsPerRequest, ids.count)]))
        }

        await withTaskGroup(of: [ArtistReleaseEntry].self) { group in
            var next = 0
            var running = 0
            func start(_ batch: [Int]) {
                group.addTask { [transport] in
                    await Self.fetchBatch(batch, transport: transport)
                }
            }
            while next < batches.count && running < ReleaseFeedPolicy.maxConcurrentRequests {
                start(batches[next]); next += 1; running += 1
            }
            while running > 0 {
                guard let result = await group.next() else { break }
                running -= 1
                apply(result, fallbackNames: due)
                if next < batches.count { start(batches[next]); next += 1; running += 1 }
            }
        }
        save()
    }

    /// One batch, with backoff. `nonisolated` + static so the request itself runs off the main
    /// actor — this is network I/O and must never block a frame.
    private nonisolated static func fetchBatch(_ ids: [Int], transport: Transport) async -> [ArtistReleaseEntry] {
        guard !ids.isEmpty else { return [] }
        var comps = URLComponents(string: "https://api.music.apple.com/v1/catalog/us/artists")!
        comps.queryItems = [
            URLQueryItem(name: "ids", value: ids.map(String.init).joined(separator: ",")),
            URLQueryItem(name: "views", value: "latest-release,similar-artists"),
        ]
        guard let url = comps.url else { return [] }
        var req = URLRequest(url: url)
        req.httpMethod = "GET"

        for attempt in 0...4 {
            do {
                let data = try await transport.fetch(req)
                let decoded = try JSONDecoder().decode(ArtistsCatalogResponse.self, from: data)
                return decoded.entries(checkedAtMs: Date().timeIntervalSince1970 * 1000)
            } catch {
                // The transport surfaces 429/5xx as a throw; back off and retry a few times.
                let wait = UInt64(min(30, pow(2.0, Double(attempt))) * 1_000_000_000)
                try? await Task.sleep(nanoseconds: wait)
            }
        }
        return []
    }

    /// Merge fetched entries into the cache. An artist Apple returned NOTHING for still gets its
    /// clock stamped — otherwise an artist with no releases would be re-requested on every single
    /// play forever.
    private func apply(_ fetched: [ArtistReleaseEntry], fallbackNames: [Int: String]) {
        let now = Date().timeIntervalSince1970 * 1000
        var returned = Set<Int>()
        for var e in fetched {
            returned.insert(e.artistId)
            if e.artistName.isEmpty { e.artistName = fallbackNames[e.artistId] ?? "" }
            // Carry a previously-known similar list forward when this response had none, so a
            // sparse answer never erases good data.
            if e.similarArtistIds == nil {
                e.similarArtistIds = entries[e.artistId]?.similarArtistIds
                e.similarCheckedAtMs = entries[e.artistId]?.similarCheckedAtMs
            }
            entries[e.artistId] = e
        }
        for (id, name) in fallbackNames where !returned.contains(id) {
            if var existing = entries[id] {
                existing.checkedAtMs = now
                entries[id] = existing
            } else {
                entries[id] = ArtistReleaseEntry(artistId: id, artistName: name, checkedAtMs: now)
            }
        }
        revision &+= 1
    }

    // ── Durability ───────────────────────────────────────────────────────────────────────────

    private static func defaultFileURL() -> URL {
        let dir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSTemporaryDirectory())
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent("pocketdj-release-feed.json")
    }

    private func load() {
        guard let data = try? Data(contentsOf: fileURL),
              let doc = try? JSONDecoder().decode(Document.self, from: data) else { return }
        entries = Dictionary(doc.entries.map { ($0.artistId, $0) }, uniquingKeysWith: { a, _ in a })
    }

    private func save() {
        let doc = Document(entries: Array(entries.values))
        guard let data = try? JSONEncoder().encode(doc) else { return }
        let tmp = fileURL.appendingPathExtension("tmp")
        do {
            try data.write(to: tmp, options: .atomic)
            _ = try? FileManager.default.replaceItemAt(fileURL, withItemAt: tmp)
        } catch { lastError = error.localizedDescription }
    }

    /// Test seam: drop the pending queue without fetching.
    func resetPendingForTesting() { pending = [:]; drainTask?.cancel(); drainTask = nil }
    /// Test seam: seed the cache directly.
    func seedForTesting(_ list: [ArtistReleaseEntry]) {
        entries = Dictionary(list.map { ($0.artistId, $0) }, uniquingKeysWith: { a, _ in a })
        revision &+= 1
    }
    /// Test seam: how many artists are waiting on a batch.
    var pendingCountForTesting: Int { pending.count }
}

// ============================================================================
// MARK: - MusicKit transport
// ============================================================================

extension ReleaseFeedService {
    /// The real transport where MusicKit exists, nil where it does not — the degradation seam.
    /// `nonisolated` because it is used as a DEFAULT ARGUMENT, which Swift evaluates in the
    /// caller's (non-main-actor) context.
    nonisolated static func defaultTransport() -> Transport? {
        #if canImport(MusicKit)
        return MusicKitCatalogTransport()
        #else
        return nil
        #endif
    }
}

#if canImport(MusicKit)
/// `MusicDataRequest` injects Authorization + Music-User-Token itself, so this carries no
/// credential of its own. Verified available on macOS as well as iOS (the same mechanism
/// `AppleMusicFavorites` already ships on every platform).
struct MusicKitCatalogTransport: ReleaseFeedService.Transport {
    var canSync: Bool {
        AppleMusicCredentials.isEnabled && MusicAuthorization.currentStatus == .authorized
    }

    func fetch(_ request: URLRequest) async throws -> Data {
        guard canSync else { throw StreamingError.notConfigured }
        let response = try await MusicDataRequest(urlRequest: request).response()
        return response.data
    }
}
#endif

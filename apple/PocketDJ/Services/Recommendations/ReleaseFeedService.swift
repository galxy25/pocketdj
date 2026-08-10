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

/// What went wrong reaching the catalog, in the only detail the retry policy actually needs.
///
/// The distinction is load-bearing: 429 and 5xx are worth waiting out, and everything else is
/// not. Retrying a 400 (a malformed id list) or a 401/403 (a revoked or absent Music-User-Token)
/// produces the identical failure five times over while spending budget against a limiter that
/// is already unhappy — and, because a failed batch re-queues, it would do that on every play.
enum ReleaseFeedTransportError: Error, Equatable {
    case http(status: Int)
    /// Apple Music is off, unauthorized, or MusicKit is absent on this platform.
    case unavailable

    /// Whether waiting and asking again could plausibly produce a different answer.
    var isRetryable: Bool {
        switch self {
        case .http(let status): return status == 429 || (500...599).contains(status)
        case .unavailable: return false
        }
    }
}

/// One row of the feed: the cached release plus where it sits relative to today. The status is
/// computed at READ time, never stored — a cached entry silently ages from "coming soon" into
/// "out now" as the calendar moves, and persisting the label would freeze it at whatever it was
/// on the day it was fetched.
struct ReleaseFeedItem: Identifiable, Equatable {
    let entry: ArtistReleaseEntry
    let status: ReleaseStatus
    var id: Int { entry.artistId }

    /// The id a 👍/👎 on this row is filed under.
    ///
    /// A release is not a catalog song — the listener does not own it yet, which is the whole
    /// point of the tile — so it has no `IndexSong.id` to key on. The RELEASE's Apple store id is
    /// used when there is one (a verdict then follows the record, not the artist), and the artist
    /// otherwise, which is the only identity a releaseless row has. The `rel:` / `relartist:`
    /// prefixes keep these out of the same namespace as song ids, so a rejected release can never
    /// collide with a rejected song.
    var feedbackId: String {
        entry.releaseId.map { "rel:\($0)" } ?? "relartist:\(entry.artistId)"
    }
}

@MainActor
@Observable
final class ReleaseFeedService {

    typealias Transport = ReleaseFeedTransport

    struct Document: Codable {
        var schemaVersion = 1
        var entries: [ArtistReleaseEntry] = []
        /// When the ONE-SHOT listening seed ran. ADDITIVE-OPTIONAL: a document written before the
        /// seed existed decodes to nil and is treated as "never seeded", which is exactly right —
        /// that is the install the owner reported as "my new tile is still empty".
        var seededAtMs: Double?

        init(schemaVersion: Int = 1, entries: [ArtistReleaseEntry] = [], seededAtMs: Double? = nil) {
            self.schemaVersion = schemaVersion; self.entries = entries; self.seededAtMs = seededAtMs
        }

        enum CodingKeys: String, CodingKey { case schemaVersion, entries, seededAtMs }

        init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            schemaVersion = (try? c.decode(Int.self, forKey: .schemaVersion)) ?? 1
            entries = (try? c.decode([ArtistReleaseEntry].self, forKey: .entries)) ?? []
            seededAtMs = try? c.decode(Double.self, forKey: .seededAtMs)
        }
    }

    /// artistId → cached answer.
    private(set) var entries: [Int: ArtistReleaseEntry] = [:]
    private(set) var isFetching = false
    private(set) var lastError: String?
    /// Bumped on every cache mutation so views can memo off it instead of the dictionary.
    private(set) var revision: Int = 0
    /// The one-shot seed is queued or in flight — the tile says "Checking…" instead of "empty".
    private(set) var isSeeding = false
    /// When the seed ran (nil ⇒ never). Persisted, so it does NOT repeat on every launch.
    private(set) var seededAtMs: Double?

    @ObservationIgnored private let transport: Transport?
    @ObservationIgnored private let fileURL: URL
    /// Artists whose TTL has expired, waiting to ride the next batch. Keyed by id so repeated
    /// plays of the same artist coalesce into one entry.
    @ObservationIgnored private var pending: [Int: String] = [:]
    @ObservationIgnored private var drainTask: Task<Void, Never>?
    /// Play counts for the TTL math. Injected (rather than held) so this service never has to
    /// know about PlayCountService's capture lifecycle.
    @ObservationIgnored var playsForArtist: ((Int) -> Int)?

    /// Does the local catalog ALREADY have this release? Takes the release's Apple Music ALBUM
    /// store id. Injected at composition (see `ReleaseFeedService.ownershipProbe`) so the service
    /// stays free of any dependency on the catalog.
    ///
    /// Unset means "assume nothing is owned" — the honest default for a cold launch, where the
    /// catalog has not finished loading and answering "owned" would silently empty the feed.
    @ObservationIgnored var ownsRelease: ((String) -> Bool)?

    /// Scales EVERY wall-clock wait in this service — the burst-coalescing debounce and each
    /// backoff sleep. 1 in production; tests set it near zero so a full retry sequence (and the
    /// drain scheduling that rides on it) runs in milliseconds instead of the ~30 s the real
    /// schedule takes. Scaling both is what makes the drain-scheduling path testable at all.
    @ObservationIgnored private let timeScale: Double

    /// How long a play waits before its drain runs, so a burst (a set list starting, a shuffle)
    /// coalesces into one batch instead of firing a request per song.
    @ObservationIgnored static let drainDebounceSeconds: Double = 2

    init(transport: Transport? = ReleaseFeedService.defaultTransport(),
         fileURL: URL? = nil,
         timeScale: Double = 1) {
        self.transport = transport
        self.fileURL = fileURL ?? Self.launchURL()
        self.timeScale = timeScale
        load()
    }

    // ── Reading (pure, render-path safe) ─────────────────────────────────────────────────────

    /// The feed: everything inside the window, classified, newest first, with anything the owner
    /// ALREADY HAS removed. NO network, no side effects — safe to call from a view body.
    ///
    /// Ownership exclusion happens HERE rather than at fetch time on purpose. What he owns
    /// changes constantly (every add, every rip), while the fetched release does not; filtering
    /// on read means an album he adds today drops out of the feed immediately, with no refetch
    /// and no cache invalidation. It also means the exclusion cannot go stale in a stored record.
    func feed(nowMs: Double = Date().timeIntervalSince1970 * 1000) -> [ReleaseFeedItem] {
        entries.values
            .compactMap { e -> ReleaseFeedItem? in
                guard let at = e.releaseAtMs,
                      let status = ReleaseFeedPolicy.classify(releaseAtMs: at, nowMs: nowMs)
                else { return nil }
                // A release with no store id cannot be matched against the catalog OR opened,
                // so it is not offered — there is nothing the owner could do with the row.
                guard let releaseId = e.releaseId else { return nil }
                guard !(ownsRelease?(releaseId) ?? false) else { return nil }
                return ReleaseFeedItem(entry: e, status: status)
            }
            .sorted { ($0.entry.releaseAtMs ?? 0) > ($1.entry.releaseAtMs ?? 0) }
    }

    /// Already out, within the window — newest first.
    func outNow(nowMs: Double = Date().timeIntervalSince1970 * 1000) -> [ReleaseFeedItem] {
        feed(nowMs: nowMs).filter { $0.status == .outNow }
    }

    /// Future-dated pre-releases. Sorted SOONEST first — the opposite of `outNow`, because for
    /// something that has not happened yet "next" is the useful ordering, not "furthest away".
    func comingSoon(nowMs: Double = Date().timeIntervalSince1970 * 1000) -> [ReleaseFeedItem] {
        feed(nowMs: nowMs).filter { $0.status == .comingSoon }
            .sorted { ($0.entry.releaseAtMs ?? 0) < ($1.entry.releaseAtMs ?? 0) }
    }

    /// Releases inside the 30-day window, newest first. NO network, no side effects — safe to
    /// call from a view body. Retained as the flat projection the tile's COUNT reads.
    func newReleases(nowMs: Double = Date().timeIntervalSince1970 * 1000) -> [ArtistReleaseEntry] {
        feed(nowMs: nowMs).map(\.entry)
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

    // ── FIRST POPULATION: the one-shot listening seed ────────────────────────────────────────

    /// Has the seed still to run? True only on an install that has never seeded AND has nothing
    /// cached — so it fires once, ever, on a cold feed.
    var needsSeed: Bool { seededAtMs == nil && entries.isEmpty }

    /// SEED THE FEED FROM THE LAST 30 DAYS OF LISTENING. Owner, verbatim: *"it should use the last
    /// 30 days of my listening history to give me new suggestions by default."*
    ///
    /// ── WHY THIS IS NOT A CONTRADICTION OF THE LAZY RULE ─────────────────────────────────────
    /// `noteArtistPlayed` stays the only STEADY-STATE trigger, and there is still no schedule and
    /// no polling. The lazy rule exists so the app never sweeps 12,600 artists on a timer; it was
    /// never meant to govern FIRST POPULATION, and using it for that is what left the New tile
    /// blank for weeks — with only 15–22% of artists having a release in any 30-day window, an
    /// empty cache stays empty until enough DIFFERENT artists happen to be played.
    ///
    /// ── WHY THE SEED SET IS "PLAYED IN THE LAST 30 DAYS" AND NOT "TOP BY PLAY COUNT" ─────────
    /// The feed exists to surface new records by the artists he is listening to NOW. It is also
    /// naturally bounded — a month of his log is ~493 distinct artists, i.e. ~10 batched requests
    /// at 50 ids each, which is a handful of requests and not a poll.
    ///
    /// One shot, whatever the outcome: `seededAtMs` is stamped and PERSISTED before the fetch, so
    /// a failed seed rides the ordinary re-queue/retry path rather than re-seeding every launch.
    ///
    /// - Returns: whether a fetch was actually queued.
    @discardableResult
    func seedFromRecentListening(artists: [(id: Int, name: String)],
                                 nowMs: Double = Date().timeIntervalSince1970 * 1000) -> Bool {
        guard needsSeed else { return false }
        // NOT gated on `canSync` before the stamp: an unauthorized install must be free to seed
        // the moment Apple Music is turned on, so leave `seededAtMs` nil and try again later.
        guard canSync else { return false }
        seededAtMs = nowMs
        for a in artists where entries[a.id] == nil { pending[a.id] = a.name }
        save()
        guard !pending.isEmpty else { return false }
        isSeeding = true
        revision &+= 1
        scheduleDrain()
        return true
    }

    /// WHY THE TILE IS EMPTY — so it can say which it is instead of rendering blank. An empty tile
    /// that cannot explain itself reads as a broken feature, which is exactly what happened here.
    enum EmptyReason: Equatable {
        /// The one-shot seed (or a batch) is in flight.
        case checking
        /// Apple Music is off, unauthorized, or MusicKit is absent on this platform.
        case notAuthorized
        /// The last attempt failed — offline, rate-limited, token revoked.
        case unreachable(String)
        /// Nothing has ever been checked (seed not yet run: no plays, or catalog not loaded).
        case notCheckedYet
        /// Checked, and the artists he plays genuinely released nothing inside the window.
        case nothingNew

        /// The TILE CARD's one-line version (the screen behind it gets the full explanation). nil
        /// for `nothingNew` — that is the state the card's own wording already describes correctly,
        /// and replacing it would be noise.
        var tileNote: String? {
            switch self {
            case .checking:      return "Checking for new releases…"
            case .notAuthorized: return "Apple Music isn’t connected"
            case .unreachable:   return "Couldn’t reach Apple Music"
            case .notCheckedYet: return "Play something to start checking"
            case .nothingNew:    return nil
            }
        }
    }

    func emptyReason() -> EmptyReason {
        if isSeeding || isFetching { return .checking }
        if !canSync { return .notAuthorized }
        if let e = lastError { return .unreachable(e) }
        if entries.isEmpty { return .notCheckedYet }
        return .nothingNew
    }

    // ── The ONLY steady-state trigger: a play happened ───────────────────────────────────────

    /// Call from the PLAY event (never from a view body). Enqueues the artist if its TTL has
    /// expired and schedules a batched drain; cheap and non-blocking when nothing is due.
    func noteArtistPlayed(artistId: Int, name: String,
                          nowMs: Double = Date().timeIntervalSince1970 * 1000) {
        guard canSync else { return }
        let plays = playsForArtist?(artistId) ?? 0
        if ReleaseFeedPolicy.isDue(lastCheckedAtMs: entries[artistId]?.checkedAtMs,
                                   plays: plays, nowMs: nowMs) {
            pending[artistId] = name
        }
        // Drain whenever ANYTHING is queued, not only when THIS artist was the one that queued
        // it. A batch that failed earlier put its ids back; if the retry rode only on a due
        // artist, a queue made entirely of re-queued ids would stall until one of them happened
        // to be played again — which for a once-a-year artist is indistinguishable from lost.
        if !pending.isEmpty { scheduleDrain() }
    }

    /// Arm the debounced drain, unless one is already armed OR already running.
    ///
    /// ── WHY `!isFetching` IS PART OF THE GUARD (load-bearing) ────────────────────────────────
    /// `maxConcurrentRequests` is 2, but that budget is spent INSIDE one `drain()`. This guard is
    /// therefore the only thing making the cap GLOBAL. It used to test `drainTask == nil` alone
    /// while `drain()` released its handle on ENTRY — so every play landing during a drain armed
    /// a second one beside it, each with its own pair of requests.
    ///
    /// That path is not exotic; it is the 429 path itself. A failed batch re-queues, the re-queue
    /// rides the next play, and a drain sleeping through five backoff attempts holds the window
    /// open for tens of seconds — so the fan-out multiplies exactly when the limiter is already
    /// refusing, and nothing bounds how many drains stack up. MEASURED on the unguarded code: two
    /// overlapping drains reached 4 in flight, and a 429 storm with plays still arriving reached
    /// **12** — six times the cap that was chosen because 40-way fan-out returned 24x HTTP 429.
    ///
    /// Nothing is lost by not arming: a drain that finishes cleanly re-arms itself for whatever
    /// was queued while it ran (see the tail of `drain()`).
    private func scheduleDrain() {
        guard drainTask == nil, !isFetching else { return }
        let wait = Self.drainDebounceSeconds * timeScale
        drainTask = Task { [weak self] in
            // Let a burst of plays (a set list starting, a shuffle) accumulate into one batch
            // instead of firing a request per song.
            try? await Task.sleep(nanoseconds: UInt64(max(0, wait) * 1_000_000_000))
            await self?.drain()
        }
    }

    /// Fetch every pending artist in batches of 50, two requests in flight — and never beside
    /// another drain (`isFetching` is the reentrancy guard, which also keeps that flag honest for
    /// the UI: with overlapping drains the first one to finish cleared it while the other was
    /// still working).
    func drain() async {
        guard !isFetching else { return }
        drainTask = nil
        let allSucceeded = await runDrainPass()
        // The seed is over once its batches have been through, whatever they returned — the tile
        // must stop saying "Checking…" and start saying which empty state it is really in.
        if isSeeding, pending.isEmpty || !allSucceeded { isSeeding = false; revision &+= 1 }
        // Plays that landed WHILE the pass was in flight are still queued — re-arm for them, so a
        // play during a drain is not stranded until the next unrelated play happens along.
        //
        // ONLY on a clean pass. A failed batch re-queues its own ids, so re-arming there would
        // spin against an outage instead of riding the next play — which is the lazy trigger the
        // whole feature runs on, and the reason `apply` deliberately does not reschedule either.
        if allSucceeded, !pending.isEmpty { scheduleDrain() }
    }

    /// One pass over the queue. Returns whether EVERY batch came back — the caller uses that to
    /// decide whether re-arming is safe. Separated from `drain()` so `isFetching` is already back
    /// to false (via the `defer`) by the time the re-arm decision is made.
    private func runDrainPass() async -> Bool {
        guard let transport, transport.canSync, !pending.isEmpty else { return false }
        let due = pending
        pending = [:]
        isFetching = true
        defer { isFetching = false }

        let ids = Array(due.keys)
        var batches: [[Int]] = []
        for i in stride(from: 0, to: ids.count, by: ReleaseFeedPolicy.idsPerRequest) {
            batches.append(Array(ids[i..<min(i + ReleaseFeedPolicy.idsPerRequest, ids.count)]))
        }

        var allSucceeded = true
        await withTaskGroup(of: BatchOutcome.self) { group in
            var next = 0
            var running = 0
            func start(_ batch: [Int]) {
                group.addTask { [transport, timeScale] in
                    await Self.fetchBatch(batch, transport: transport, timeScale: timeScale)
                }
            }
            while next < batches.count && running < ReleaseFeedPolicy.maxConcurrentRequests {
                start(batches[next]); next += 1; running += 1
            }
            while running > 0 {
                guard let outcome = await group.next() else { break }
                running -= 1
                if !outcome.succeeded { allSucceeded = false }
                apply(outcome, fallbackNames: due)
                if next < batches.count { start(batches[next]); next += 1; running += 1 }
            }
        }
        save()
        return allSucceeded
    }

    /// What one batch came back with, and — critically — whether it came back AT ALL.
    ///
    /// An empty `entries` is ambiguous on its own: it is what Apple returns for fifty artists who
    /// genuinely have no releases, and it is also what five failed attempts leave behind. Those
    /// two cases must be handled in OPPOSITE ways, so the distinction is carried explicitly
    /// rather than inferred from the count.
    private struct BatchOutcome: Sendable {
        let ids: [Int]
        let entries: [ArtistReleaseEntry]
        let succeeded: Bool
    }

    /// One batch, with backoff. `nonisolated` + static so the request itself runs off the main
    /// actor — this is network I/O and must never block a frame.
    private nonisolated static func fetchBatch(_ ids: [Int], transport: Transport,
                                               timeScale: Double) async -> BatchOutcome {
        func failed() -> BatchOutcome { BatchOutcome(ids: ids, entries: [], succeeded: false) }
        guard !ids.isEmpty else { return BatchOutcome(ids: ids, entries: [], succeeded: true) }
        var comps = URLComponents(string: "https://api.music.apple.com/v1/catalog/us/artists")!
        comps.queryItems = [
            URLQueryItem(name: "ids", value: ids.map(String.init).joined(separator: ",")),
            URLQueryItem(name: "views", value: "latest-release,similar-artists"),
        ]
        guard let url = comps.url else { return failed() }
        var req = URLRequest(url: url)
        req.httpMethod = "GET"

        let maxAttempts = 5
        for attempt in 0..<maxAttempts {
            do {
                let data = try await transport.fetch(req)
                let decoded = try JSONDecoder().decode(ArtistsCatalogResponse.self, from: data)
                // EVERY field of the wire model is optional, so an error envelope — or any body
                // that simply isn't this endpoint's — decodes "successfully" into `data == nil`.
                // Treating that as a good answer is the cache-poisoning path: it would stamp
                // fifty artists' TTL clocks off a response that contained no artists at all.
                guard decoded.data != nil else { return failed() }
                return BatchOutcome(ids: ids,
                                    entries: decoded.entries(checkedAtMs: Date().timeIntervalSince1970 * 1000),
                                    succeeded: true)
            } catch {
                let retryable = (error as? ReleaseFeedTransportError)?.isRetryable
                    ?? (error is URLError)   // offline / timeout: transient by nature
                guard retryable, attempt < maxAttempts - 1 else { return failed() }
                // Exponential, plus jitter: the two in-flight batches hit the same limiter, so
                // an unjittered schedule would put them to sleep and wake them in lockstep —
                // reproducing the burst that caused the 429 in the first place.
                let base = min(30, pow(2.0, Double(attempt + 1)))
                let wait = (base + Double.random(in: 0...(base / 2))) * timeScale
                try? await Task.sleep(nanoseconds: UInt64(max(0, wait) * 1_000_000_000))
            }
        }
        return failed()
    }

    /// Merge one batch into the cache.
    ///
    /// On SUCCESS an artist Apple returned nothing for still gets its clock stamped — otherwise
    /// an artist with no releases would be re-requested on every single play, forever.
    ///
    /// On FAILURE nothing is stamped and the ids go back on the queue. Stamping a failed batch
    /// would be the worst outcome available: a few seconds offline would mark up to fifty artists
    /// "checked" and blind the feed to their releases for as long as fourteen days, with no error
    /// anywhere and nothing to retry against.
    private func apply(_ outcome: BatchOutcome, fallbackNames: [Int: String]) {
        guard outcome.succeeded else {
            for id in outcome.ids { pending[id] = fallbackNames[id] ?? entries[id]?.artistName ?? "" }
            // Deliberately does NOT reschedule a drain. Re-arming here would spin against an
            // outage; the queue instead rides the next play event, which is the same lazy
            // trigger the whole feature runs on.
            lastError = "Couldn't check \(outcome.ids.count) artists for new releases."
            return
        }
        lastError = nil
        let now = Date().timeIntervalSince1970 * 1000
        var returned = Set<Int>()
        for var e in outcome.entries {
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
        // ONLY this batch's ids. Walking the whole due set here would let the first batch to
        // return stamp the clocks of artists belonging to batches still in flight — and if one of
        // those then failed, its artists would already be marked "checked" by a request that
        // never asked about them.
        for id in outcome.ids where !returned.contains(id) {
            if var existing = entries[id] {
                existing.checkedAtMs = now
                entries[id] = existing
            } else {
                entries[id] = ArtistReleaseEntry(artistId: id,
                                                 artistName: fallbackNames[id] ?? "",
                                                 checkedAtMs: now)
            }
        }
        revision &+= 1
    }

    // ── Durability ───────────────────────────────────────────────────────────────────────────

    /// `nonisolated` because `launchURL()` (also nonisolated, so it can be used as a default
    /// argument) calls it: pure filesystem work touching no actor state. Mirrors
    /// `PlayStatsStore.defaultURL`.
    private nonisolated static func defaultFileURL() -> URL {
        let dir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSTemporaryDirectory())
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent("pocketdj-release-feed.json")
    }

    /// Under UI tests use an isolated, freshly-cleared file, so a run starts from a COLD cache
    /// and never reads (or writes) the real one. Mirrors `PlayStatsStore.launchURL`.
    ///
    /// This matters more here than for most stores: the feed's whole observable behaviour is
    /// "what is cached", so a leftover document from a previous run would make an assertion about
    /// the New tile pass or fail on yesterday's network rather than on the code under test.
    nonisolated static func launchURL() -> URL {
        if ProcessInfo.processInfo.environment["PDJ_USE_FIXTURE"] != nil {
            let url = FileManager.default.temporaryDirectory
                .appendingPathComponent("pdj-uitest-release-feed.json")
            try? FileManager.default.removeItem(at: url)
            return url
        }
        return defaultFileURL()
    }

    private func load() {
        guard let data = try? Data(contentsOf: fileURL),
              let doc = try? JSONDecoder().decode(Document.self, from: data) else { return }
        entries = Dictionary(doc.entries.map { ($0.artistId, $0) }, uniquingKeysWith: { a, _ in a })
        seededAtMs = doc.seededAtMs
    }

    private func save() {
        let doc = Document(entries: Array(entries.values), seededAtMs: seededAtMs)
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

    /// The ownership probe, composed against the live catalog: given a release's Apple Music
    /// ALBUM store id, does the owner already have that album?
    ///
    /// Two routes, matching `AlbumPreviewView.catalogAlbum` exactly:
    ///   • a real indexed album claims that Apple Music id (`albumId(forAppleMusicId:)`), or
    ///   • the provisional `amrec_album_<id>` an earlier Discover/recognizer add synthesized.
    /// Both are O(1) — the revision-keyed memo and a dictionary hit — so this is cheap enough to
    /// run per row on the render path, which is where the feed applies it.
    ///
    /// Built as a CLOSURE over the app model rather than a stored reference: the service must not
    /// hold the catalog, and a closure keeps the dependency one-directional and easy to stub.
    @MainActor
    static func ownershipProbe(app: AppModel) -> (String) -> Bool {
        { [weak app] albumStoreId in
            guard let app else { return false }
            let adHocId = "amrec_album_\(albumStoreId)"
            // Minimal singleton sets, never the whole catalog's ids — building an O(90k) set per
            // row is the collections-perf trap, and the predicate only ever asks about this one.
            let provisional: Set<String> = app.albumsById[adHocId] != nil ? [adHocId] : []
            let claimed: Set<String> = app.albumId(forAppleMusicId: albumStoreId) != nil
                ? [albumStoreId] : []
            return AlbumOwnership.owns(storeID: albumStoreId,
                                       catalogSongIds: provisional,
                                       catalogAppleMusicIds: claimed,
                                       // An ALBUM is never in the rips manifest — that is keyed by
                                       // song. Per-track rips are covered by the album already
                                       // being in the catalog, which is what a rip produces.
                                       rippedSongIds: [],
                                       adHocPrefix: "amrec_album_")
        }
    }

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
        guard canSync else { throw ReleaseFeedTransportError.unavailable }
        do {
            let response = try await MusicDataRequest(urlRequest: request).response()
            return response.data
        } catch let error as MusicDataRequest.Error {
            // MusicDataRequest throws on non-2xx and carries the status. Translating it here is
            // what lets the retry policy tell "slow down" (429) from "this will never work"
            // (401/403 — token revoked; 400 — bad id list).
            throw ReleaseFeedTransportError.http(status: error.status)
        }
    }
}
#endif

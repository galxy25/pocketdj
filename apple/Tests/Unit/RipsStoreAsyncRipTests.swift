import XCTest
@testable import PocketDJ

/// Tests for the rip-on-demand client's WRITE paths (the parts driven by a server):
///   • Feature 1 — `requestRipIfNeeded` is the fire-and-forget async rip. It must be
///     idempotent at the cheap MainActor layer (cached / in-flight / already-requesting
///     short-circuits, no network), single-flight under concurrent calls (the synchronous
///     `requesting` guard collapses near-simultaneous calls to one POST), and NEVER throw.
///   • Feature 2 RIP — `ripCollection` decodes the batch envelope + counts, records
///     queued/inflight jobs, and on a 404 falls back to a per-song loop whose counts use
///     the SAME ready/queued/inflight/unknown buckets (GAP 4).
///
/// A `RecordingURLProtocol` seam stands in for the iMac rip server: it counts requests
/// per path and serves a scripted JSON body (optionally a 404) so no real network is hit.
@MainActor
final class RipsStoreAsyncRipTests: XCTestCase {
    private let ripsBase = URL(string: "https://rips.test")!

    override func setUp() {
        super.setUp()
        RecordingURLProtocol.reset()
    }

    // MARK: Helpers — a RipsStore wired to the stub session + a configured server URL.

    private func makeStore(serverURL: String = "https://imac.test", ripFromCloud: Bool = false) -> RipsStore {
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [RecordingURLProtocol.self]
        let rips = RipsStore(ripsBase: ripsBase, session: URLSession(configuration: config))
        let settings = SettingsStore(defaults: UserDefaults(suiteName: "test.\(UUID().uuidString)")!)
        settings.ripServerURL = serverURL
        settings.ripToken = ""
        settings.ripFromCloud = ripFromCloud
        rips.settings = settings
        return rips
    }

    // MARK: F1 — cheap idempotency short-circuits (NO network)

    func testRequestRipIfNeededSkipsWhenCached() async {
        let rips = makeStore()
        rips.setManifest(["sng_1": .init(key: "rips/sng_1.mp3")])
        await rips.requestRipIfNeeded("sng_1")
        XCTAssertEqual(RecordingURLProtocol.count(path: "/rip"), 0, "cached song must not POST /rip")
    }

    func testRequestRipIfNeededSkipsWhenNoServer() async {
        let rips = makeStore(serverURL: "")   // no rip server configured
        await rips.requestRipIfNeeded("sng_1")
        XCTAssertEqual(RecordingURLProtocol.count(path: "/rip"), 0)
    }

    func testRequestRipIfNeededFiresPostAndRecordsJob() async {
        let rips = makeStore()
        RecordingURLProtocol.body = Data(#"{"jobId":"job_1","songId":"sng_1","phase":"queued"}"#.utf8)
        await rips.requestRipIfNeeded("sng_1")
        XCTAssertEqual(RecordingURLProtocol.count(path: "/rip"), 1)
        XCTAssertEqual(rips.jobs["sng_1"]?.phase, .queued)
        XCTAssertEqual(rips.jobs["sng_1"]?.jobId, "job_1")
    }

    func testRequestRipIfNeededSkipsWhenJobInFlight() async {
        let rips = makeStore()
        RecordingURLProtocol.body = Data(#"{"jobId":"job_1","songId":"sng_1","phase":"ripping"}"#.utf8)
        await rips.requestRipIfNeeded("sng_1")              // first POST → job becomes .ripping
        XCTAssertEqual(RecordingURLProtocol.count(path: "/rip"), 1)
        await rips.requestRipIfNeeded("sng_1")              // in-flight phase → cheap skip
        XCTAssertEqual(RecordingURLProtocol.count(path: "/rip"), 1, "in-flight job must not re-POST")
    }

    /// Concurrent calls for the same song collapse to a single POST via the synchronous
    /// `requesting` guard (inserted BEFORE the first await). The stub delays its response
    /// so all callers are mid-flight when the guard is consulted.
    func testRequestRipIfNeededIsSingleFlightUnderConcurrency() async {
        let rips = makeStore()
        RecordingURLProtocol.body = Data(#"{"jobId":"job_1","songId":"sng_hot","phase":"queued"}"#.utf8)
        RecordingURLProtocol.responseDelayMs = 50

        await withTaskGroup(of: Void.self) { group in
            for _ in 0..<8 { group.addTask { await rips.requestRipIfNeeded("sng_hot") } }
        }
        XCTAssertEqual(RecordingURLProtocol.count(path: "/rip"), 1,
                       "8 concurrent calls for the same song must fire exactly one POST")
    }

    /// Distinct songs are NOT collapsed — the guard is per-song.
    func testRequestRipIfNeededDistinctSongsEachPost() async {
        let rips = makeStore()
        RecordingURLProtocol.body = Data(#"{"jobId":"j","phase":"queued"}"#.utf8)
        await withTaskGroup(of: Void.self) { group in
            for i in 0..<5 { group.addTask { await rips.requestRipIfNeeded("sng_\(i)") } }
        }
        XCTAssertEqual(RecordingURLProtocol.count(path: "/rip"), 5)
    }

    /// Fire-and-forget contract: a server error / non-2xx is swallowed (never throws),
    /// and leaves no job recorded so a later call can retry.
    func testRequestRipIfNeededSwallowsServerError() async {
        let rips = makeStore()
        RecordingURLProtocol.statusCode = 500
        RecordingURLProtocol.body = Data("boom".utf8)
        await rips.requestRipIfNeeded("sng_1")             // must not throw / crash
        XCTAssertNil(rips.jobs["sng_1"], "a failed request records no job")
        // The requesting guard is released on failure, so a retry is allowed.
        RecordingURLProtocol.statusCode = 200
        RecordingURLProtocol.body = Data(#"{"jobId":"job_2","phase":"queued"}"#.utf8)
        await rips.requestRipIfNeeded("sng_1")
        XCTAssertEqual(rips.jobs["sng_1"]?.jobId, "job_2")
    }

    // MARK: ripFromCloud flag in the POST body (omitted off, present on)

    func testRequestRipIfNeededOmitsCloudFlagWhenOff() async {
        let rips = makeStore(ripFromCloud: false)
        RecordingURLProtocol.body = Data(#"{"jobId":"job_1","phase":"queued"}"#.utf8)
        await rips.requestRipIfNeeded("sng_1")
        let sent = RecordingURLProtocol.lastBodyJSON(path: "/rip")
        XCTAssertEqual(sent?["songId"] as? String, "sng_1")
        XCTAssertNil(sent?["ripFromCloud"], "flag omitted when off (older-server compat)")
    }

    func testRequestRipIfNeededSendsCloudFlagWhenOn() async {
        let rips = makeStore(ripFromCloud: true)
        RecordingURLProtocol.body = Data(#"{"jobId":"job_1","phase":"queued"}"#.utf8)
        await rips.requestRipIfNeeded("sng_1")
        let sent = RecordingURLProtocol.lastBodyJSON(path: "/rip")
        XCTAssertEqual(sent?["songId"] as? String, "sng_1")
        XCTAssertEqual(sent?["ripFromCloud"] as? Bool, true)
    }

    func testRipCollectionSendsCloudFlagWhenOn() async {
        let rips = makeStore(ripFromCloud: true)
        RecordingURLProtocol.bodyByPath["/rip-collection"] = Data("""
        { "results": [], "counts": { "ready": 0, "queued": 0, "inflight": 0, "unknown": 0, "total": 0 } }
        """.utf8)
        _ = await rips.ripCollection(["sng_1", "sng_2"])
        let sent = RecordingURLProtocol.lastBodyJSON(path: "/rip-collection")
        XCTAssertEqual(sent?["songIds"] as? [String], ["sng_1", "sng_2"])
        XCTAssertEqual(sent?["ripFromCloud"] as? Bool, true)
    }

    func testRipCollectionOmitsCloudFlagWhenOff() async {
        let rips = makeStore(ripFromCloud: false)
        RecordingURLProtocol.bodyByPath["/rip-collection"] = Data("""
        { "results": [], "counts": { "ready": 0, "queued": 0, "inflight": 0, "unknown": 0, "total": 0 } }
        """.utf8)
        _ = await rips.ripCollection(["sng_1"])
        let sent = RecordingURLProtocol.lastBodyJSON(path: "/rip-collection")
        XCTAssertNil(sent?["ripFromCloud"], "flag omitted when off")
    }

    // MARK: Feature 2 RIP — ripCollection batch path

    func testRipCollectionEmptyIsNoOp() async {
        let rips = makeStore()
        let result = await rips.ripCollection([])
        XCTAssertEqual(result, RipsStore.BatchRipResult())
        XCTAssertEqual(RecordingURLProtocol.count(path: "/rip-collection"), 0)
    }

    func testRipCollectionDecodesBatchEnvelopeAndCounts() async {
        let rips = makeStore()
        RecordingURLProtocol.bodyByPath["/rip-collection"] = Data("""
        {
          "results": [
            { "songId": "sng_1", "status": "ready", "url": "https://rips.test/rips/sng_1.mp3" },
            { "songId": "sng_2", "status": "queued", "jobId": "job_2" },
            { "songId": "sng_3", "status": "inflight", "jobId": "job_3" }
          ],
          "counts": { "ready": 1, "queued": 1, "inflight": 1, "unknown": 0, "total": 3 }
        }
        """.utf8)

        let result = await rips.ripCollection(["sng_1", "sng_2", "sng_3"])
        XCTAssertEqual(RecordingURLProtocol.count(path: "/rip-collection"), 1)
        XCTAssertEqual(result.total, 3)
        XCTAssertEqual(result.ready, 1)
        XCTAssertEqual(result.queued, 1)
        XCTAssertEqual(result.inflight, 1)
        XCTAssertEqual(result.unknown, 0)
        XCTAssertEqual(result.results.count, 3)
        // queued/inflight items are recorded as jobs so the row's phase label updates.
        XCTAssertEqual(rips.jobs["sng_2"]?.jobId, "job_2")
        XCTAssertEqual(rips.jobs["sng_3"]?.jobId, "job_3")
        XCTAssertNil(rips.jobs["sng_1"], "ready item is not recorded as an in-flight job")
    }

    func testRipCollectionDedupesSongIds() async {
        let rips = makeStore()
        RecordingURLProtocol.bodyByPath["/rip-collection"] = Data("""
        { "results": [], "counts": { "ready": 0, "queued": 0, "inflight": 0, "unknown": 0, "total": 0 } }
        """.utf8)
        _ = await rips.ripCollection(["sng_1", "sng_1", "", "sng_2", "sng_1"])
        // The POST body carries the deduped, order-preserving id list.
        let sent = RecordingURLProtocol.lastBodyJSON(path: "/rip-collection")?["songIds"] as? [String]
        XCTAssertEqual(sent, ["sng_1", "sng_2"])
    }

    // MARK: Feature 2 RIP — 404 fallback classifies by ACTUAL job phase (GAP 4)

    func testRipCollectionFallsBackOn404AndClassifiesByPhase() async {
        let rips = makeStore()
        // sng_a is already cached → "ready" without any /rip.
        rips.setManifest(["sng_a": .init(key: "rips/sng_a.mp3")])
        // /rip-collection 404s → per-song fallback loop hits /rip for the misses.
        RecordingURLProtocol.statusCodeByPath["/rip-collection"] = 404
        // The per-song /rip responses script distinct phases so the buckets diverge:
        //   sng_b → queued, sng_c → ripping (inflight), sng_d → error (unknown).
        RecordingURLProtocol.scriptedRipBodies = [
            Data(#"{"jobId":"job_b","phase":"queued"}"#.utf8),
            Data(#"{"jobId":"job_c","phase":"ripping"}"#.utf8),
            Data(#"{"phase":"error","error":"nope"}"#.utf8),
        ]

        let result = await rips.ripCollection(["sng_a", "sng_b", "sng_c", "sng_d"])

        XCTAssertEqual(RecordingURLProtocol.count(path: "/rip-collection"), 1)
        XCTAssertEqual(result.total, 4)
        XCTAssertEqual(result.ready, 1, "cached sng_a")
        XCTAssertEqual(result.queued, 1, "sng_b queued")
        XCTAssertEqual(result.inflight, 1, "sng_c ripping → inflight")
        XCTAssertEqual(result.unknown, 1, "sng_d error → unknown")
        // The per-song result statuses match the batch vocabulary.
        XCTAssertEqual(result.results.first { $0.songId == "sng_a" }?.status, "ready")
        XCTAssertEqual(result.results.first { $0.songId == "sng_b" }?.status, "queued")
        XCTAssertEqual(result.results.first { $0.songId == "sng_c" }?.status, "inflight")
        XCTAssertEqual(result.results.first { $0.songId == "sng_d" }?.status, "unknown")
    }

    func testRipCollectionFallbackUnknownWhenNoServer() async {
        let rips = makeStore(serverURL: "")   // no server → straight to fallback, all unknown
        let result = await rips.ripCollection(["sng_x", "sng_y"])
        XCTAssertEqual(result.unknown, 2)
        XCTAssertEqual(result.total, 2)
        XCTAssertTrue(result.results.allSatisfy { $0.status == "unknown" })
    }

    // MARK: Feature 1 STOP — cancelCollection POSTs /rip-cancel + clears canceled jobs

    /// `cancelCollection` POSTs `{songIds:[...]}` to `/rip-cancel` (deduped, order-preserving)
    /// and, on a successful response, clears the LOCAL job entry for each `canceled` id so the
    /// row's phase label resets. A `notFound` / `alreadyDone` id keeps its job entry.
    func testCancelCollectionPostsRipCancelAndClearsCanceledJobs() async {
        let rips = makeStore()
        // Seed local jobs so we can prove the canceled ones are cleared and others survive.
        RecordingURLProtocol.body = Data(#"{"jobId":"j1","phase":"queued"}"#.utf8)
        await rips.requestRipIfNeeded("sng_1")
        RecordingURLProtocol.body = Data(#"{"jobId":"j2","phase":"queued"}"#.utf8)
        await rips.requestRipIfNeeded("sng_2")
        RecordingURLProtocol.reset()   // clear the /rip counts; keep the seeded jobs
        XCTAssertNotNil(rips.jobs["sng_1"])
        XCTAssertNotNil(rips.jobs["sng_2"])

        RecordingURLProtocol.bodyByPath["/rip-cancel"] = Data("""
        { "results": [
            { "songId": "sng_1", "status": "canceled" },
            { "songId": "sng_2", "status": "notFound" }
          ],
          "counts": { "canceled": 1, "notFound": 1 } }
        """.utf8)

        let results = await rips.cancelCollection(["sng_1", "sng_2"])

        // Path + body: exactly one POST to /rip-cancel carrying {songIds:[...]}.
        XCTAssertEqual(RecordingURLProtocol.count(path: "/rip-cancel"), 1)
        let sent = RecordingURLProtocol.lastBodyJSON(path: "/rip-cancel")
        XCTAssertEqual(sent?["songIds"] as? [String], ["sng_1", "sng_2"])
        // Decoded per-song results.
        XCTAssertEqual(results.count, 2)
        XCTAssertEqual(results.first { $0.songId == "sng_1" }?.status, "canceled")
        XCTAssertEqual(results.first { $0.songId == "sng_2" }?.status, "notFound")
        // Canceled id's job is cleared; the not-found id keeps its job entry.
        XCTAssertNil(rips.jobs["sng_1"], "canceled job entry is cleared")
        XCTAssertNotNil(rips.jobs["sng_2"], "a notFound id keeps its job entry")
    }

    func testCancelCollectionDedupesSongIds() async {
        let rips = makeStore()
        RecordingURLProtocol.bodyByPath["/rip-cancel"] = Data("""
        { "results": [], "counts": {} }
        """.utf8)
        _ = await rips.cancelCollection(["sng_1", "sng_1", "", "sng_2", "sng_1"])
        let sent = RecordingURLProtocol.lastBodyJSON(path: "/rip-cancel")?["songIds"] as? [String]
        XCTAssertEqual(sent, ["sng_1", "sng_2"], "deduped, order-preserving, empties dropped")
    }

    func testCancelCollectionEmptyIsNoOp() async {
        let rips = makeStore()
        let results = await rips.cancelCollection([])
        XCTAssertTrue(results.isEmpty)
        XCTAssertEqual(RecordingURLProtocol.count(path: "/rip-cancel"), 0, "empty input → no POST")
    }

    func testCancelCollectionNoServerIsNoOp() async {
        let rips = makeStore(serverURL: "")
        let results = await rips.cancelCollection(["sng_1"])
        XCTAssertTrue(results.isEmpty)
        XCTAssertEqual(RecordingURLProtocol.count(path: "/rip-cancel"), 0, "no server → no POST")
    }

    /// An older server that 404s `/rip-cancel` is a silent no-op (forward-compatible): no
    /// results, and a seeded job entry is NOT cleared (the cancel never took effect).
    func testCancelCollection404IsSilentNoOp() async {
        let rips = makeStore()
        RecordingURLProtocol.body = Data(#"{"jobId":"j1","phase":"queued"}"#.utf8)
        await rips.requestRipIfNeeded("sng_1")
        RecordingURLProtocol.statusCodeByPath["/rip-cancel"] = 404

        let results = await rips.cancelCollection(["sng_1"])
        XCTAssertTrue(results.isEmpty)
        XCTAssertNotNil(rips.jobs["sng_1"], "a 404 cancel leaves the job entry intact")
    }

    // MARK: LAZY RIP ON MISS — the wanted EDITION, acquired one song at a time

    private let base = "sng_72012147649f"

    /// The owner's Big Sean shape: primary id = the CLEAN cut, explicit edition resolved.
    private var bigSean: IndexSong {
        try! JSONDecoder().decode(IndexSong.self, from: Data(#"""
        {"id":"sng_72012147649f","artist":"Big Sean","name":"IDFWU","explicit":true,
         "appleMusicId":"1446744375","appleMusicIdExplicit":"1440831608","appleMusicIdClean":"1446744375"}
        """#.utf8))
    }
    private var preferExplicit: EditionPolicy.Decision {
        EditionPolicy.decide(song: bigSean, collectionCleanOnly: false, preferExplicitRaw: true)
    }

    /// The missing edition is enqueued under its VARIANT id — the same durable queue,
    /// the same `/rip` endpoint, the same dedup as every other rip.
    func testLazyEditionRipEnqueuesTheVariantId() async {
        let rips = makeStore()
        RecordingURLProtocol.body = Data(#"{"jobId":"job_e","songId":"sng_72012147649f_explicit","phase":"queued"}"#.utf8)
        let id = await rips.requestEditionRipIfNeeded(base: base, decision: preferExplicit)
        XCTAssertEqual(id, "\(base)_explicit")
        XCTAssertEqual(RecordingURLProtocol.count(path: "/rip"), 1)
        XCTAssertEqual(rips.jobs["\(base)_explicit"]?.phase, .queued)
        XCTAssertNil(rips.jobs[base], "the BASE song's rip is untouched — the clean cut is never overwritten")
    }

    /// IDEMPOTENT: repeated misses while a rip is in flight enqueue exactly ONCE.
    func testLazyEditionRipFiresExactlyOnceForRepeatedMisses() async {
        let rips = makeStore()
        RecordingURLProtocol.body = Data(#"{"jobId":"job_e","songId":"sng_72012147649f_explicit","phase":"queued"}"#.utf8)
        for _ in 0..<5 {
            await rips.requestEditionRipIfNeeded(base: base, decision: preferExplicit)
        }
        XCTAssertEqual(RecordingURLProtocol.count(path: "/rip"), 1,
                       "the in-flight job guard collapses every later miss")
    }

    /// …and under CONCURRENT misses too (the synchronous `requesting` reservation).
    func testLazyEditionRipIsSingleFlightUnderConcurrency() async {
        let rips = makeStore()
        RecordingURLProtocol.body = Data(#"{"jobId":"job_e","songId":"sng_72012147649f_explicit","phase":"queued"}"#.utf8)
        RecordingURLProtocol.responseDelayMs = 50
        await withTaskGroup(of: Void.self) { group in
            for _ in 0..<8 {
                group.addTask { _ = await rips.requestEditionRipIfNeeded(base: self.base, decision: self.preferExplicit) }
            }
        }
        XCTAssertEqual(RecordingURLProtocol.count(path: "/rip"), 1)
    }

    /// NOTHING is enqueued when that edition's catalog id is unknown — the server would
    /// otherwise have to guess the edition from artist+title.
    func testLazyEditionRipNeverFiresWithoutACatalogId() async {
        let rips = makeStore()
        let noId = EditionPolicy.Decision(edition: .explicit, reason: .globalPreference, catalogId: nil)
        let id = await rips.requestEditionRipIfNeeded(base: base, decision: noId)
        XCTAssertNil(id)
        XCTAssertEqual(RecordingURLProtocol.count(path: "/rip"), 0, "unknown edition id → no POST")
    }

    /// Nothing is enqueued when the wanted edition is ALREADY stored…
    func testLazyEditionRipSkipsWhenTheEditionIsStored() async {
        let rips = makeStore()
        rips.setManifest(["\(base)_explicit": .init(key: "rips/\(base)_explicit.mp3")])
        let id = await rips.requestEditionRipIfNeeded(base: base, decision: preferExplicit)
        XCTAssertNil(id)
        XCTAssertEqual(RecordingURLProtocol.count(path: "/rip"), 0)
    }

    /// …but a LEGACY un-suffixed rip does NOT satisfy the edition (that is the whole point
    /// of edition keying) — it still plays, and the wanted edition is still acquired.
    func testLegacyRipDoesNotSatisfyTheWantedEdition() async {
        let rips = makeStore()
        rips.setManifest([base: .init(key: "rips/\(base).mp3")])
        RecordingURLProtocol.body = Data(#"{"jobId":"job_e","phase":"queued"}"#.utf8)
        let id = await rips.requestEditionRipIfNeeded(base: base, decision: preferExplicit)
        XCTAssertEqual(id, "\(base)_explicit")
        XCTAssertEqual(RecordingURLProtocol.count(path: "/rip"), 1)
        XCTAssertNotNil(rips.cachedURL(base), "and the legacy rip is still there, untouched")
    }

    /// No substitution wanted (the tri-state nil) ⇒ nothing is ever enqueued.
    func testLazyEditionRipNoOpWhenNoSubstitution() async {
        let rips = makeStore()
        let id = await rips.requestEditionRipIfNeeded(base: base, decision: .unchanged)
        XCTAssertNil(id)
        XCTAssertEqual(RecordingURLProtocol.count(path: "/rip"), 0)
    }
}

/// A scriptable, request-counting `URLProtocol` standing in for the rip server. Serves
/// either a per-path body (`bodyByPath`), a sequence of scripted `/rip` bodies
/// (`scriptedRipBodies`, consumed in order), or the default `body`. Supports per-path
/// status overrides (e.g. 404 the batch endpoint) and an optional response delay so
/// concurrency tests can keep callers in-flight.
private final class RecordingURLProtocol: URLProtocol {
    // Scripted responses
    static var body = Data("{}".utf8)
    static var bodyByPath: [String: Data] = [:]
    static var scriptedRipBodies: [Data] = []
    static var statusCode = 200
    static var statusCodeByPath: [String: Int] = [:]
    static var responseDelayMs = 0

    // Recording
    private static let lock = NSLock()
    static var requestCounts: [String: Int] = [:]
    static var lastBodies: [String: Data] = [:]
    private static var ripCursor = 0

    static func reset() {
        lock.lock(); defer { lock.unlock() }
        body = Data("{}".utf8); bodyByPath = [:]; scriptedRipBodies = []
        statusCode = 200; statusCodeByPath = [:]; responseDelayMs = 0
        requestCounts = [:]; lastBodies = [:]; ripCursor = 0
    }

    static func count(path: String) -> Int {
        lock.lock(); defer { lock.unlock() }
        return requestCounts[path] ?? 0
    }

    static func lastBodyJSON(path: String) -> [String: Any]? {
        lock.lock(); let data = lastBodies[path]; lock.unlock()
        guard let data else { return nil }
        return (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
    }

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func stopLoading() {}

    override func startLoading() {
        let path = request.url?.path ?? ""
        Self.lock.lock()
        Self.requestCounts[path, default: 0] += 1
        if let bodyStream = request.httpBodyStream {
            Self.lastBodies[path] = Self.read(bodyStream)
        } else if let httpBody = request.httpBody {
            Self.lastBodies[path] = httpBody
        }
        let status = Self.statusCodeByPath[path] ?? Self.statusCode
        let payload: Data
        if path == "/rip", !Self.scriptedRipBodies.isEmpty {
            payload = Self.scriptedRipBodies[min(Self.ripCursor, Self.scriptedRipBodies.count - 1)]
            Self.ripCursor += 1
        } else {
            payload = Self.bodyByPath[path] ?? Self.body
        }
        let delay = Self.responseDelayMs
        Self.lock.unlock()

        let emit = {
            let response = HTTPURLResponse(url: self.request.url!, statusCode: status,
                                           httpVersion: "HTTP/1.1", headerFields: nil)!
            self.client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            self.client?.urlProtocol(self, didLoad: payload)
            self.client?.urlProtocolDidFinishLoading(self)
        }
        if delay > 0 {
            DispatchQueue.global().asyncAfter(deadline: .now() + .milliseconds(delay), execute: emit)
        } else {
            emit()
        }
    }

    private static func read(_ stream: InputStream) -> Data {
        stream.open(); defer { stream.close() }
        var data = Data(); let bufSize = 4096
        let buffer = UnsafeMutablePointer<UInt8>.allocate(capacity: bufSize)
        defer { buffer.deallocate() }
        while stream.hasBytesAvailable {
            let read = stream.read(buffer, maxLength: bufSize)
            if read <= 0 { break }
            data.append(buffer, count: read)
        }
        return data
    }
}

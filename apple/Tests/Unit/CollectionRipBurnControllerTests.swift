import XCTest
@testable import PocketDJ

/// Feature 1 / collection-RIP progress: the collection RIP enqueues in ~1-2s but completes
/// server-side over minutes/hours (real-time, concurrency-1). `CollectionRipBurnController`
/// keeps a VISIBLE STOP + live progress alive by polling the public S3 manifest until every
/// enqueued song is ripped (`rips.cachedURL(id) != nil`). These tests drive the controller
/// against a stubbed `RipsStore` whose manifest seam (`setManifest`) we mutate between polls:
///
///   • `ripInProgress` stays true while songs are pending and flips false when all are ripped,
///     with the progress count tracking the manifest as songs complete;
///   • `stop()` POSTs `/rip-cancel` with exactly `lastRipIds`, stops the poll, and clears the
///     in-progress state (idempotent — a second STOP is a harmless no-op);
///   • the poll only runs while there are pending rips and never leaks.
///
/// The manifest GET is served by a `ManifestStubURLProtocol` that returns the CURRENT scripted
/// manifest body each tick; `/rip-collection` + `/rip-cancel` are stubbed so no real network
/// is hit. The poll interval is dialled down so the tests run fast.
@MainActor
final class CollectionRipBurnControllerTests: XCTestCase {
    private let ripsBase = URL(string: "https://rips.test")!

    override func setUp() {
        super.setUp()
        ManifestStubURLProtocol.reset()
        // Fast poll for tests; restored in tearDown.
        CollectionRipBurnController.ripPollIntervalMs = 10
        CollectionRipBurnController.ripPollMaxTicks = 200
    }

    override func tearDown() {
        CollectionRipBurnController.ripPollIntervalMs = 4500
        CollectionRipBurnController.ripPollMaxTicks = 1600
        super.tearDown()
    }

    // MARK: Helpers

    private func makeRips(serverURL: String = "https://imac.test") -> RipsStore {
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [ManifestStubURLProtocol.self]
        let rips = RipsStore(ripsBase: ripsBase, session: URLSession(configuration: config))
        let settings = SettingsStore(defaults: UserDefaults(suiteName: "test.\(UUID().uuidString)")!)
        settings.ripServerURL = serverURL
        settings.ripToken = ""
        rips.settings = settings
        return rips
    }

    /// Build the public-manifest JSON body for a set of ripped song ids.
    private func manifestJSON(_ rippedIds: [String]) -> Data {
        let entries = rippedIds.map { #""\#($0)":{"key":"rips/\#($0).mp3"}"# }
        return Data("{\(entries.joined(separator: ","))}".utf8)
    }

    /// Spin the main run loop until `predicate` is true or `timeout` elapses.
    private func wait(timeout: TimeInterval = 3, until predicate: () -> Bool) async {
        let deadline = Date().addingTimeInterval(timeout)
        while !predicate() && Date() < deadline {
            try? await Task.sleep(nanoseconds: 5_000_000)   // 5ms
        }
    }

    private func burns(_ rips: RipsStore) -> BurnStore {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("pdj-ripctrl-\(UUID().uuidString).json")
        addTeardownBlock { try? FileManager.default.removeItem(at: url) }
        return BurnStore(rips: rips, fileURL: url)
    }

    // MARK: ripInProgress stays true while pending, flips false when all ripped

    func testRipInProgressStaysTrueWhilePendingThenFlipsWhenAllRipped() async {
        let rips = makeRips()
        let burns = self.burns(rips)
        let controller = CollectionRipBurnController()

        // /rip-collection enqueues 2 songs as "queued" (pending > 0 → poll starts).
        ManifestStubURLProtocol.bodyByPath["/rip-collection"] = Data("""
        {"results":[{"songId":"sng_1","status":"queued","jobId":"j1"},
                    {"songId":"sng_2","status":"queued","jobId":"j2"}],
         "counts":{"ready":0,"queued":2,"inflight":0,"unknown":0,"total":2}}
        """.utf8)
        // Manifest starts empty (nothing ripped yet).
        ManifestStubURLProtocol.manifestBody = manifestJSON([])

        controller.rip(["sng_1", "sng_2"], rips: rips, noun: "playlist")

        // Once the enqueue POST resolves, the poll starts and ripInProgress goes true.
        await wait(until: { controller.ripInProgress })
        XCTAssertTrue(controller.ripInProgress, "poll keeps the rip in progress while songs pending")
        XCTAssertEqual(controller.ripProgress, "ripping — 0 of 2 done")

        // One song completes server-side → manifest now lists sng_1. The poll picks it up.
        ManifestStubURLProtocol.manifestBody = manifestJSON(["sng_1"])
        await wait(until: { controller.ripProgress == "ripping — 1 of 2 done" })
        XCTAssertTrue(controller.ripInProgress, "still in progress with 1 of 2 pending")
        XCTAssertEqual(controller.ripProgress, "ripping — 1 of 2 done")

        // Both complete → poll sees pending == 0, flips ripInProgress false + finishes.
        ManifestStubURLProtocol.manifestBody = manifestJSON(["sng_1", "sng_2"])
        await wait(until: { !controller.ripInProgress })
        XCTAssertFalse(controller.ripInProgress, "all ripped → in progress flips false")
        XCTAssertNil(controller.ripProgress, "progress cleared when done")
        XCTAssertEqual(controller.summary, "Ripped 2 of 2")
        XCTAssertTrue(controller.canRefresh)
    }

    // MARK: stop() cancels with lastRipIds + clears state (idempotent)

    func testStopCancelsCollectionWithLastRipIdsAndClearsState() async {
        let rips = makeRips()
        let burns = self.burns(rips)
        let controller = CollectionRipBurnController()

        ManifestStubURLProtocol.bodyByPath["/rip-collection"] = Data("""
        {"results":[{"songId":"sng_a","status":"queued","jobId":"ja"},
                    {"songId":"sng_b","status":"queued","jobId":"jb"}],
         "counts":{"ready":0,"queued":2,"inflight":0,"unknown":0,"total":2}}
        """.utf8)
        ManifestStubURLProtocol.bodyByPath["/rip-cancel"] = Data("""
        {"results":[{"songId":"sng_a","status":"canceled"},
                    {"songId":"sng_b","status":"canceled"}]}
        """.utf8)
        ManifestStubURLProtocol.manifestBody = manifestJSON([])

        controller.rip(["sng_a", "sng_b"], rips: rips, noun: "setlist")
        await wait(until: { controller.ripInProgress })
        XCTAssertTrue(controller.ripInProgress)

        controller.stop(rips: rips, burns: burns)

        // STOP clears the in-progress state synchronously.
        XCTAssertFalse(controller.ripInProgress, "STOP clears ripInProgress")
        XCTAssertNil(controller.ripProgress, "STOP clears progress")

        // The /rip-cancel POST carries exactly the enqueued ids (deduped, in order).
        await wait(until: { ManifestStubURLProtocol.count(path: "/rip-cancel") == 1 })
        XCTAssertEqual(ManifestStubURLProtocol.count(path: "/rip-cancel"), 1)
        let sent = ManifestStubURLProtocol.lastBodyJSON(path: "/rip-cancel")?["songIds"] as? [String]
        XCTAssertEqual(sent, ["sng_a", "sng_b"], "cancel targets exactly lastRipIds")

        // Idempotent: a second STOP after the ids are cleared POSTs nothing more.
        controller.stop(rips: rips, burns: burns)
        try? await Task.sleep(nanoseconds: 50_000_000)
        XCTAssertEqual(ManifestStubURLProtocol.count(path: "/rip-cancel"), 1,
                       "second STOP is a harmless no-op")
    }

    // MARK: STOP stops the poll (no further manifest reconciliation drives the UI)

    func testStopStopsThePoll() async {
        let rips = makeRips()
        let burns = self.burns(rips)
        let controller = CollectionRipBurnController()

        ManifestStubURLProtocol.bodyByPath["/rip-collection"] = Data("""
        {"results":[{"songId":"sng_1","status":"queued","jobId":"j1"}],
         "counts":{"ready":0,"queued":1,"inflight":0,"unknown":0,"total":1}}
        """.utf8)
        ManifestStubURLProtocol.bodyByPath["/rip-cancel"] = Data(#"{"results":[]}"#.utf8)
        ManifestStubURLProtocol.manifestBody = manifestJSON([])

        controller.rip(["sng_1"], rips: rips, noun: "pocket")
        await wait(until: { controller.ripInProgress })
        controller.stop(rips: rips, burns: burns)
        XCTAssertFalse(controller.ripInProgress)

        // Let STOP's single /rip-cancel POST settle, then snapshot the count.
        await wait(until: { ManifestStubURLProtocol.count(path: "/rip-cancel") == 1 })
        let cancels = ManifestStubURLProtocol.count(path: "/rip-cancel")

        // Now mark the song ripped: if the poll were still running it'd rewrite progress.
        ManifestStubURLProtocol.manifestBody = manifestJSON(["sng_1"])
        try? await Task.sleep(nanoseconds: 80_000_000)
        XCTAssertFalse(controller.ripInProgress, "poll stayed stopped after STOP")
        XCTAssertNil(controller.ripProgress, "no progress is recomputed after STOP")
        // STOP issued exactly one cancel and the stopped poll added nothing more.
        XCTAssertEqual(ManifestStubURLProtocol.count(path: "/rip-cancel"), cancels)
    }

    // MARK: No poll when nothing is pending (everything already ripped)

    func testNoPollWhenNothingPending() async {
        let rips = makeRips()
        let controller = CollectionRipBurnController()

        // Everything already ripped → pending == 0 → no poll, no in-progress state.
        ManifestStubURLProtocol.bodyByPath["/rip-collection"] = Data("""
        {"results":[{"songId":"sng_1","status":"ready"}],
         "counts":{"ready":1,"queued":0,"inflight":0,"unknown":0,"total":1}}
        """.utf8)
        ManifestStubURLProtocol.manifestBody = manifestJSON(["sng_1"])

        controller.rip(["sng_1"], rips: rips, noun: "playlist")
        await wait(until: { controller.showSummary })
        XCTAssertFalse(controller.ripInProgress, "nothing pending → no in-progress poll")
        XCTAssertNil(controller.ripProgress)
        XCTAssertTrue(controller.summary?.contains("already ripped") ?? false)
    }
}

/// A `URLProtocol` standing in for the public S3 manifest + the iMac rip server: it serves
/// the CURRENT scripted manifest body for the manifest GET (so a test can advance which songs
/// are ripped between poll ticks), a per-path body for `/rip-collection` + `/rip-cancel`, and
/// counts/records the last JSON body per path. No real network is hit.
private final class ManifestStubURLProtocol: URLProtocol {
    static var manifestBody = Data("{}".utf8)
    static var bodyByPath: [String: Data] = [:]
    static var statusCodeByPath: [String: Int] = [:]
    private static var counts: [String: Int] = [:]
    private static var lastBody: [String: Data] = [:]
    private static let lock = NSLock()

    static func reset() {
        lock.lock(); defer { lock.unlock() }
        manifestBody = Data("{}".utf8)
        bodyByPath = [:]
        statusCodeByPath = [:]
        counts = [:]
        lastBody = [:]
    }

    static func count(path: String) -> Int {
        lock.lock(); defer { lock.unlock() }
        return counts[path] ?? 0
    }

    static func lastBodyJSON(path: String) -> [String: Any]? {
        lock.lock(); let data = lastBody[path]; lock.unlock()
        guard let data else { return nil }
        return (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
    }

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func stopLoading() {}

    override func startLoading() {
        let path = request.url?.path ?? ""
        Self.lock.lock()
        Self.counts[path, default: 0] += 1
        if let body = request.httpBodyStream.flatMap({ Self.readStream($0) }) ?? request.httpBody {
            Self.lastBody[path] = body
        }
        let status = Self.statusCodeByPath[path] ?? 200
        let payload: Data
        if path.hasSuffix("manifest.json") {
            payload = Self.manifestBody
        } else if let b = Self.bodyByPath[path] {
            payload = b
        } else {
            payload = Data("{}".utf8)
        }
        Self.lock.unlock()

        let response = HTTPURLResponse(url: request.url!, statusCode: status,
                                       httpVersion: "HTTP/1.1", headerFields: nil)!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: payload)
        client?.urlProtocolDidFinishLoading(self)
    }

    private static func readStream(_ stream: InputStream) -> Data? {
        stream.open(); defer { stream.close() }
        var data = Data()
        let size = 4096
        var buf = [UInt8](repeating: 0, count: size)
        while stream.hasBytesAvailable {
            let read = stream.read(&buf, maxLength: size)
            if read <= 0 { break }
            data.append(buf, count: read)
        }
        return data.isEmpty ? nil : data
    }
}

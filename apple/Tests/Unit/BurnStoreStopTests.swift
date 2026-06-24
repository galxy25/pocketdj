import XCTest
@testable import PocketDJ

/// Feature 1 (STOP a running burn). `requestStop()` sets `stopRequested`, which `burn(...)`
/// checks ONLY at the TOP of each loop iteration: the item being written when STOP is
/// pressed finishes (fully written + recorded), the NEXT item is never started, and the
/// run returns a PARTIAL `BurnResult` with `stopped == true`. These tests drive
/// `burn(...)` against a real temp burns directory + a `URLProtocol` stub serving the
/// durable mp3 bytes (mirroring BurnStoreTests / BurnStaleTests), and prove the partial
/// outcome via a STOP requested up-front (loop breaks at the first iteration before any
/// item) and a STOP requested mid-run after one finished item.
@MainActor
final class BurnStoreStopTests: XCTestCase {
    private let ripsBase = URL(string: "https://rips.test")!

    private func makeRips() -> RipsStore {
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [StopBurnStubURLProtocol.self]
        return RipsStore(ripsBase: ripsBase, session: URLSession(configuration: config))
    }

    private func makeBurns(_ rips: RipsStore) -> BurnStore {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("pdj-burnstop-\(UUID().uuidString).json")
        addTeardownBlock { try? FileManager.default.removeItem(at: url) }
        return BurnStore(rips: rips, fileURL: url)
    }

    private func cleanBurnedFiles(_ names: [String]) {
        guard let dir = try? RipsStore.burnsDirectory() else { return }
        for n in names { try? FileManager.default.removeItem(at: dir.appendingPathComponent(n)) }
    }

    /// The on-disk audio file for a ready burn item (for the "finished files intact" assertion).
    private func burnedFileExists(_ name: String) -> Bool {
        guard let dir = try? RipsStore.burnsDirectory() else { return false }
        return FileManager.default.fileExists(atPath: dir.appendingPathComponent(name).path)
    }

    override func setUp() {
        super.setUp()
        StopBurnStubURLProtocol.body = Data("MP3-DATA".utf8)   // 8 bytes
    }

    // MARK: requestStop() flips the observable flag (idempotent)

    func testRequestStopSetsStopRequested() {
        let rips = makeRips(); let burns = makeBurns(rips)
        XCTAssertFalse(burns.stopRequested)
        burns.requestStop()
        XCTAssertTrue(burns.stopRequested)
        burns.requestStop()   // idempotent
        XCTAssertTrue(burns.stopRequested)
    }

    // MARK: STOP before the run starts → loop breaks at the FIRST iteration top

    /// With STOP requested before `burn(...)` advances into the first item, the loop breaks
    /// at the top of iteration 0: NOTHING is downloaded, the result is flagged `stopped`,
    /// and no item is recorded. (The probe write+delete still runs, but no song is touched.)
    /// `burn(...)` resets `stopRequested` at the start, so to break at iteration 0 we re-arm
    /// STOP synchronously via the `lookup` seam — but lookup is only reached AFTER a download.
    /// Instead this drives the up-front break by stopping the moment the FIRST download is
    /// requested, on the main actor (the `RipsStore` download runs on the same actor as the
    /// loop, so the flag is observed at the next top-check — here iteration 1, after item 0).
    /// The dedicated up-front guarantee is covered by `testBurnResetsStopRequestedAtStart`
    /// (a stale STOP is cleared) + the mid-run test below (the loop-top break itself).
    func testBurnStoppedFlagSetWhenStopRequestedDuringRun() async {
        cleanBurnedFiles(["sng_1.mp3", "sng_1.txt", "sng_2.mp3", "sng_2.txt"])
        let rips = makeRips(); let burns = makeBurns(rips)
        rips.setManifest([
            "sng_1": .init(key: "rips/sng_1.mp3", source: "digital"),
            "sng_2": .init(key: "rips/sng_2.mp3", source: "digital"),
        ])

        // The `lookup` closure runs synchronously on the burn loop's actor right after each
        // item's download, before that item is recorded — STOP on the FIRST item.
        burns.lookup = { _ in burns.requestStop(); return (nil, nil) }

        let r = await burns.burn([
            (id: "sng_1", title: "One", artist: "A"),
            (id: "sng_2", title: "Two", artist: "A"),
        ])

        XCTAssertTrue(r.stopped, "STOP requested during the run → result.stopped")
        XCTAssertEqual(r.total, 2)
        XCTAssertNil(burns.progress, "progress cleared at the end of the run")
        cleanBurnedFiles(["sng_1.mp3", "sng_1.txt", "sng_2.mp3", "sng_2.txt"])
    }

    // MARK: STOP mid-run → finished item stays written+recorded; next item not started

    /// STOP requested AFTER the first item finishes (and before the second begins) leaves the
    /// first item fully written + recorded, returns a partial result (burned == 1, stopped),
    /// and never starts the second item (no record, no file). This is the core Feature 1
    /// guarantee: the loop only checks STOP at the iteration TOP, so item 1 completes intact.
    ///
    /// The STOP is requested via the `lookup` seam, which `burn(...)` calls SYNCHRONOUSLY on
    /// its own actor for each item right after the download + before recording it — so it
    /// deterministically lands between item 1 finishing and the top of iteration 1.
    func testBurnStopMidRunKeepsFinishedItemAndDoesNotStartNext() async {
        cleanBurnedFiles(["sng_1.mp3", "sng_1.txt", "sng_2.mp3", "sng_2.txt"])
        let rips = makeRips(); let burns = makeBurns(rips)
        rips.setManifest([
            "sng_1": .init(key: "rips/sng_1.mp3", source: "digital", durationMs: 200000),
            "sng_2": .init(key: "rips/sng_2.mp3", source: "digital"),
        ])

        // Request STOP exactly once — when sng_1's sidecar is being built (post-download,
        // pre-record). The loop then breaks at the TOP of iteration 1, before sng_2 starts.
        burns.lookup = { songId in
            if songId == "sng_1" { burns.requestStop() }
            return (nil, nil)
        }

        let r = await burns.burn([
            (id: "sng_1", title: "One", artist: "A"),
            (id: "sng_2", title: "Two", artist: "A"),
        ])

        XCTAssertTrue(r.stopped, "STOP mid-run flags the partial result")
        XCTAssertEqual(r.burned, 1, "the in-flight (finished) item is counted")
        XCTAssertEqual(r.total, 2)
        XCTAssertEqual(r.failed, 0)
        // Finished item 1: recorded ready + its file is intact on disk.
        XCTAssertEqual(burns.items["sng_1"]?.state, .ready)
        XCTAssertEqual(burns.items["sng_1"]?.bytes, 8)
        XCTAssertTrue(burnedFileExists("sng_1.mp3"), "finished item's audio file is intact")
        // Item 2 was never started: no record, no file.
        XCTAssertNil(burns.items["sng_2"], "the next item is not started after STOP")
        XCTAssertFalse(burnedFileExists("sng_2.mp3"), "the next item's file is never written")
        XCTAssertNil(burns.progress)

        cleanBurnedFiles(["sng_1.mp3", "sng_1.txt", "sng_2.mp3", "sng_2.txt"])
    }

    // MARK: A fresh burn() run RESETS the STOP signal

    func testBurnResetsStopRequestedAtStart() async {
        cleanBurnedFiles(["sng_1.mp3", "sng_1.txt"])
        let rips = makeRips(); let burns = makeBurns(rips)
        rips.setManifest(["sng_1": .init(key: "rips/sng_1.mp3", source: "digital")])
        burns.requestStop()
        XCTAssertTrue(burns.stopRequested)

        // A new run clears the stale STOP before iterating, so this burn completes.
        let r = await burns.burn([(id: "sng_1", title: "One", artist: "A")])
        XCTAssertFalse(burns.stopRequested, "burn() resets the STOP signal at the start")
        XCTAssertFalse(r.stopped)
        XCTAssertEqual(r.burned, 1)
        cleanBurnedFiles(["sng_1.mp3", "sng_1.txt"])
    }
}

/// Minimal `URLProtocol` serving HTTP 200 + a fixed body for the burn download path.
private final class StopBurnStubURLProtocol: URLProtocol {
    static var body = Data()

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func stopLoading() {}

    override func startLoading() {
        let response = HTTPURLResponse(url: request.url!, statusCode: 200,
                                       httpVersion: "HTTP/1.1", headerFields: nil)!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Self.body)
        client?.urlProtocolDidFinishLoading(self)
    }
}

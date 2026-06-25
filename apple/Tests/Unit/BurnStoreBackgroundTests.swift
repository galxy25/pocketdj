import XCTest
@testable import PocketDJ

/// Tests for the BACKGROUND burn path (a `TransferCoordinator` injected into `BurnStore`).
/// With a coordinator, `burn(...)` does NOT download inline — it pre-renders the sidecar,
/// persists a `.downloading` item IMMEDIATELY, and hands the song to the coordinator (which,
/// in these tests, runs with `realSession: false` so it just persists the join record). The
/// delegate-finish path is simulated by calling `finalizeBurn`, which upserts the `.ready`
/// item. `requestStop` cancels the in-flight records. The default (nil-coordinator) loop is
/// covered byte-for-byte by the existing BurnStoreTests / BurnStoreStopTests.
@MainActor
final class BurnStoreBackgroundTests: XCTestCase {
    private let ripsBase = URL(string: "https://rips.test")!

    private func makeRips() -> RipsStore {
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [BGBurnStubURLProtocol.self]
        return RipsStore(ripsBase: ripsBase, session: URLSession(configuration: config))
    }

    private func makeCoordinator() -> TransferCoordinator {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("pdj-bgxfer-\(UUID().uuidString).json")
        addTeardownBlock { try? FileManager.default.removeItem(at: url) }
        return TransferCoordinator(fileURL: url, realSession: false)
    }

    private func makeBurns(_ rips: RipsStore, _ transfers: TransferCoordinator) -> BurnStore {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("pdj-bgburn-\(UUID().uuidString).json")
        addTeardownBlock { try? FileManager.default.removeItem(at: url) }
        return BurnStore(rips: rips, transfers: transfers, fileURL: url)
    }

    // MARK: burn hands off — items go .downloading, records are enqueued, nothing is .ready yet

    func testBurnEnqueuesAndMarksDownloading() async {
        let rips = makeRips()
        let transfers = makeCoordinator()
        let burns = makeBurns(rips, transfers)
        rips.setManifest([
            "sng_1": .init(key: "rips/sng_1.mp3", source: "digital", durationMs: 1000),
            "sng_2": .init(key: "rips/sng_2.mp3", source: "digital"),
        ])

        let r = await burns.burn([
            (id: "sng_1", title: "One", artist: "A"),
            (id: "sng_2", title: "Two", artist: "A"),
        ])

        // Both ENQUEUED (the result's "burned" counts the hand-off, not completion).
        XCTAssertEqual(r.burned, 2)
        XCTAssertEqual(r.total, 2)
        // Items are .downloading (persisted incrementally), NOT .ready — bytes await the delegate.
        XCTAssertEqual(burns.items["sng_1"]?.state, .downloading)
        XCTAssertEqual(burns.items["sng_2"]?.state, .downloading)
        XCTAssertEqual(burns.items["sng_1"]?.audioFileName, "sng_1.mp3")
        // The coordinator holds a persisted join record per song.
        XCTAssertEqual(Set(transfers.records.map { $0.songId }), ["sng_1", "sng_2"])
        // The sidecar text was PRE-RENDERED at enqueue (cold-launch finalize needs no lookup).
        XCTAssertTrue(transfers.records.first { $0.songId == "sng_1" }?.sidecarText.contains("One") ?? false)
    }

    // MARK: finalizeBurn upserts a .ready item (the delegate-finish callback)

    func testFinalizeBurnMarksReady() async {
        let rips = makeRips()
        let transfers = makeCoordinator()
        let burns = makeBurns(rips, transfers)
        rips.setManifest(["sng_1": .init(key: "rips/sng_1.mp3", source: "digital", durationMs: 1000)])

        _ = await burns.burn([(id: "sng_1", title: "One", artist: "A")])
        XCTAssertEqual(burns.items["sng_1"]?.state, .downloading)

        let rec = transfers.records.first { $0.songId == "sng_1" }!
        burns.finalizeBurn(record: rec, bytes: 8)
        XCTAssertEqual(burns.items["sng_1"]?.state, .ready)
        XCTAssertEqual(burns.items["sng_1"]?.bytes, 8)
        XCTAssertEqual(burns.items["sng_1"]?.durationMs, 1000)
    }

    // MARK: requestStop cancels in-flight transfers + drops the downloading items

    func testRequestStopCancelsInFlightTransfers() async {
        let rips = makeRips()
        let transfers = makeCoordinator()
        let burns = makeBurns(rips, transfers)
        rips.setManifest([
            "sng_1": .init(key: "rips/sng_1.mp3", source: "digital"),
            "sng_2": .init(key: "rips/sng_2.mp3", source: "digital"),
        ])
        _ = await burns.burn([
            (id: "sng_1", title: "One", artist: "A"),
            (id: "sng_2", title: "Two", artist: "A"),
        ])
        XCTAssertEqual(transfers.records.count, 2)

        burns.requestStop()
        XCTAssertTrue(burns.stopRequested)
        // The coordinator's records for the still-downloading items are cancelled/dropped.
        XCTAssertTrue(transfers.records.isEmpty)
        XCTAssertNil(burns.items["sng_1"])
        XCTAssertNil(burns.items["sng_2"])
    }

    // MARK: background progress mirrors into BurnStore's @Observable state (the overlay reads it)

    /// The collection overlay's "Burning N of M" reads `BurnStore.backgroundProgress` (an
    /// @Observable), NOT the non-observable coordinator snapshot — so it actually re-renders as
    /// the run progresses. Enqueue publishes (N,0); Stop clears it so the overlay hides.
    func testBackgroundProgressMirrorsCoordinatorIntoObservableState() async {
        let rips = makeRips()
        let transfers = makeCoordinator()
        let burns = makeBurns(rips, transfers)
        // Idle: nothing in flight.
        XCTAssertEqual(burns.backgroundProgress.enqueued, 0)
        XCTAssertEqual(burns.backgroundProgress.finished, 0)

        rips.setManifest([
            "sng_1": .init(key: "rips/sng_1.mp3", source: "digital"),
            "sng_2": .init(key: "rips/sng_2.mp3", source: "digital"),
        ])
        _ = await burns.burn([
            (id: "sng_1", title: "One", artist: "A"),
            (id: "sng_2", title: "Two", artist: "A"),
        ])
        // Enqueuing 2 songs mirrored (2, 0) into the observable the overlay binds to.
        XCTAssertEqual(burns.backgroundProgress.enqueued, 2)
        XCTAssertEqual(burns.backgroundProgress.finished, 0)

        // Stop drops the in-flight records and re-publishes (0,0) so the overlay clears.
        burns.requestStop()
        XCTAssertEqual(burns.backgroundProgress.enqueued, 0)
        XCTAssertEqual(burns.backgroundProgress.finished, 0)
    }

    // MARK: not-ripped songs are still reported (never enqueued)

    func testNotRippedSongIsNotEnqueued() async {
        let rips = makeRips()
        let transfers = makeCoordinator()
        let burns = makeBurns(rips, transfers)
        rips.setManifest([:])   // nothing cached

        let r = await burns.burn([(id: "missing", title: "M", artist: "A")])
        XCTAssertEqual(r.notRipped, 1)
        XCTAssertEqual(r.burned, 0)
        XCTAssertTrue(transfers.records.isEmpty)
        XCTAssertEqual(burns.items["missing"]?.state, .error)
    }
}

/// Minimal `URLProtocol` (unused by the background path, but the rips session still needs a
/// stub class registered so any incidental fetch doesn't hit the network).
private final class BGBurnStubURLProtocol: URLProtocol {
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func stopLoading() {}
    override func startLoading() {
        let response = HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: "HTTP/1.1", headerFields: nil)!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Data("MP3-DATA".utf8))
        client?.urlProtocolDidFinishLoading(self)
    }
}

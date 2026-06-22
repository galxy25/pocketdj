import XCTest
@testable import PocketDJ

/// Tests for the gap-closing pass on the RIP/BURN pipeline:
///   • GAP 3 — `ManifestEntry.rippedAt` decodes (epoch-ms, optional) and `BurnStore`
///     treats a burn as STALE (=> re-download) when the manifest's `rippedAt` is newer
///     than the burn's `downloadedAt`, while staying backward-compatible when nil.
///   • GAP 4 — the per-song `ripCollection` fallback classifies each result by the ACTUAL
///     job phase (ready/queued/inflight/unknown) so its counts match the batch path.
///
/// The staleness path is driven end-to-end through `BurnStore.burn(...)` against a real
/// temp burns directory, with a `URLProtocol` stub serving the durable mp3 bytes so no
/// network is hit.
@MainActor
final class BurnStaleTests: XCTestCase {
    private let ripsBase = URL(string: "https://rips.test")!

    // MARK: GAP 3 — manifest rippedAt decode (optional / backward-compat)

    func testManifestDecodesRippedAt() throws {
        let json = """
        {
          "sng_new": { "key": "rips/sng_new.mp3", "rippedAt": 1718000000000 },
          "sng_old": { "key": "rips/sng_old.mp3" }
        }
        """
        let m = try JSONDecoder().decode([String: RipsStore.ManifestEntry].self, from: Data(json.utf8))
        XCTAssertEqual(m["sng_new"]?.rippedAt, 1718000000000)
        XCTAssertNil(m["sng_old"]?.rippedAt)   // older entries lack it
    }

    // MARK: GAP 4 — phase → batch-status mapping

    func testBatchStatusMapsEachPhase() {
        XCTAssertEqual(RipsStore.batchStatus(for: .ready), "ready")
        XCTAssertEqual(RipsStore.batchStatus(for: .queued), "queued")
        XCTAssertEqual(RipsStore.batchStatus(for: .searching), "inflight")
        XCTAssertEqual(RipsStore.batchStatus(for: .ripping), "inflight")
        XCTAssertEqual(RipsStore.batchStatus(for: .streaming), "inflight")
        XCTAssertEqual(RipsStore.batchStatus(for: .uploading), "inflight")
        XCTAssertEqual(RipsStore.batchStatus(for: .error), "unknown")
        XCTAssertEqual(RipsStore.batchStatus(for: nil), "unknown")
    }

    // MARK: GAP 3 — burn staleness via rippedAt

    func testBurnReDownloadsWhenManifestRippedAtIsNewer() async throws {
        let session = Self.stubSession()
        let rips = RipsStore(ripsBase: ripsBase, session: session)

        let burnURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("pdj-burn-stale-\(UUID().uuidString).json")
        defer { try? FileManager.default.removeItem(at: burnURL) }
        let burns = BurnStore(rips: rips, fileURL: burnURL)

        let song = (id: "sng_x", title: "Stale Song", artist: "Tester")

        // First burn: rip completed at t=1000, bytes = "v1".
        StubURLProtocol.body = Data("v1".utf8)
        rips.setManifest(["sng_x": .init(key: "rips/sng_x.mp3", source: "digital", rippedAt: 1000)])
        let first = await burns.burn([song])
        XCTAssertEqual(first.burned, 1)
        let burnedAt = burns.items["sng_x"]?.downloadedAt
        XCTAssertNotNil(burnedAt)
        XCTAssertEqual(burns.items["sng_x"]?.rippedAt, 1000)
        XCTAssertEqual(burns.items["sng_x"]?.bytes, 2)

        // Re-rip happened AFTER our download (rippedAt newer than downloadedAt) → stale,
        // so a second burn must re-download. The new rip yields DIFFERENT bytes ("v2-bigger"),
        // which proves a real re-download (not a fresh short-circuit) and updates rippedAt.
        StubURLProtocol.body = Data("v2-bigger".utf8)
        let newRippedAt = (burnedAt ?? 0) + 60_000
        rips.setManifest(["sng_x": .init(key: "rips/sng_x.mp3", source: "digital", rippedAt: newRippedAt)])
        let second = await burns.burn([song])
        XCTAssertEqual(second.burned, 1)
        XCTAssertEqual(burns.items["sng_x"]?.rippedAt, newRippedAt, "re-download records the newer rippedAt")
        XCTAssertEqual(burns.items["sng_x"]?.bytes, 9, "re-downloaded the newer, larger rip")
    }

    func testBurnStaysFreshWhenRippedAtNotNewer() async throws {
        let session = Self.stubSession()
        let rips = RipsStore(ripsBase: ripsBase, session: session)

        let burnURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("pdj-burn-fresh-\(UUID().uuidString).json")
        defer { try? FileManager.default.removeItem(at: burnURL) }
        let burns = BurnStore(rips: rips, fileURL: burnURL)

        let song = (id: "sng_y", title: "Fresh Song", artist: "Tester")
        StubURLProtocol.body = Data("v1".utf8)
        rips.setManifest(["sng_y": .init(key: "rips/sng_y.mp3", source: "digital", rippedAt: 1000)])
        _ = await burns.burn([song])

        // Same (older) rippedAt → still fresh; the second burn short-circuits WITHOUT
        // re-downloading even though fresh bytes are now available, so `bytes` stays "v1".
        StubURLProtocol.body = Data("v2-bigger".utf8)
        let second = await burns.burn([song])
        XCTAssertEqual(second.burned, 1)
        XCTAssertEqual(burns.items["sng_y"]?.bytes, 2, "fresh burn is not re-downloaded")
    }

    func testBurnBackwardCompatWhenRippedAtNil() async throws {
        let session = Self.stubSession()
        let rips = RipsStore(ripsBase: ripsBase, session: session)

        let burnURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("pdj-burn-nilripped-\(UUID().uuidString).json")
        defer { try? FileManager.default.removeItem(at: burnURL) }
        let burns = BurnStore(rips: rips, fileURL: burnURL)

        let song = (id: "sng_z", title: "Legacy Song", artist: "Tester")
        // Older manifest entry: no rippedAt → only the size check applies (stays fresh).
        StubURLProtocol.body = Data("v1".utf8)
        rips.setManifest(["sng_z": .init(key: "rips/sng_z.mp3", source: "digital")])
        _ = await burns.burn([song])
        XCTAssertNil(burns.items["sng_z"]?.rippedAt)

        StubURLProtocol.body = Data("v2-bigger".utf8)
        let second = await burns.burn([song])
        XCTAssertEqual(second.burned, 1)
        XCTAssertEqual(burns.items["sng_z"]?.bytes, 2, "nil rippedAt → size-only freshness, no re-download")
    }

    // MARK: URLProtocol stub (serves the durable mp3 bytes for any request)

    private static func stubSession() -> URLSession {
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [StubURLProtocol.self]
        return URLSession(configuration: config)
    }
}

/// Minimal `URLProtocol` that answers every request with HTTP 200 + a fixed body.
private final class StubURLProtocol: URLProtocol {
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

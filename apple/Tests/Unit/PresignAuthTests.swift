import XCTest
@testable import PocketDJ

/// Regression tests for the MobileOne 2026-09-01 bug: the app attached its rip-server bearer
/// token to PRESIGNED S3 URLs, and S3 rejects a request carrying two auth mechanisms with a
/// 400 whose small XML body was then finalized as the "downloaded" mp3 — items went .ready,
/// loader rows listed, and nothing could ever play.
///
/// Three layers, each tested here:
///   1. `applyAuth` (the choke point) skips the bearer for any URL carrying `X-Amz-Signature`.
///   2. `TransferCoordinator.enqueueDownload` does the same for the background path.
///   3. `BurnStore.reconcileOnLaunch` self-heals items already poisoned by the broken build.
@MainActor
final class PresignAuthTests: XCTestCase {
    private let ripsBase = URL(string: "https://rips.test")!

    private func makeRips() -> RipsStore {
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [PresignStubURLProtocol.self]
        let rips = RipsStore(ripsBase: ripsBase, session: URLSession(configuration: config))
        let settings = SettingsStore(defaults: UserDefaults(suiteName: "presign.\(UUID().uuidString)")!)
        settings.ripServerURL = "https://imac.test"
        settings.ripToken = "sekrit"
        rips.settings = settings
        return rips
    }

    override func setUp() {
        super.setUp()
        PresignStubURLProtocol.reset()
    }

    /// 1+e2e: `downloadData` asks `/rips/presign` WITH the bearer, then fetches the presigned
    /// S3 URL WITHOUT it. (Before the fix the second request carried both — S3's 400.)
    func testPresignedFetchCarriesNoBearer() async throws {
        let rips = makeRips()
        rips.setManifest(["sng_p": .init(key: "rips/sng_p.mp3", source: "digital")])
        PresignStubURLProtocol.bodyByPath["/rips/presign"] = Data(
            #"{"url":"https://bucket.s3.test/rips/sng_p.mp3?X-Amz-Algorithm=AWS4-HMAC-SHA256&X-Amz-Signature=abc123"}"#.utf8)
        PresignStubURLProtocol.bodyByPath["/rips/sng_p.mp3"] = Data("MP3-BYTES".utf8)

        let data = try await rips.downloadData((id: "sng_p", title: "T", artist: "A"))

        XCTAssertEqual(String(decoding: data, as: UTF8.self), "MP3-BYTES")
        XCTAssertEqual(PresignStubURLProtocol.authHeaderByPath["/rips/presign"] ?? nil, "Bearer sekrit",
                       "the rip-server presign call itself still authenticates")
        let s3Auth = PresignStubURLProtocol.authHeaderByPath["/rips/sng_p.mp3"] ?? nil
        XCTAssertNil(s3Auth, "the presigned S3 fetch must NOT carry a bearer (S3 400s double auth)")
    }

    /// 2: the background-download request builder skips the bearer for presigned URLs AND for
    /// any S3 host (plain public-bucket GETs also 400 on a non-AWS Authorization header —
    /// "Unsupported Authorization Type", the macOS half of the bug), and keeps it only for
    /// rip-server URLs.
    func testEnqueueDownloadSkipsBearerForPresignedURL() {
        let presigned = URL(string: "https://bucket.s3.test/rips/x.mp3?X-Amz-Algorithm=AWS4-HMAC-SHA256&X-Amz-Signature=abc")!
        let plainS3 = URL(string: "https://pocketdj-rips-1.s3.us-west-2.amazonaws.com/rips/x.mp3")!
        let plain = URL(string: "https://imac.test/hls/x/index.m3u8")!
        XCTAssertFalse(TransferCoordinator.shouldAttachBearer(to: presigned, token: "t"))
        XCTAssertFalse(TransferCoordinator.shouldAttachBearer(to: plainS3, token: "t"),
                       "plain public S3 rejects a bearer header too (Unsupported Authorization Type)")
        XCTAssertTrue(TransferCoordinator.shouldAttachBearer(to: plain, token: "t"))
        XCTAssertFalse(TransferCoordinator.shouldAttachBearer(to: plain, token: ""), "no token, no header")
    }

    /// 2b (the macOS in-process half): `downloadDataIfCached` fetches the DIRECT ripsBase URL —
    /// with a token configured, that request must carry no bearer (its host isn't the rip
    /// server), while the rip-server call keeps it. Pins `applyAuth`'s host rule end-to-end.
    func testDirectS3FetchCarriesNoBearer() async throws {
        let rips = makeRips()
        rips.setManifest(["sng_d": .init(key: "rips/sng_d.mp3", source: "digital")])
        PresignStubURLProtocol.bodyByPath["/rips/sng_d.mp3"] = Data("MP3-DIRECT".utf8)

        let out = try await rips.downloadDataIfCached((id: "sng_d", title: "T", artist: "A"))

        XCTAssertEqual(String(decoding: out?.data ?? Data(), as: UTF8.self), "MP3-DIRECT")
        let auth = PresignStubURLProtocol.authHeaderByPath["/rips/sng_d.mp3"] ?? nil
        XCTAssertNil(auth, "a direct ripsBase (S3-host) fetch must not carry the rip-server bearer")
    }

    /// 3: a .ready item whose "audio" is S3's XML error body is pruned (record + file) by the
    /// launch reconcile; a real small binary file and a normal mp3 survive untouched.
    func testReconcilePrunesPoisonedItemsOnly() throws {
        let rips = makeRips()
        let fileURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("pdj-poison-\(UUID().uuidString).json")
        addTeardownBlock { try? FileManager.default.removeItem(at: fileURL) }
        let burns = BurnStore(rips: rips, fileURL: fileURL)

        guard let dir = try? RipsStore.burnsDirectory() else { return XCTFail("no burns dir") }
        let poisonName = "poison-\(UUID().uuidString).mp3"
        let tinyName = "tiny-\(UUID().uuidString).mp3"
        let realName = "real-\(UUID().uuidString).mp3"
        addTeardownBlock {
            for n in [poisonName, tinyName, realName] {
                try? FileManager.default.removeItem(at: dir.appendingPathComponent(n))
            }
        }
        // The actual body S3 returned for the double-auth request (shape, not verbatim).
        let xml = #"<?xml version="1.0" encoding="UTF-8"?><Error><Code>InvalidArgument</Code></Error>"#
        try Data(xml.utf8).write(to: dir.appendingPathComponent(poisonName))
        try Data([0xFF, 0xFB, 0x90, 0x00] + Array(repeating: 0x11, count: 600))    // tiny but audio-shaped
            .write(to: dir.appendingPathComponent(tinyName))
        try Data(repeating: 0x22, count: 40_000).write(to: dir.appendingPathComponent(realName))

        burns.injectItemForTesting(songId: "sng_poison", audioFileName: poisonName)
        burns.injectItemForTesting(songId: "sng_tiny", audioFileName: tinyName)
        burns.injectItemForTesting(songId: "sng_real", audioFileName: realName)

        burns.reconcileOnLaunch()

        XCTAssertNil(burns.localURL(forSong: "sng_poison"), "poisoned item pruned")
        XCTAssertFalse(FileManager.default.fileExists(atPath: dir.appendingPathComponent(poisonName).path),
                       "poisoned file deleted so a re-download can land clean")
        XCTAssertNotNil(burns.localURL(forSong: "sng_tiny"), "small NON-XML file survives (no false positives)")
        XCTAssertNotNil(burns.localURL(forSong: "sng_real"), "normal file untouched")
    }
}

/// Stub answering both the rip-server presign call and the "S3" fetch, recording the
/// Authorization header each path was called with.
private final class PresignStubURLProtocol: URLProtocol {
    nonisolated(unsafe) static var bodyByPath: [String: Data] = [:]
    nonisolated(unsafe) static var authHeaderByPath: [String: String?] = [:]
    static func reset() { bodyByPath = [:]; authHeaderByPath = [:] }

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func stopLoading() {}

    override func startLoading() {
        let path = request.url?.path ?? ""
        Self.authHeaderByPath[path] = request.value(forHTTPHeaderField: "Authorization")
        let body = Self.bodyByPath[path] ?? Data("{}".utf8)
        let resp = HTTPURLResponse(url: request.url!, statusCode: 200,
                                   httpVersion: "HTTP/1.1", headerFields: nil)!
        client?.urlProtocol(self, didReceive: resp, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: body)
        client?.urlProtocolDidFinishLoading(self)
    }
}

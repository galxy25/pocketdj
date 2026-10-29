import XCTest
@testable import PocketDJ

/// MUT stale-cache fix (2026-10-29): MusicKit's CACHED Music-User-Token was rejected by the Apple
/// Music REST API (403 40300) so every server-side playlist sync failed. The service now mints with
/// `.ignoreCache` once per launch, and the sync client re-mints + re-submits ONCE after an Apple
/// 401/403. These tests drive the real `AMPlaylistSyncClient` against a stubbed Lambda and a fake
/// minter.
@MainActor
final class MusicUserTokenRefreshTests: XCTestCase {
    private let base = URL(string: "https://amsync.test")!
    private var session: URLSession!
    private var defaults: UserDefaults!

    override func setUp() {
        super.setUp()
        AMSyncStub.reset()
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [AMSyncStub.self]
        session = URLSession(configuration: config)
        defaults = UserDefaults(suiteName: "MUTRefresh-\(UUID().uuidString)")
    }

    private func makeService(_ minter: FakeMinter) -> MusicUserTokenService {
        MusicUserTokenService(base: base, session: session, minter: minter, preflight: { nil })
    }

    private func makeClient(_ service: MusicUserTokenService) -> AMPlaylistSyncClient {
        AMPlaylistSyncClient(base: base, tokens: service, session: session,
                             stallTimeout: 5, pollInterval: 0.01, defaults: defaults)
    }

    // MARK: - Service

    func testFirstTokenIsMintedFreshAndMemoizedForTheLaunch() async throws {
        let minter = FakeMinter(["t1", "t2"])
        let service = makeService(minter)
        let a = try await service.musicUserToken()
        let b = try await service.musicUserToken()
        XCTAssertEqual(a, "t1")
        XCTAssertEqual(b, "t1", "memoized — no second MusicKit mint")
        XCTAssertEqual(minter.calls, [true], "the first (unvalidated) token must bypass MusicKit's cache")
        XCTAssertEqual(AMSyncStub.count("/musickit-token"), 1)
    }

    func testConcurrentRefreshesCoalesceOntoOneMint() async throws {
        let minter = FakeMinter(["stale", "fresh", "extra"], delayMs: 50)
        let service = makeService(minter)
        _ = try await service.musicUserToken()
        async let r1 = service.refreshAfterRejection(of: "stale")
        async let r2 = service.refreshAfterRejection(of: "stale")
        let (x, y) = try await (r1, r2)
        XCTAssertEqual(x, "fresh")
        XCTAssertEqual(y, "fresh")
        XCTAssertEqual(minter.calls.count, 2, "one launch mint + ONE refresh mint")
        // A late caller still holding the stale token gets the replacement without a new mint.
        let late = try await service.refreshAfterRejection(of: "stale")
        XCTAssertEqual(late, "fresh")
        XCTAssertEqual(minter.calls.count, 2)
    }

    // MARK: - Client: 403 → refresh → retry

    func testApple403RefreshesTokenAndRetrySucceeds() async throws {
        AMSyncStub.rejected = ["stale"]
        let minter = FakeMinter(["stale", "fresh"])
        let client = makeClient(makeService(minter))
        let playlists = try await client.pull()
        XCTAssertEqual(playlists.map(\.name), ["Road Trip"])
        XCTAssertEqual(AMSyncStub.submittedTokens, ["stale", "fresh"],
                       "the re-minted token reaches the server with the re-submitted job")
        XCTAssertEqual(minter.calls, [true, true], "both mints bypass MusicKit's cache")
    }

    func testRefreshedTokenIsReusedByTheNextSyncWithoutMinting() async throws {
        AMSyncStub.rejected = ["stale"]
        let minter = FakeMinter(["stale", "fresh", "never"])
        let client = makeClient(makeService(minter))
        _ = try await client.pull()
        _ = try await client.push([.init(name: "P", trackCatalogIds: ["1"])])
        XCTAssertEqual(AMSyncStub.submittedTokens, ["stale", "fresh", "fresh"])
        XCTAssertEqual(minter.calls.count, 2)
    }

    func testPersistent403RetriesOnlyOnce() async {
        AMSyncStub.rejectAll = true
        let minter = FakeMinter(["a", "b", "c", "d"])
        let client = makeClient(makeService(minter))
        do {
            _ = try await client.pull()
            XCTFail("expected the 403 to surface")
        } catch {
            XCTAssertTrue(AMPlaylistSyncClient.isAppleAuthRejection(error))
        }
        XCTAssertEqual(AMSyncStub.submittedTokens, ["a", "b"], "exactly one retry — no refresh loop")
        XCTAssertEqual(minter.calls.count, 2)
    }

    func testSameTokenBackFromAppleDoesNotResubmit() async {
        AMSyncStub.rejectAll = true
        let minter = FakeMinter(["same", "same", "same"])
        let client = makeClient(makeService(minter))
        do { _ = try await client.pull(); XCTFail("expected failure") } catch {}
        XCTAssertEqual(AMSyncStub.submittedTokens, ["same"], "re-sending a token Apple just refused is pointless")
        XCTAssertEqual(minter.calls.count, 2)
    }

    func testOwnGateway401DoesNotRefreshTheMUT() async {
        AMSyncStub.submitStatus = 401
        AMSyncStub.submitBody = #"{"error":"unauthorized"}"#
        let minter = FakeMinter(["t1", "t2"])
        let client = makeClient(makeService(minter))
        do { _ = try await client.pull(); XCTFail("expected failure") } catch {
            XCTAssertFalse(AMPlaylistSyncClient.isAppleAuthRejection(error))
        }
        XCTAssertEqual(AMSyncStub.submittedTokens, ["t1"])
        XCTAssertEqual(minter.calls.count, 1)
    }

    func testAppleAuthRejectionClassifier() {
        typealias E = AMPlaylistSyncClient.ClientError
        let yes: [Error] = [
            E.worker("AM GET /v1/me/library/playlists?limit=100 -> 403"),
            E.worker("AM POST /v1/me/library/playlists -> 401"),
            E.http(403, #"{"error":"AM GET /v1/me/storefront -> 403"}"#),
        ]
        let no: [Error] = [
            E.worker("AM GET /v1/me/library/playlists -> 404"),
            E.worker("AM GET /v1/me/library/playlists -> 4031"),
            E.worker("sync exceeded the continuation limit"),
            E.http(401, #"{"error":"unauthorized"}"#),
            E.stalled("x"), E.jobGone, URLError(.timedOut),
        ]
        for e in yes { XCTAssertTrue(AMPlaylistSyncClient.isAppleAuthRejection(e), "\(e)") }
        for e in no { XCTAssertFalse(AMPlaylistSyncClient.isAppleAuthRejection(e), "\(e)") }
    }
}

/// Scripted minter: hands out `tokens` in order (repeating the last), recording each call's
/// `ignoreCache` flag.
private final class FakeMinter: MusicUserTokenMinting, @unchecked Sendable {
    private let lock = NSLock()
    private let tokens: [String]
    private let delayMs: UInt64
    private var _calls: [Bool] = []
    var calls: [Bool] { lock.lock(); defer { lock.unlock() }; return _calls }

    init(_ tokens: [String], delayMs: UInt64 = 0) { self.tokens = tokens; self.delayMs = delayMs }

    func userToken(developerToken: String, ignoreCache: Bool) async throws -> String {
        XCTAssertEqual(developerToken, "dev-jwt")
        let i = lock.withLock { () -> Int in
            _calls.append(ignoreCache)
            return _calls.count - 1
        }
        if delayMs > 0 { try await Task.sleep(nanoseconds: delayMs * 1_000_000) }
        return tokens[min(i, tokens.count - 1)]
    }
}

/// Stand-in for the am-playlist-sync Lambda: /musickit-token, POST /pull|/push → jobId, and
/// GET /job/{id} → done, or the worker's Apple-403 error when the job's token is rejected.
private final class AMSyncStub: URLProtocol {
    private static let lock = NSLock()
    static var rejected: Set<String> = []
    static var rejectAll = false
    static var submitStatus = 202
    static var submitBody: String?
    private static var counts: [String: Int] = [:]
    private static var tokens: [String] = []
    private static var jobs: [String: (op: String, token: String)] = [:]

    static func reset() {
        lock.lock(); defer { lock.unlock() }
        rejected = []; rejectAll = false; submitStatus = 202; submitBody = nil
        counts = [:]; tokens = []; jobs = [:]
    }
    static func count(_ path: String) -> Int { lock.lock(); defer { lock.unlock() }; return counts[path] ?? 0 }
    static var submittedTokens: [String] { lock.lock(); defer { lock.unlock() }; return tokens }

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func stopLoading() {}

    override func startLoading() {
        let path = request.url?.path ?? ""
        var status = 200
        var body = "{}"
        Self.lock.lock()
        Self.counts[path, default: 0] += 1
        if path == "/musickit-token" {
            body = #"{"token":"dev-jwt","expiresAt":\#(Date().addingTimeInterval(90 * 86400).timeIntervalSince1970 * 1000)}"#
        } else if path == "/pull" || path == "/push" {
            let data = request.httpBody ?? request.httpBodyStream.map(Self.read) ?? Data()
            let json = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
            let token = json?["musicUserToken"] as? String ?? ""
            Self.tokens.append(token)
            if let b = Self.submitBody {
                status = Self.submitStatus; body = b
            } else {
                let id = "job-\(Self.tokens.count)"
                Self.jobs[id] = (String(path.dropFirst()), token)
                status = 202; body = #"{"jobId":"\#(id)"}"#
            }
        } else if path.hasPrefix("/job/"), let job = Self.jobs[String(path.dropFirst(5))] {
            if Self.rejectAll || Self.rejected.contains(job.token) {
                body = #"{"status":"error","error":"AM GET /v1/me/library/playlists?limit=100 -> 403"}"#
            } else if job.op == "pull" {
                body = #"{"status":"done","result":{"storefront":"us","playlists":[{"id":"p.1","name":"Road Trip","trackCatalogIds":[]}]}}"#
            } else {
                body = #"{"status":"done","result":{"playlists":[],"errors":[]}}"#
            }
        } else {
            status = 404
        }
        Self.lock.unlock()
        let resp = HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: nil,
                                   headerFields: ["Content-Type": "application/json"])!
        client?.urlProtocol(self, didReceive: resp, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Data(body.utf8))
        client?.urlProtocolDidFinishLoading(self)
    }

    private static func read(_ stream: InputStream) -> Data {
        stream.open(); defer { stream.close() }
        var data = Data()
        var buf = [UInt8](repeating: 0, count: 4096)
        while stream.hasBytesAvailable {
            let n = stream.read(&buf, maxLength: buf.count)
            if n <= 0 { break }
            data.append(buf, count: n)
        }
        return data
    }
}

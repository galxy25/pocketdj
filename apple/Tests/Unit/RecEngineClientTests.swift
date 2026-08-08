import XCTest
@testable import PocketDJ

/// `RecEngineClient` request construction + error mapping, driven through the injectable
/// transport closure (no network). The captured `URLRequest` IS the contract: bearer key +
/// identity headers on every call, the documented paths/methods, 403 → `.keyMismatch`.
final class RecEngineClientTests: XCTestCase {

    /// Thread-safe request recorder for the nonisolated transport closure.
    private final class Spy: @unchecked Sendable {
        private let lock = NSLock()
        private var _requests: [URLRequest] = []
        var status = 200
        var body = Data("{}".utf8)

        var requests: [URLRequest] {
            lock.lock(); defer { lock.unlock() }
            return _requests
        }
        func record(_ req: URLRequest) -> (Data, URLResponse) {
            lock.lock(); _requests.append(req); lock.unlock()
            let resp = HTTPURLResponse(url: req.url!, statusCode: status,
                                       httpVersion: nil, headerFields: nil)!
            return (body, resp)
        }
    }

    private func makeClient(_ spy: Spy) -> RecEngineClient {
        RecEngineClient(base: URL(string: "https://rec.test")!,
                        transport: { spy.record($0) })
    }

    func testPostEventsBuildsAuthAndIdentityHeaders() async throws {
        let spy = Spy()
        spy.body = Data(#"{"ok":true}"#.utf8)
        let client = makeClient(spy)
        let batch = RecUploadBatch(deviceId: "dev", sentAtMs: 1,
                                   plays: [RecPlayEventWire(id: "e", songId: "s", atMs: 1, source: nil)])
        _ = try await client.postEvents(batch, key: "sekrit", profileId: "profile-abc-123")
        let req = try XCTUnwrap(spy.requests.first)
        XCTAssertEqual(req.httpMethod, "POST")
        XCTAssertEqual(req.url?.path, "/events")
        XCTAssertEqual(req.value(forHTTPHeaderField: "Authorization"), "Bearer sekrit")
        XCTAssertEqual(req.value(forHTTPHeaderField: "X-PocketDJ-Profile"), "profile-abc-123")
        XCTAssertEqual(req.value(forHTTPHeaderField: "X-PocketDJ-Device"), DeviceIdentity.current)
        XCTAssertEqual(req.value(forHTTPHeaderField: "Content-Type"), "application/json")
        let sent = try XCTUnwrap(req.httpBody)
        let obj = try XCTUnwrap(try JSONSerialization.jsonObject(with: sent) as? [String: Any])
        XCTAssertEqual((obj["plays"] as? [[String: Any]])?.count, 1)
    }

    func testForYouPathAndLimitQuery() async throws {
        let spy = Spy()
        spy.body = Data(#"{"songs":[]}"#.utf8)
        let client = makeClient(spy)
        _ = try await client.forYou(limit: 50, key: "k", profileId: "profile-abc-123")
        let req = try XCTUnwrap(spy.requests.first)
        XCTAssertEqual(req.httpMethod, "GET")
        XCTAssertEqual(req.url?.path, "/recs/songs")
        XCTAssertEqual(req.url?.query, "limit=50")
        XCTAssertEqual(req.value(forHTTPHeaderField: "Authorization"), "Bearer k")
    }

    func testCollectionSuggestionsPathAndQuery() async throws {
        let spy = Spy()
        spy.body = Data(#"{"suggestions":[]}"#.utf8)
        let client = makeClient(spy)
        _ = try await client.collectionSuggestions(songId: "sng_9", key: "k", profileId: "p")
        let req = try XCTUnwrap(spy.requests.first)
        XCTAssertEqual(req.url?.path, "/recs/collections")
        XCTAssertEqual(req.url?.query, "songId=sng_9")
    }

    func test403MapsToKeyMismatch() async {
        let spy = Spy()
        spy.status = 403
        spy.body = Data(#"{"error":"key-mismatch"}"#.utf8)
        let client = makeClient(spy)
        do {
            _ = try await client.forYou(limit: 50, key: "wrong", profileId: "p")
            XCTFail("a 403 must throw")
        } catch let e as RecEngineClient.ClientError {
            XCTAssertEqual(e, .keyMismatch)
        } catch {
            XCTFail("unexpected error type: \(error)")
        }

        // A generic failure maps to .http(code), not keyMismatch.
        spy.status = 500
        do {
            _ = try await client.forYou(limit: 50, key: "k", profileId: "p")
            XCTFail("a 500 must throw")
        } catch let e as RecEngineClient.ClientError {
            XCTAssertEqual(e, .http(500))
        } catch {
            XCTFail("unexpected error type: \(error)")
        }
    }

    /// The server's 403s are NOT one condition, and the recoveries differ: `key-mismatch` is
    /// fixed in-app ("Delete cloud data"), `enrollment-required` (a rotated server secret) only
    /// by an app update. Collapsing them sent the user to a reset that could never help.
    func test403BodyDisambiguatesEnrollmentRequiredFromKeyMismatch() async {
        let spy = Spy()
        spy.status = 403
        spy.body = Data(#"{"error":"enrollment-required"}"#.utf8)
        let client = makeClient(spy)
        do {
            _ = try await client.postEvents(RecUploadBatch(deviceId: "d", sentAtMs: 1),
                                            key: "k", profileId: "profile-abc-123")
            XCTFail("a 403 must throw")
        } catch let e as RecEngineClient.ClientError {
            XCTAssertEqual(e, .enrollmentRequired)
        } catch {
            XCTFail("unexpected error type: \(error)")
        }

        // Unknown/garbled 403 bodies keep the old mapping — the in-app reset is the only
        // recovery the app can offer for a refusal it doesn't recognize.
        for body in [#"{"error":"profile-cap-reached","max":10}"#, "not json", ""] {
            spy.body = Data(body.utf8)
            do {
                _ = try await client.forYou(limit: 5, key: "k", profileId: "p")
                XCTFail("a 403 must throw")
            } catch let e as RecEngineClient.ClientError {
                XCTAssertEqual(e, .keyMismatch, "body: \(body)")
            } catch {
                XCTFail("unexpected error type: \(error)")
            }
        }
    }

    func testDeleteStateUsesDELETE() async throws {
        let spy = Spy()
        spy.body = Data(#"{"deleted":true}"#.utf8)
        let client = makeClient(spy)
        try await client.deleteState(key: "k", profileId: "p")
        let req = try XCTUnwrap(spy.requests.first)
        XCTAssertEqual(req.httpMethod, "DELETE")
        XCTAssertEqual(req.url?.path, "/state")
    }

    /// The enrollment secret is what stops ANY bearer from minting a fresh profile server-side.
    /// It rides the two routes that CREATE or DESTROY state — and only those.
    func testEnrollmentSecretRidesOnlyTheStateMutatingRoutes() async throws {
        let spy = Spy()
        spy.body = Data(#"{"ok":true}"#.utf8)
        var client = makeClient(spy)
        client.enrollSecret = "enroll-me"
        let header = RecEngineClient.enrollHeader

        _ = try await client.postEvents(RecUploadBatch(deviceId: "d", sentAtMs: 1),
                                        key: "k", profileId: "profile-abc-123")
        XCTAssertEqual(spy.requests[0].value(forHTTPHeaderField: header), "enroll-me",
                       "the FIRST upload is what creates server state — it must enroll")

        spy.body = Data(#"{"deleted":true}"#.utf8)
        try await client.deleteState(key: "k", profileId: "profile-abc-123")
        XCTAssertEqual(spy.requests[1].value(forHTTPHeaderField: header), "enroll-me",
                       "delete must work even when this device's key no longer matches")

        spy.body = Data(#"{"songs":[]}"#.utf8)
        _ = try await client.forYou(limit: 5, key: "k", profileId: "profile-abc-123")
        XCTAssertNil(spy.requests[2].value(forHTTPHeaderField: header),
                     "read routes authenticate with the bearer key alone")

        // A build with no secret configured simply omits the header (the server then refuses
        // enrollment) — it never sends an empty one.
        var bare = makeClient(spy)
        bare.enrollSecret = ""
        spy.body = Data(#"{"ok":true}"#.utf8)
        _ = try await bare.postEvents(RecUploadBatch(deviceId: "d", sentAtMs: 1), key: "k", profileId: "p")
        XCTAssertNil(spy.requests[3].value(forHTTPHeaderField: header))
    }
}

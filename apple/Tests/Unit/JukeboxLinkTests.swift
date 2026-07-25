import XCTest
@testable import PocketDJ

/// F2 — join an in-progress jukebox via a shared link. `JukeboxLink` parses BOTH the universal
/// link (`https://jukebox.pocket-dj.com/<id>/`) and the custom-scheme fallback
/// (`pocketdj://jukebox/<id>`) into a jukebox id + the guest `state.json` URL to poll. Only the
/// id crosses the link — the joining device is a CLIENT, never the lead (no hostKey).
final class JukeboxLinkTests: XCTestCase {

    // MARK: Universal link

    func testParsesUniversalLinkWithTrailingSlash() {
        let link = JukeboxLink(url: URL(string: "https://jukebox.pocket-dj.com/abc23xyz/")!)
        XCTAssertEqual(link?.jukeboxId, "abc23xyz")
        XCTAssertEqual(link?.guestBase?.absoluteString, "https://jukebox.pocket-dj.com")
        XCTAssertEqual(link?.stateURL?.absoluteString,
                       "https://jukebox.pocket-dj.com/abc23xyz/state.json")
    }

    func testParsesUniversalLinkPointingAtStateJson() {
        // A link that already includes /state.json still resolves to the id (first segment).
        let link = JukeboxLink(url: URL(string: "https://jukebox.pocket-dj.com/mnop45qr/state.json")!)
        XCTAssertEqual(link?.jukeboxId, "mnop45qr")
    }

    // MARK: Custom scheme

    func testParsesCustomScheme() {
        let link = JukeboxLink(url: URL(string: "pocketdj://jukebox/abc23xyz")!)
        XCTAssertEqual(link?.jukeboxId, "abc23xyz")
        XCTAssertNil(link?.guestBase, "the custom scheme carries no origin")
        // Falls back to the canonical host for the state URL.
        XCTAssertEqual(link?.stateURL?.absoluteString,
                       "https://jukebox.pocket-dj.com/abc23xyz/state.json")
    }

    func testParsesCustomSchemeTripleSlash() {
        let link = JukeboxLink(url: URL(string: "pocketdj:///jukebox/abc23xyz")!)
        XCTAssertEqual(link?.jukeboxId, "abc23xyz")
    }

    // MARK: Rejection (never misread an unrelated URL as a jukebox link)

    func testRejectsUnrelatedURLs() {
        // OAuth redirect (a different non-file URL the app's onOpenURL also sees).
        XCTAssertNil(JukeboxLink(url: URL(string: "https://accounts.example.com/authorize?code=1")!))
        // Right host, no id.
        XCTAssertNil(JukeboxLink(url: URL(string: "https://jukebox.pocket-dj.com/")!))
        // Right host, malformed id (not base32 [a-z2-7]).
        XCTAssertNil(JukeboxLink(url: URL(string: "https://jukebox.pocket-dj.com/BAD_ID!!/")!))
        // Custom scheme, wrong path root.
        XCTAssertNil(JukeboxLink(url: URL(string: "pocketdj://settings/open")!))
        // A .pdjcollection file URL (the app's other onOpenURL branch) is not a jukebox link.
        XCTAssertNil(JukeboxLink(url: URL(fileURLWithPath: "/tmp/My Party.pocket.pdjcollection")))
    }

    func testIdValidation() {
        XCTAssertTrue(JukeboxLink.isValidId("abcd2345"))
        XCTAssertFalse(JukeboxLink.isValidId("abc"))              // too short (<4)
        XCTAssertFalse(JukeboxLink.isValidId("ABCD2345"))         // uppercase not in base32
        XCTAssertFalse(JukeboxLink.isValidId("abcd2389"))         // 8,9 not in [2-7]
    }

    // MARK: Guest state decode (the state.json a joined client reads)

    func testDecodesGuestStateLeniently() throws {
        let json = """
        {"v":1,"jukeboxId":"abc23xyz","name":"Friday Mix","updatedAt":1,"ended":false,"hear":true,
         "nowPlaying":{"title":"Pulse","artist":"Aria","lengthMs":180000,"positionMs":42000},
         "upNext":[{"title":"Drift","artist":"Cass"}],
         "played":[{"title":"Onset","artist":"Vale","endedAt":100}],
         "requests":[{"id":"rq_1","title":"Neon","artist":"Ivo","status":"pending"}],
         "apiBase":"https://host.example/jukebox"}
        """
        let s = try JSONDecoder().decode(JukeboxGuestState.self, from: Data(json.utf8))
        XCTAssertEqual(s.jukeboxId, "abc23xyz")
        XCTAssertEqual(s.name, "Friday Mix")
        XCTAssertEqual(s.hear, true)
        XCTAssertEqual(s.nowPlaying?.title, "Pulse")
        XCTAssertEqual(s.upNext.first?.artist, "Cass")
        XCTAssertEqual(s.played.first?.title, "Onset")
        XCTAssertEqual(s.requests.first?.status, "pending")
        XCTAssertEqual(s.apiBase, "https://host.example/jukebox")
    }

    /// A partial/older state.json (missing arrays + apiBase) still decodes — arrays default to [].
    func testDecodesPartialGuestState() throws {
        let json = """
        {"jukeboxId":"abc23xyz","name":"Bare","nowPlaying":null}
        """
        let s = try JSONDecoder().decode(JukeboxGuestState.self, from: Data(json.utf8))
        XCTAssertEqual(s.jukeboxId, "abc23xyz")
        XCTAssertNil(s.nowPlaying)
        XCTAssertTrue(s.upNext.isEmpty)
        XCTAssertTrue(s.played.isEmpty)
        XCTAssertTrue(s.requests.isEmpty)
        XCTAssertNil(s.apiBase)
    }
}

/// The guest-client verbs a JOINED device uses — `guestState` reads the public CloudFront
/// state.json (no hostKey); `submitGuestRequest` posts to the broker's public request endpoint,
/// mirroring the web guest page's `<apiBase>/jukebox/<id>/request`.
@MainActor
final class JukeboxGuestClientTests: XCTestCase {
    private func makeClient() -> JukeboxClient {
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [JukeboxGuestStub.self]
        return JukeboxClient(baseURL: "", token: "", session: URLSession(configuration: config))
    }

    func testGuestStateDecodes() async throws {
        JukeboxGuestStub.reset()
        JukeboxGuestStub.getBody = Data("""
        {"jukeboxId":"abc23xyz","name":"Party","nowPlaying":{"title":"Pulse","artist":"Aria"},
         "upNext":[{"title":"Drift","artist":"Cass"}],"played":[],"requests":[],
         "apiBase":"https://host.example/jukebox"}
        """.utf8)
        let s = try await makeClient().guestState(
            url: URL(string: "https://jukebox.pocket-dj.com/abc23xyz/state.json")!)
        XCTAssertEqual(s.jukeboxId, "abc23xyz")
        XCTAssertEqual(s.nowPlaying?.title, "Pulse")
        XCTAssertEqual(s.upNext.first?.artist, "Cass")
        XCTAssertEqual(s.apiBase, "https://host.example/jukebox")
    }

    func testSubmitGuestRequestHitsPublicEndpoint() async throws {
        JukeboxGuestStub.reset()
        try await makeClient().submitGuestRequest(
            apiBase: "https://host.example/jukebox", jukeboxId: "abc23xyz",
            title: "Neon", artist: "Ivo", clientId: "dev1")
        // Mirrors the web guest page: <apiBase>/jukebox/<id>/request.
        XCTAssertEqual(JukeboxGuestStub.lastPOSTURL?.absoluteString,
                       "https://host.example/jukebox/jukebox/abc23xyz/request")
    }

    /// A trailing slash on apiBase doesn't double up into `//jukebox`.
    func testSubmitGuestRequestTrimsTrailingSlash() async throws {
        JukeboxGuestStub.reset()
        try await makeClient().submitGuestRequest(
            apiBase: "https://host.example/jukebox/", jukeboxId: "abc23xyz",
            title: "Neon", artist: "Ivo", clientId: "dev1")
        XCTAssertEqual(JukeboxGuestStub.lastPOSTURL?.absoluteString,
                       "https://host.example/jukebox/jukebox/abc23xyz/request")
    }
}

/// Serves a canned state.json for GETs and records POST URLs (the guest request endpoint).
private final class JukeboxGuestStub: URLProtocol {
    static var getBody = Data("{}".utf8)
    static var lastPOSTURL: URL?
    static func reset() { getBody = Data("{}".utf8); lastPOSTURL = nil }
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func stopLoading() {}
    override func startLoading() {
        let isPost = request.httpMethod == "POST"
        if isPost { Self.lastPOSTURL = request.url }
        let body = isPost ? Data("{\"ok\":true}".utf8) : Self.getBody
        let resp = HTTPURLResponse(url: request.url!, statusCode: 200,
                                   httpVersion: "HTTP/1.1", headerFields: nil)!
        client?.urlProtocol(self, didReceive: resp, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: body)
        client?.urlProtocolDidFinishLoading(self)
    }
}

import XCTest
@testable import PocketDJ

/// Browse ▸ Discover client plumbing (RipsStore):
///   • `discoverSearch` GETs the rip server's `/search` proxy (q + limit, bearer auth),
///     decodes the results envelope into `DiscoverHit`s (id = songId), and surfaces
///     failures via `discoverError` instead of throwing — a 401 must point the user at
///     Settings ▸ Rip server token.
///   • `discoverAdd` rides the EXISTING ad-hoc `/rip` path (`requestRip`), carrying the
///     `amrec_` songId + title/artist/appleMusicId/lengthMs so the server can synthesize
///     its ad-hoc catalog row; the queued job is recorded so the row shows progress.
///
/// A scriptable `URLProtocol` stands in for the server (no real network).
@MainActor
final class DiscoverStoreTests: XCTestCase {
    private let ripsBase = URL(string: "https://rips.test")!

    override func setUp() {
        super.setUp()
        DiscoverURLProtocol.reset()
    }

    private func makeStore(serverURL: String = "https://imac.test", token: String = "tok") -> RipsStore {
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [DiscoverURLProtocol.self]
        let rips = RipsStore(ripsBase: ripsBase, session: URLSession(configuration: config))
        let settings = SettingsStore(defaults: UserDefaults(suiteName: "test.\(UUID().uuidString)")!)
        settings.ripServerURL = serverURL
        settings.ripToken = token
        rips.settings = settings
        return rips
    }

    // MARK: /search — request shape + DiscoverHit decoding

    func testDiscoverSearchDecodesHitsAndSendsAuthorizedGet() async {
        let rips = makeStore()
        DiscoverURLProtocol.bodyByPath["/search"] = Data("""
        { "results": [
            { "appleMusicId": "123", "title": "Take On Me", "artist": "a-ha",
              "album": "Hunting High and Low", "artworkUrl": "https://art.test/123.jpg",
              "durationMs": 225000, "songId": "amrec_123", "ripped": false },
            { "appleMusicId": "456", "title": "Hunting High and Low", "artist": "a-ha",
              "durationMs": 0, "songId": "amrec_456", "ripped": true,
              "url": "https://rips.test/rips/amrec_456.mp3" }
          ] }
        """.utf8)

        let hits = await rips.discoverSearch("take on me", limit: 25)

        XCTAssertEqual(hits.count, 2)
        XCTAssertNil(rips.discoverError)
        // Identity = songId (the ad-hoc rip id), and the decoded fields round-trip.
        XCTAssertEqual(hits[0].id, "amrec_123")
        XCTAssertEqual(hits[0].appleMusicId, "123")
        XCTAssertEqual(hits[0].title, "Take On Me")
        XCTAssertEqual(hits[0].album, "Hunting High and Low")
        XCTAssertEqual(hits[0].artworkUrl, "https://art.test/123.jpg")
        XCTAssertEqual(hits[0].durationMs, 225000)
        XCTAssertEqual(hits[0].ripped, false)
        XCTAssertNil(hits[0].url)
        XCTAssertEqual(hits[1].ripped, true)
        XCTAssertEqual(hits[1].url, "https://rips.test/rips/amrec_456.mp3")
        XCTAssertNil(hits[1].album, "optional fields decode as nil when absent")
        // Request shape: GET /search?q=…&limit=… with the bearer token.
        let req = DiscoverURLProtocol.last(path: "/search")
        XCTAssertEqual(req?.httpMethod, "GET")
        let query = req?.url?.query ?? ""
        XCTAssertTrue(query.contains("q=take%20on%20me"), "query is percent-encoded: \(query)")
        XCTAssertTrue(query.contains("limit=25"))
        XCTAssertEqual(req?.value(forHTTPHeaderField: "Authorization"), "Bearer tok")
    }

    func testDiscoverSearch401PointsAtToken() async {
        let rips = makeStore()
        DiscoverURLProtocol.statusCodeByPath["/search"] = 401
        let hits = await rips.discoverSearch("abba")
        XCTAssertTrue(hits.isEmpty)
        XCTAssertTrue(rips.discoverError?.contains("token") == true,
                      "401 must mention the rip-server token: \(rips.discoverError ?? "nil")")
    }

    func testDiscoverSearchNoServerNoNetwork() async {
        let rips = makeStore(serverURL: "")
        let hits = await rips.discoverSearch("abba")
        XCTAssertTrue(hits.isEmpty)
        XCTAssertNotNil(rips.discoverError)
        XCTAssertEqual(DiscoverURLProtocol.count(path: "/search"), 0)
    }

    func testDiscoverSearchEmptyQueryNoRequest() async {
        let rips = makeStore()
        let hits = await rips.discoverSearch("   ")
        XCTAssertTrue(hits.isEmpty)
        XCTAssertNil(rips.discoverError, "an empty query is a healthy no-op")
        XCTAssertEqual(DiscoverURLProtocol.count(path: "/search"), 0)
    }

    /// A failed search sets the error; the next healthy search clears it.
    func testDiscoverSearchRecoversAfterFailure() async {
        let rips = makeStore()
        DiscoverURLProtocol.statusCodeByPath["/search"] = 500
        _ = await rips.discoverSearch("abba")
        XCTAssertNotNil(rips.discoverError)
        DiscoverURLProtocol.statusCodeByPath["/search"] = 200
        DiscoverURLProtocol.bodyByPath["/search"] = Data(#"{ "results": [] }"#.utf8)
        let hits = await rips.discoverSearch("abba")
        XCTAssertTrue(hits.isEmpty)
        XCTAssertNil(rips.discoverError)
    }

    // MARK: discoverAdd — the ad-hoc /rip descriptor + job tracking

    private var hit: RipsStore.DiscoverHit {
        RipsStore.DiscoverHit(appleMusicId: "123", title: "Take On Me", artist: "a-ha",
                              album: "Hunting High and Low", artworkUrl: nil,
                              durationMs: 225000, songId: "amrec_123", ripped: false, url: nil)
    }

    func testDiscoverAddPostsAdHocRipDescriptor() async {
        let rips = makeStore()
        DiscoverURLProtocol.bodyByPath["/rip"] =
            Data(#"{"jobId":"job_1","songId":"amrec_123","phase":"queued"}"#.utf8)

        await rips.discoverAdd(hit)

        XCTAssertEqual(DiscoverURLProtocol.count(path: "/rip"), 1)
        let sent = DiscoverURLProtocol.lastBodyJSON(path: "/rip")
        XCTAssertEqual(sent?["songId"] as? String, "amrec_123")
        XCTAssertEqual(sent?["title"] as? String, "Take On Me")
        XCTAssertEqual(sent?["artist"] as? String, "a-ha")
        XCTAssertEqual(sent?["appleMusicId"] as? String, "123")
        XCTAssertEqual(sent?["lengthMs"] as? Int, 225000)
        // The queued job is recorded so the Discover row shows live progress.
        XCTAssertEqual(rips.jobs["amrec_123"]?.jobId, "job_1")
        XCTAssertEqual(rips.jobs["amrec_123"]?.phase, .queued)
        XCTAssertNil(rips.discoverError)
    }

    func testDiscoverAddAlreadyCachedSkipsNetwork() async {
        let rips = makeStore()
        rips.setManifest(["amrec_123": .init(key: "rips/amrec_123.mp3")])
        await rips.discoverAdd(hit)
        XCTAssertEqual(DiscoverURLProtocol.count(path: "/rip"), 0, "cached song must not re-POST /rip")
    }

    func testDiscoverAddFailureSurfacesError() async {
        let rips = makeStore()
        DiscoverURLProtocol.statusCodeByPath["/rip"] = 500
        await rips.discoverAdd(hit)
        XCTAssertNotNil(rips.discoverError)
        XCTAssertNil(rips.jobs["amrec_123"])
    }
}

/// Scriptable, request-recording `URLProtocol` standing in for the rip server —
/// per-path bodies + status overrides, full request capture (URL/method/headers/body).
private final class DiscoverURLProtocol: URLProtocol {
    static var bodyByPath: [String: Data] = [:]
    static var statusCodeByPath: [String: Int] = [:]

    private static let lock = NSLock()
    private static var requests: [(request: URLRequest, body: Data?)] = []

    static func reset() {
        lock.lock(); defer { lock.unlock() }
        bodyByPath = [:]; statusCodeByPath = [:]; requests = []
    }

    static func count(path: String) -> Int {
        lock.lock(); defer { lock.unlock() }
        return requests.filter { $0.request.url?.path == path }.count
    }

    static func last(path: String) -> URLRequest? {
        lock.lock(); defer { lock.unlock() }
        return requests.last { $0.request.url?.path == path }?.request
    }

    static func lastBodyJSON(path: String) -> [String: Any]? {
        lock.lock()
        let data = requests.last { $0.request.url?.path == path }?.body
        lock.unlock()
        guard let data else { return nil }
        return (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
    }

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func stopLoading() {}

    override func startLoading() {
        let path = request.url?.path ?? ""
        let body: Data?
        if let stream = request.httpBodyStream {
            body = Self.read(stream)
        } else {
            body = request.httpBody
        }
        Self.lock.lock()
        Self.requests.append((request, body))
        let status = Self.statusCodeByPath[path] ?? 200
        let payload = Self.bodyByPath[path] ?? Data("{}".utf8)
        Self.lock.unlock()

        let response = HTTPURLResponse(url: request.url!, statusCode: status,
                                       httpVersion: "HTTP/1.1", headerFields: nil)!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: payload)
        client?.urlProtocolDidFinishLoading(self)
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

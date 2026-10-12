import XCTest
@testable import PocketDJ

/// Remote endpoint config (docs/design/remote-endpoints.md): schema-v1 decode, the host
/// allowlist, the resolution order (cached last-good → compiled-in), persistence of the
/// last-good doc, the fetch/refresh path, and — the point of it all — that the call sites read
/// the resolver live, so swapping the config changes the URLs services build.
final class RemoteEndpointsTests: XCTestCase {

    private static let green: [String: Any] = [
        "v": 1,
        "env": "green",
        "endpoints": [
            "catalogBase": "https://dgreen123.cloudfront.net",
            "ripsBase": "https://pocketdj-rips-623170744161.s3.us-west-2.amazonaws.com",
            "amPlaylistSyncBase": "https://abc123.execute-api.us-west-2.amazonaws.com",
            "recEngineBase": "https://def456.execute-api.us-west-2.amazonaws.com",
            "diagLogsBase": "https://pocketdj-logs-623170744161.s3.us-west-2.amazonaws.com",
        ],
    ]

    private static func data(_ obj: Any) -> Data { try! JSONSerialization.data(withJSONObject: obj) }

    private static func doc(replacing key: String, with value: Any?) -> Data {
        var d = green
        var eps = d["endpoints"] as! [String: Any]
        eps[key] = value
        d["endpoints"] = eps
        return data(d)
    }

    private var tmpDir: URL!
    private var savedResolver: EndpointResolver!

    override func setUp() {
        super.setUp()
        tmpDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("endpoints-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: tmpDir, withIntermediateDirectories: true)
        savedResolver = Config.endpoints
    }

    override func tearDown() {
        Config.endpoints = savedResolver
        try? FileManager.default.removeItem(at: tmpDir)
        super.tearDown()
    }

    private var cacheURL: URL { tmpDir.appendingPathComponent("pocketdj-endpoints.json") }

    private func greenConfig() throws -> EndpointConfig {
        try EndpointConfig.decode(Self.data(Self.green)).get()
    }

    // MARK: Decode

    func testCommittedBlueDocEqualsCompiledInDefaults() throws {
        let repo = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent()
        let blue = try Data(contentsOf: repo.appendingPathComponent("config/endpoints.blue.json"))
        let cfg = try EndpointConfig.decode(blue).get()
        XCTAssertEqual(cfg, EndpointConfig.compiledIn)
        for key in EndpointKey.allCases {
            XCTAssertEqual(cfg.url(key), EndpointConfig.compiledIn.url(key), key.rawValue)
        }
    }

    func testCompiledInMatchesTodaysBlueValues() {
        let c = EndpointConfig.compiledIn
        XCTAssertEqual(c.env, "blue")
        XCTAssertEqual(c.url(.catalogBase).absoluteString, "https://d2p4cubg6se03u.cloudfront.net")
        XCTAssertEqual(c.url(.catalogBaseDev).absoluteString, "https://djictbz9w796r.cloudfront.net")
        XCTAssertEqual(c.url(.ripsBase).absoluteString,
                       "https://pocketdj-rips-011183829623.s3.us-west-2.amazonaws.com")
        XCTAssertEqual(c.url(.amPlaylistSyncBase).host, "ynwdaa8vh2.execute-api.us-west-2.amazonaws.com")
        XCTAssertEqual(c.url(.recEngineBase).host, "n5ordrwfe9.execute-api.us-west-2.amazonaws.com")
        XCTAssertEqual(c.url(.listeningPocketsBase), c.url(.recEngineBase))
        XCTAssertEqual(c.url(.diagLogsBase).host, "pocketdj-logs-011183829623.s3.us-west-2.amazonaws.com")
    }

    func testOptionalKeysDeriveFromTheSameDocNeverFromBlue() throws {
        let cfg = try greenConfig()
        XCTAssertEqual(cfg.env, "green")
        XCTAssertEqual(cfg.url(.listeningPocketsBase).host, "def456.execute-api.us-west-2.amazonaws.com")
        XCTAssertEqual(cfg.url(.catalogBaseDev).host, "dgreen123.cloudfront.net")
        XCTAssertEqual(cfg.url(.searchConfigURL).absoluteString,
                       "https://dgreen123.cloudfront.net/search-config.json")
    }

    func testTrailingSlashTrimmedAndUnknownKeysIgnored() throws {
        var d = Self.green
        var eps = d["endpoints"] as! [String: Any]
        eps["catalogBase"] = "https://dgreen123.cloudfront.net/"
        eps["somethingNew"] = "https://example.com"   // unknown key: ignored, not a rejection
        d["endpoints"] = eps
        d["futureField"] = ["x": 1]
        let cfg = try EndpointConfig.decode(Self.data(d)).get()
        XCTAssertEqual(cfg.url(.catalogBase).absoluteString, "https://dgreen123.cloudfront.net")
    }

    // MARK: Allowlist / rejection

    func testHostAllowlist() {
        for ok in ["app.pocket-dj.com", "pocket-dj.com", "d2p4cubg6se03u.cloudfront.net",
                   "n5ordrwfe9.execute-api.us-west-2.amazonaws.com",
                   "pocketdj-rips-623170744161.s3.us-west-2.amazonaws.com"] {
            XCTAssertTrue(EndpointConfig.isAllowedHost(ok), ok)
        }
        for bad in ["evil.com", "pocket-dj.com.evil.com", "evilpocket-dj.com",
                    "x.execute-api.us-east-1.amazonaws.com", "other-bucket.s3.us-west-2.amazonaws.com",
                    "pocketdj-rips.s3.us-east-1.amazonaws.com", "cloudfront.net"] {
            XCTAssertFalse(EndpointConfig.isAllowedHost(bad), bad)
        }
    }

    func testRejectsInvalidDocuments() {
        var wrongVersion = Self.green; wrongVersion["v"] = 2
        var noEnv = Self.green; noEnv["env"] = " "
        var noEndpoints = Self.green; noEndpoints["endpoints"] = nil
        let cases: [(String, Data, EndpointConfig.Rejection)] = [
            ("html", Data("<!doctype html><html></html>".utf8), .notJSON),
            ("array", Self.data([1, 2]), .notJSON),
            ("version", Self.data(wrongVersion), .unsupportedVersion),
            ("env", Self.data(noEnv), .missingEnv),
            ("endpoints", Self.data(noEndpoints), .missingEndpoints),
            ("missing required", Self.doc(replacing: "ripsBase", with: nil), .missingKey("ripsBase")),
            ("http", Self.doc(replacing: "catalogBase", with: "http://dgreen123.cloudfront.net"),
             .rejectedURL("catalogBase")),
            ("foreign host", Self.doc(replacing: "recEngineBase", with: "https://api.evil.com"),
             .rejectedURL("recEngineBase")),
            ("foreign optional", Self.doc(replacing: "searchConfigURL", with: "https://evil.com/x.json"),
             .rejectedURL("searchConfigURL")),
            ("credentials", Self.doc(replacing: "catalogBase", with: "https://u:p@dgreen123.cloudfront.net"),
             .rejectedURL("catalogBase")),
            ("query", Self.doc(replacing: "catalogBase", with: "https://dgreen123.cloudfront.net/?x=1"),
             .rejectedURL("catalogBase")),
            ("port", Self.doc(replacing: "catalogBase", with: "https://dgreen123.cloudfront.net:8443"),
             .rejectedURL("catalogBase")),
            ("non-string", Self.doc(replacing: "catalogBase", with: 42), .rejectedURL("catalogBase")),
        ]
        for (label, data, expected) in cases {
            switch EndpointConfig.decode(data) {
            case .success: XCTFail("\(label) should be rejected")
            case .failure(let why): XCTAssertEqual(why, expected, label)
            }
        }
    }

    // MARK: Resolution order + persistence

    func testNoCacheResolvesToCompiledIn() {
        let r = EndpointResolver(cacheURL: cacheURL, fetcher: nil)
        XCTAssertEqual(r.source, .compiledIn)
        XCTAssertEqual(r.config, .compiledIn)
    }

    func testAcceptedDocIsPersistedAndWinsOnNextLaunch() throws {
        let r = EndpointResolver(cacheURL: cacheURL, fetcher: nil)
        XCTAssertEqual(try r.apply(Self.data(Self.green)).get(), true)
        XCTAssertEqual(r.source, .remote)
        XCTAssertEqual(r.url(.ripsBase).host, "pocketdj-rips-623170744161.s3.us-west-2.amazonaws.com")
        XCTAssertGreaterThan(r.generation, 0)

        let relaunch = EndpointResolver(cacheURL: cacheURL, fetcher: nil)
        XCTAssertEqual(relaunch.source, .cached)
        XCTAssertEqual(relaunch.config, try greenConfig())
    }

    func testRejectedDocKeepsLastGoodAndDoesNotOverwriteCache() throws {
        let r = EndpointResolver(cacheURL: cacheURL, fetcher: nil)
        _ = r.apply(Self.data(Self.green))
        let bad = Self.doc(replacing: "ripsBase", with: "https://evil.com")
        if case .success = r.apply(bad) { XCTFail("must reject") }
        XCTAssertEqual(r.config.env, "green")
        XCTAssertEqual(EndpointResolver(cacheURL: cacheURL, fetcher: nil).config.env, "green")
    }

    func testCorruptOrTamperedCacheFallsBackToCompiledIn() throws {
        try Data("not json".utf8).write(to: cacheURL)
        XCTAssertEqual(EndpointResolver(cacheURL: cacheURL, fetcher: nil).source, .compiledIn)
        // A cache file whose doc no longer validates (e.g. edited) is not trusted either.
        let tampered = try JSONSerialization.data(withJSONObject: [
            "doc": String(decoding: Self.doc(replacing: "catalogBase", with: "https://evil.com"), as: UTF8.self),
        ])
        try tampered.write(to: cacheURL)
        XCTAssertEqual(EndpointResolver(cacheURL: cacheURL, fetcher: nil).source, .compiledIn)
    }

    // MARK: Fetch

    private static func fetcher(status: Int = 200, body: Data, counter: Counter? = nil)
        -> EndpointResolver.Fetcher {
        { url in
            counter?.bump()
            XCTAssertEqual(url, EndpointResolver.remoteURL)
            return (body, HTTPURLResponse(url: url, statusCode: status, httpVersion: nil, headerFields: nil)!)
        }
    }

    final class Counter: @unchecked Sendable {
        private let lock = NSLock(); private var n = 0
        func bump() { lock.lock(); n += 1; lock.unlock() }
        var value: Int { lock.lock(); defer { lock.unlock() }; return n }
    }

    func testRemoteURLIsTheStableOwnDomainURL() {
        XCTAssertEqual(EndpointResolver.remoteURL.absoluteString, "https://app.pocket-dj.com/config/endpoints.json")
    }

    func testRefreshAppliesValidRemoteDoc() async throws {
        let r = EndpointResolver(cacheURL: cacheURL, fetcher: Self.fetcher(body: Self.data(Self.green)))
        let changed = await r.refresh(force: true)
        XCTAssertTrue(changed)
        XCTAssertEqual(r.source, .remote)
        XCTAssertEqual(r.config.env, "green")
        XCTAssertTrue(r.summary.contains("env=green"))
        // Same doc again: accepted, but nothing changed.
        let again = await r.refresh(force: true)
        XCTAssertFalse(again)
    }

    func testRefreshIgnoresSpaFallbackHttpErrorsAndNetworkFailures() async {
        let html = EndpointResolver(cacheURL: cacheURL,
                                    fetcher: Self.fetcher(body: Data("<!doctype html>".utf8)))
        let htmlChanged = await html.refresh(force: true)
        XCTAssertFalse(htmlChanged)
        XCTAssertEqual(html.source, .compiledIn)

        let http = EndpointResolver(cacheURL: cacheURL,
                                    fetcher: Self.fetcher(status: 503, body: Self.data(Self.green)))
        let httpChanged = await http.refresh(force: true)
        XCTAssertFalse(httpChanged)
        XCTAssertEqual(http.config, .compiledIn)
        XCTAssertEqual(http.lastOutcome, "http 503")

        let offline = EndpointResolver(cacheURL: cacheURL, fetcher: { _ in throw URLError(.notConnectedToInternet) })
        let offlineChanged = await offline.refresh(force: true)
        XCTAssertFalse(offlineChanged)
        XCTAssertEqual(offline.config, .compiledIn)
        XCTAssertFalse(FileManager.default.fileExists(atPath: cacheURL.path), "nothing persisted")
    }

    func testForegroundRefreshIsThrottled() async {
        let counter = Counter()
        let r = EndpointResolver(cacheURL: cacheURL,
                                 fetcher: Self.fetcher(body: Self.data(Self.green), counter: counter))
        let t0 = Date()
        _ = await r.refresh(force: true, now: t0)
        _ = await r.refresh(now: t0.addingTimeInterval(EndpointResolver.minRefreshInterval - 1))
        XCTAssertEqual(counter.value, 1)
        _ = await r.refresh(now: t0.addingTimeInterval(EndpointResolver.minRefreshInterval + 1))
        XCTAssertEqual(counter.value, 2)
    }

    func testTestHostSharedResolverIsCompiledInAndOffline() async {
        // Unit tests must never fetch or read a developer's persisted cache.
        XCTAssertNil(EndpointResolver.shared.cacheURL)
        let changed = await EndpointResolver.shared.refresh(force: true)
        XCTAssertFalse(changed)
        XCTAssertEqual(EndpointResolver.shared.config, .compiledIn)
    }

    // MARK: Call sites read the resolver live

    func testSwappingTheConfigChangesConfigAccessors() throws {
        Config.endpoints = EndpointResolver(config: try greenConfig())
        XCTAssertEqual(Config.ripsBase.host, "pocketdj-rips-623170744161.s3.us-west-2.amazonaws.com")
        XCTAssertEqual(Config.catalogBase.host, "dgreen123.cloudfront.net")
        XCTAssertEqual(Config.indexURL.absoluteString, "https://dgreen123.cloudfront.net/current-index.json")
        XCTAssertEqual(Config.amPlaylistSyncBase.host, "abc123.execute-api.us-west-2.amazonaws.com")
        XCTAssertEqual(Config.recEngineBase.host, "def456.execute-api.us-west-2.amazonaws.com")
        XCTAssertEqual(Config.listeningPocketsBase.host, "def456.execute-api.us-west-2.amazonaws.com")
        XCTAssertEqual(Config.diagLogsBase.host, "pocketdj-logs-623170744161.s3.us-west-2.amazonaws.com")
        XCTAssertEqual(Config.instrumentsIndexURL.absoluteString,
                       "https://pocketdj-rips-623170744161.s3.us-west-2.amazonaws.com/rips/instruments/index.json")
        XCTAssertEqual(Config.artURL("/art/a.jpg")?.absoluteString, "https://dgreen123.cloudfront.net/art/a.jpg")
        XCTAssertEqual(Config.searchConfigURL.absoluteString, "https://dgreen123.cloudfront.net/search-config.json")
        Config.endpoints = EndpointResolver(config: .compiledIn)
        XCTAssertEqual(Config.ripsBase.host, "pocketdj-rips-011183829623.s3.us-west-2.amazonaws.com")
    }

    @MainActor
    func testRipsStoreBuildsStreamURLsOnTheLiveBucket() throws {
        let rips = RipsStore()   // no injected base: follows the resolver
        rips.setManifest(["s1": .init(key: "rips/s1.mp3")])
        XCTAssertEqual(rips.cachedURL("s1")?.host, "pocketdj-rips-011183829623.s3.us-west-2.amazonaws.com")
        Config.endpoints = EndpointResolver(config: try greenConfig())
        // SAME store instance (built before the flip) — the next URL uses the new bucket.
        XCTAssertEqual(rips.cachedURL("s1")?.absoluteString,
                       "https://pocketdj-rips-623170744161.s3.us-west-2.amazonaws.com/rips/s1.mp3")
    }

    func testRecEngineAndPocketsClientsHitTheLiveHost() async throws {
        final class Spy: @unchecked Sendable {
            private let lock = NSLock(); private var urls: [URL] = []
            func record(_ r: URLRequest) -> (Data, URLResponse) {
                lock.lock(); urls.append(r.url!); lock.unlock()
                return (Data("{}".utf8), HTTPURLResponse(url: r.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!)
            }
            var all: [URL] { lock.lock(); defer { lock.unlock() }; return urls }
        }
        let spy = Spy()
        let rec = RecEngineClient(transport: { spy.record($0) })
        let pockets = ListeningPocketsClient(transport: { spy.record($0) })
        Config.endpoints = EndpointResolver(config: try greenConfig())
        _ = await rec.health()
        _ = await pockets.health()
        XCTAssertEqual(spy.all.map { $0.host }, ["def456.execute-api.us-west-2.amazonaws.com",
                                                 "def456.execute-api.us-west-2.amazonaws.com"])
        Config.endpoints = EndpointResolver(config: .compiledIn)
        _ = await rec.health()
        XCTAssertEqual(spy.all.last?.host, "n5ordrwfe9.execute-api.us-west-2.amazonaws.com")
    }

    func testPersistedBuiltInSourceURLsRebaseOntoTheLiveCatalog() throws {
        let vinyl = SourceConfig(name: "My Vinyl",
                                 urlString: "https://d2p4cubg6se03u.cloudfront.net/current-index.json")
        let dev = SourceConfig(name: "Dev", urlString: "https://djictbz9w796r.cloudfront.net/digital-index.json")
        let custom = SourceConfig(name: "Mine", urlString: "https://example.org/my-index.json")
        XCTAssertEqual(vinyl.url?.host, "d2p4cubg6se03u.cloudfront.net")   // blue: untouched

        Config.endpoints = EndpointResolver(config: try greenConfig())
        XCTAssertEqual(vinyl.url?.absoluteString, "https://dgreen123.cloudfront.net/current-index.json")
        XCTAssertEqual(dev.url?.absoluteString, "https://dgreen123.cloudfront.net/digital-index.json")
        XCTAssertEqual(custom.url?.absoluteString, "https://example.org/my-index.json")
    }

    func testSourceSavedWhileGreenRebasesAfterFlippingBack() throws {
        let r = EndpointResolver(cacheURL: cacheURL, fetcher: nil)
        _ = r.apply(Self.data(Self.green))
        // Flip back to a blue doc: the green catalog host was SEEN, so it rebases onto blue.
        var blue = Self.green
        blue["env"] = "blue"
        blue["endpoints"] = Dictionary(uniqueKeysWithValues: EndpointKey.allCases.map {
            ($0.rawValue, EndpointConfig.compiledIn.url($0).absoluteString)
        })
        _ = r.apply(Self.data(blue))
        let relaunch = EndpointResolver(cacheURL: cacheURL, fetcher: nil)   // history persisted
        let saved = URL(string: "https://dgreen123.cloudfront.net/current-index.json")!
        XCTAssertEqual(relaunch.rebasedCatalogURL(saved).absoluteString,
                       "https://d2p4cubg6se03u.cloudfront.net/current-index.json")
    }

    func testDocAliasesRebaseExtraHosts() throws {
        var d = Self.green
        d["aliases"] = ["catalogBase": ["old123.cloudfront.net", "evil.com"]]
        let r = EndpointResolver(config: try EndpointConfig.decode(Self.data(d)).get())
        XCTAssertEqual(r.rebasedCatalogURL(URL(string: "https://old123.cloudfront.net/a.json")!).host,
                       "dgreen123.cloudfront.net")
        XCTAssertEqual(r.rebasedCatalogURL(URL(string: "https://evil.com/a.json")!).host, "evil.com",
                       "a non-allowlisted alias is dropped, never rebased")
    }

    func testBearerNeverRidesToTheLiveRipsHost() throws {
        var d = Self.green
        var eps = d["endpoints"] as! [String: Any]
        eps["ripsBase"] = "https://rips.pocket-dj.com"   // a CDN/own-domain rips host
        d["endpoints"] = eps
        Config.endpoints = EndpointResolver(config: try EndpointConfig.decode(Self.data(d)).get())
        XCTAssertFalse(TransferCoordinator.shouldAttachBearer(
            to: URL(string: "https://rips.pocket-dj.com/rips/a.mp3")!, token: "t"))
        XCTAssertTrue(TransferCoordinator.shouldAttachBearer(
            to: URL(string: "https://my-rip-server.example/rip")!, token: "t"))
    }
}

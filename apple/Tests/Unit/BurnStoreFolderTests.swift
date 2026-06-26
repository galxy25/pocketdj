import XCTest
@testable import PocketDJ

/// Feature 2 (burnt-music FOLDER). `BurnStore` writes burned audio + sidecars into the
/// user-picked, security-scoped folder (`SettingsStore.burnFolderBookmark`) when that
/// bookmark resolves to a WRITABLE directory, and otherwise falls back to the app-managed
/// Application Support `burns/` dir. `resolveBurnFolder` + `itemDir` are private, so these
/// tests exercise them through the PUBLIC behavior they drive:
///   • `burn(...)` writes the files INTO the configured folder + records `wasAppStorage == false`,
///   • with no bookmark (or one that resolves to a non-writable dir) it falls back to the
///     app `burns/` dir + records `wasAppStorage == true`,
///   • `localURL(forSong:)` keeps a pre-existing burn resolvable against the dir it was
///     ACTUALLY written to (per-item `wasAppStorage`), even after the folder setting changes.
///
/// On macOS a plain on-disk directory bookmark resolves WITHOUT needing the sandbox
/// entitlement (the test target is unsigned/non-sandboxed), so `burnFolderBookmark` round-
/// trips a real temp dir here. The download bytes come from the same `URLProtocol` stub the
/// other BurnStore tests use.
@MainActor
final class BurnStoreFolderTests: XCTestCase {
    private let ripsBase = URL(string: "https://rips.test")!

    private func makeRips() -> RipsStore {
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [FolderBurnStubURLProtocol.self]
        return RipsStore(ripsBase: ripsBase, session: URLSession(configuration: config))
    }

    private func makeBurns(_ rips: RipsStore) -> BurnStore {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("pdj-burnfolder-\(UUID().uuidString).json")
        addTeardownBlock { try? FileManager.default.removeItem(at: url) }
        return BurnStore(rips: rips, fileURL: url)
    }

    private func makeSettings() -> SettingsStore {
        SettingsStore(defaults: UserDefaults(suiteName: "test.\(UUID().uuidString)")!)
    }

    /// A fresh, writable temp directory + a security-scoped bookmark to it (auto-cleaned).
    private func makeWritableFolder() throws -> (url: URL, bookmark: Data) {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("pdj-burndest-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: dir) }
        let bookmark = try XCTUnwrap(BurnStore.makeBookmark(for: dir), "bookmark for a real temp dir")
        return (dir, bookmark)
    }

    private func cleanAppBurnFiles(_ names: [String]) {
        guard let dir = try? RipsStore.burnsDirectory() else { return }
        for n in names { try? FileManager.default.removeItem(at: dir.appendingPathComponent(n)) }
    }

    override func setUp() {
        super.setUp()
        FolderBurnStubURLProtocol.body = Data("MP3-DATA".utf8)   // 8 bytes
    }

    // MARK: Configured folder → files written there + wasAppStorage == false

    func testBurnUsesConfiguredFolderWhenWritable() async throws {
        let (folder, bookmark) = try makeWritableFolder()
        let rips = makeRips(); let burns = makeBurns(rips)
        let settings = makeSettings()
        settings.burnFolderBookmark = bookmark
        burns.settings = settings

        rips.setManifest(["sng_1": .init(key: "rips/sng_1.mp3", source: "digital")])
        let r = await burns.burn([(id: "sng_1", title: "One", artist: "A")])

        XCTAssertEqual(r.burned, 1)
        // The item is tagged as living in the USER folder (not app storage).
        XCTAssertEqual(burns.items["sng_1"]?.wasAppStorage, false)
        // The audio + sidecar actually landed in the configured folder...
        XCTAssertTrue(FileManager.default.fileExists(atPath: folder.appendingPathComponent("sng_1.mp3").path),
                      "audio written to the configured folder")
        XCTAssertTrue(FileManager.default.fileExists(atPath: folder.appendingPathComponent("sng_1.txt").path),
                      "sidecar written to the configured folder")
        // ...and NOT in the app-managed burns dir.
        if let appDir = try? RipsStore.burnsDirectory() {
            XCTAssertFalse(FileManager.default.fileExists(atPath: appDir.appendingPathComponent("sng_1.mp3").path),
                           "nothing written to app storage when a user folder is configured")
        }
        // localURL resolves against the configured folder. Compare symlink-resolved paths:
        // a bookmark resolves the temp dir to its canonical `/private/var/...` form, while the
        // raw temp URL is `/var/...` (the same file via a symlink).
        XCTAssertEqual(burns.localURL(forSong: "sng_1")?.resolvingSymlinksInPath().path,
                       folder.appendingPathComponent("sng_1.mp3").resolvingSymlinksInPath().path)
    }

    // MARK: No bookmark → fall back to RipsStore.burnsDirectory(), wasAppStorage == true

    func testBurnFallsBackToAppStorageWhenNoBookmark() async {
        cleanAppBurnFiles(["sng_2.mp3", "sng_2.txt"])
        let rips = makeRips(); let burns = makeBurns(rips)
        let settings = makeSettings()
        settings.burnFolderBookmark = nil   // no user folder configured
        burns.settings = settings

        rips.setManifest(["sng_2": .init(key: "rips/sng_2.mp3", source: "digital")])
        let r = await burns.burn([(id: "sng_2", title: "Two", artist: "A")])

        XCTAssertEqual(r.burned, 1)
        XCTAssertEqual(burns.items["sng_2"]?.wasAppStorage, true, "app-storage item is tagged true")
        let appDir = try? RipsStore.burnsDirectory()
        XCTAssertEqual(burns.localURL(forSong: "sng_2")?.path,
                       appDir?.appendingPathComponent("sng_2.mp3").path,
                       "falls back to the app-managed burns dir")
        cleanAppBurnFiles(["sng_2.mp3", "sng_2.txt"])
    }

    // MARK: Non-writable bookmark target → fall back to app storage

    func testBurnFallsBackToAppStorageWhenBookmarkTargetNotWritable() async throws {
        cleanAppBurnFiles(["sng_3.mp3", "sng_3.txt"])
        // Bookmark a directory, then DELETE it: resolving yields a path that isn't a writable
        // dir, so resolveBurnFolder must fall back to app storage (the "denied/unmounted" arm).
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("pdj-gonefolder-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let bookmark = try XCTUnwrap(BurnStore.makeBookmark(for: dir))
        try FileManager.default.removeItem(at: dir)   // the target no longer exists

        let rips = makeRips(); let burns = makeBurns(rips)
        let settings = makeSettings()
        settings.burnFolderBookmark = bookmark
        burns.settings = settings

        rips.setManifest(["sng_3": .init(key: "rips/sng_3.mp3", source: "digital")])
        let r = await burns.burn([(id: "sng_3", title: "Three", artist: "A")])

        XCTAssertEqual(r.burned, 1, "unusable folder falls back to app storage, not a failure")
        XCTAssertEqual(burns.items["sng_3"]?.wasAppStorage, true)
        let appDir = try? RipsStore.burnsDirectory()
        XCTAssertTrue(FileManager.default.fileExists(atPath: appDir!.appendingPathComponent("sng_3.mp3").path))
        cleanAppBurnFiles(["sng_3.mp3", "sng_3.txt"])
    }

    // MARK: Per-item wasAppStorage keeps an app-storage burn resolvable after a folder switch

    /// An item burned to app storage (no folder set) stays resolvable via `localURL` even
    /// after a user folder is later configured — `itemDir` resolves it against the dir it was
    /// ACTUALLY written to (`wasAppStorage == true` → Application Support), never the new
    /// folder. This is the "later folder switch never mis-resolves a pre-existing burn" path.
    func testPreExistingAppStorageBurnStaysResolvableAfterFolderSet() async throws {
        cleanAppBurnFiles(["sng_4.mp3", "sng_4.txt"])
        let rips = makeRips(); let burns = makeBurns(rips)
        let settings = makeSettings()
        burns.settings = settings

        // Burn with NO folder → app storage.
        rips.setManifest(["sng_4": .init(key: "rips/sng_4.mp3", source: "digital")])
        _ = await burns.burn([(id: "sng_4", title: "Four", artist: "A")])
        XCTAssertEqual(burns.items["sng_4"]?.wasAppStorage, true)
        let appDir = try XCTUnwrap(try? RipsStore.burnsDirectory())
        let appPath = appDir.appendingPathComponent("sng_4.mp3").path
        XCTAssertEqual(burns.localURL(forSong: "sng_4")?.path, appPath)

        // NOW configure a user folder. The pre-existing app-storage item must STILL resolve
        // against Application Support (its recorded dir), not the freshly-set user folder.
        let (folder, bookmark) = try makeWritableFolder()
        settings.burnFolderBookmark = bookmark
        XCTAssertEqual(burns.localURL(forSong: "sng_4")?.path, appPath,
                       "the pre-existing app-storage burn resolves against app storage, not the new folder")
        XCTAssertNotEqual(burns.localURL(forSong: "sng_4")?.path,
                          folder.appendingPathComponent("sng_4.mp3").path)
        cleanAppBurnFiles(["sng_4.mp3", "sng_4.txt"])
    }
}

/// Minimal `URLProtocol` serving HTTP 200 + a fixed body for the burn download path.
private final class FolderBurnStubURLProtocol: URLProtocol {
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

/// `BurnStore.cutFileName(amongst:songId:audioFileName:)` — the pure matcher behind the cut
/// self-heal: when an analog shared-album song's in-memory `cutFileName` is stale/nil, the reader
/// re-finds the on-disk cut by its deterministic `-<songId>.mp3` suffix so a no-seek Mix deck loads
/// the RIGHT song instead of silently opening the whole-album mp3. (Regression for the "On & On
/// loaded the whole album" bug.)
final class BurnStoreCutMatchTests: XCTestCase {
    private let albumFile = "SWV-New Beginning (SWV album)-1996-R&B-alb_cd9fed0030f2.mp3"
    private let cutFile = "SWV-On & On (featuring Erick Sermon)-New Beginning (SWV album)-1996-R&B-11B-A major-96-sng_26d99e750931.mp3"
    private let songId = "sng_26d99e750931"

    func testAnalogSharedAlbumFindsTheCutNotTheAlbum() {
        let names = [albumFile, cutFile, "Other-Artist-Song-alb_dead.mp3"]
        XCTAssertEqual(
            BurnStore.cutFileName(amongst: names, songId: songId, audioFileName: albumFile),
            cutFile)
    }

    func testDigitalPerSongFileIsNotMistakenForACut() {
        // A digital burn's audio file ALSO ends "-<songId>.mp3" but IS the song — excluding the
        // item's own audioFileName means no false cut is returned.
        let digital = "Aaliyah-Back & Forth-...-sng_c7ea598bd2dd.mp3"
        XCTAssertNil(
            BurnStore.cutFileName(amongst: [digital], songId: "sng_c7ea598bd2dd", audioFileName: digital))
    }

    func testNoCutOnDiskReturnsNil() {
        XCTAssertNil(
            BurnStore.cutFileName(amongst: [albumFile], songId: songId, audioFileName: albumFile))
    }

    func testBarePrefixlessCutName() {
        let bare = "\(songId).mp3"
        XCTAssertEqual(
            BurnStore.cutFileName(amongst: [albumFile, bare], songId: songId, audioFileName: albumFile),
            bare)
    }

    func testOtherSongsCutsAreIgnored() {
        let names = [albumFile, "SWV-You're The One-...-sng_aaaaaaaaaaaa.mp3", cutFile]
        XCTAssertEqual(
            BurnStore.cutFileName(amongst: names, songId: songId, audioFileName: albumFile),
            cutFile)
    }

    func testEmptySongIdReturnsNil() {
        XCTAssertNil(BurnStore.cutFileName(amongst: [cutFile], songId: "", audioFileName: albumFile))
    }
}

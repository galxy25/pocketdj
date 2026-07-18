import XCTest
@testable import PocketDJ

/// CloudSyncService — the document-level iCloud session sync — driven end-to-end against
/// an in-memory CloudDocDatabase (no CloudKit, no account, no network): push/pull LWW
/// decisions, the pre-overwrite backup, reload seams, watermarks, and the launch deadline.
@MainActor
final class CloudSyncServiceTests: XCTestCase {

    /// In-memory stand-in for the CloudKit private DB.
    actor MemoryCloudDB: CloudDocDatabase {
        var docs: [String: CloudDoc] = [:]
        var available = true
        var saveCount = 0
        func accountAvailable() async -> Bool { available }
        func fetchMeta(keys: [String]) async throws -> [String: Double] {
            Dictionary(uniqueKeysWithValues: keys.compactMap { k in docs[k].map { (k, $0.modifiedAtMs) } })
        }
        func fetch(_ key: String) async throws -> CloudDoc? { docs[key] }
        func save(_ doc: CloudDoc) async throws { docs[doc.key] = doc; saveCount += 1 }
        func seed(_ key: String, payload: Data, modifiedAtMs: Double) {
            docs[key] = CloudDoc(key: key, payload: payload, modifiedAtMs: modifiedAtMs, deviceName: "seed")
        }
        func setAvailable(_ v: Bool) { available = v }
    }

    private var tempDir: URL!

    override func setUp() async throws {
        tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("pdj-cloudsync-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
    }
    override func tearDown() async throws {
        try? FileManager.default.removeItem(at: tempDir)
    }

    private func makeService(db: MemoryCloudDB, enabled: Bool = true) -> CloudSyncService {
        CloudSyncService(database: db, enabled: { enabled },
                         stateURL: tempDir.appendingPathComponent("state.json"))
    }

    private func writeLocal(_ name: String, _ text: String, mtimeMs: Double? = nil) -> URL {
        let url = tempDir.appendingPathComponent(name)
        try? text.data(using: .utf8)!.write(to: url, options: .atomic)
        if let mtimeMs {
            try? FileManager.default.setAttributes(
                [.modificationDate: Date(timeIntervalSince1970: mtimeMs / 1000)], ofItemAtPath: url.path)
        }
        return url
    }

    func testPushesLocalDocWhenCloudEmpty() async throws {
        let db = MemoryCloudDB()
        let svc = makeService(db: db)
        let url = writeLocal("doc.json", #"{"v":1}"#)
        svc.register("doc", fileURL: url)

        await svc.syncNow()
        let pushed = await db.docs["doc"]
        XCTAssertEqual(pushed?.payload, try Data(contentsOf: url))

        // Watermarked: a second pass with an unchanged file must NOT re-push.
        await svc.syncNow()
        let saves = await db.saveCount
        XCTAssertEqual(saves, 1)
    }

    func testPullsNewerCloudDocAppliesReloadAndBacksUp() async throws {
        let db = MemoryCloudDB()
        let svc = makeService(db: db)
        let now = Date().timeIntervalSince1970 * 1000
        // Local is OLD (mtime 60 s back); cloud is newer than local + skew.
        let url = writeLocal("doc.json", #"{"v":"local"}"#, mtimeMs: now - 60_000)
        let cloudPayload = #"{"v":"cloud"}"#.data(using: .utf8)!
        await db.seed("doc", payload: cloudPayload, modifiedAtMs: now - 10_000)
        var reloads = 0
        svc.register("doc", fileURL: url) { reloads += 1 }

        await svc.syncNow()

        XCTAssertEqual(try Data(contentsOf: url), cloudPayload, "local file overwritten by the pull")
        XCTAssertEqual(reloads, 1, "reload seam applies the pull to the live store")
        let backup = url.appendingPathExtension("pre-cloud")
        XCTAssertEqual(try String(contentsOf: backup, encoding: .utf8), #"{"v":"local"}"#,
                       "pre-pull local copy survives as .pre-cloud (data-safety rule)")
        // The freshly-pulled file's newer mtime must not bounce identical bytes back up.
        await svc.syncNow()
        let saves = await db.saveCount
        XCTAssertEqual(saves, 0, "a pull is not followed by a push of the same bytes")
    }

    func testLocalNewerWinsAndPushes() async throws {
        let db = MemoryCloudDB()
        let svc = makeService(db: db)
        let now = Date().timeIntervalSince1970 * 1000
        let url = writeLocal("doc.json", #"{"v":"local-newer"}"#, mtimeMs: now)
        await db.seed("doc", payload: #"{"v":"cloud-old"}"#.data(using: .utf8)!, modifiedAtMs: now - 60_000)
        var reloads = 0
        svc.register("doc", fileURL: url) { reloads += 1 }

        await svc.syncNow()

        XCTAssertEqual(try String(contentsOf: url, encoding: .utf8), #"{"v":"local-newer"}"#,
                       "local file untouched when it is the newer copy")
        XCTAssertEqual(reloads, 0)
        let pushed = await db.docs["doc"]
        XCTAssertEqual(pushed.map { String(decoding: $0.payload, as: UTF8.self) }, #"{"v":"local-newer"}"#)
    }

    func testSkewWindowTreatsCloseTimestampsAsInSync() async throws {
        let db = MemoryCloudDB()
        let svc = makeService(db: db)
        let now = Date().timeIntervalSince1970 * 1000
        let url = writeLocal("doc.json", #"{"v":"local"}"#, mtimeMs: now)
        // Cloud 1 s newer — inside the ±2 s slack ⇒ same write, no pull.
        await db.seed("doc", payload: #"{"v":"cloud"}"#.data(using: .utf8)!, modifiedAtMs: now + 1_000)
        var reloads = 0
        svc.register("doc", fileURL: url) { reloads += 1 }

        await svc.syncNow()
        XCTAssertEqual(try String(contentsOf: url, encoding: .utf8), #"{"v":"local"}"#)
        XCTAssertEqual(reloads, 0)
    }

    func testDisabledToggleIsANoOp() async throws {
        let db = MemoryCloudDB()
        let svc = makeService(db: db, enabled: false)
        let url = writeLocal("doc.json", #"{"v":1}"#)
        svc.register("doc", fileURL: url)
        await svc.syncNow()
        let empty = await db.docs.isEmpty
        XCTAssertTrue(empty)
    }

    func testUnavailableAccountReportsAndSkips() async throws {
        let db = MemoryCloudDB()
        await db.setAvailable(false)
        let svc = makeService(db: db)
        let url = writeLocal("doc.json", #"{"v":1}"#)
        svc.register("doc", fileURL: url)
        await svc.syncNow()
        XCTAssertEqual(svc.accountAvailable, false)
        let empty = await db.docs.isEmpty
        XCTAssertTrue(empty)
    }

    func testMissingLocalFilePullsFromCloud() async throws {
        let db = MemoryCloudDB()
        let svc = makeService(db: db)
        let url = tempDir.appendingPathComponent("absent.json")   // fresh install: no file
        let cloudPayload = #"{"v":"cloud"}"#.data(using: .utf8)!
        await db.seed("doc", payload: cloudPayload, modifiedAtMs: Date().timeIntervalSince1970 * 1000 - 5_000)
        var reloads = 0
        svc.register("doc", fileURL: url) { reloads += 1 }

        await svc.syncNow()
        XCTAssertEqual(try Data(contentsOf: url), cloudPayload)
        XCTAssertEqual(reloads, 1)
    }

    func testWatermarksPersistAcrossServiceInstances() async throws {
        let db = MemoryCloudDB()
        let stateURL = tempDir.appendingPathComponent("state.json")
        let url = writeLocal("doc.json", #"{"v":1}"#)
        let first = CloudSyncService(database: db, enabled: { true }, stateURL: stateURL)
        first.register("doc", fileURL: url)
        await first.syncNow()
        let saves1 = await db.saveCount
        XCTAssertEqual(saves1, 1)

        // A relaunch (fresh service, same state file) must not re-push the unchanged file.
        let second = CloudSyncService(database: db, enabled: { true }, stateURL: stateURL)
        second.register("doc", fileURL: url)
        await second.syncNow()
        let saves2 = await db.saveCount
        XCTAssertEqual(saves2, 1)
    }
}

/// ProfileStore — identity migration + the settings/collections name mirror.
@MainActor
final class ProfileStoreTests: XCTestCase {

    private func makeStore() -> (store: ProfileStore, url: URL) {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("pdj-profile-\(UUID().uuidString).json")
        addTeardownBlock { try? FileManager.default.removeItem(at: url) }
        return (ProfileStore(fileURL: url), url)
    }

    func testMigratesSettingsNameOnce() {
        let (store, url) = makeStore()
        XCTAssertEqual(store.name, "")
        store.migrateIfNeeded(settingsName: "  DJ Levi  ")
        XCTAssertEqual(store.name, "DJ Levi", "pre-profile pocketDJName is adopted (trimmed)")
        // The profile file materialized so it can sync.
        XCTAssertTrue(FileManager.default.fileExists(atPath: url.path))
        // A later migration attempt never clobbers an existing profile name.
        store.migrateIfNeeded(settingsName: "Someone Else")
        XCTAssertEqual(store.name, "DJ Levi")
    }

    func testSetNamePersistsAndMirrors() {
        let (store, url) = makeStore()
        var mirrored: [String] = []
        store.onNameApplied = { mirrored.append($0) }
        store.setName("Beta Tester")
        XCTAssertEqual(mirrored, ["Beta Tester"])
        // Persisted: a second store on the same file decodes the name + SAME durable id.
        let reopened = ProfileStore(fileURL: url)
        XCTAssertEqual(reopened.name, "Beta Tester")
        XCTAssertEqual(reopened.id, store.id)
    }

    func testReloadFromDiskAdoptsCloudDocAndMirrors() throws {
        let (store, url) = makeStore()
        var mirrored: [String] = []
        store.onNameApplied = { mirrored.append($0) }
        // Simulate a cloud pull: a different device's profile doc lands on disk.
        let doc = ProfileStore.Document(id: "cloud-id", name: "Cloud Name", createdAtMs: 123)
        try JSONEncoder().encode(doc).write(to: url, options: .atomic)
        store.reloadFromDisk()
        XCTAssertEqual(store.id, "cloud-id", "one identity per Apple ID — the cloud doc's id wins")
        XCTAssertEqual(store.name, "Cloud Name")
        XCTAssertEqual(mirrored, ["Cloud Name"])
    }
}

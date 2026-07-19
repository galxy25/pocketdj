import XCTest
@testable import PocketDJ

/// The onboarding-era CloudSync additions: the push gate (R1), the pull-forced
/// stage-1 restore (R3), and the profile probe's outcome mapping (R5).
@MainActor
final class CloudSyncOnboardingTests: XCTestCase {

    typealias MemoryCloudDB = CloudSyncServiceTests.MemoryCloudDB

    private var tempDir: URL!

    override func setUp() async throws {
        tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("pdj-cloudonb-\(UUID().uuidString)", isDirectory: true)
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

    // MARK: - Push gate (R1)

    func testPushGateRefusesAllPushesUntilOpened() async throws {
        let db = MemoryCloudDB()
        let svc = makeService(db: db)
        var allowed = false
        svc.pushAllowed = { allowed }
        let url = writeLocal("doc.json", #"{"v":1}"#)
        svc.register("doc", fileURL: url)

        await svc.syncNow()
        let closedDocs = await db.docs
        XCTAssertNil(closedDocs["doc"], "runPass must not push while the gate is closed")
        svc.pushOnBackground()
        try? await Task.sleep(for: .milliseconds(200))
        let stillClosed = await db.docs
        XCTAssertNil(stillClosed["doc"], "pushDirty must not push while the gate is closed")

        allowed = true
        await svc.syncNow()
        let openDocs = await db.docs
        XCTAssertNotNil(openDocs["doc"], "gate open ⇒ normal LWW push resumes")
    }

    func testPushGateNeverBlocksPulls() async throws {
        let db = MemoryCloudDB()
        let svc = makeService(db: db)
        svc.pushAllowed = { false }
        let now = Date().timeIntervalSince1970 * 1000
        let url = writeLocal("doc.json", #"{"v":"local"}"#, mtimeMs: now - 60_000)
        await db.seed("doc", payload: #"{"v":"cloud"}"#.data(using: .utf8)!, modifiedAtMs: now - 10_000)
        svc.register("doc", fileURL: url)

        await svc.syncNow()
        XCTAssertEqual(try Data(contentsOf: url), #"{"v":"cloud"}"#.data(using: .utf8)!)
    }

    // MARK: - Pull-forced restore (R3)

    /// The launch-pass LWW would SKIP a cloud doc whose local file is newer (exactly
    /// what a mid-onboarding flush/intent write produces) — the restore must not.
    func testRestoreForOnboardingAppliesCloudOverNewerLocalWithBackup() async throws {
        let db = MemoryCloudDB()
        let svc = makeService(db: db)
        let now = Date().timeIntervalSince1970 * 1000
        // Local file JUST written (mtime now); cloud copy is older.
        let url = writeLocal("collections.json", #"{"v":"empty-local"}"#)
        await db.seed("collections", payload: #"{"v":"cloud"}"#.data(using: .utf8)!,
                      modifiedAtMs: now - 600_000)
        var reloads = 0
        svc.register("collections", fileURL: url) { reloads += 1 }

        let pulled = await svc.restoreForOnboarding()
        XCTAssertEqual(pulled, ["collections"])
        XCTAssertEqual(try Data(contentsOf: url), #"{"v":"cloud"}"#.data(using: .utf8)!)
        XCTAssertEqual(reloads, 1)
        // User-data-safety: the pre-restore local copy survives as .pre-cloud.
        let backup = url.appendingPathExtension("pre-cloud")
        XCTAssertEqual(try Data(contentsOf: backup), #"{"v":"empty-local"}"#.data(using: .utf8)!)
        // Nothing pushed during a restore.
        let saves = await db.saveCount
        XCTAssertEqual(saves, 0)
    }

    func testRestoreForOnboardingSkipsAbsentDocsAndReturnsNilWhenUnavailable() async throws {
        let db = MemoryCloudDB()
        let svc = makeService(db: db)
        let url = writeLocal("doc.json", #"{"v":1}"#)
        svc.register("doc", fileURL: url)

        // No cloud doc at all: success with nothing pulled (a fresh iCloud user).
        let pulled = await svc.restoreForOnboarding()
        XCTAssertEqual(pulled, [])

        await db.setAvailable(false)
        let unavailable = await svc.restoreForOnboarding()
        XCTAssertNil(unavailable, "no-account restore must NOT look complete")
    }

    // MARK: - Profile probe (R5)

    func testProbeDisabledWhenSyncOff() async {
        let svc = makeService(db: MemoryCloudDB(), enabled: false)
        let r = await svc.probeCloudProfile()
        XCTAssertEqual(r, .disabled)
    }

    func testProbeNoAccount() async {
        let db = MemoryCloudDB()
        await db.setAvailable(false)
        let r = await makeService(db: db).probeCloudProfile()
        XCTAssertEqual(r, .noAccount)
    }

    func testProbeFreshVsExisting() async throws {
        let db = MemoryCloudDB()
        let svc = makeService(db: db)
        let fresh = await svc.probeCloudProfile()
        XCTAssertEqual(fresh, .fresh)

        let doc = ProfileStore.Document(id: "abc", name: "Levi", createdAtMs: 1)
        await db.seed("profile", payload: try JSONEncoder().encode(doc), modifiedAtMs: 5)
        let existing = await svc.probeCloudProfile()
        XCTAssertEqual(existing, .existing(name: "Levi"))
    }

    func testProbeUndecodableProfileStillReadsAsExisting() async {
        let db = MemoryCloudDB()
        await db.seed("profile", payload: Data("junk".utf8), modifiedAtMs: 5)
        let r = await makeService(db: db).probeCloudProfile()
        XCTAssertEqual(r, .existing(name: ""),
                       "a profile DOC exists — never mistake it for .fresh")
    }
}

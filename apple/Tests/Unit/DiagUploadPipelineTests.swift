import XCTest
import Security
@testable import PocketDJ

/// Regression for the 2026-10 iOS diag outage: after the diag key moved from the binary to a
/// Keychain-only store (4ca541e), nothing delivered the key, every TestFlight build on a
/// keyless device became a SILENT no-op, and iOS uploads stopped for 5+ days with no signal.
/// These pin (1) the "diag-key" credsync lane that delivers the key, with empty-never-wins,
/// and (2) DiagLog's visible status + keyless buffering + failure reporting.
@MainActor
final class DiagUploadPipelineTests: XCTestCase {

    /// Collects every PUT the logger makes; answers with a scripted outcome.
    actor Recorder {
        var puts: [(key: String, body: String)] = []
        var outcome: DiagLog.UploadOutcome = .ok
        func record(_ key: String, _ body: Data) -> DiagLog.UploadOutcome {
            puts.append((key, String(decoding: body, as: UTF8.self)))
            return outcome
        }
        func set(_ o: DiagLog.UploadOutcome) { outcome = o }
    }

    private var tempDir: URL!
    private var suites: [String] = []

    override func setUp() async throws {
        tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("pdj-diagkey-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
    }
    override func tearDown() async throws {
        try? FileManager.default.removeItem(at: tempDir)
        for s in suites { UserDefaults(suiteName: s)?.removePersistentDomain(forName: s) }
    }

    private func memStore() -> DiagCredentialStore {
        DiagCredentialStore(service: "diag.tests", memory: DiagCredentialStore.MemoryBox())
    }
    private func defaults() -> UserDefaults {
        let name = "diag.pipeline.\(UUID().uuidString)"
        suites.append(name)
        return UserDefaults(suiteName: name)!
    }
    private func makeLog(store: DiagCredentialStore, defaults: UserDefaults, recorder: Recorder) -> DiagLog {
        DiagLog(enabled: true, store: store, defaults: defaults,
                uploader: { key, body, _ in await recorder.record(key, body) })
    }

    // MARK: credsync lane

    func testKeylessDeviceNeverMaterializesTheDoc() {
        let sync = DiagKeySync(fileURL: tempDir.appendingPathComponent("a.json"), store: memStore())
        XCTAssertFalse(sync.materialize())
        XCTAssertFalse(FileManager.default.fileExists(atPath: sync.fileURL.path),
                       "an empty doc would LWW-wipe the key on every other device")
    }

    func testKeyEnteredOnOneDeviceIsAdoptedByAnother() {
        let phoneStore = memStore()
        let phone = DiagKeySync(fileURL: tempDir.appendingPathComponent("phone.json"), store: phoneStore)
        XCTAssertEqual(phoneStore.save(accessKeyID: "AKIDNEW", secret: "s3cr3t"), errSecSuccess)
        XCTAssertTrue(phone.materialize())
        XCTAssertFalse(phone.materialize(), "unchanged content must not rewrite (mtime = last key change)")

        // CloudSyncService's pull = the cloud bytes land on the TV's file.
        let tvStore = memStore()
        let tv = DiagKeySync(fileURL: tempDir.appendingPathComponent("tv.json"), store: tvStore)
        try? FileManager.default.copyItem(at: phone.fileURL, to: tv.fileURL)
        XCTAssertEqual(tv.applyPulled(), .adopted)
        XCTAssertEqual(tvStore.load(), .init(accessKeyID: "AKIDNEW", secret: "s3cr3t"))
        XCTAssertEqual(tv.applyPulled(), .unchanged)
    }

    func testEmptyPullNeverClearsALocalKey() throws {
        let store = memStore()
        store.save(accessKeyID: "AKIDKEEP", secret: "keep")
        let sync = DiagKeySync(fileURL: tempDir.appendingPathComponent("b.json"), store: store)
        let empty = try JSONEncoder().encode(DiagKeySync.Document(accessKeyID: " ", secret: ""))
        try empty.write(to: sync.fileURL)
        XCTAssertEqual(sync.applyPulled(), .ignoredEmpty)
        try Data("garbage".utf8).write(to: sync.fileURL)
        XCTAssertEqual(sync.applyPulled(), .ignoredEmpty)
        XCTAssertEqual(store.load(), .init(accessKeyID: "AKIDKEEP", secret: "keep"))
    }

    func testRotatedKeyReplacesTheOldOne() throws {
        let store = memStore()
        store.save(accessKeyID: "AKIDOLD", secret: "old")
        let sync = DiagKeySync(fileURL: tempDir.appendingPathComponent("c.json"), store: store)
        try JSONEncoder().encode(DiagKeySync.Document(accessKeyID: "AKIDNEW", secret: "new")).write(to: sync.fileURL)
        XCTAssertEqual(sync.applyPulled(), .adopted)
        XCTAssertEqual(store.load()?.accessKeyID, "AKIDNEW")
    }

    func testRefusedKeychainWriteOnPullIsReported() throws {
        let store = memStore()
        store.memory?.failWrites = errSecMissingEntitlement
        let sync = DiagKeySync(fileURL: tempDir.appendingPathComponent("d.json"), store: store)
        try JSONEncoder().encode(DiagKeySync.Document(accessKeyID: "AKID", secret: "s")).write(to: sync.fileURL)
        XCTAssertEqual(sync.applyPulled(), .saveFailed(errSecMissingEntitlement))
    }

    // MARK: DiagLog — never silent

    func testKeylessLaunchIsVisibleAndBufferedThenUploadedWhenKeyArrives() async {
        let store = memStore()
        let rec = Recorder()
        let log = makeLog(store: store, defaults: defaults(), recorder: rec)

        XCTAssertFalse(log.uploadStatus.keyPresent)
        XCTAssertFalse(log.uploadStatus.healthy)
        XCTAssertTrue(log.uploadStatus.summary().hasPrefix("DISABLED — no diag key"), log.uploadStatus.summary())

        log.log("error", "something broke before the key arrived")   // `error` would flush if keyed
        log.flushOnBackground()
        await log.waitForUploads()
        let none = await rec.puts
        XCTAssertTrue(none.isEmpty, "no key ⇒ no PUT")

        // Key adopted later in the same launch (credsync pull / Settings entry).
        store.save(accessKeyID: "AKID", secret: "s")
        log.reloadCredentials()
        await log.waitForUploads()
        let puts = await rec.puts
        XCTAssertEqual(puts.count, 1)
        let body = puts.first?.body ?? ""
        XCTAssertTrue(body.contains("[launch] build="), "launch line survived the keyless window")
        XCTAssertTrue(body.contains("[diag] status key=MISSING"), body)
        XCTAssertTrue(body.contains("something broke before the key arrived"))
        XCTAssertTrue(body.contains("[diag] key configured; late start"))
        XCTAssertTrue(puts.first?.key.hasSuffix(".log") ?? false)
        XCTAssertTrue(log.uploadStatus.keyPresent)
        XCTAssertNotNil(log.uploadStatus.lastSuccessAt)
        XCTAssertTrue(log.uploadStatus.healthy)
    }

    func testKeylessBufferIsBounded() async {
        let store = memStore()
        let rec = Recorder()
        let log = makeLog(store: store, defaults: defaults(), recorder: rec)
        for i in 0..<(DiagLog.partLineLimit * 3) { log.log("np", "line \(i)") }
        store.save(accessKeyID: "AKID", secret: "s")
        log.reloadCredentials()
        await log.waitForUploads()
        let body = await rec.puts.first?.body ?? ""
        XCTAssertTrue(body.contains("keyless buffer full"))
        XCTAssertLessThanOrEqual(body.split(separator: "\n").count, DiagLog.partLineLimit + 1)
    }

    func testFailingUploadsAreRecordedPersistedAndLoggedOnce() async {
        let store = memStore()
        store.save(accessKeyID: "AKIDREVOKED", secret: "s")
        let rec = Recorder()
        await rec.set(.http(403))
        let d = defaults()
        let log = makeLog(store: store, defaults: d, recorder: rec)

        log.log("error", "e1"); await log.waitForUploads()
        log.log("error", "e2"); await log.waitForUploads()
        log.log("error", "e3"); await log.waitForUploads()

        XCTAssertTrue(log.uploadStatus.failing)
        XCTAssertFalse(log.uploadStatus.healthy)
        XCTAssertTrue(log.uploadStatus.summary().hasPrefix("FAILING — HTTP 403"), log.uploadStatus.summary())
        let last = await rec.puts.last?.body ?? ""
        XCTAssertEqual(last.components(separatedBy: "[diag] upload FAILED HTTP 403").count - 1, 1,
                       "transition logged once, not once per failing PUT")

        // Next launch: the failure is still visible, in the readout AND the launch status line.
        await rec.set(.ok)
        let next = makeLog(store: store, defaults: d, recorder: rec)
        XCTAssertTrue(next.uploadStatus.failing)
        next.log("error", "flush"); await next.waitForUploads()
        let body = await rec.puts.last?.body ?? ""
        XCTAssertTrue(body.contains("[diag] status key=present"), body)
        XCTAssertTrue(body.contains("last-err=HTTP 403@"), body)
        XCTAssertFalse(body.contains("[diag] upload recovered"),
                       "recovery is logged on the NEXT flush after the successful PUT")
        next.log("error", "flush2"); await next.waitForUploads()
        let after = await rec.puts.last?.body ?? ""
        XCTAssertTrue(after.contains("[diag] upload recovered (was HTTP 403)"), after)
        XCTAssertFalse(next.uploadStatus.failing)
        XCTAssertTrue(next.uploadStatus.healthy)
    }

    func testKeyRemovalIsVisible() {
        let store = memStore()
        store.save(accessKeyID: "AKID", secret: "s")
        let log = makeLog(store: store, defaults: defaults(), recorder: Recorder())
        XCTAssertTrue(log.uploadStatus.healthy)
        store.clear()
        log.reloadCredentials()
        XCTAssertFalse(log.uploadStatus.keyPresent)
        XCTAssertTrue(log.uploadStatus.summary().hasPrefix("DISABLED"))
    }

    func testAppStoreChannelReadsAsOffByDesign() {
        let log = DiagLog(enabled: false, store: memStore(), defaults: defaults(),
                          uploader: { _, _, _ in .ok })
        XCTAssertFalse(log.uploadStatus.channelEnabled)
        XCTAssertTrue(log.uploadStatus.summary().hasPrefix("off — App Store build"))
    }
}

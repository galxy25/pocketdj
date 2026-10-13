import XCTest
import Security
import UniformTypeIdentifiers
@testable import PocketDJ

/// `.pdjdiagkey` import (scripts/green/export-diag-key.sh → Settings ▸ Debug / drop / open):
/// file decode + validation, import → store → credsync materialize + push, the account/bucket
/// pairing guard (no silent 403s), and delete-after-import.
@MainActor
final class DiagKeyImportTests: XCTestCase {
    private var tempDir: URL!
    private let greenAccount = "623170744161"
    private let blueAccount = "011183829623"
    private let fakeID = "AKIAFAKEFAKEFAKE1234"
    private let fakeSecret = "fAkEsEcReT/0123456789+abcdefghijklmnopQRST"

    override func setUp() async throws {
        tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("diagkey-import-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
    }

    override func tearDown() async throws {
        try? FileManager.default.removeItem(at: tempDir)
    }

    private func fileJSON(env: String = "green", account: String? = nil, id: String? = nil,
                          secret: String? = nil, type: String = "pocketdj-diag-key", version: Int = 1,
                          drop: String? = nil) -> Data {
        var d: [String: Any] = ["type": type, "schemaVersion": version, "env": env,
                                "account": account ?? greenAccount, "accessKeyID": id ?? fakeID,
                                "secret": secret ?? fakeSecret, "exportedAt": "2026-10-12T00:00:00Z"]
        if let drop { d.removeValue(forKey: drop) }
        return try! JSONSerialization.data(withJSONObject: d, options: [.sortedKeys])
    }

    private func writeFile(_ data: Data, name: String = "pocketdj-diag-key.pdjdiagkey") -> URL {
        let url = tempDir.appendingPathComponent(name)
        try! data.write(to: url)
        return url
    }

    /// Recorder for the importer's side effects.
    private final class Spy {
        var pushes = 0
        var reloads = 0
        var lines: [String] = []
    }

    private func makeImporter(bucketAccount: String, activeEnv: String, spy: Spy,
                              store: DiagCredentialStore? = nil) -> DiagKeyImporter {
        let store = store ?? DiagCredentialStore(service: "com.levi.pocketdj.diag.import-tests",
                                                 memory: DiagCredentialStore.MemoryBox())
        let sync = DiagKeySync(fileURL: tempDir.appendingPathComponent("diag-key-doc.json"), store: store)
        return DiagKeyImporter(
            sync: sync,
            logsBase: { URL(string: "https://pocketdj-logs-\(bucketAccount).s3.us-west-2.amazonaws.com")! },
            activeEnv: { activeEnv },
            push: { spy.pushes += 1 },
            log: { spy.lines.append($0) },
            reloadCredentials: { spy.reloads += 1 })
    }

    // MARK: Decode / validation

    func testDecodesExportedShape() throws {
        let f = try DiagKeyFile.decode(fileJSON()).get()
        XCTAssertEqual(f.env, "green")
        XCTAssertEqual(f.account, greenAccount)
        XCTAssertEqual(f.accessKeyID, fakeID)
        XCTAssertEqual(f.secret, fakeSecret)
    }

    func testDecodeTrimsWhitespace() throws {
        let f = try DiagKeyFile.decode(fileJSON(id: " \(fakeID)\n", secret: " \(fakeSecret) ")).get()
        XCTAssertEqual(f.accessKeyID, fakeID)
        XCTAssertEqual(f.secret, fakeSecret)
    }

    func testDecodeRejections() {
        func rejected(_ d: Data) -> DiagKeyFile.Invalid? {
            if case .failure(let e) = DiagKeyFile.decode(d) { return e }
            return nil
        }
        XCTAssertEqual(rejected(Data("not json".utf8)), .notJSON)
        XCTAssertEqual(rejected(fileJSON(type: "something-else")), .wrongType)
        XCTAssertEqual(rejected(fileJSON(version: 2)), .unsupportedVersion(2))
        XCTAssertEqual(rejected(fileJSON(drop: "secret")), .missing("secret"))
        XCTAssertEqual(rejected(fileJSON(drop: "account")), .missing("account"))
        XCTAssertEqual(rejected(fileJSON(secret: "   ")), .missing("secret"))
        XCTAssertEqual(rejected(fileJSON(id: "not-a-key")), .badAccessKeyID)
        XCTAssertEqual(rejected(fileJSON(account: "12345")), .badAccount)
    }

    /// No validation error may carry secret material (they reach the diag log + alerts).
    func testErrorsNeverCarrySecret() {
        for d in [fileJSON(id: "bad"), fileJSON(account: "x"), fileJSON(type: "t"), fileJSON(drop: "env")] {
            if case .failure(let e) = DiagKeyFile.decode(d) {
                XCTAssertFalse(e.description.contains(fakeSecret))
                XCTAssertFalse(e.description.contains(fakeID))
            } else { XCTFail("expected a rejection") }
        }
    }

    func testBucketAccountParsing() {
        XCTAssertEqual(DiagKeyFile.bucketAccount(of: URL(string: "https://pocketdj-logs-623170744161.s3.us-west-2.amazonaws.com")!), greenAccount)
        XCTAssertEqual(DiagKeyFile.bucketAccount(of: EndpointConfig.compiledIn.url(.diagLogsBase)), blueAccount)
        XCTAssertNil(DiagKeyFile.bucketAccount(of: URL(string: "https://logs.pocket-dj.com")!))
    }

    // MARK: Import → store → sync

    func testImportStoresMaterializesAndPushes() async throws {
        let spy = Spy()
        let importer = makeImporter(bucketAccount: greenAccount, activeEnv: "green", spy: spy)
        let outcome = await importer.importFile(at: writeFile(fileJSON()))
        XCTAssertEqual(outcome, .imported(env: "green", account: greenAccount, mismatch: nil))
        XCTAssertEqual(importer.sync.store.load(), .init(accessKeyID: fakeID, secret: fakeSecret))
        // The credsync doc now holds the key (what CloudSyncService pushes as "diag-key").
        let doc = try JSONDecoder().decode(DiagKeySync.Document.self, from: Data(contentsOf: importer.sync.fileURL))
        XCTAssertEqual(doc.accessKeyID, fakeID)
        XCTAssertEqual(spy.pushes, 1)
        XCTAssertEqual(spy.reloads, 1)
        XCTAssertTrue(spy.lines.contains { $0.hasPrefix("key imported env=green") }, "\(spy.lines)")
        XCTAssertFalse(spy.lines.joined().contains(fakeSecret))
    }

    func testInvalidFileStoresNothingAndDoesNotPush() async {
        let spy = Spy()
        let importer = makeImporter(bucketAccount: greenAccount, activeEnv: "green", spy: spy)
        let outcome = await importer.importFile(at: writeFile(fileJSON(id: "nope")))
        guard case .invalid = outcome else { return XCTFail("\(outcome)") }
        XCTAssertNil(importer.sync.store.load())
        XCTAssertEqual(spy.pushes, 0)
        XCTAssertFalse(FileManager.default.fileExists(atPath: importer.sync.fileURL.path))
    }

    func testKeychainRefusalIsReported() async {
        let spy = Spy()
        let box = DiagCredentialStore.MemoryBox()
        box.failWrites = errSecMissingEntitlement
        let importer = makeImporter(bucketAccount: greenAccount, activeEnv: "green", spy: spy,
                                    store: DiagCredentialStore(service: "t", memory: box))
        let outcome = await importer.importData(fileJSON())
        XCTAssertEqual(outcome, .saveFailed(errSecMissingEntitlement))
        XCTAssertEqual(spy.pushes, 0)
    }

    // MARK: Env / account pairing

    /// A green key while the app still uploads to blue's bucket: held for confirmation, nothing
    /// saved (the device's working key is NOT replaced by one that would 403).
    func testEnvMismatchWarnsInsteadOfSaving() async {
        let spy = Spy()
        let importer = makeImporter(bucketAccount: blueAccount, activeEnv: "blue", spy: spy)
        let outcome = await importer.importData(fileJSON())
        guard case .needsConfirmation(let m) = outcome else { return XCTFail("\(outcome)") }
        XCTAssertEqual(m, .init(keyEnv: "green", keyAccount: greenAccount, activeEnv: "blue", bucketAccount: blueAccount))
        XCTAssertTrue(m.warning.contains("403"))
        XCTAssertNil(importer.sync.store.load())
        XCTAssertEqual(spy.pushes, 0)
    }

    func testEnvMismatchForcedImportsWithWarning() async {
        let spy = Spy()
        let importer = makeImporter(bucketAccount: blueAccount, activeEnv: "blue", spy: spy)
        let outcome = await importer.importData(fileJSON(), force: true)
        guard case .imported(_, _, let m?) = outcome else { return XCTFail("\(outcome)") }
        XCTAssertEqual(m.bucketAccount, blueAccount)
        XCTAssertNotNil(importer.sync.store.load())
        XCTAssertEqual(spy.pushes, 1)
        XCTAssertTrue(spy.lines.contains { $0.contains("paired=false") }, "\(spy.lines)")
    }

    // MARK: Model: delete-after-import

    func testModelOffersDeleteAndDeletesFile() async {
        let spy = Spy()
        let importer = makeImporter(bucketAccount: greenAccount, activeEnv: "green", spy: spy)
        let model = DiagKeyImportModel(makeImporter: { importer })
        let url = writeFile(fileJSON())
        await model.begin(url, origin: .settings)
        guard case .imported(_, let file)? = model.presentation else { return XCTFail("\(String(describing: model.presentation))") }
        XCTAssertEqual(file, url)
        XCTAssertEqual(model.importCount, 1)
        model.deleteImported(file)
        XCTAssertFalse(FileManager.default.fileExists(atPath: url.path))
        XCTAssertNil(model.presentation)
    }

    func testModelKeepFileLeavesItInPlace() async {
        let spy = Spy()
        let importer = makeImporter(bucketAccount: greenAccount, activeEnv: "green", spy: spy)
        let model = DiagKeyImportModel(makeImporter: { importer })
        let url = writeFile(fileJSON())
        await model.begin(url, origin: .openedFile)
        XCTAssertEqual(model.origin, .openedFile)
        model.dismiss()
        XCTAssertTrue(FileManager.default.fileExists(atPath: url.path))
    }

    func testModelMismatchThenForce() async {
        let spy = Spy()
        let importer = makeImporter(bucketAccount: blueAccount, activeEnv: "blue", spy: spy)
        let model = DiagKeyImportModel(makeImporter: { importer })
        let url = writeFile(fileJSON())
        await model.begin(url, origin: .settings)
        guard case .mismatch? = model.presentation else { return XCTFail("\(String(describing: model.presentation))") }
        XCTAssertEqual(model.importCount, 0)
        await model.begin(url, origin: .settings, force: true)
        guard case .imported(let text, _)? = model.presentation else { return XCTFail() }
        XCTAssertTrue(text.contains("403"))
        XCTAssertFalse(text.contains(fakeSecret))
    }

    func testDeleteFailureIsReported() {
        let model = DiagKeyImportModel()
        model.deleteImported(tempDir.appendingPathComponent("missing.pdjdiagkey"))
        guard case .message(let title, _)? = model.presentation else { return XCTFail() }
        XCTAssertEqual(title, "File not deleted")
    }

    func testHandlesOnlyDiagKeyFiles() {
        XCTAssertTrue(DiagKeyImportModel.handles(URL(fileURLWithPath: "/tmp/a.pdjdiagkey")))
        XCTAssertTrue(DiagKeyImportModel.handles(URL(fileURLWithPath: "/tmp/a.PDJDIAGKEY")))
        XCTAssertFalse(DiagKeyImportModel.handles(URL(fileURLWithPath: "/tmp/a.pdjcollection")))
        XCTAssertFalse(DiagKeyImportModel.handles(URL(string: "https://x.pocket-dj.com/a.pdjdiagkey")!))
    }

    /// The exported UTI must resolve to the plist declaration (else pickers grey the file out).
    func testUTTypeConformsToJSON() {
        XCTAssertTrue(UTType.pocketDJDiagKey.conforms(to: .json))
        XCTAssertEqual(UTType(filenameExtension: "pdjdiagkey"), .pocketDJDiagKey)
    }
}

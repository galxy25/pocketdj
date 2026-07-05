import XCTest
@testable import PocketDJ

/// InstrumentPacks — the S3 pack manifest (lenient/lossy decode incl. the unknown-instrument
/// skip rule), the locked-in GM program mapping, bank dedupe by `bankKey` (the second pack
/// referencing a downloaded bank is instantly "downloaded"), and the SHA-256 verify that gates
/// the install (mismatch deletes + fails — spec §6). Hermetic: `StudioFolders.appRootOverride`
/// + a temp cache dir; no network is ever touched (the store's init reads only disk).
final class InstrumentPacksTests: XCTestCase {

    private var root: URL!

    override func setUp() {
        super.setUp()
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("pdj-instrpacks-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        StudioFolders.appRootOverride = root
    }

    override func tearDown() {
        StudioFolders.appRootOverride = nil
        try? FileManager.default.removeItem(at: root)
        super.tearDown()
    }

    /// A store that can never hit the network (invalid host, cold temp cache dir).
    @MainActor
    private func makeStore() -> InstrumentPackStore {
        InstrumentPackStore(indexURL: URL(string: "https://invalid.test/index.json")!,
                            cacheDir: root.appendingPathComponent("cache", isDirectory: true))
    }

    // MARK: Manifest decode (spec §6 shape; lenient + lossy)

    private static let manifestJSON = """
    {
      "version": 3,
      "attribution": "GeneralUser GS by S. Christian Collins",
      "sharedBanks": [
        { "key": "banks/generaluser-gs-2.0.3.sf2", "bytes": 33554432,
          "sha256": "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad" },
        { "bytes": 1 }
      ],
      "packs": [
        { "id": "pk_piano", "name": "Grand Piano", "instrument": "piano", "program": 0,
          "bankKey": "banks/generaluser-gs-2.0.3.sf2", "bytes": 33554432 },
        { "id": "pk_harp", "instrument": "harp",
          "bankKey": "banks/generaluser-gs-2.0.3.sf2" },
        { "id": "pk_theremin", "name": "Theremin", "instrument": "theremin", "program": 90,
          "bankKey": "banks/generaluser-gs-2.0.3.sf2", "bytes": 1 },
        { "id": "", "instrument": "piano" }
      ]
    }
    """

    func testManifestDecodeSkipsUnknownInstrumentPacksOnly() throws {
        let idx = try JSONDecoder().decode(InstrumentPackIndex.self,
                                           from: Data(Self.manifestJSON.utf8))
        XCTAssertEqual(idx.version, 3)
        XCTAssertEqual(idx.attribution, "GeneralUser GS by S. Christian Collins")
        // The keyless bank entry is dropped; the real one survives with its digest.
        XCTAssertEqual(idx.sharedBanks.count, 1)
        XCTAssertEqual(idx.sharedBanks[0].key, "banks/generaluser-gs-2.0.3.sf2")
        XCTAssertEqual(idx.sharedBanks[0].bytes, 33_554_432)
        XCTAssertFalse(idx.sharedBanks[0].sha256.isEmpty)
        // The unknown "theremin" pack and the id-less pack are skipped — the two known packs
        // survive intact (one bad element never drops the list; the unknown-instrument rule).
        XCTAssertEqual(idx.packs.map(\.id), ["pk_piano", "pk_harp"])
        XCTAssertEqual(idx.packs[0].instrument, .piano)
        XCTAssertEqual(idx.packs[0].name, "Grand Piano")
    }

    /// Lenient field defaults: a pack that omits name/program inherits them from its
    /// InstrumentKey (display name + the locked-in GM program).
    func testManifestDecodeLenientDefaults() throws {
        let idx = try JSONDecoder().decode(InstrumentPackIndex.self,
                                           from: Data(Self.manifestJSON.utf8))
        let harp = try XCTUnwrap(idx.packs.first { $0.id == "pk_harp" })
        XCTAssertEqual(harp.instrument, .harp)
        XCTAssertEqual(harp.name, "Harp")        // defaulted from the instrument
        XCTAssertEqual(harp.program, 46)         // defaulted from InstrumentKey.gmProgram
        XCTAssertEqual(harp.bytes, 0)
    }

    /// Garbage/empty documents decode to an EMPTY index rather than throwing — the offline
    /// cache-validation gate then rejects them (no packs), never the decoder.
    func testGarbageDocumentDecodesEmptyNeverThrows() throws {
        let empty = try JSONDecoder().decode(InstrumentPackIndex.self, from: Data("{}".utf8))
        XCTAssertEqual(empty.version, 0)
        XCTAssertTrue(empty.packs.isEmpty)
        XCTAssertTrue(empty.sharedBanks.isEmpty)
        let junk = try JSONDecoder().decode(InstrumentPackIndex.self,
                                            from: Data(#"{"packs": "nope", "version": "x"}"#.utf8))
        XCTAssertTrue(junk.packs.isEmpty)
        // The store-level validator additionally refuses to SERVE an empty document.
        XCTAssertNotNil(InstrumentPackStore.decodeIndex(Data("{}".utf8)))
        XCTAssertNil(InstrumentPackStore.decodeIndex(Data("not json".utf8)))
    }

    // MARK: GM program mapping (locked in the spec — a change would re-voice saved takes)

    func testGMProgramMapping() {
        let expected: [InstrumentKey: UInt8] = [
            .piano: 0, .violin: 40, .bassGuitar: 33, .acousticGuitar: 25,
            .trumpet: 56, .clarinet: 71, .harp: 46,
        ]
        XCTAssertEqual(Set(expected.keys), Set(InstrumentKey.allCases))
        for key in InstrumentKey.allCases {
            XCTAssertEqual(key.gmProgram, expected[key], "GM program drifted for \(key.rawValue)")
        }
    }

    // MARK: Deterministic local naming (slug ↔ strict family parser round trip)

    func testBankSlugAndLocalFileName() {
        // Spaces/case collapse; dots survive so the version stays readable — the spec's example.
        XCTAssertEqual(InstrumentPackStore.bankSlug(forKey: "banks/GeneralUser GS 2.0.3.sf2"),
                       "generaluser-gs-2.0.3")
        XCTAssertEqual(InstrumentPackStore.bankSlug(forKey: "banks/generaluser-gs-2.0.3.sf2"),
                       "generaluser-gs-2.0.3")
        XCTAssertEqual(InstrumentPackStore.localBankFileName(forKey: "banks/generaluser-gs-2.0.3.sf2"),
                       "instrument-generaluser-gs-2.0.3.sf2")
        // Minted names parse back through the STRICT instruments-family parser.
        XCTAssertEqual(StudioFolders.fileId(family: .instruments,
                                            name: InstrumentPackStore.localBankFileName(
                                                forKey: "banks/GeneralUser GS 2.0.3.sf2")),
                       "generaluser-gs-2.0.3")
        // Degenerate keys still mint a legal (non-empty, separator-free) slug.
        XCTAssertEqual(InstrumentPackStore.bankSlug(forKey: "banks/♪♪.sf2"), "bank")
    }

    // MARK: Bank dedupe (spec §6: the second pack sharing a bank is instantly downloaded)

    @MainActor
    func testBankDedupeByBankKey() throws {
        // Pre-"download" the shared bank straight onto disk (both keys slug to shared-bank).
        let dir = try StudioFolders.appRoot(.instruments)
        try Data([1, 2, 3]).write(to: dir.appendingPathComponent("instrument-shared-bank.sf2"))
        let store = makeStore()   // init rescans disk

        let a = InstrumentPack(id: "pk_a", name: "A", instrument: .piano, program: 0,
                               bankKey: "banks/Shared Bank.sf2", bytes: 3)
        let b = InstrumentPack(id: "pk_b", name: "B", instrument: .violin, program: 40,
                               bankKey: "banks/shared-bank.sf2", bytes: 3)
        XCTAssertTrue(store.isDownloaded(a))
        XCTAssertTrue(store.isDownloaded(b), "second pack must ride the already-downloaded bank")
        XCTAssertEqual(store.localBankURL(a)?.path, store.localBankURL(b)?.path)
        XCTAssertEqual(store.usageBytes, 3)

        // Deleting the BANK flips every pack referencing it back to downloadable.
        store.deleteBank(bankKey: a.bankKey)
        XCTAssertFalse(store.isDownloaded(a))
        XCTAssertFalse(store.isDownloaded(b))
        XCTAssertNil(store.localBankURL(b))
        XCTAssertEqual(store.usageBytes, 0)
    }

    /// A pack with no bankKey is never "downloaded" and resolves no local file (degraded future
    /// manifest — listable, not downloadable).
    @MainActor
    func testPackWithoutBankKeyIsNotDownloadable() {
        let store = makeStore()
        let orphan = InstrumentPack(id: "pk_x", name: "X", instrument: .piano, program: 0,
                                    bankKey: "", bytes: 0)
        XCTAssertFalse(store.isDownloaded(orphan))
        XCTAssertNil(store.localBankURL(orphan))
    }

    /// `rescanDownloads` is the resync seam after `StudioStore.deleteAll(.instruments)` sweeps
    /// the same files — and only STRICT-shape names count as banks.
    @MainActor
    func testRescanSeesOnlyExactShapeFiles() throws {
        let store = makeStore()
        let dir = try StudioFolders.appRoot(.instruments)
        try Data([1]).write(to: dir.appendingPathComponent("instrument-real-bank.sf2"))
        try Data([1]).write(to: dir.appendingPathComponent("my-soundfont.sf2"))       // foreign
        try Data([1]).write(to: dir.appendingPathComponent("instrument-.sf2"))        // empty slug
        store.rescanDownloads()
        let real = InstrumentPack(id: "pk_r", name: "R", instrument: .piano, program: 0,
                                  bankKey: "banks/real-bank.sf2", bytes: 1)
        XCTAssertTrue(store.isDownloaded(real))
        XCTAssertEqual(store.usageBytes, 1)   // decoys never count (strict-shape discipline)
    }

    // MARK: SHA-256 verify (small fixture data; spec §6: mismatch deletes + fails)

    /// Streaming digest matches the known SHA-256 of "abc".
    func testSha256HexStreaming() throws {
        let f = root.appendingPathComponent("fixture.bin")
        try Data("abc".utf8).write(to: f)
        XCTAssertEqual(try InstrumentPackStore.sha256Hex(ofFileAt: f),
                       "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad")
    }

    func testInstallRejectsShaMismatchAndCleansUp() throws {
        let temp = root.appendingPathComponent("dl.tmp")
        let dest = root.appendingPathComponent("instrument-x.sf2")
        try Data("abc".utf8).write(to: temp)
        XCTAssertThrowsError(try InstrumentPackStore.installBank(
            fromTemp: temp, dest: dest,
            expectedSha256: "deadbeefdeadbeefdeadbeefdeadbeefdeadbeefdeadbeefdeadbeefdeadbeef")) { error in
            XCTAssertEqual(error as? InstrumentPackError, .shaMismatch)
        }
        // Mismatch DELETES: no destination, no staging leftovers, temp consumed.
        XCTAssertFalse(FileManager.default.fileExists(atPath: dest.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: temp.path))
        let leftovers = (try? FileManager.default.contentsOfDirectory(atPath: root.path)) ?? []
        XCTAssertFalse(leftovers.contains { $0.hasPrefix(".pack-staging-") },
                       "no unverified bytes may be left behind")
    }

    func testInstallAcceptsMatchingShaCaseInsensitive() throws {
        let temp = root.appendingPathComponent("dl.tmp")
        let dest = root.appendingPathComponent("instrument-y.sf2")
        try Data("abc".utf8).write(to: temp)
        try InstrumentPackStore.installBank(
            fromTemp: temp, dest: dest,
            expectedSha256: "BA7816BF8F01CFEA414140DE5DAE2223B00361A396177A9CB410FF61F20015AD")
        XCTAssertTrue(FileManager.default.fileExists(atPath: dest.path))
        XCTAssertEqual(try Data(contentsOf: dest), Data("abc".utf8))
    }

    /// An empty expected digest (older manifest without checksums) installs unverified rather
    /// than bricking downloads — the lenient-decode doctrine applied to integrity metadata.
    func testInstallWithoutExpectedShaInstalls() throws {
        let temp = root.appendingPathComponent("dl.tmp")
        let dest = root.appendingPathComponent("instrument-z.sf2")
        try Data("abc".utf8).write(to: temp)
        try InstrumentPackStore.installBank(fromTemp: temp, dest: dest, expectedSha256: "")
        XCTAssertTrue(FileManager.default.fileExists(atPath: dest.path))
    }

    /// Losing the install race to a concurrent pack sharing the bank is SUCCESS (the winner is
    /// verified; ours is a duplicate) — and must not clobber the winner's file.
    func testInstallRaceLoserIsSuccessAndKeepsWinner() throws {
        let temp = root.appendingPathComponent("dl.tmp")
        let dest = root.appendingPathComponent("instrument-w.sf2")
        try Data("winner".utf8).write(to: dest)
        try Data("abc".utf8).write(to: temp)
        try InstrumentPackStore.installBank(
            fromTemp: temp, dest: dest,
            expectedSha256: "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad")
        XCTAssertEqual(try Data(contentsOf: dest), Data("winner".utf8))
        XCTAssertFalse(FileManager.default.fileExists(atPath: temp.path))
    }
}

import XCTest
@testable import PocketDJ

/// StudioFolders — the per-FAMILY storage resolver (samples/loops/sequences/takes/instruments)
/// + the strict deterministic-name mint/parse pair + shape-owned usage measurement. Hermetic via
/// `StudioFolders.appRootOverride`; these exercise the APP-STORAGE path (no bookmark) — the
/// user-folder bookmark machinery is byte-identical to SessionFolders/BurnStore, whose tests
/// cover bookmark resolution itself.
final class StudioFoldersTests: XCTestCase {

    private var root: URL!

    override func setUp() {
        super.setUp()
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("pdj-studiofolders-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        StudioFolders.appRootOverride = root
    }

    override func tearDown() {
        StudioFolders.appRootOverride = nil
        try? FileManager.default.removeItem(at: root)
        super.tearDown()
    }

    // MARK: Roots

    func testAppRootsAreDistinctPerFamilyUnderOverride() throws {
        var seen = Set<String>()
        for family in StudioFamily.allCases {
            let dir = try StudioFolders.appRoot(family)
            XCTAssertTrue(FileManager.default.fileExists(atPath: dir.path))
            XCTAssertEqual(dir.lastPathComponent, family.rawValue)
            XCTAssertTrue(dir.path.hasPrefix(root.path), "family root must live under the override")
            XCTAssertTrue(seen.insert(dir.path).inserted, "family roots must not collide")
        }
    }

    func testResolveRootWithNoBookmarkFallsBackToAppRoot() throws {
        let resolved = try XCTUnwrap(StudioFolders.resolveRoot(family: .samples, bookmark: nil,
                                                               requireWritable: true))
        XCTAssertFalse(resolved.scoped)
        XCTAssertFalse(resolved.isUserFolder)
        XCTAssertEqual(resolved.url.path, try StudioFolders.appRoot(.samples).path)
    }

    /// Garbage bookmark data must never fail the resolve — ANY problem falls back to app
    /// storage so a write can't target an inaccessible path.
    func testResolveRootWithGarbageBookmarkFallsBackToAppRoot() throws {
        let resolved = try XCTUnwrap(StudioFolders.resolveRoot(family: .loops,
                                                               bookmark: Data([0x00, 0x01, 0x02]),
                                                               requireWritable: true))
        XCTAssertFalse(resolved.isUserFolder)
        XCTAssertEqual(resolved.url.path, try StudioFolders.appRoot(.loops).path)
    }

    /// Instrument packs are ALWAYS app-managed — a bookmark for them is a caller bug (asserted in
    /// the resolver). Every other family (samples/loops/sequences/takes) is user-relocatable, but
    /// still falls back to the app root when no bookmark is set.
    func testAppManagedFamiliesResolveToAppRoot() throws {
        XCTAssertFalse(StudioFamily.instruments.supportsUserFolder)
        for family in StudioFamily.allCases {
            let resolved = try XCTUnwrap(StudioFolders.resolveRoot(family: family, bookmark: nil,
                                                                   requireWritable: true))
            XCTAssertFalse(resolved.isUserFolder)          // nil bookmark ⇒ app root for every family
        }
        XCTAssertTrue(StudioFamily.samples.supportsUserFolder)
        XCTAssertTrue(StudioFamily.loops.supportsUserFolder)
        XCTAssertTrue(StudioFamily.sequences.supportsUserFolder)
        XCTAssertTrue(StudioFamily.takes.supportsUserFolder)
    }

    // MARK: Deterministic names — mint + strict parse

    func testFileNameFileIdRoundTripPerFamily() {
        XCTAssertEqual(StudioFolders.fileName(.samples, id: "smp_abc"), "sample-smp_abc.m4a")
        XCTAssertEqual(StudioFolders.fileName(.loops, id: "lp_abc"), "loop-lp_abc.caf")
        XCTAssertEqual(StudioFolders.fileName(.sequences, id: "ptn_abc"), "pattern-ptn_abc.m4a")
        XCTAssertEqual(StudioFolders.fileName(.takes, id: "tk_abc"), "take-tk_abc.m4a")
        for (family, id) in [(StudioFamily.samples, "smp_abc"), (.loops, "lp_abc"),
                             (.sequences, "ptn_abc"), (.takes, "tk_abc")] {
            XCTAssertEqual(StudioFolders.fileId(family: family,
                                                name: StudioFolders.fileName(family, id: id)), id)
        }
        // Instruments embed a bank SLUG, not a minted id.
        XCTAssertEqual(StudioFolders.fileId(family: .instruments,
                                            name: "instrument-generaluser-gs-2.0.3.sf2"),
                       "generaluser-gs-2.0.3")
    }

    /// The parser is STRICT — user files share these folders, so anything that isn't exactly
    /// the family's shape (prefix + minted id namespace + extension) must never parse.
    func testStrictParserRejectsLooseNames() {
        // Wrong/absent id namespace.
        XCTAssertNil(StudioFolders.fileId(family: .samples, name: "sample-abc.m4a"))
        XCTAssertNil(StudioFolders.fileId(family: .samples, name: "sample-smp_.m4a"))   // empty id
        XCTAssertNil(StudioFolders.fileId(family: .samples, name: "sample-lp_abc.m4a")) // other family's id
        // Loose prefix/suffix matches.
        XCTAssertNil(StudioFolders.fileId(family: .samples, name: "mysample-smp_a.m4a"))
        XCTAssertNil(StudioFolders.fileId(family: .samples, name: "sample-smp_a.m4a.bak"))
        XCTAssertNil(StudioFolders.fileId(family: .samples, name: "sample-smp_a.mp3"))  // wrong ext
        // Cross-family confusion: a loop name never parses as a sample and vice versa.
        XCTAssertNil(StudioFolders.fileId(family: .samples, name: "loop-lp_a.caf"))
        XCTAssertNil(StudioFolders.fileId(family: .loops, name: "loop-lp_a.m4a"))       // loops are CAF
        // Instruments: an empty slug is not a file this app wrote.
        XCTAssertNil(StudioFolders.fileId(family: .instruments, name: "instrument-.sf2"))
        // Path separators never parse (corrupt/hostile document names).
        XCTAssertNil(StudioFolders.fileId(family: .samples, name: "x/sample-smp_a.m4a"))
    }

    /// A sample's render cache (`sample-<id>-r<rev>.m4a`) attributes to the SAME sample id —
    /// the `-r<digits>` stamp is stripped ('r' isn't a hex digit, so a real uuid can't collide).
    func testRenderedSampleNameParsesToSampleId() {
        let name = StudioFolders.renderedSampleFileName(id: "smp_abc", revision: 3)
        XCTAssertEqual(name, "sample-smp_abc-r3.m4a")
        XCTAssertEqual(StudioFolders.fileId(family: .samples, name: name), "smp_abc")
        // A trailing "-r" with no digits is NOT a revision stamp.
        XCTAssertEqual(StudioFolders.fileId(family: .samples, name: "sample-smp_abc-r.m4a"),
                       "smp_abc-r")
    }

    // MARK: fileURL — resolve by where the file was WRITTEN

    func testFileURLResolvesOnlyExistingAppStorageFiles() throws {
        let dir = try StudioFolders.appRoot(.samples)
        let name = "sample-smp_x.m4a"
        // Missing file → nil (never hand back a URL that isn't there).
        XCTAssertNil(StudioFolders.fileURL(family: .samples, fileName: name,
                                           wasUserFolder: false, bookmark: nil))
        try Data([0x00, 0x01]).write(to: dir.appendingPathComponent(name))
        let resolved = try XCTUnwrap(StudioFolders.fileURL(family: .samples, fileName: name,
                                                           wasUserFolder: false, bookmark: nil))
        XCTAssertEqual(resolved.url.path, dir.appendingPathComponent(name).path)
        XCTAssertNil(resolved.release)   // app storage → no security scope
    }

    /// A file recorded as living in the USER folder can't resolve when no folder is configured
    /// (the root is "gone") — it must NOT silently fall back to the app root, where a same-named
    /// file would be the WRONG file.
    func testUserFolderFileWithNoBookmarkDoesNotResolve() throws {
        let dir = try StudioFolders.appRoot(.samples)
        try Data([0x00]).write(to: dir.appendingPathComponent("sample-smp_y.m4a"))
        XCTAssertNil(StudioFolders.fileURL(family: .samples, fileName: "sample-smp_y.m4a",
                                           wasUserFolder: true, bookmark: nil))
    }

    /// Persisted names with path separators never resolve (they can't be names this app wrote).
    func testFileURLRejectsPathTraversal() {
        XCTAssertNil(StudioFolders.fileURL(family: .samples, fileName: "../evil.m4a",
                                           wasUserFolder: false, bookmark: nil))
        XCTAssertNil(StudioFolders.fileURL(family: .samples, fileName: "",
                                           wasUserFolder: false, bookmark: nil))
    }

    // MARK: Usage — only exact-shape names count

    func testUsageBytesCountsOnlyExactShapeNames() throws {
        let dir = try StudioFolders.appRoot(.samples)
        try Data(repeating: 0, count: 10).write(to: dir.appendingPathComponent("sample-smp_a.m4a"))
        try Data(repeating: 0, count: 5).write(to: dir.appendingPathComponent("sample-smp_b-r2.m4a"))
        // Decoys that must NOT count: user-ish names, other families, non-audio.
        try Data(repeating: 0, count: 100).write(to: dir.appendingPathComponent("sample-of-my-mix.m4a"))
        try Data(repeating: 0, count: 100).write(to: dir.appendingPathComponent("loop-lp_x.caf"))
        try Data(repeating: 0, count: 100).write(to: dir.appendingPathComponent("notes.txt"))
        XCTAssertEqual(StudioFolders.usageBytes(family: .samples, bookmark: nil), 15)
        // The loop decoy lives in the SAMPLES dir — the loops family's usage doesn't see it.
        XCTAssertEqual(StudioFolders.usageBytes(family: .loops, bookmark: nil), 0)
    }

    /// `knownIds` gates ownership in the USER root only — the app root is app-private, so
    /// shape alone owns there (BurnStore.ownsAuxFile discipline).
    func testUsageBytesKnownIdsGateDoesNotApplyToAppRoot() throws {
        let dir = try StudioFolders.appRoot(.loops)
        try Data(repeating: 0, count: 7).write(to: dir.appendingPathComponent("loop-lp_a.caf"))
        XCTAssertEqual(StudioFolders.usageBytes(family: .loops, bookmark: nil, knownIds: []), 7)
    }
}

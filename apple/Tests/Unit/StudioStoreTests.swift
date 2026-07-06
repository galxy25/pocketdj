import XCTest
@testable import PocketDJ

/// StudioStore — the Studio document (samples/loops/patterns/takes/cues): CRUD + persistence
/// round-trip, lenient/lossy decode, the cue 8-slot cap, delete-with-referrers, BurnStore-style
/// reconcile (unreachable root ⇒ keep), playback resolution incl. the render-cache freshness
/// stamp, per-family usage/delete-all safety rules, and id minting. Hermetic: a temp document
/// file + `StudioFolders.appRootOverride`; `settings` stays nil (⇒ no user roots, and a
/// `wasUserFolder` record behaves exactly like one whose folder is unplugged).
@MainActor
final class StudioStoreTests: XCTestCase {

    private var root: URL!
    private var storeURL: URL!

    override func setUp() {
        super.setUp()
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("pdj-studiostore-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        StudioFolders.appRootOverride = root
        storeURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("pdj-studiostore-\(UUID().uuidString).json")
    }

    override func tearDown() {
        StudioFolders.appRootOverride = nil
        try? FileManager.default.removeItem(at: root)
        try? FileManager.default.removeItem(at: storeURL)
        super.tearDown()
    }

    // MARK: Helpers

    /// Write a family artifact file into the APP root and return its deterministic name.
    @discardableResult
    private func writeFile(_ family: StudioFamily, id: String, bytes: Int = 4) throws -> String {
        let name = StudioFolders.fileName(family, id: id)
        let dir = try StudioFolders.appRoot(family)
        try Data(repeating: 0, count: bytes).write(to: dir.appendingPathComponent(name))
        return name
    }

    private func makeSample(_ id: String, wasUserFolder: Bool = false) -> StudioSample {
        StudioSample(id: id, name: "Sample \(id)", fileName: StudioFolders.fileName(.samples, id: id),
                     wasUserFolder: wasUserFolder, createdAt: 1_000, durationMs: 2_000,
                     source: .track(songId: "sng_1", startMs: 0, endMs: 2_000),
                     grid: StudioGrid(bpm: 120))
    }

    private func makeLoop(_ id: String, sampleId: String, wasUserFolder: Bool = false) -> StudioLoop {
        StudioLoop(id: id, name: "Loop \(id)", sampleId: sampleId, anchorMs: 0, beats: .four,
                   bpm: 120, lengthMs: 2_000, frames: 88_200,
                   fileName: StudioFolders.fileName(.loops, id: id),
                   wasUserFolder: wasUserFolder, createdAt: 1_000)
    }

    // MARK: CRUD + persistence round-trip

    func testCrudRoundTripPersistsAcrossReload() throws {
        let store = StudioStore(fileURL: storeURL)
        store.addSample(makeSample("smp_a"))
        store.addLoop(makeLoop("lp_a", sampleId: "smp_a"))
        store.addPattern(StudioPattern(id: "ptn_a", name: "P", bpm: 100,
                                       rows: [StudioPatternRow(targetId: "lp_a")], createdAt: 1_000))
        store.addTake(StudioTake(id: "tk_a", name: "T", instrument: .harp,
                                 fileName: StudioFolders.fileName(.takes, id: "tk_a"), bpm: 90,
                                 events: [StudioNoteEvent(onMs: 0, offMs: 500, note: 60, velocity: 100)],
                                 durationMs: 4_000, createdAt: 1_000))
        XCTAssertNotNil(store.setCue(songId: "sng_1", slot: 0, positionMs: 1_500, name: "Intro"))

        // Rename everywhere (spec §2) — every family supports it.
        store.renameSample("smp_a", to: "My Stab")
        store.renameLoop("lp_a", to: "My Loop")
        store.renamePattern("ptn_a", to: "My Pattern")
        store.renameTake("tk_a", to: "My Take")
        store.renameCue(songId: "sng_1", slot: 0, name: "Verse")
        // Blank rename is a no-op, not a wipe.
        store.renameSample("smp_a", to: "   ")
        XCTAssertEqual(store.sample("smp_a")?.name, "My Stab")

        store.flush()   // synchronous — reload must see everything

        let reloaded = StudioStore(fileURL: storeURL)
        XCTAssertEqual(reloaded.sample("smp_a")?.name, "My Stab")
        XCTAssertEqual(reloaded.sample("smp_a")?.grid?.bpm, 120)
        XCTAssertEqual(reloaded.loop("lp_a")?.name, "My Loop")
        XCTAssertEqual(reloaded.loop("lp_a")?.frames, 88_200)
        XCTAssertEqual(reloaded.loop("lp_a")?.beats, .four)
        XCTAssertEqual(reloaded.pattern("ptn_a")?.name, "My Pattern")
        XCTAssertEqual(reloaded.pattern("ptn_a")?.rows.first?.steps.count, StudioPattern.stepCount)
        XCTAssertEqual(reloaded.take("tk_a")?.instrument, .harp)
        XCTAssertEqual(reloaded.take("tk_a")?.events.first?.note, 60)
        XCTAssertEqual(reloaded.cue(songId: "sng_1", slot: 0)?.name, "Verse")
        XCTAssertEqual(reloaded.cue(songId: "sng_1", slot: 0)?.positionMs, 1_500)
    }

    /// Upsert-by-id: re-filing the same id replaces the record, never duplicates a row.
    func testAddIsUpsertById() {
        let store = StudioStore(fileURL: storeURL)
        store.addSample(makeSample("smp_a"))
        var replacement = makeSample("smp_a")
        replacement.name = "Replaced"
        store.addSample(replacement)
        XCTAssertEqual(store.samples.count, 1)
        XCTAssertEqual(store.sample("smp_a")?.name, "Replaced")
    }

    // MARK: Lenient decode

    /// Unknown top-level fields, unknown per-record fields, an unknown source kind, an invalid
    /// LoopBeats value, missing arrays, a short steps array, AND one garbage list element — all
    /// must degrade (defaults / dropped element), never brick the document.
    func testLenientDecodeUnknownFieldsAndMissingArrays() throws {
        let json = """
        {
          "schemaVersion": 99,
          "futureBlob": {"nested": [1, 2, 3]},
          "samples": [
            "garbage-element",
            {
              "id": "smp_a", "name": "A", "fileName": "sample-smp_a.m4a",
              "futureField": true,
              "source": {"type": "warp", "warpFactor": 9},
              "edit": {"rate": 1.25, "futureKnob": 3}
            }
          ],
          "loops": [
            {"id": "lp_a", "name": "L", "sampleId": "smp_a", "beats": 3.7,
             "fileName": "loop-lp_a.caf"}
          ],
          "patterns": [
            {"id": "ptn_a", "name": "P",
             "rows": [{"targetId": "smp_a", "steps": [true, true]}]}
          ]
        }
        """
        try Data(json.utf8).write(to: storeURL)
        let store = StudioStore(fileURL: storeURL)

        XCTAssertEqual(store.samples.count, 1)                       // garbage element dropped, sibling kept
        let s = try XCTUnwrap(store.sample("smp_a"))
        XCTAssertEqual(s.source, .mic)                               // unknown source kind → lenient sink
        XCTAssertEqual(s.edit.rate, 1.25)                            // known edit fields survive
        XCTAssertEqual(s.edit.gainDb, 0)                             // missing edit fields default
        XCTAssertEqual(store.loop("lp_a")?.beats, .four)             // invalid beats → default
        let row = try XCTUnwrap(store.pattern("ptn_a")?.rows.first)
        XCTAssertEqual(row.steps.count, StudioPattern.stepCount)     // short steps padded to 16
        XCTAssertEqual(Array(row.steps.prefix(2)), [true, true])
        XCTAssertTrue(store.takes.isEmpty)                           // missing arrays → empty
        XCTAssertTrue(store.cues.isEmpty)
    }

    // MARK: Source provenance — .file round-trips; encoded form stays old-build-safe

    func testFileSourceRoundTripsAndDegradesGracefully() throws {
        let src = StudioSource.file(originalName: "Amen Break.wav")
        let data = try JSONEncoder().encode(src)
        XCTAssertEqual(try JSONDecoder().decode(StudioSource.self, from: data), src)
        // Encoded as type:"file" + originalName — an OLD build with no .file case hits its
        // hand-written default arm and degrades to .mic (the sample still plays; label is lost).
        let obj = try XCTUnwrap(try JSONSerialization.jsonObject(with: data) as? [String: Any])
        XCTAssertEqual(obj["type"] as? String, "file")
        XCTAssertEqual(obj["originalName"] as? String, "Amen Break.wav")
    }

    // MARK: Cues — max 8, slot replace

    func testCueMaxEightAndSlotReplace() {
        let store = StudioStore(fileURL: storeURL)
        for slot in 0..<StudioCue.maxSlots {
            XCTAssertNotNil(store.setCue(songId: "sng_1", slot: slot, positionMs: slot * 1_000))
        }
        XCTAssertEqual(store.cues(forSong: "sng_1").count, 8)
        // The cap is the slot domain itself: slot 8 / negative slots are rejected outright.
        XCTAssertNil(store.setCue(songId: "sng_1", slot: 8, positionMs: 0))
        XCTAssertNil(store.setCue(songId: "sng_1", slot: -1, positionMs: 0))
        XCTAssertEqual(store.cues(forSong: "sng_1").count, 8)
        // Re-setting an occupied slot REPLACES: same id, new position, name preserved.
        store.renameCue(songId: "sng_1", slot: 3, name: "Bridge")
        let before = store.cue(songId: "sng_1", slot: 3)
        XCTAssertNotNil(store.setCue(songId: "sng_1", slot: 3, positionMs: 9_999))
        let after = store.cue(songId: "sng_1", slot: 3)
        XCTAssertEqual(store.cues(forSong: "sng_1").count, 8)
        XCTAssertEqual(after?.id, before?.id)
        XCTAssertEqual(after?.positionMs, 9_999)
        XCTAssertEqual(after?.name, "Bridge")
        // Another song has its own 8 slots.
        XCTAssertNotNil(store.setCue(songId: "sng_2", slot: 0, positionMs: 1))
        // Nudge clamps at 0; remove frees the slot.
        store.nudgeCue(songId: "sng_1", slot: 0, deltaMs: -99_999)
        XCTAssertEqual(store.cue(songId: "sng_1", slot: 0)?.positionMs, 0)
        store.removeCue(songId: "sng_1", slot: 0)
        XCTAssertNil(store.cue(songId: "sng_1", slot: 0))
        XCTAssertEqual(store.cues(forSong: "sng_1").count, 7)
    }

    // MARK: Delete with referrers

    func testReferrersCountsAndDeleteKeepsThem() throws {
        let store = StudioStore(fileURL: storeURL)
        try writeFile(.samples, id: "smp_a")
        store.addSample(makeSample("smp_a"))
        store.addLoop(makeLoop("lp_1", sampleId: "smp_a"))
        store.addLoop(makeLoop("lp_2", sampleId: "smp_a"))
        store.addPattern(StudioPattern(id: "ptn_1", name: "P1",
                                       rows: [StudioPatternRow(targetId: "smp_a"),
                                              StudioPatternRow(targetId: "smp_a")]))
        store.addPattern(StudioPattern(id: "ptn_2", name: "P2",
                                       rows: [StudioPatternRow(targetId: "lp_1"),
                                              StudioPatternRow(targetId: "smp_a")]))

        let refs = store.referrers(for: "smp_a")
        XCTAssertEqual(refs.loopCount, 2)          // "2 loops keep playing but can't be re-sliced"
        XCTAssertEqual(refs.patternRowCount, 3)    // "3 pattern rows will be muted"

        XCTAssertTrue(store.deleteSample("smp_a"))
        // Loops SURVIVE (self-contained after render) with a now-dangling sampleId — flagged,
        // never deleted; pattern rows stay as "missing" rows.
        XCTAssertEqual(store.loops.count, 2)
        XCTAssertFalse(store.sampleExists("smp_a"))
        XCTAssertEqual(store.pattern("ptn_1")?.rows.count, 2)
        XCTAssertFalse(store.targetExists("smp_a"))
        XCTAssertTrue(store.targetExists("lp_1"))
    }

    /// Deleting an artifact whose USER root is unreachable is refused (record kept) — dropping
    /// the record without deleting the file would orphan it forever.
    func testDeleteRefusedWhenUserRootUnreachable() {
        let store = StudioStore(fileURL: storeURL)   // settings nil ⇒ every user root unreachable
        store.addSample(makeSample("smp_u", wasUserFolder: true))
        XCTAssertFalse(store.deleteSample("smp_u"))
        XCTAssertNotNil(store.sample("smp_u"))
    }

    // MARK: Reconcile

    func testReconcileKeepsUnreachableDropsProvablyGone() throws {
        let store = StudioStore(fileURL: storeURL)
        // App-storage sample WITH its file → kept.
        try writeFile(.samples, id: "smp_kept")
        store.addSample(makeSample("smp_kept"))
        // App-storage sample whose file vanished (iOS purge) → provably gone → dropped.
        store.addSample(makeSample("smp_gone"))
        // USER-folder sample with no bookmark (unplugged drive / offline provider) → SKIP, kept.
        store.addSample(makeSample("smp_user", wasUserFolder: true))
        // Loop whose CAF vanished → dropped; loop with file → kept.
        try writeFile(.loops, id: "lp_kept")
        store.addLoop(makeLoop("lp_kept", sampleId: "smp_kept"))
        store.addLoop(makeLoop("lp_gone", sampleId: "smp_kept"))
        // Pattern whose BOUNCE vanished: the pattern (its steps are the data) survives with the
        // bounce reference cleared + re-marked dirty — never dropped.
        store.addPattern(StudioPattern(id: "ptn_b", name: "P",
                                       rows: [StudioPatternRow(targetId: "lp_kept")],
                                       fileName: StudioFolders.fileName(.sequences, id: "ptn_b"),
                                       bounceDirty: false))
        // Take whose audio vanished → dropped.
        store.addTake(StudioTake(id: "tk_gone", name: "T",
                                 fileName: StudioFolders.fileName(.takes, id: "tk_gone")))

        store.reconcileOnLaunch()

        XCTAssertNotNil(store.sample("smp_kept"))
        XCTAssertNil(store.sample("smp_gone"))
        XCTAssertNotNil(store.sample("smp_user"))    // unreachable root ⇒ never pruned
        XCTAssertNotNil(store.loop("lp_kept"))
        XCTAssertNil(store.loop("lp_gone"))
        let p = try XCTUnwrap(store.pattern("ptn_b"))
        XCTAssertNil(p.fileName)
        XCTAssertTrue(p.bounceDirty)
        XCTAssertNil(store.take("tk_gone"))
    }

    /// A stale render-cache reference (file gone, raw intact) is cleared without touching the
    /// sample itself.
    func testReconcileClearsDanglingRenderCache() throws {
        let store = StudioStore(fileURL: storeURL)
        try writeFile(.samples, id: "smp_a")
        store.addSample(makeSample("smp_a"))
        store.setRenderedSample("smp_a", fileName: StudioFolders.renderedSampleFileName(id: "smp_a", revision: 0),
                                wasUserFolder: false, revision: 0)
        store.reconcileOnLaunch()
        let s = try XCTUnwrap(store.sample("smp_a"))
        XCTAssertNil(s.renderedFileName)
        XCTAssertNil(s.renderedRevision)
    }

    // MARK: Render revision + playback resolution

    func testRenderRevisionBumpsOnlyOnRealEditChange() {
        let store = StudioStore(fileURL: storeURL)
        store.addSample(makeSample("smp_a"))
        XCTAssertEqual(store.sample("smp_a")?.renderRevision, 0)
        var edit = StudioSampleEdit(); edit.rate = 1.5
        store.updateSampleEdit("smp_a", edit)
        XCTAssertEqual(store.sample("smp_a")?.renderRevision, 1)
        store.updateSampleEdit("smp_a", edit)                 // identical → no bump
        XCTAssertEqual(store.sample("smp_a")?.renderRevision, 1)
        edit.rate = 5.0                                        // clamped to 2.0 — a real change
        store.updateSampleEdit("smp_a", edit)
        XCTAssertEqual(store.sample("smp_a")?.renderRevision, 2)
        XCTAssertEqual(store.sample("smp_a")?.edit.rate, 2.0)
    }

    func testLocalURLForPlaybackPrefersFreshRenderElseRaw() throws {
        let store = StudioStore(fileURL: storeURL)
        try writeFile(.samples, id: "smp_a")
        store.addSample(makeSample("smp_a"))

        // No render cache yet → the raw file.
        var got = try XCTUnwrap(store.localURLForPlayback(id: "smp_a"))
        XCTAssertEqual(got.url.lastPathComponent, "sample-smp_a.m4a")
        XCTAssertEqual(got.title, "Sample smp_a")
        XCTAssertEqual(got.lengthMs, 2_000)

        // Fresh render cache (revision matches) → the cache.
        let cache = StudioFolders.renderedSampleFileName(id: "smp_a", revision: 0)
        let dir = try StudioFolders.appRoot(.samples)
        try Data([0x1]).write(to: dir.appendingPathComponent(cache))
        store.setRenderedSample("smp_a", fileName: cache, wasUserFolder: false, revision: 0)
        got = try XCTUnwrap(store.localURLForPlayback(id: "smp_a"))
        XCTAssertEqual(got.url.lastPathComponent, cache)

        // An edit bumps the revision → the cache is STALE → back to the raw file.
        store.updateSampleEdit("smp_a", StudioSampleEdit(rate: 1.5))
        got = try XCTUnwrap(store.localURLForPlayback(id: "smp_a"))
        XCTAssertEqual(got.url.lastPathComponent, "sample-smp_a.m4a")
        // The edited length reflects the trim/rate math (2000 ms at 1.5× → 1333 ms).
        XCTAssertEqual(got.lengthMs, 1_333)
    }

    func testLocalURLForPlaybackLoopAndPattern() throws {
        let store = StudioStore(fileURL: storeURL)
        try writeFile(.loops, id: "lp_a")
        store.addLoop(makeLoop("lp_a", sampleId: "smp_gone"))
        let l = try XCTUnwrap(store.localURLForPlayback(id: "lp_a"))
        XCTAssertEqual(l.url.lastPathComponent, "loop-lp_a.caf")
        XCTAssertEqual(l.lengthMs, 2_000)

        // A dirty pattern has no truthful file → nil, even with a stale bounce on disk.
        let bounce = try writeFile(.sequences, id: "ptn_a")
        store.addPattern(StudioPattern(id: "ptn_a", name: "P", bpm: 120,
                                       rows: [StudioPatternRow(targetId: "lp_a")]))
        XCTAssertNil(store.localURLForPlayback(id: "ptn_a"))
        store.setPatternBounced("ptn_a", fileName: bounce, wasUserFolder: false)
        let p = try XCTUnwrap(store.localURLForPlayback(id: "ptn_a"))
        XCTAssertEqual(p.url.lastPathComponent, bounce)
        XCTAssertEqual(p.lengthMs, 2_000)   // one bar at 120 BPM
        // Any content edit re-dirties → nil again (spec §2: dirty on any edit).
        store.setPatternStep("ptn_a", row: 0, col: 0, on: true)
        XCTAssertNil(store.localURLForPlayback(id: "ptn_a"))
        // Non-studio / non-playable ids resolve to nothing.
        XCTAssertNil(store.localURLForPlayback(id: "sng_1"))
        XCTAssertNil(store.localURLForPlayback(id: "tk_x"))
    }

    // MARK: Usage + delete-all

    func testUsageBytesCountsOnlyOwnedShapes() throws {
        let store = StudioStore(fileURL: storeURL)
        try writeFile(.samples, id: "smp_a", bytes: 10)
        store.addSample(makeSample("smp_a"))
        let dir = try StudioFolders.appRoot(.samples)
        try Data(repeating: 0, count: 100).write(to: dir.appendingPathComponent("users-own.m4a"))
        XCTAssertEqual(store.usageBytes(family: .samples), 10)
    }

    func testDeleteAllSkipsActiveTakeAndKeepsUnreachableRecords() throws {
        let store = StudioStore(fileURL: storeURL)
        // Two takes on disk + records; one is the recorder's LIVE capture.
        let liveName = try writeFile(.takes, id: "tk_live")
        let doneName = try writeFile(.takes, id: "tk_done")
        store.addTake(StudioTake(id: "tk_live", name: "Live", fileName: liveName))
        store.addTake(StudioTake(id: "tk_done", name: "Done", fileName: doneName))
        store.activeTakeFileName = { liveName }

        store.deleteAll(family: .takes)

        let dir = try StudioFolders.appRoot(.takes)
        XCTAssertTrue(FileManager.default.fileExists(atPath: dir.appendingPathComponent(liveName).path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: dir.appendingPathComponent(doneName).path))
        XCTAssertNotNil(store.take("tk_live"))   // file survived → record survives
        XCTAssertNil(store.take("tk_done"))

        // Samples: an app-storage record goes; a user-root record (unreachable — settings nil)
        // is KEPT, its file untouched wherever it lives.
        try writeFile(.samples, id: "smp_app")
        store.addSample(makeSample("smp_app"))
        store.addSample(makeSample("smp_user", wasUserFolder: true))
        store.deleteAll(family: .samples)
        XCTAssertNil(store.sample("smp_app"))
        XCTAssertNotNil(store.sample("smp_user"))
    }

    // MARK: Id minting

    func testIdMintingAndIsStudioId() {
        XCTAssertTrue(StudioFactory.newSampleId().hasPrefix("smp_"))
        XCTAssertTrue(StudioFactory.newLoopId().hasPrefix("lp_"))
        XCTAssertTrue(StudioFactory.newPatternId().hasPrefix("ptn_"))
        XCTAssertTrue(StudioFactory.newTakeId().hasPrefix("tk_"))
        XCTAssertTrue(StudioFactory.newCueId().hasPrefix("cue_"))
        // Minted uuids are lowercase (CollectionsFactory convention).
        let minted = StudioFactory.uid()
        XCTAssertEqual(minted, minted.lowercased())

        XCTAssertEqual(StudioFactory.studioPrefixes, ["smp_", "lp_", "ptn_", "tk_"])
        for p in StudioFactory.studioPrefixes {
            XCTAssertTrue(StudioFactory.isStudioId(p + "x"))
        }
        // Catalog songs and cues are NOT collection-riding studio ids.
        XCTAssertFalse(StudioFactory.isStudioId("sng_1"))
        XCTAssertFalse(StudioFactory.isStudioId("cue_abc"))
        XCTAssertFalse(StudioFactory.isStudioId("pkt_abc"))
    }
}

import XCTest
import AVFoundation
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
        XCTAssertEqual(reloaded.pattern("ptn_a")?.rows.first?.steps.count, StudioPattern.defaultStepCount)
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

    // MARK: Multitrack arranger (Tracks sub-tab)

    /// Arrangement / track / clip CRUD: create, add tracks, place a clip (with a real clip file),
    /// set mix-strip state + rename, then RELOAD and verify it all persisted. Duplicate copies the
    /// clip audio to a fresh file (two records never share one file); delete removes the files.
    func testArrangementTrackClipCrudRoundTripAndFiles() throws {
        let store = StudioStore(fileURL: storeURL)
        let arr = store.createArrangement(name: "Set A")
        let t0 = try XCTUnwrap(store.addTrack(arrangement: arr.id, name: "Vocals"))
        let t1 = try XCTUnwrap(store.addTrack(arrangement: arr.id))
        XCTAssertEqual(t1.name, "Track 2")                 // auto-named by position
        XCTAssertEqual(t1.colorIndex, 1)                   // palette cycles by index

        // Place a clip on track 0 (its audio file must exist on disk).
        let clipName = StudioStore.clipFileName("clip_x")
        let dir = try StudioStore.arrangementsDir()
        try Data(repeating: 7, count: 16).write(to: dir.appendingPathComponent(clipName))
        store.addClip(arrangement: arr.id, track: t0.id,
                      StudioClip(id: "clip_x", name: "Hook", fileName: clipName,
                                 startMs: 500, durationMs: 1_500, source: .sample, sourceId: "smp_a"))

        // Mix strip + rename.
        store.setTrackGain(arrangement: arr.id, track: t0.id, gainDb: -6)
        store.setTrackMuted(arrangement: arr.id, track: t1.id, true)
        store.setTrackSoloed(arrangement: arr.id, track: t0.id, true)
        store.renameTrack(arrangement: arr.id, track: t1.id, to: "Drums")
        store.flush()

        let reloaded = StudioStore(fileURL: storeURL)
        let ra = try XCTUnwrap(reloaded.arrangement(arr.id))
        XCTAssertEqual(ra.name, "Set A")
        XCTAssertEqual(ra.tracks.count, 2)
        XCTAssertEqual(ra.tracks[0].clips.first?.id, "clip_x")
        XCTAssertEqual(ra.tracks[0].clips.first?.startMs, 500)
        XCTAssertEqual(ra.tracks[0].clips.first?.endMs, 2_000)
        XCTAssertEqual(ra.tracks[0].gainDb, -6)
        XCTAssertTrue(ra.tracks[0].soloed)
        XCTAssertTrue(ra.tracks[1].muted)
        XCTAssertEqual(ra.tracks[1].name, "Drums")
        XCTAssertEqual(ra.lengthMs, 2_000)                 // timeline end = longest track

        // Duplicate track 0: fresh ids, clip audio COPIED to its own file (both exist, distinct).
        let dup = try XCTUnwrap(reloaded.duplicateTrack(arrangement: arr.id, track: t0.id))
        XCTAssertEqual(dup.name, "Vocals copy")
        XCTAssertFalse(dup.soloed)                          // solo dropped on duplicate
        let dupClip = try XCTUnwrap(dup.clips.first)
        XCTAssertNotEqual(dupClip.id, "clip_x")
        XCTAssertNotNil(reloaded.clipFileURL(dupClip.fileName), "duplicated clip audio must exist")
        XCTAssertNotNil(reloaded.clipFileURL(clipName), "original clip audio must survive")

        // Delete the duplicate track → its (copied) clip file is removed; the original stays.
        XCTAssertTrue(reloaded.deleteTrack(arrangement: arr.id, track: dup.id))
        XCTAssertNil(reloaded.clipFileURL(dupClip.fileName), "deleted track's clip file must be gone")
        XCTAssertNotNil(reloaded.clipFileURL(clipName), "original clip audio must survive the delete")

        // Delete the arrangement → gone, its clip files swept.
        XCTAssertTrue(reloaded.deleteArrangement(arr.id))
        XCTAssertNil(reloaded.arrangement(arr.id))
        XCTAssertNil(reloaded.clipFileURL(clipName))
    }

    /// Additive-optional: a legacy document with NO `arrangements` key decodes to `[]` (never a
    /// decode failure), and a garbage arrangement element drops only itself (per-element lossy).
    func testArrangementLegacyDecodeAndLossyElement() throws {
        let json = """
        { "schemaVersion": 1, "samples": [], "loops": [], "patterns": [], "takes": [],
          "cues": [], "slices": [], "folders": [],
          "arrangements": [ { "id": "arr_ok", "name": "Keep", "tracks": [] }, 42 ] }
        """
        let doc = try JSONDecoder().decode(StudioDocument.self, from: Data(json.utf8))
        XCTAssertEqual(doc.arrangements.count, 1)          // the "42" garbage element dropped
        XCTAssertEqual(doc.arrangements.first?.id, "arr_ok")

        // A document missing the key entirely → empty list (no brick).
        let legacy = "{ \"schemaVersion\": 1, \"samples\": [] }"
        let ld = try JSONDecoder().decode(StudioDocument.self, from: Data(legacy.utf8))
        XCTAssertTrue(ld.arrangements.isEmpty)
    }

    // MARK: Multitrack arranger — round 2 (pan / color / tempo / loop / master-FX / folders)

    /// Per-track pan + user-set colour round-trip; pan clamps to [-1,1]; colour wraps into the palette.
    func testTrackPanColorRoundTripAndClamp() throws {
        let store = StudioStore(fileURL: storeURL)
        let arr = store.createArrangement(name: "Mix")
        let t0 = try XCTUnwrap(store.addTrack(arrangement: arr.id))
        store.setTrackPan(arrangement: arr.id, track: t0.id, pan: -0.7)
        store.setTrackColor(arrangement: arr.id, track: t0.id, colorIndex: 11)   // wraps mod 8 → 3
        store.setTrackPan(arrangement: arr.id, track: t0.id, pan: 5)             // clamps to +1
        store.flush()

        let rt = try XCTUnwrap(StudioStore(fileURL: storeURL).arrangement(arr.id)?.tracks.first)
        XCTAssertEqual(rt.pan, 1, accuracy: 0.0001)
        XCTAssertEqual(rt.colorIndex, 3)
    }

    /// Arrangement tempo + loop region + master-FX round-trip; loop end clamps ≥ start; bpm garbage
    /// falls back to 120 and clamps to a musical range.
    func testArrangementTempoLoopMasterFXRoundTrip() throws {
        let store = StudioStore(fileURL: storeURL)
        let arr = store.createArrangement(name: "Set")
        XCTAssertEqual(store.arrangement(arr.id)?.bpm, 120)               // default

        store.setArrangementBpm(arr.id, bpm: 0)                          // garbage ⇒ 120
        XCTAssertEqual(store.arrangement(arr.id)?.bpm, 120)
        store.setArrangementBpm(arr.id, bpm: 90)
        store.setArrangementLoop(arr.id, enabled: true, startMs: 2_000, endMs: 500) // end clamps up
        var fx = StudioMasterFX()
        fx.phaserEnabled = true; fx.phaserRate = 1.5
        fx.brazilianBassEnabled = true; fx.brazilianBassAmount = 0.8
        fx.driveEnabled = true; fx.driveAmount = 0.7
        fx.masterGainDb = 3
        store.setArrangementMasterFX(arr.id, fx)
        store.flush()

        let ra = try XCTUnwrap(StudioStore(fileURL: storeURL).arrangement(arr.id))
        XCTAssertEqual(ra.bpm, 90)
        XCTAssertTrue(ra.loopEnabled)
        XCTAssertEqual(ra.loopStartMs, 2_000)
        XCTAssertEqual(ra.loopEndMs, 2_000)                              // clamped up to start
        XCTAssertTrue(ra.masterFX.phaserEnabled)
        XCTAssertEqual(ra.masterFX.phaserRate, 1.5, accuracy: 0.0001)
        XCTAssertTrue(ra.masterFX.brazilianBassEnabled)
        XCTAssertTrue(ra.masterFX.driveEnabled)
        XCTAssertEqual(ra.masterFX.driveAmount, 0.7, accuracy: 0.0001)
        XCTAssertEqual(ra.masterFX.masterGainDb, 3, accuracy: 0.0001)
    }

    /// Legacy arrangements (no bpm/loop/pan/masterFX keys) default cleanly; a partial masterFX blob
    /// degrades field-by-field (present field decoded, absent fields default).
    func testArrangementRound2LegacyDecode() throws {
        let json = """
        { "schemaVersion": 1, "arrangements": [
            { "id": "arr_x", "name": "Legacy",
              "tracks": [ { "id": "trk_a", "name": "T", "clips": [] } ],
              "masterFX": { "ringModEnabled": true } }
        ] }
        """
        let doc = try JSONDecoder().decode(StudioDocument.self, from: Data(json.utf8))
        let a = try XCTUnwrap(doc.arrangements.first)
        XCTAssertEqual(a.bpm, 120)                     // absent ⇒ default
        XCTAssertFalse(a.loopEnabled)
        XCTAssertEqual(a.tracks.first?.pan, 0)         // absent ⇒ center
        XCTAssertTrue(a.masterFX.ringModEnabled)       // present field decoded
        XCTAssertFalse(a.masterFX.phaserEnabled)       // absent field ⇒ default
        XCTAssertEqual(a.masterFX.ringModFreqHz, 200)  // absent ⇒ default
    }

    /// Tempo seeds from the FIRST clip's source item; a later clip from a different-bpm source does
    /// NOT override the seeded tempo.
    func testArrangementBpmSeedsFromFirstClip() throws {
        let store = StudioStore(fileURL: storeURL)
        _ = store.addLoop(StudioLoop(id: "lp_a", name: "Groove", sampleId: "smp_a",
                                     bpm: 128, fileName: StudioFolders.fileName(.loops, id: "lp_a")))
        _ = store.addLoop(StudioLoop(id: "lp_b", name: "Other", sampleId: "smp_b",
                                     bpm: 90, fileName: StudioFolders.fileName(.loops, id: "lp_b")))
        let arr = store.createArrangement(name: "Set")
        let t0 = try XCTUnwrap(store.addTrack(arrangement: arr.id))
        let dir = try StudioStore.arrangementsDir()
        let f1 = StudioStore.clipFileName("clip_1")
        try Data(repeating: 1, count: 8).write(to: dir.appendingPathComponent(f1))
        store.addClip(arrangement: arr.id, track: t0.id,
                      StudioClip(id: "clip_1", name: "L", fileName: f1, durationMs: 500,
                                 source: .loop, sourceId: "lp_a"))
        XCTAssertEqual(store.arrangement(arr.id)?.bpm, 128)              // seeded from first clip

        let f2 = StudioStore.clipFileName("clip_2")
        try Data(repeating: 2, count: 8).write(to: dir.appendingPathComponent(f2))
        store.addClip(arrangement: arr.id, track: t0.id,
                      StudioClip(id: "clip_2", name: "L2", fileName: f2, startMs: 600, durationMs: 500,
                                 source: .loop, sourceId: "lp_b"))
        XCTAssertEqual(store.arrangement(arr.id)?.bpm, 128)             // NOT overridden by later clip
    }

    /// Arrangement-folder CRUD: mints an `arrfld_` id (NOT collection-riding), partitions
    /// arrangements(inFolder:), delete re-homes members (deletes NO arrangement), dangling ⇒ loose,
    /// and the whole thing round-trips.
    func testArrangementFolderCrudRehomeDanglingRoundTrip() throws {
        let store = StudioStore(fileURL: storeURL)
        let a1 = store.createArrangement(name: "Set A")
        let a2 = store.createArrangement(name: "Set B")
        let f = store.createArrangementFolder("Live")
        XCTAssertTrue(f.id.hasPrefix("arrfld_"))
        XCTAssertFalse(StudioFactory.isStudioId(f.id), "arrfld_ must NOT ride collections")

        store.moveArrangementToFolder(a1.id, folderId: f.id)
        XCTAssertEqual(store.arrangements(inFolder: f.id).map(\.id), [a1.id])
        XCTAssertEqual(store.arrangements(inFolder: nil).map(\.id), [a2.id])

        store.renameArrangementFolder(f.id, to: "  On Stage ")
        XCTAssertEqual(store.arrangementFolder(f.id)?.name, "On Stage")

        // Dangling membership (folder id not in the document) reads as loose.
        store.moveArrangementToFolder(a2.id, folderId: "arrfld_ghost")
        XCTAssertEqual(Set(store.arrangements(inFolder: nil).map(\.id)), [a2.id])

        store.flush()
        let reloaded = StudioStore(fileURL: storeURL)
        XCTAssertEqual(reloaded.arrangementFoldersOrdered().map(\.name), ["On Stage"])
        XCTAssertEqual(reloaded.arrangement(a1.id)?.folderId, f.id)

        // Delete the folder → members re-home to loose; NO arrangement deleted.
        reloaded.deleteArrangementFolder(f.id)
        XCTAssertNil(reloaded.arrangementFolder(f.id))
        XCTAssertNotNil(reloaded.arrangement(a1.id))
        XCTAssertNil(reloaded.arrangement(a1.id)?.folderId)
        XCTAssertEqual(Set(reloaded.arrangements(inFolder: nil).map(\.id)), [a1.id, a2.id])
    }

    /// A bounce BAKES the master FX into the written audio (Levi: "add tests that bouncing includes
    /// the master fx affect on the bounced audio"). Bounce a 440 Hz sine dry vs with Drive and require
    /// the driven bounce's peak to be soft-clipped well below the dry one.
    func testBounceBakesMasterFXIntoAudio() async throws {
        let store = StudioStore(fileURL: storeURL)
        let arr = store.createArrangement(name: "FX")
        let t = try XCTUnwrap(store.addTrack(arrangement: arr.id))
        let clipId = "clip_sine"
        let fileName = StudioStore.clipFileName(clipId)
        let dir = try StudioStore.arrangementsDir()
        try writeSineClip(to: dir.appendingPathComponent(fileName), seconds: 1.0, freq: 440, amp: 0.8)
        store.addClip(arrangement: arr.id, track: t.id,
                      StudioClip(id: clipId, name: "S", fileName: fileName, durationMs: 1000,
                                 source: .sample, sourceId: "smp_x"))
        let tracks = try XCTUnwrap(store.arrangement(arr.id)?.tracks)

        var driven = StudioMasterFX(); driven.driveEnabled = true; driven.driveAmount = 1.0
        let dryBounce = await ArrangerBouncer.bounce(tracks: tracks, store: store, name: "dry")
        let wetBounce = await ArrangerBouncer.bounce(tracks: tracks, store: store, name: "wet",
                                                     masterFX: driven, bpm: 120)
        let dry = try XCTUnwrap(dryBounce)
        let wet = try XCTUnwrap(wetBounce)
        let dryPeak = try peakOfClip(store, dry.fileName)
        let wetPeak = try peakOfClip(store, wet.fileName)
        XCTAssertGreaterThan(dryPeak, 0.3, "the sine should survive a dry bounce")
        XCTAssertLessThan(wetPeak, dryPeak * 0.85, "Drive must be baked into the bounce (peak soft-clipped)")
    }

    // MARK: Arrangement artifacts (bounces + recordings)

    /// Add → list-by-kind → persist round-trip → delete (record + file). The artifact rides the
    /// additive `arrangementArtifacts` array (no schema bump).
    func testArrangementArtifactCRUDAndRoundTrip() async throws {
        let store = StudioStore(fileURL: storeURL)
        let arr = store.createArrangement(name: "A")
        let dir = try StudioStore.arrangementsDir()
        let fileName = "bounce-2026-01-01 00-00-00.m4a"
        try writeSineClip(to: dir.appendingPathComponent(fileName), seconds: 0.3, freq: 440, amp: 0.5)
        let art = StudioArrangementArtifact(id: StudioFactory.newArtifactId(), arrangementId: arr.id,
                                            kind: .bounce, name: "bounce-x", fileName: fileName,
                                            durationMs: 300, createdAt: 1)
        store.addArrangementArtifact(art)
        XCTAssertEqual(store.arrangementArtifacts(forArrangement: arr.id, kind: .bounce).count, 1)
        XCTAssertTrue(store.arrangementArtifacts(forArrangement: arr.id, kind: .recording).isEmpty)

        store.flush()
        let reloaded = StudioStore(fileURL: storeURL)
        XCTAssertEqual(reloaded.arrangementArtifacts(forArrangement: arr.id, kind: .bounce).count, 1)

        let url = try XCTUnwrap(reloaded.artifactFileURL(fileName))
        XCTAssertTrue(FileManager.default.fileExists(atPath: url.path))
        reloaded.deleteArrangementArtifact(art.id)
        XCTAssertTrue(reloaded.arrangementArtifacts(forArrangement: arr.id, kind: .bounce).isEmpty)
        XCTAssertFalse(FileManager.default.fileExists(atPath: url.path), "delete removes the audio file")
    }

    /// Convert-to-sample bakes an INDEPENDENT `smp_` copy: deleting the artifact afterwards leaves
    /// the sample + its audio intact.
    func testCreateSampleFromArtifactIsIndependent() async throws {
        let store = StudioStore(fileURL: storeURL)
        let arr = store.createArrangement(name: "A")
        let dir = try StudioStore.arrangementsDir()
        let fileName = "bounce-y.m4a"
        try writeSineClip(to: dir.appendingPathComponent(fileName), seconds: 0.4, freq: 440, amp: 0.6)
        let art = StudioArrangementArtifact(id: StudioFactory.newArtifactId(), arrangementId: arr.id,
                                            kind: .bounce, name: "bounce-y", fileName: fileName,
                                            durationMs: 400, createdAt: 1)
        store.addArrangementArtifact(art)

        let made = await store.createSampleFromArtifact(art)
        let sample = try XCTUnwrap(made)
        XCTAssertTrue(sample.id.hasPrefix("smp_"))
        XCTAssertGreaterThan(sample.durationMs, 0)
        XCTAssertNotNil(store.sample(sample.id))

        store.deleteArrangementArtifact(art.id)
        XCTAssertNotNil(store.sample(sample.id), "the sample is a copy — deleting the artifact keeps it")
        let sURL = try XCTUnwrap(StudioFolders.fileURL(family: .samples, fileName: sample.fileName,
                                                       wasUserFolder: false, bookmark: nil)?.url)
        XCTAssertTrue(FileManager.default.fileExists(atPath: sURL.path))
    }

    /// `bounceToFile` writes real audio to the caller's dest and returns a positive length (the
    /// artifact-only Bounce path — no clip/track created).
    func testBounceToFileWritesAudio() async throws {
        let store = StudioStore(fileURL: storeURL)
        let arr = store.createArrangement(name: "A")
        let t = try XCTUnwrap(store.addTrack(arrangement: arr.id))
        let clipId = "clip_bt"
        let cn = StudioStore.clipFileName(clipId)
        let dir = try StudioStore.arrangementsDir()
        try writeSineClip(to: dir.appendingPathComponent(cn), seconds: 0.5, freq: 440, amp: 0.7)
        store.addClip(arrangement: arr.id, track: t.id,
                      StudioClip(id: clipId, name: "S", fileName: cn, durationMs: 500,
                                 source: .sample, sourceId: "smp_z"))
        let tracks = try XCTUnwrap(store.arrangement(arr.id)?.tracks)
        let dest = dir.appendingPathComponent("bounce-bt.m4a")
        let bounced = await ArrangerBouncer.bounceToFile(tracks: tracks, store: store, to: dest)
        let ms = try XCTUnwrap(bounced)
        XCTAssertGreaterThan(ms, 0)
        XCTAssertTrue(FileManager.default.fileExists(atPath: dest.path))
        XCTAssertNil(store.arrangement(arr.id)?.tracks.first { $0.name.hasPrefix("Master") },
                     "bounce-to-file must NOT add a Master track")
    }

    /// Quantized (lo-fi) bake = relabel-without-resample: a 48 kHz capture keeps its frame count at
    /// 44.1 kHz → audibly LONGER (the retro downpitch) than a clean resampling import.
    func testRelabelIsLongerThanCleanImport() async throws {
        let src = root.appendingPathComponent("src48k.caf")
        try writeSine(to: src, seconds: 0.5, freq: 440, amp: 0.5, sampleRate: 48_000)
        let clean = try await StudioRender.shared.importAudioFile(
            sourceURL: src, to: root.appendingPathComponent("clean.m4a"))
        let lofi = try await StudioRender.shared.importAudioFileRelabeled(
            sourceURL: src, to: root.appendingPathComponent("lofi.m4a"))
        XCTAssertGreaterThan(clean.durationMs, 400)
        XCTAssertGreaterThan(lofi.durationMs, Int(Double(clean.durationMs) * 1.05),
                             "48 kHz frames relabelled to 44.1 play ~1.088× longer / downpitched")
    }

    // MARK: Scissor trim ("one track, leave a gap")

    /// `trimGap` is PURE: every case — disjoint keep, middle split, head trim, tail trim, full drop,
    /// degenerate region — with the exact id / fileName / fileStartMs / duration bookkeeping.
    func testTrimGapAllCases() {
        let c = StudioClip(id: "clip_a", name: "A", fileName: "clip-clip_a.m4a",
                           startMs: 100, durationMs: 400)   // timeline [100, 500), file window [0,400)
        var n = 0
        let mint = { () -> String in n += 1; return "clip_t\(n)" }

        // Disjoint (region entirely before / after) → unchanged.
        XCTAssertEqual(StudioStore.trimGap(clips: [c], cutStartMs: 0, cutEndMs: 100), [c])
        XCTAssertEqual(StudioStore.trimGap(clips: [c], cutStartMs: 500, cutEndMs: 600), [c])
        // Degenerate region → no-op.
        XCTAssertEqual(StudioStore.trimGap(clips: [c], cutStartMs: 200, cutEndMs: 200), [c])

        // Middle split → head (id/file/offset kept, shortened) + tail (new id, SAME file, offset in).
        let mid = StudioStore.trimGap(clips: [c], cutStartMs: 200, cutEndMs: 300, newId: mint)
        XCTAssertEqual(mid.count, 2)
        XCTAssertEqual(mid[0].id, "clip_a")
        XCTAssertEqual(mid[0].startMs, 100); XCTAssertEqual(mid[0].durationMs, 100)   // [100,200)
        XCTAssertEqual(mid[0].fileStartMs, 0); XCTAssertEqual(mid[0].fileName, "clip-clip_a.m4a")
        XCTAssertEqual(mid[1].id, "clip_t1")
        XCTAssertEqual(mid[1].startMs, 300); XCTAssertEqual(mid[1].durationMs, 200)   // [300,500)
        XCTAssertEqual(mid[1].fileStartMs, 200)                                        // 300 - 100
        XCTAssertEqual(mid[1].fileName, "clip-clip_a.m4a", "tail shares the head's file until commit")

        // Cut off the head → the sole survivor keeps its id, slides to cutEnd, fileStartMs advances.
        let headCut = StudioStore.trimGap(clips: [c], cutStartMs: 50, cutEndMs: 250, newId: mint)
        XCTAssertEqual(headCut.count, 1)
        XCTAssertEqual(headCut[0].id, "clip_a", "a single surviving piece keeps the clip identity")
        XCTAssertEqual(headCut[0].startMs, 250); XCTAssertEqual(headCut[0].durationMs, 250)  // [250,500)
        XCTAssertEqual(headCut[0].fileStartMs, 150)                                          // 250 - 100

        // Cut off the tail → duration shortens, everything else kept.
        let tailCut = StudioStore.trimGap(clips: [c], cutStartMs: 350, cutEndMs: 900, newId: mint)
        XCTAssertEqual(tailCut.count, 1)
        XCTAssertEqual(tailCut[0].id, "clip_a")
        XCTAssertEqual(tailCut[0].startMs, 100); XCTAssertEqual(tailCut[0].durationMs, 250)  // [100,350)
        XCTAssertEqual(tailCut[0].fileStartMs, 0)

        // Region covers the whole clip → dropped (pure silence in the gap).
        XCTAssertEqual(StudioStore.trimGap(clips: [c], cutStartMs: 0, cutEndMs: 900), [])
    }

    /// Commit de-dups the shared tail file to its own `clip-<id>.m4a`, keeps the head's file, persists
    /// `fileStartMs`, and orphan-cleans a fully-cut clip's file.
    func testCommitTrimmedTrackDedupAndOrphanClean() async throws {
        let store = StudioStore(fileURL: storeURL)
        let arr = store.createArrangement(name: "A")
        let t = try XCTUnwrap(store.addTrack(arrangement: arr.id))
        let dir = try StudioStore.arrangementsDir()
        let keepId = "clip_keep", dropId = "clip_drop"
        let keepFile = StudioStore.clipFileName(keepId), dropFile = StudioStore.clipFileName(dropId)
        try writeSineClip(to: dir.appendingPathComponent(keepFile), seconds: 0.5, freq: 440, amp: 0.6)
        try writeSineClip(to: dir.appendingPathComponent(dropFile), seconds: 0.3, freq: 330, amp: 0.6)
        store.addClip(arrangement: arr.id, track: t.id,
                      StudioClip(id: keepId, name: "keep", fileName: keepFile, startMs: 0, durationMs: 500))
        store.addClip(arrangement: arr.id, track: t.id,
                      StudioClip(id: dropId, name: "drop", fileName: dropFile, startMs: 600, durationMs: 300))

        // Middle-split `keep` [200,300) AND fully cover `drop`.
        let live = try XCTUnwrap(store.arrangement(arr.id)?.tracks.first?.clips)
        var staged = StudioStore.trimGap(clips: live, cutStartMs: 200, cutEndMs: 300)  // splits keep
        staged = StudioStore.trimGap(clips: staged, cutStartMs: 600, cutEndMs: 900)    // drops drop
        store.commitTrimmedTrack(arrangement: arr.id, track: t.id, clips: staged)
        store.flush()   // saveNow is async; force the write before reloading

        let after = try XCTUnwrap(StudioStore(fileURL: storeURL).arrangement(arr.id)?.tracks.first?.clips)
        XCTAssertEqual(after.count, 2, "head + tail of keep; drop is gone")
        let head = try XCTUnwrap(after.first { $0.id == keepId })
        let tail = try XCTUnwrap(after.first { $0.id != keepId })
        XCTAssertEqual(head.fileName, keepFile, "head keeps the original file")
        XCTAssertEqual(head.fileStartMs, 0)
        XCTAssertNotEqual(tail.fileName, keepFile, "tail is de-duped to its own file")
        XCTAssertEqual(tail.fileStartMs, 300, "tail resumes at file offset ce − startMs (300 − 0)")
        XCTAssertEqual(tail.startMs, 300); XCTAssertEqual(tail.durationMs, 200)
        XCTAssertTrue(FileManager.default.fileExists(atPath: dir.appendingPathComponent(head.fileName).path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: dir.appendingPathComponent(tail.fileName).path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: dir.appendingPathComponent(dropFile).path),
                       "the fully-cut clip's file is orphan-cleaned")
    }

    /// The payoff: a cut on ONE track really removes that audio from the mix. A clip whose file is
    /// LOUD then SILENT, cut to leave only the silent tail, bounces near-silent — proving both read
    /// paths honor the `fileStartMs`/`durationMs` window (the bounce path exercises the same math the
    /// player does).
    func testTrimmedTailBounceIsSilent() async throws {
        let store = StudioStore(fileURL: storeURL)
        let arr = store.createArrangement(name: "A")
        let t = try XCTUnwrap(store.addTrack(arrangement: arr.id))
        let dir = try StudioStore.arrangementsDir()
        let cid = "clip_split"
        let file = StudioStore.clipFileName(cid)
        // 0.25s loud sine, then 0.25s silence.
        try writeSplitClip(to: dir.appendingPathComponent(file), loudSeconds: 0.25, silentSeconds: 0.25)
        store.addClip(arrangement: arr.id, track: t.id,
                      StudioClip(id: cid, name: "S", fileName: file, startMs: 0, durationMs: 500))

        // Baseline: the untrimmed bounce is LOUD.
        let full = dir.appendingPathComponent("bounce-full.m4a")
        _ = await ArrangerBouncer.bounceToFile(tracks: try XCTUnwrap(store.arrangement(arr.id)?.tracks),
                                               store: store, to: full)
        XCTAssertGreaterThan(try peakOfFile(full), 0.4, "untrimmed bounce keeps the loud half")

        // Cut off the loud head [0,250) → only the silent tail survives.
        let live = try XCTUnwrap(store.arrangement(arr.id)?.tracks.first?.clips)
        let staged = StudioStore.trimGap(clips: live, cutStartMs: 0, cutEndMs: 250)
        store.commitTrimmedTrack(arrangement: arr.id, track: t.id, clips: staged)

        let trimmed = dir.appendingPathComponent("bounce-trimmed.m4a")
        _ = await ArrangerBouncer.bounceToFile(tracks: try XCTUnwrap(store.arrangement(arr.id)?.tracks),
                                               store: store, to: trimmed)
        XCTAssertLessThan(try peakOfFile(trimmed), 0.1, "the loud half was cut — the tail is silent")
    }

    /// A canonical AAC clip: `loudSeconds` of 440 Hz sine then `silentSeconds` of silence.
    private func writeSplitClip(to url: URL, loudSeconds: Double, silentSeconds: Double) throws {
        let fmt = StudioAudio.canonicalFormat
        let sr = fmt.sampleRate
        let loudN = Int(loudSeconds * sr), total = loudN + Int(silentSeconds * sr)
        let buf = AVAudioPCMBuffer(pcmFormat: fmt, frameCapacity: AVAudioFrameCount(total))!
        buf.frameLength = AVAudioFrameCount(total)
        for c in 0..<Int(fmt.channelCount) {
            let d = buf.floatChannelData![c]
            for i in 0..<total {
                d[i] = i < loudN ? 0.7 * sinf(2 * .pi * 440 * Float(i) / Float(sr)) : 0
            }
        }
        let settings: [String: Any] = [AVFormatIDKey: kAudioFormatMPEG4AAC,
                                        AVSampleRateKey: sr, AVNumberOfChannelsKey: 2]
        try AVAudioFile(forWriting: url, settings: settings).write(from: buf)
    }

    private func peakOfFile(_ url: URL) throws -> Float {
        let f = try AVAudioFile(forReading: url)
        let buf = AVAudioPCMBuffer(pcmFormat: f.processingFormat, frameCapacity: AVAudioFrameCount(f.length))!
        try f.read(into: buf)
        var p: Float = 0
        let ch = buf.floatChannelData!
        for c in 0..<Int(buf.format.channelCount) { for i in 0..<Int(buf.frameLength) { p = max(p, abs(ch[c][i])) } }
        return p
    }

    /// Write a stereo sine at an ARBITRARY rate (CAF/LPCM) — for the relabel test's 48 kHz source.
    private func writeSine(to url: URL, seconds: Double, freq: Double, amp: Float, sampleRate: Double) throws {
        let fmt = AVAudioFormat(standardFormatWithSampleRate: sampleRate, channels: 2)!
        let frames = Int(seconds * sampleRate)
        let buf = AVAudioPCMBuffer(pcmFormat: fmt, frameCapacity: AVAudioFrameCount(frames))!
        buf.frameLength = AVAudioFrameCount(frames)
        for c in 0..<Int(fmt.channelCount) {
            for i in 0..<frames {
                buf.floatChannelData![c][i] = amp * sinf(2 * .pi * Float(freq) * Float(i) / Float(sampleRate))
            }
        }
        try AVAudioFile(forWriting: url, settings: fmt.settings).write(from: buf)
    }

    private func writeSineClip(to url: URL, seconds: Double, freq: Double, amp: Float) throws {
        let fmt = StudioAudio.canonicalFormat
        let frames = Int(seconds * fmt.sampleRate)
        let buf = AVAudioPCMBuffer(pcmFormat: fmt, frameCapacity: AVAudioFrameCount(frames))!
        buf.frameLength = AVAudioFrameCount(frames)
        for c in 0..<Int(fmt.channelCount) {
            for i in 0..<frames {
                buf.floatChannelData![c][i] = amp * sinf(2 * .pi * Float(freq) * Float(i) / Float(fmt.sampleRate))
            }
        }
        let settings: [String: Any] = [AVFormatIDKey: kAudioFormatMPEG4AAC,
                                        AVSampleRateKey: fmt.sampleRate, AVNumberOfChannelsKey: 2]
        try AVAudioFile(forWriting: url, settings: settings).write(from: buf)
    }
    private func peakOfClip(_ store: StudioStore, _ fileName: String) throws -> Float {
        let url = try XCTUnwrap(store.clipFileURL(fileName))
        let f = try AVAudioFile(forReading: url)
        let buf = AVAudioPCMBuffer(pcmFormat: f.processingFormat, frameCapacity: AVAudioFrameCount(f.length))!
        try f.read(into: buf)
        var p: Float = 0
        let ch = buf.floatChannelData!
        for c in 0..<Int(buf.format.channelCount) { for i in 0..<Int(buf.frameLength) { p = max(p, abs(ch[c][i])) } }
        return p
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
        XCTAssertEqual(row.steps.count, StudioPattern.defaultStepCount)     // short steps padded to 16
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

    // MARK: Slices — 8-pad cap, derived play window, chop, orphan cleanup

    func testSliceCapWindowChopAndOrphanCleanup() {
        let store = StudioStore(fileURL: storeURL)
        store.addSample(makeSample("smp_x"))                       // durationMs = 2000
        for slot in 0..<StudioSlice.maxSlots {
            XCTAssertNotNil(store.setSlice(sampleId: "smp_x", slot: slot, startMs: slot * 250))
        }
        XCTAssertEqual(store.slices(forSample: "smp_x").count, 8)
        XCTAssertNil(store.setSlice(sampleId: "smp_x", slot: 8, startMs: 0))     // slot-domain cap
        XCTAssertNil(store.setSlice(sampleId: "smp_x", slot: -1, startMs: 0))
        // Derived window: pad 0 = [0,250), the last pad ends at the raw duration.
        XCTAssertEqual(store.sliceWindow(sampleId: "smp_x", slot: 0)?.startMs, 0)
        XCTAssertEqual(store.sliceWindow(sampleId: "smp_x", slot: 0)?.endMs, 250)
        XCTAssertEqual(store.sliceWindow(sampleId: "smp_x", slot: 7)?.endMs, 2_000)
        // Chop replaces everything, slot = time order, de-duped + capped.
        store.setSlices(sampleId: "smp_x", startsMs: [1_000, 0, 0, 500])
        XCTAssertEqual(store.slices(forSample: "smp_x").map(\.startMs), [0, 500, 1_000])
        // Deleting the parent sample sweeps its pads (no orphans).
        _ = store.deleteSample("smp_x")
        XCTAssertTrue(store.slices(forSample: "smp_x").isEmpty)
    }

    // MARK: Take edits — editedEvents override + duration extension + revert

    func testSetTakeEventsPersistsEditsExtendsDurationAndReverts() {
        let store = StudioStore(fileURL: storeURL)
        store.addTake(StudioTake(id: "tk_a", name: "T", fileName: StudioFolders.fileName(.takes, id: "tk_a"),
                                 bpm: 120, events: [StudioNoteEvent(onMs: 0, offMs: 500, note: 60, velocity: 96)],
                                 durationMs: 500))
        XCTAssertNil(store.take("tk_a")?.editedEvents)              // untouched ⇒ derive from raw
        XCTAssertEqual(store.take("tk_a")?.scoreEvents.count, 1)

        store.setTakeEvents("tk_a", events: [
            StudioNoteEvent(onMs: 0, offMs: 500, note: 60, velocity: 96, accidental: .flat),
            StudioNoteEvent(onMs: 1_000, offMs: 2_000, note: 67, velocity: 96),
        ])
        XCTAssertEqual(store.take("tk_a")?.editedEvents?.count, 2)
        XCTAssertEqual(store.take("tk_a")?.scoreEvents.count, 2)    // scoreEvents now the edited stream
        XCTAssertEqual(store.take("tk_a")?.durationMs, 2_000)       // extended to the new max offMs
        XCTAssertEqual(store.take("tk_a")?.scoreEvents.first?.accidental, .flat)

        // Round-trips through persistence (flush = synchronous write before reload).
        store.flush()
        let reloaded = StudioStore(fileURL: storeURL)
        XCTAssertEqual(reloaded.take("tk_a")?.editedEvents?.count, 2)

        store.revertTakeEdits("tk_a")
        XCTAssertNil(store.take("tk_a")?.editedEvents)              // back to deriving from raw
        XCTAssertEqual(store.take("tk_a")?.scoreEvents.count, 1)
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
        // USER-folder instrumental with no bookmark (relocated to an unplugged drive) → kept.
        store.addTake(StudioTake(id: "tk_user", name: "T",
                                 fileName: StudioFolders.fileName(.takes, id: "tk_user"),
                                 wasUserFolder: true))

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
        XCTAssertNotNil(store.take("tk_user"))       // unreachable instrumentals folder ⇒ never pruned
    }

    /// `StudioPatternBouncer.ensureBounced` (auto-burn a sequence on add-to-collection) is a no-op
    /// when the pattern is already bounced-fresh, and doesn't bounce a pattern with no sounding row.
    /// (The full render is covered by StudioRenderTests; here we pin the orchestration guards.)
    func testEnsureBouncedGuards() async {
        let store = StudioStore(fileURL: storeURL)
        // Already bounced + not dirty → left untouched (no re-render).
        store.addPattern(StudioPattern(id: "ptn_fresh", name: "P", bpm: 120,
                                       rows: [StudioPatternRow(targetId: "smp_x")],
                                       fileName: StudioFolders.fileName(.sequences, id: "ptn_fresh"),
                                       bounceDirty: false))
        await StudioPatternBouncer.ensureBounced(patternId: "ptn_fresh", studio: store)
        XCTAssertEqual(store.pattern("ptn_fresh")?.bounceDirty, false)
        XCTAssertNotNil(store.pattern("ptn_fresh")?.fileName)

        // Dirty, but its only row has no enabled steps (silent) ⇒ nothing to bounce.
        store.addPattern(StudioPattern(id: "ptn_silent", name: "P", bpm: 120,
                                       rows: [StudioPatternRow(targetId: "smp_x")], createdAt: 0))
        await StudioPatternBouncer.ensureBounced(patternId: "ptn_silent", studio: store)
        XCTAssertNil(store.pattern("ptn_silent")?.fileName, "no sounding row ⇒ no bounce")
    }

    /// A sample captured from AUDIO IN (`.lineIn`) round-trips its provenance + port name, and an
    /// unknown/older source still degrades to `.mic` (the lenient decoder is unaffected).
    func testLineInSampleSourceRoundTrips() throws {
        let store = StudioStore(fileURL: storeURL)
        store.addSample(StudioSample(id: "smp_li", name: "TX-6 recording",
                                     fileName: StudioFolders.fileName(.samples, id: "smp_li"),
                                     durationMs: 1_000, source: .lineIn(inputName: "TX-6")))
        store.flush()
        let reloaded = StudioStore(fileURL: storeURL)
        guard case .lineIn(let name)? = reloaded.sample("smp_li")?.source else {
            return XCTFail("expected a .lineIn source, got \(String(describing: reloaded.sample("smp_li")?.source))")
        }
        XCTAssertEqual(name, "TX-6")
    }

    /// The detected-key map (`keys`) round-trips, `mixInfo` surfaces the item's bpm + key for a
    /// Mix deck, and clearing removes the entry.
    func testStudioKeysRoundTripAndMixInfo() throws {
        let store = StudioStore(fileURL: storeURL)
        store.addTake(StudioTake(id: "tk_k", name: "Inst", fileName: "take-tk_k.m4a", bpm: 128,
                                 events: [StudioNoteEvent(onMs: 0, offMs: 500, note: 60, velocity: 100)]))
        XCTAssertNil(store.camelot(forStudioId: "tk_k"))
        store.setCamelot("8A", forStudioId: "tk_k")
        XCTAssertEqual(store.camelot(forStudioId: "tk_k"), "8A")
        let mi = store.mixInfo(forStudioId: "tk_k")
        XCTAssertEqual(mi?.bpm, 128)
        XCTAssertEqual(mi?.firstDownbeatMs, 0)
        XCTAssertEqual(mi?.camelot, "8A")
        store.flush()
        XCTAssertEqual(StudioStore(fileURL: storeURL).camelot(forStudioId: "tk_k"), "8A")
        store.setCamelot(nil, forStudioId: "tk_k")   // clearing removes the key
        XCTAssertNil(store.camelot(forStudioId: "tk_k"))
        XCTAssertNil(store.mixInfo(forStudioId: "tk_k")?.camelot)
    }

    /// Instrumental playback resolves the raw take file, and PREFERS the rendered-audio cache when
    /// one is present (the audible synth for a live-saved placeholder take).
    func testTakePlaybackResolvesFileAndPrefersRenderCache() throws {
        let store = StudioStore(fileURL: storeURL)
        let raw = try writeFile(.takes, id: "tk_p")
        store.addTake(StudioTake(id: "tk_p", name: "Inst", fileName: raw,
                                 events: [StudioNoteEvent(onMs: 0, offMs: 500, note: 60, velocity: 100)],
                                 durationMs: 800))
        let r1 = store.localURLForPlayback(id: "tk_p")
        XCTAssertEqual(r1?.url.lastPathComponent, raw)
        XCTAssertEqual(r1?.title, "Inst")
        XCTAssertEqual(r1?.lengthMs, 800)
        r1?.release?()
        // A render cache present ⇒ preferred.
        let rendered = StudioFolders.renderedTakeFileName(id: "tk_p")
        try Data(repeating: 0, count: 8).write(to: try StudioFolders.appRoot(.takes).appendingPathComponent(rendered))
        store.setTakeRendered("tk_p", fileName: rendered, wasUserFolder: false)
        let r2 = store.localURLForPlayback(id: "tk_p")
        XCTAssertEqual(r2?.url.lastPathComponent, rendered)
        r2?.release?()
    }

    /// Editing a take's score invalidates its rendered-audio cache (file removed + fields cleared),
    /// so playback falls back to the raw file until it re-renders from the new notes.
    func testTakeRenderCacheClearedOnEdit() throws {
        let store = StudioStore(fileURL: storeURL)
        let raw = try writeFile(.takes, id: "tk_e")
        let rendered = StudioFolders.renderedTakeFileName(id: "tk_e")
        let renderedURL = try StudioFolders.appRoot(.takes).appendingPathComponent(rendered)
        try Data(repeating: 0, count: 8).write(to: renderedURL)
        store.addTake(StudioTake(id: "tk_e", name: "E", fileName: raw, durationMs: 500,
                                 renderedFileName: rendered, renderedWasUserFolder: false))
        XCTAssertEqual(store.localURLForPlayback(id: "tk_e")?.url.lastPathComponent, rendered)
        store.setTakeEvents("tk_e", events: [StudioNoteEvent(onMs: 0, offMs: 300, note: 62, velocity: 90)])
        XCTAssertNil(store.take("tk_e")?.renderedFileName)
        XCTAssertFalse(FileManager.default.fileExists(atPath: renderedURL.path))
        XCTAssertEqual(store.localURLForPlayback(id: "tk_e")?.url.lastPathComponent, raw)
    }

    /// `StudioTake.wasUserFolder` survives the persistence round-trip (the instrumentals-folder
    /// relocation stamp), and an OLDER blob with no such key decodes to app storage (false).
    func testTakeWasUserFolderRoundTrips() throws {
        let store = StudioStore(fileURL: storeURL)
        store.addTake(StudioTake(id: "tk_u", name: "In a folder",
                                 fileName: StudioFolders.fileName(.takes, id: "tk_u"),
                                 wasUserFolder: true))
        store.addTake(StudioTake(id: "tk_a", name: "App storage",
                                 fileName: StudioFolders.fileName(.takes, id: "tk_a")))
        store.flush()
        let reloaded = StudioStore(fileURL: storeURL)
        XCTAssertEqual(reloaded.take("tk_u")?.wasUserFolder, true)
        XCTAssertEqual(reloaded.take("tk_a")?.wasUserFolder, false)   // default when absent
    }

    /// With no instrumentals folder configured (settings nil ⇒ no bookmark), `addTakeRelocating`
    /// leaves the file in app storage and stamps `wasUserFolder: false` — a plain file (no move),
    /// resolvable + deletable against the app root.
    func testAddTakeRelocatingWithoutUserFolderKeepsAppStorage() throws {
        let store = StudioStore(fileURL: storeURL)   // settings nil ⇒ bookmark(for: .takes) == nil
        let name = try writeFile(.takes, id: "tk_r")
        let filed = store.addTakeRelocating(StudioTake(id: "tk_r", name: "R", fileName: name))
        XCTAssertFalse(filed.wasUserFolder)
        XCTAssertEqual(store.take("tk_r")?.wasUserFolder, false)
        // The file is still in the app root and the record resolves + deletes cleanly.
        let appRoot = try StudioFolders.appRoot(.takes)
        XCTAssertTrue(FileManager.default.fileExists(atPath: appRoot.appendingPathComponent(name).path))
        XCTAssertTrue(store.deleteTake("tk_r"))
        XCTAssertFalse(FileManager.default.fileExists(atPath: appRoot.appendingPathComponent(name).path))
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
        edit.rate = 12.0                                       // clamped to 10.0 — a real change
        store.updateSampleEdit("smp_a", edit)
        XCTAssertEqual(store.sample("smp_a")?.renderRevision, 2)
        XCTAssertEqual(store.sample("smp_a")?.edit.rate, 10.0)
    }

    // MARK: B6 mixer-deck FX (compWet / filterAmt) — additive-optional, clamped, revision-tracked

    func testSampleEditMixerDeckFXClampAndRoundTrip() throws {
        // Clamp: comp/filter clamp into 0…1 like the other wets.
        let clamped = StudioSampleEdit(compWet: 2.0, filterAmt: -0.5).clamped()
        XCTAssertEqual(clamped.compWet, 1.0)
        XCTAssertEqual(clamped.filterAmt, 0.0)

        // Round-trip: the new FX survive encode/decode alongside the existing fields.
        let e = StudioSampleEdit(rate: 1.25, compWet: 0.6, filterAmt: 0.4)
        let back = try JSONDecoder().decode(StudioSampleEdit.self, from: JSONEncoder().encode(e))
        XCTAssertEqual(back.compWet, 0.6, accuracy: 1e-9)
        XCTAssertEqual(back.filterAmt, 0.4, accuracy: 1e-9)
        XCTAssertEqual(back.rate, 1.25, accuracy: 1e-9)
    }

    /// A legacy edit JSON with NO comp/filter keys decodes to 0 (off) — the additive-optional
    /// wipe-safety contract: absent ⇒ default, never a decode failure, never dropping present fields.
    func testSampleEditLegacyDecodeDefaultsFXOff() throws {
        let legacy = #"{ "gainDb": 3, "rate": 1, "reverbWet": 0.5 }"#
        let old = try JSONDecoder().decode(StudioSampleEdit.self, from: Data(legacy.utf8))
        XCTAssertEqual(old.compWet, 0)
        XCTAssertEqual(old.filterAmt, 0)
        XCTAssertEqual(old.reverbWet, 0.5, accuracy: 1e-9)   // present field preserved
        XCTAssertEqual(old.gainDb, 3, accuracy: 1e-9)
    }

    func testUpdateSampleEditBumpsRevisionOnFXChange() {
        let store = StudioStore(fileURL: storeURL)
        store.addSample(makeSample("smp_fx"))
        store.updateSampleEdit("smp_fx", StudioSampleEdit(compWet: 0.5))
        XCTAssertEqual(store.sample("smp_fx")?.renderRevision, 1)
        XCTAssertEqual(store.sample("smp_fx")?.edit.compWet, 0.5)
        store.updateSampleEdit("smp_fx", StudioSampleEdit(compWet: 0.5))         // identical → no bump
        XCTAssertEqual(store.sample("smp_fx")?.renderRevision, 1)
        store.updateSampleEdit("smp_fx", StudioSampleEdit(compWet: 0.5, filterAmt: 0.3))  // real change
        XCTAssertEqual(store.sample("smp_fx")?.renderRevision, 2)
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

    // MARK: - Sample folders (F9)

    /// createSampleFolder mints an `sfld_` id, name-orders, and persists across a reload.
    func testCreateSampleFolderMintsIdAndPersists() {
        let store = StudioStore(fileURL: storeURL)
        let drums = store.createSampleFolder("Drums")
        XCTAssertTrue(drums.id.hasPrefix("sfld_"))
        XCTAssertFalse(StudioFactory.isStudioId(drums.id), "sfld_ must NOT ride collections")
        _ = store.createSampleFolder("Bass")
        // Name-ordered (case-insensitive): Bass before Drums.
        XCTAssertEqual(store.sampleFoldersOrdered().map(\.name), ["Bass", "Drums"])
        XCTAssertNotNil(store.sampleFolder(drums.id))

        store.flush()
        let reloaded = StudioStore(fileURL: storeURL)
        XCTAssertEqual(reloaded.sampleFoldersOrdered().map(\.name), ["Bass", "Drums"])
        XCTAssertTrue(reloaded.sampleFolder(drums.id)?.id.hasPrefix("sfld_") ?? false)
    }

    /// renameSampleFolder updates the name (trimmed); a blank rename is a no-op, not a wipe.
    func testRenameSampleFolder() {
        let store = StudioStore(fileURL: storeURL)
        let f = store.createSampleFolder("Old")
        store.renameSampleFolder(f.id, to: "  New Name  ")
        XCTAssertEqual(store.sampleFolder(f.id)?.name, "New Name")
        store.renameSampleFolder(f.id, to: "   ")               // blank ⇒ no-op
        XCTAssertEqual(store.sampleFolder(f.id)?.name, "New Name")
        store.renameSampleFolder("sfld_missing", to: "X")       // unknown id ⇒ no-op
        XCTAssertEqual(store.folders.count, 1)
    }

    /// deleteSampleFolder re-homes its member samples to Unfiled (folderId ⇒ nil) and deletes NO
    /// sample records and NO audio files.
    func testDeleteSampleFolderRehomesMembersDeletesNothing() throws {
        let store = StudioStore(fileURL: storeURL)
        let name = try writeFile(.samples, id: "smp_a")           // a real audio file on disk
        store.addSample(makeSample("smp_a"))
        let f = store.createSampleFolder("Drums")
        store.setSampleFolder("smp_a", folderId: f.id)
        XCTAssertEqual(store.sample("smp_a")?.folderId, f.id)

        store.deleteSampleFolder(f.id)

        XCTAssertNil(store.sampleFolder(f.id))                    // folder gone
        XCTAssertNotNil(store.sample("smp_a"))                    // sample RECORD kept
        XCTAssertNil(store.sample("smp_a")?.folderId)             // re-homed to Unfiled
        let appRoot = try StudioFolders.appRoot(.samples)
        XCTAssertTrue(FileManager.default.fileExists(atPath: appRoot.appendingPathComponent(name).path),
                      "the audio file must NOT be touched by a folder delete")
    }

    /// setSampleFolder + samples(inFolder:) partition correctly (nil ⇒ Unfiled).
    func testSetSampleFolderPartitions() {
        let store = StudioStore(fileURL: storeURL)
        store.addSample(makeSample("smp_a"))
        store.addSample(makeSample("smp_b"))
        store.addSample(makeSample("smp_c"))
        let f = store.createSampleFolder("Drums")
        store.setSampleFolder("smp_a", folderId: f.id)
        store.setSampleFolder("smp_b", folderId: f.id)

        XCTAssertEqual(Set(store.samples(inFolder: f.id).map(\.id)), ["smp_a", "smp_b"])
        XCTAssertEqual(store.samples(inFolder: nil).map(\.id), ["smp_c"])
        // Moving back to Unfiled repartitions.
        store.setSampleFolder("smp_a", folderId: nil)
        XCTAssertEqual(store.samples(inFolder: f.id).map(\.id), ["smp_b"])
        XCTAssertEqual(Set(store.samples(inFolder: nil).map(\.id)), ["smp_a", "smp_c"])
    }

    /// A save→reload round-trip preserves both the `folders` collection and each sample's `folderId`.
    func testSampleFoldersRoundTripPreservesFolderId() {
        let store = StudioStore(fileURL: storeURL)
        store.addSample(makeSample("smp_a"))
        let f = store.createSampleFolder("Drums")
        store.setSampleFolder("smp_a", folderId: f.id)
        store.flush()

        let reloaded = StudioStore(fileURL: storeURL)
        XCTAssertEqual(reloaded.sampleFoldersOrdered().map(\.name), ["Drums"])
        XCTAssertEqual(reloaded.sample("smp_a")?.folderId, f.id)
        XCTAssertEqual(reloaded.samples(inFolder: f.id).map(\.id), ["smp_a"])
    }

    /// WIPE-SAFETY: a LEGACY document with NO `folders` key and samples with NO `folderId` decodes
    /// fully intact — folders default to `[]`, folderId to nil (Unfiled). No discarding version bump.
    func testLegacyDocumentWithoutFoldersDecodesIntact() throws {
        let json = """
        {
          "schemaVersion": 1,
          "samples": [
            {"id": "smp_a", "name": "Legacy", "fileName": "sample-smp_a.m4a", "durationMs": 1000}
          ]
        }
        """
        try Data(json.utf8).write(to: storeURL)
        let store = StudioStore(fileURL: storeURL)
        XCTAssertEqual(store.samples.count, 1)
        XCTAssertEqual(store.sample("smp_a")?.name, "Legacy")
        XCTAssertNil(store.sample("smp_a")?.folderId)            // absent key ⇒ nil (Unfiled)
        XCTAssertTrue(store.folders.isEmpty)                     // absent collection ⇒ []
        XCTAssertEqual(store.samples(inFolder: nil).map(\.id), ["smp_a"])
    }

    /// A sample referencing a folder id that isn't in the document (deleted / hand-edited) reads as
    /// Unfiled — it never vanishes from the UI.
    func testSampleWithDeletedFolderIdReadsAsUnfiled() {
        let store = StudioStore(fileURL: storeURL)
        store.addSample(makeSample("smp_a"))
        store.setSampleFolder("smp_a", folderId: "sfld_ghost")   // no such folder exists
        XCTAssertTrue(store.folders.isEmpty)
        XCTAssertEqual(store.samples(inFolder: nil).map(\.id), ["smp_a"],
                       "a dangling folderId must surface under Unfiled")
        XCTAssertEqual(store.sampleFoldersOrdered().count, 0)
    }

    // MARK: Id minting

    func testIdMintingAndIsStudioId() {
        XCTAssertTrue(StudioFactory.newSampleId().hasPrefix("smp_"))
        XCTAssertTrue(StudioFactory.newLoopId().hasPrefix("lp_"))
        XCTAssertTrue(StudioFactory.newPatternId().hasPrefix("ptn_"))
        XCTAssertTrue(StudioFactory.newTakeId().hasPrefix("tk_"))
        XCTAssertTrue(StudioFactory.newCueId().hasPrefix("cue_"))
        XCTAssertTrue(StudioFactory.newSampleFolderId().hasPrefix("sfld_"))
        XCTAssertTrue(StudioFactory.newArrangementFolderId().hasPrefix("arrfld_"))
        // Minted uuids are lowercase (CollectionsFactory convention).
        let minted = StudioFactory.uid()
        XCTAssertEqual(minted, minted.lowercased())

        XCTAssertEqual(StudioFactory.studioPrefixes, ["smp_", "lp_", "ptn_", "tk_"])
        for p in StudioFactory.studioPrefixes {
            XCTAssertTrue(StudioFactory.isStudioId(p + "x"))
        }
        // Catalog songs, cues, slices, and sample folders are NOT collection-riding studio ids.
        XCTAssertFalse(StudioFactory.isStudioId("sng_1"))
        XCTAssertFalse(StudioFactory.isStudioId("cue_abc"))
        XCTAssertFalse(StudioFactory.isStudioId("pkt_abc"))
        XCTAssertFalse(StudioFactory.isStudioId("sfld_abc"))
        XCTAssertFalse(StudioFactory.isStudioId("arrfld_abc"))
    }
}

import XCTest
@testable import PocketDJ

/// Multi-staff instrumentals (`StudioTakeStaff` + `StudioTake.extraStaffs`) — the overdub write
/// path at the STORE level, the 4-staff cap, and the ADDITIVE-OPTIONAL decode contract the
/// score schema's lossy-decode history demands: a legacy document decodes single-staff, a
/// malformed staff drops per-element, and edits/tempo follow the `editedEvents` doctrine.
@MainActor
final class StudioStaffTests: XCTestCase {

    private var root: URL!
    private var storeURL: URL!

    override func setUp() {
        super.setUp()
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("pdj-staff-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        StudioFolders.appRootOverride = root
        storeURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("pdj-staff-\(UUID().uuidString).json")
    }

    override func tearDown() {
        StudioFolders.appRootOverride = nil
        try? FileManager.default.removeItem(at: root)
        try? FileManager.default.removeItem(at: storeURL)
        try? FileManager.default.removeItem(at: StudioStore.cuesURL(forStudio: storeURL))
        super.tearDown()
    }

    private func makeTake(_ id: String = "tk_1", durationMs: Int = 3_000) -> StudioTake {
        StudioTake(id: id, name: "Take", instrument: .piano,
                   fileName: StudioFolders.fileName(.takes, id: id), bpm: 120,
                   events: [StudioNoteEvent(onMs: 0, offMs: 500, note: 60, velocity: 96)],
                   durationMs: durationMs, createdAt: 1_000)
    }

    private func ev(_ on: Int, _ off: Int, _ note: Int = 64) -> StudioNoteEvent {
        StudioNoteEvent(onMs: on, offMs: off, note: note, velocity: 90)
    }

    // MARK: Overdub write path (store)

    func testAddOverdubStaffAppendsAtPositionAndExtendsDuration() {
        let store = StudioStore(fileURL: storeURL)
        var take = makeTake()
        take.renderedFileName = "take-tk_1-r0.m4a"       // a stale cache to invalidate
        store.addTake(take)

        let staffId = store.addOverdubStaff("tk_1", instrument: .trumpet,
                                            events: [ev(4_250, 4_750)])
        XCTAssertNotNil(staffId)
        let got = store.take("tk_1")!
        XCTAssertEqual(got.staffCount, 2)
        XCTAssertEqual(got.extraStaffs?.first?.instrument, .trumpet)
        XCTAssertEqual(got.extraStaffs?.first?.events.first?.onMs, 4_250,
                       "events stay ABSOLUTE on the take's one score clock")
        XCTAssertEqual(got.durationMs, 4_750, "duration extends to the overdub's last off")
        XCTAssertNil(got.renderedFileName, "the rendered-audio cache is invalidated")
        XCTAssertGreaterThan(got.renderRevision, 0, "…and the score revision moves with it")
        XCTAssertFalse(got.isRenderFresh)
        XCTAssertEqual(got.allScoreEvents.map(\.onMs), [0, 4_250],
                       "allScoreEvents merges every staff onset-sorted")

        // An overdub that ends INSIDE the take must not shrink it.
        _ = store.addOverdubStaff("tk_1", instrument: .harp, events: [ev(100, 200)])
        XCTAssertEqual(store.take("tk_1")?.durationMs, 4_750)
    }

    func testFourStaffCapAndEmptyCaptureEnforced() {
        let store = StudioStore(fileURL: storeURL)
        store.addTake(makeTake())
        XCTAssertNotNil(store.addOverdubStaff("tk_1", instrument: .piano, events: [ev(0, 100)]))
        XCTAssertNotNil(store.addOverdubStaff("tk_1", instrument: .violin, events: [ev(0, 100)]))
        XCTAssertNotNil(store.addOverdubStaff("tk_1", instrument: .harp, events: [ev(0, 100)]))
        XCTAssertNil(store.addOverdubStaff("tk_1", instrument: .clarinet, events: [ev(0, 100)]),
                     "a 5th staff is refused (4 = 1 primary + 3 extras)")
        XCTAssertEqual(store.take("tk_1")?.staffCount, 4)
        XCTAssertNil(store.addOverdubStaff("tk_2", instrument: .piano, events: [ev(0, 100)]),
                     "unknown take refused")

        store.flush()   // synchronous — reload must see everything
        let store2 = StudioStore(fileURL: storeURL)
        XCTAssertEqual(store2.take("tk_1")?.staffCount, 4, "staffs persist across a relaunch")
        XCTAssertNil(store2.addOverdubStaff("tk_1", instrument: .piano, events: []),
                     "an empty capture files no staff (no junk)")
    }

    // MARK: Decode compatibility (the lossy-decode history)

    func testLegacyTakeDecodesSingleStaffAndRoundTripPreservesStaffs() throws {
        // Today's exact key set — NO extraStaffs anywhere.
        let legacy = """
        {"id":"tk_old","name":"Old","instrument":"piano","fileName":"take-tk_old.m4a",
         "wasUserFolder":false,"bpm":120,
         "events":[{"onMs":0,"offMs":500,"note":60,"velocity":96}],
         "durationMs":500,"createdAt":1}
        """.data(using: .utf8)!
        let old = try JSONDecoder().decode(StudioTake.self, from: legacy)
        XCTAssertNil(old.extraStaffs, "absent key ⇒ nil, single-staff")
        XCTAssertEqual(old.staffCount, 1)
        XCTAssertEqual(old.renderRevision, 0, "absent revision ⇒ 0 (additive-optional)")
        XCTAssertNil(old.renderedRevision)
        XCTAssertFalse(old.isRenderFresh, "no cache at all ⇒ nothing to be fresh")
        // A cache filed BEFORE the stamp existed still counts as fresh — otherwise every
        // instrumental in an existing library falls back to its raw file, and a live-saved
        // take’s raw file is a SILENT placeholder.
        let legacyCached = """
        {"id":"tk_c","name":"C","instrument":"piano","fileName":"take-tk_c.m4a","bpm":120,
         "events":[],"durationMs":0,"createdAt":1,"renderedFileName":"take-tk_c-r0.m4a"}
        """.data(using: .utf8)!
        let cached = try JSONDecoder().decode(StudioTake.self, from: legacyCached)
        XCTAssertTrue(cached.isRenderFresh, "a pre-stamp cache reads as revision 0, which it is")
        XCTAssertEqual(old.allScoreEvents.map(\.note), old.scoreEvents.map(\.note))

        // Round-trip: a 3-staff take survives encode→decode with per-staff fields intact.
        var take = makeTake("tk_rt")
        take.extraStaffs = [
            StudioTakeStaff(id: "stf_a", instrument: .trumpet, events: [ev(1_000, 1_500)],
                            editedEvents: [ev(1_000, 1_250)], createdAt: 2),
            StudioTakeStaff(id: "stf_b", instrument: .harp, events: [ev(2_000, 2_500, 72)]),
        ]
        let redecoded = try JSONDecoder().decode(StudioTake.self,
                                                 from: JSONEncoder().encode(take))
        XCTAssertEqual(redecoded.extraStaffs?.count, 2)
        XCTAssertEqual(redecoded.extraStaffs?[0].instrument, .trumpet)
        XCTAssertEqual(redecoded.extraStaffs?[0].editedEvents?.first?.offMs, 1_250)
        XCTAssertEqual(redecoded.extraStaffs?[0].scoreEvents.first?.offMs, 1_250,
                       "edited stream wins (the editedEvents contract)")
        XCTAssertEqual(redecoded.extraStaffs?[1].instrument, .harp)
        XCTAssertEqual(redecoded.extraStaffs?[1].scoreEvents.first?.note, 72,
                       "nil editedEvents derives from raw")

        // One malformed element inside extraStaffs drops THAT element only (LossyBox).
        let mangled = """
        {"id":"tk_m","name":"M","instrument":"piano","fileName":"f.m4a","bpm":120,
         "events":[],"durationMs":0,"createdAt":1,
         "extraStaffs":[42,{"id":"stf_ok","instrument":"harp",
                             "events":[{"onMs":10,"offMs":20,"note":64,"velocity":90}],
                             "createdAt":3}]}
        """.data(using: .utf8)!
        let m = try JSONDecoder().decode(StudioTake.self, from: mangled)
        XCTAssertEqual(m.extraStaffs?.count, 1, "the broken sibling is dropped, not the list")
        XCTAssertEqual(m.extraStaffs?.first?.id, "stf_ok")
    }

    // MARK: Per-staff edits + tempo (the editedEvents doctrine)

    func testStaffEditsFollowEditedEventsContract() {
        let store = StudioStore(fileURL: storeURL)
        store.addTake(makeTake())
        let staffId = store.addOverdubStaff("tk_1", instrument: .violin,
                                            events: [ev(1_000, 2_000)])!

        store.setStaffEvents("tk_1", staffId: staffId, events: [ev(1_000, 1_500)])
        var staff = store.take("tk_1")!.extraStaffs!.first!
        XCTAssertEqual(staff.editedEvents?.first?.offMs, 1_500)
        XCTAssertEqual(staff.scoreEvents.first?.offMs, 1_500, "the edited stream is read")
        XCTAssertEqual(staff.events.first?.offMs, 2_000, "the raw capture is untouched")

        store.revertStaffEdits("tk_1", staffId: staffId)
        staff = store.take("tk_1")!.extraStaffs!.first!
        XCTAssertNil(staff.editedEvents)
        XCTAssertEqual(staff.scoreEvents.first?.offMs, 2_000, "revert derives from raw again")

        store.setStaffInstrument("tk_1", staffId: staffId, .clarinet)
        XCTAssertEqual(store.take("tk_1")?.extraStaffs?.first?.instrument, .clarinet)

        // Tempo rescale hits EVERY staff with the same factor (alignment preserved).
        store.setStaffEvents("tk_1", staffId: staffId, events: [ev(1_000, 1_500)])
        store.setTakeTempo("tk_1", newBpm: 240)                          // 120 → 240 ⇒ ms halve
        let t = store.take("tk_1")!
        XCTAssertEqual(t.events.first?.offMs, 250, "primary rescaled")
        XCTAssertEqual(t.extraStaffs?.first?.events.first?.onMs, 500, "staff raw rescaled")
        XCTAssertEqual(t.extraStaffs?.first?.editedEvents?.first?.offMs, 750,
                       "staff edited stream rescaled by the same factor")

        store.deleteStaff("tk_1", staffId: staffId)
        XCTAssertNil(store.take("tk_1")?.extraStaffs,
                     "an emptied staff list collapses to nil (legacy shape)")
    }

    // MARK: The render cache's freshness stamp (a stale mixdown = "the overdub isn't there")

    /// EVERY mutation the mixdown is made of bumps the take's render revision. Table-driven,
    /// because the failure mode of a missed one is invisible: playback quietly plays the PREVIOUS
    /// mixdown, which looks exactly like the multi-staff silence bug never being fixed.
    func testEveryScoreMutationBumpsTheRenderRevision() {
        let mutations: [(name: String, apply: (StudioStore, String) -> Void)] = [
            ("setTakeEvents", { s, sid in s.setTakeEvents("tk_1", events: [self.ev(0, 400)]) }),
            ("setTakeInstrument", { s, _ in s.setTakeInstrument("tk_1", .violin) }),
            ("setTakeTempo", { s, _ in s.setTakeTempo("tk_1", newBpm: 90) }),
            ("revertTakeEdits", { s, _ in
                s.setTakeEvents("tk_1", events: [self.ev(0, 400)])   // arms the revert
                s.revertTakeEdits("tk_1")
            }),
            ("addOverdubStaff", { s, _ in
                _ = s.addOverdubStaff("tk_1", instrument: .harp, events: [self.ev(900, 950)])
            }),
            ("setStaffEvents", { s, sid in s.setStaffEvents("tk_1", staffId: sid, events: [self.ev(0, 90)]) }),
            ("setStaffInstrument", { s, sid in s.setStaffInstrument("tk_1", staffId: sid, .clarinet) }),
            ("revertStaffEdits", { s, sid in
                s.setStaffEvents("tk_1", staffId: sid, events: [self.ev(0, 90)])
                s.revertStaffEdits("tk_1", staffId: sid)
            }),
            ("deleteStaff", { s, sid in s.deleteStaff("tk_1", staffId: sid) }),
        ]
        for m in mutations {
            let url = FileManager.default.temporaryDirectory
                .appendingPathComponent("pdj-rev-\(UUID().uuidString).json")
            defer { try? FileManager.default.removeItem(at: url) }
            let store = StudioStore(fileURL: url)
            store.addTake(makeTake())
            let staffId = store.addOverdubStaff("tk_1", instrument: .trumpet,
                                                events: [ev(1_000, 1_200)])!
            let before = store.take("tk_1")!.renderRevision
            m.apply(store, staffId)
            XCTAssertGreaterThan(store.take("tk_1")!.renderRevision, before,
                                 "\(m.name) changes the mixdown ⇒ it MUST invalidate the render")
        }
    }

    /// THE race the revision exists for: a render started before an edit, landing after it, must
    /// not re-file itself as the current cache. Without the guard the take would play its
    /// PRE-OVERDUB mixdown forever — the reported bug, still reported, after the fix.
    func testAnInFlightRenderCannotRestampAnInvalidatedCache() {
        let store = StudioStore(fileURL: storeURL)
        store.addTake(makeTake())
        let staffId = store.addOverdubStaff("tk_1", instrument: .trumpet, events: [ev(1_000, 1_200)])!
        let inFlight = store.take("tk_1")!.renderRevision           // what the render was made OF
        let name = StudioFolders.renderedTakeFileName(id: "tk_1", revision: inFlight)
        store.setStaffEvents("tk_1", staffId: staffId, events: [ev(1_000, 1_100)])   // …then an edit lands
        store.setTakeRendered("tk_1", fileName: name, wasUserFolder: false, revision: inFlight)
        XCTAssertNil(store.take("tk_1")?.renderedFileName,
                     "a mixdown of the PRE-edit score is refused, not filed as current")
        XCTAssertFalse(store.take("tk_1")!.isRenderFresh)
        // The render that matches the CURRENT revision is accepted, and only then is it fresh.
        let now = store.take("tk_1")!.renderRevision
        store.setTakeRendered("tk_1", fileName: StudioFolders.renderedTakeFileName(id: "tk_1", revision: now),
                              wasUserFolder: false, revision: now)
        XCTAssertTrue(store.take("tk_1")!.isRenderFresh)
    }
}

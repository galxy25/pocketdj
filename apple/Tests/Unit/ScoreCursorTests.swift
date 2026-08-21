import XCTest
@testable import PocketDJ

/// The saved instrumental's score cursor STAYS WHERE IT WAS LAST PLAYED — per take, across
/// relaunches — and Replay resumes from it.
///
/// The behaviour these pin is the whole point of keying the mark by take: the engine has ONE
/// replay clock, so a position remembered globally would have shown take A's playback on take B's
/// score (which is why the cursor used to be wiped on every appearance). A take that has never
/// been replayed must still open clean.
@MainActor
final class ScoreCursorTests: XCTestCase {

    private func url(_ tag: String = "cursors") -> URL {
        let u = FileManager.default.temporaryDirectory
            .appendingPathComponent("pdj-\(tag)-\(UUID().uuidString).json")
        addTeardownBlock { try? FileManager.default.removeItem(at: u) }
        return u
    }

    // MARK: Per-take restore

    func testACursorIsRestoredForItsOwnTakeAndNoOther() {
        let store = ScoreCursorStore(fileURL: url())
        store.setPosition(4_250, for: "tk_a")
        XCTAssertEqual(store.position("tk_a"), 4_250, "the take that was played resumes there")
        XCTAssertNil(store.position("tk_b"), "a DIFFERENT take shows nothing")
        XCTAssertNil(store.position(""), "an empty id is never a take")
        // A second take keeps its own mark; the two never bleed into each other.
        store.setPosition(900, for: "tk_b")
        XCTAssertEqual(store.position("tk_a"), 4_250)
        XCTAssertEqual(store.position("tk_b"), 900)
    }

    /// DURABLE, not session-scoped: "stay where it was last played" must survive a relaunch, so a
    /// fresh store reading the same file finds the same marks.
    func testCursorsSurviveARelaunch() {
        let file = url()
        let first = ScoreCursorStore(fileURL: file)
        first.setPosition(7_000, for: "tk_a")
        first.setPosition(120, for: "tk_b")
        first.flush()                       // the write is off the main thread; wait for the disk
        let relaunched = ScoreCursorStore(fileURL: file)
        XCTAssertEqual(relaunched.position("tk_a"), 7_000)
        XCTAssertEqual(relaunched.position("tk_b"), 120)
        XCTAssertNil(relaunched.position("tk_never_played"))
    }

    /// nil = "nothing has played" — it FORGETS the mark rather than parking at 0, so the score
    /// opens with no cursor highlight at all.
    func testNilForgetsTheMark() {
        let file = url()
        let store = ScoreCursorStore(fileURL: file)
        store.setPosition(3_000, for: "tk_a")
        store.setPosition(nil, for: "tk_a")
        store.flush()
        XCTAssertNil(store.position("tk_a"))
        XCTAssertNil(ScoreCursorStore(fileURL: file).position("tk_a"), "and the file forgot too")
    }

    /// Opening and closing a score without moving the cursor must not touch the disk: the mark is
    /// compared on its POSITION, not on the whole record (whose `updatedAt` always differs), so an
    /// unchanged cursor neither rewrites the file nor refreshes its eviction rank.
    func testRewritingTheSamePositionIsNotAWrite() {
        let file = url()
        let store = ScoreCursorStore(fileURL: file)
        store.setPosition(2_000, for: "tk_a", at: 1_000)
        store.setPosition(2_000, for: "tk_a", at: 9_999)     // same place, later — dropped
        store.flush()
        let doc = try! JSONDecoder().decode(ScoreCursorStore.Document.self,
                                            from: Data(contentsOf: file))
        XCTAssertEqual(doc.marks["tk_a"]?.updatedAt, 1_000, "an unchanged position keeps its stamp")
        store.setPosition(2_500, for: "tk_a", at: 12_000)    // a real move DOES write
        store.flush()
        let after = try! JSONDecoder().decode(ScoreCursorStore.Document.self,
                                              from: Data(contentsOf: file))
        XCTAssertEqual(after.marks["tk_a"]?.ms, 2_500)
        XCTAssertEqual(after.marks["tk_a"]?.updatedAt, 12_000)
    }

    /// A corrupt/absurd stored position must degrade to something a transport can accept — never
    /// a negative or a wild time (the clamp-before-Int discipline).
    func testPositionsAreClamped() {
        let store = ScoreCursorStore(fileURL: url())
        store.setPosition(-5_000, for: "tk_a")
        XCTAssertEqual(store.position("tk_a"), 0)
        store.setPosition(Int.max, for: "tk_b")
        XCTAssertEqual(store.position("tk_b"), ScoreCursorStore.maxMs)
    }

    /// The file is written on every seek, so it needs a bound: the most recently written marks
    /// survive, the stalest are evicted.
    func testCapacityEvictsTheStalestMarks() {
        var marks: [String: ScoreCursorStore.Mark] = [:]
        for i in 0..<10 { marks["tk_\(i)"] = .init(ms: i * 100, updatedAt: Double(i)) }
        let kept = ScoreCursorStore.pruned(marks, capacity: 4)
        XCTAssertEqual(Set(kept.keys), ["tk_9", "tk_8", "tk_7", "tk_6"])
        XCTAssertEqual(ScoreCursorStore.pruned(marks, capacity: 100).count, 10, "under the cap: untouched")
        XCTAssertTrue(ScoreCursorStore.pruned(marks, capacity: 0).isEmpty)
    }

    func testPruneDropsMarksForTakesThatAreGone() {
        let store = ScoreCursorStore(fileURL: url())
        store.setPosition(1, for: "tk_a")
        store.setPosition(2, for: "tk_b")
        store.prune(keeping: ["tk_a"])
        XCTAssertEqual(store.position("tk_a"), 1)
        XCTAssertNil(store.position("tk_b"))
    }

    // MARK: StudioStore integration (what the score screen actually calls)

    func testStudioStoreRemembersACursorPerTakeAndDropsItWithTheTake() {
        let studioURL = url("studiostore")
        addTeardownBlock {
            try? FileManager.default.removeItem(at: ScoreCursorStore.url(forStudio: studioURL))
            try? FileManager.default.removeItem(at: StudioStore.cuesURL(forStudio: studioURL))
        }
        let studio = StudioStore(fileURL: studioURL)
        studio.addTake(StudioTake(id: "tk_1", name: "One", instrument: .piano, fileName: "a.m4a",
                                  bpm: 120, events: [], durationMs: 1_000,
                                  createdAt: 1_700_000_000_000))
        studio.setScoreCursorMs(2_400, forTake: "tk_1")
        XCTAssertEqual(studio.scoreCursorMs("tk_1"), 2_400)
        XCTAssertNil(studio.scoreCursorMs("tk_2"), "another instrumental's score shows nothing")
        // The mark lives in a SIBLING of the studio document, so a relaunch finds it…
        studio.flush()
        XCTAssertEqual(StudioStore(fileURL: studioURL).scoreCursorMs("tk_1"), 2_400)
        // …and deleting the instrumental takes its cursor with it.
        XCTAssertTrue(studio.deleteTake("tk_1"))
        studio.flush()
        XCTAssertNil(studio.scoreCursorMs("tk_1"))
        XCTAssertNil(StudioStore(fileURL: studioURL).scoreCursorMs("tk_1"))
    }

    /// A take that leaves the document by ANY route (an import that replaces it, a hand-edited
    /// document — not just `deleteTake`) must not leave its cursor behind: the store reconciles the
    /// marks against the takes it loaded.
    func testOrphanMarksAreDroppedWhenTheDocumentLoads() {
        let studioURL = url("studioprune")
        addTeardownBlock {
            try? FileManager.default.removeItem(at: ScoreCursorStore.url(forStudio: studioURL))
            try? FileManager.default.removeItem(at: StudioStore.cuesURL(forStudio: studioURL))
        }
        let studio = StudioStore(fileURL: studioURL)
        studio.addTake(StudioTake(id: "tk_1", name: "One", instrument: .piano, fileName: "a.m4a",
                                  bpm: 120, events: [], durationMs: 1_000,
                                  createdAt: 1_700_000_000_000))
        studio.setScoreCursorMs(2_400, forTake: "tk_1")
        studio.setScoreCursorMs(900, forTake: "tk_gone")   // an id the document never knew
        studio.flush()
        let relaunched = StudioStore(fileURL: studioURL)
        XCTAssertEqual(relaunched.scoreCursorMs("tk_1"), 2_400, "a live take keeps its cursor")
        XCTAssertNil(relaunched.scoreCursorMs("tk_gone"), "an orphan mark is reconciled away")
    }

    // MARK: The engine's ONE replay clock, read + written through its OWNER

    /// The clock is stamped with the take it belongs to, and every accessor honours that stamp —
    /// which is what stops one instrumental's playback position from being shown on, or saved
    /// into, another instrumental's score.
    func testTheReplayClockIsOwnedByTheTakeThatSetIt() {
        let engine = InstrumentEngine()
        engine.parkReplayPosition(atMs: 1_500, forTake: "tk_a")
        XCTAssertEqual(engine.replayPositionMs(forTake: "tk_a"), 1_500)
        XCTAssertNil(engine.replayPositionMs(forTake: "tk_b"), "another take reads NOTHING here")
        XCTAssertTrue(engine.replayClockBelongs(to: "tk_a"))
        XCTAssertFalse(engine.replayClockBelongs(to: "tk_b"))
        // A different take taking the clock over hands the first one nothing (not a stale value).
        engine.parkReplayPosition(atMs: 90, forTake: "tk_b")
        XCTAssertNil(engine.replayPositionMs(forTake: "tk_a"))
        XCTAssertEqual(engine.replayPositionMs(forTake: "tk_b"), 90)
        // …and a take may only clear the clock it owns.
        engine.resetReplayPosition(forTake: "tk_a")
        XCTAssertEqual(engine.replayPositionMs(forTake: "tk_b"), 90, "tk_a can't clear tk_b's clock")
        engine.resetReplayPosition(forTake: "tk_b")
        XCTAssertNil(engine.replayPositionMs(forTake: "tk_b"))
        XCTAssertFalse(engine.replayClockBelongs(to: "tk_b"), "a nil clock has no owner")
    }

    /// THE regression: replay take B (its row's ▶ in the takes list), then open take A's score.
    /// Nothing about A's cursor may be derived from B's clock — not what A shows, and above all not
    /// what A REMEMBERS, because that write is durable and would follow the user across relaunches.
    func testAnotherInstrumentalsClockIsNeverShownOrRememberedOnThisScore() {
        let studioURL = url("studiobleed")
        addTeardownBlock {
            try? FileManager.default.removeItem(at: ScoreCursorStore.url(forStudio: studioURL))
            try? FileManager.default.removeItem(at: StudioStore.cuesURL(forStudio: studioURL))
        }
        let studio = StudioStore(fileURL: studioURL)
        for id in ["tk_a", "tk_b"] {
            studio.addTake(StudioTake(id: id, name: id, instrument: .piano, fileName: "\(id).m4a",
                                      bpm: 120, events: [], durationMs: 10_000,
                                      createdAt: 1_700_000_000_000))
        }
        studio.setScoreCursorMs(1_000, forTake: "tk_a")     // where A was left last time
        let engine = InstrumentEngine()
        engine.parkReplayPosition(atMs: 8_000, forTake: "tk_b")   // B's replay owns the clock
        let a = ScoreCursorSession(takeId: "tk_a", instruments: engine, studio: studio)

        // Opening A's score while the clock is B's: A shows ITS OWN mark, never B's 8 s.
        XCTAssertEqual(a.positionMs(), 1_000)
        // Leaving again must write nothing — B's position is not A's to keep.
        a.leave()
        XCTAssertEqual(studio.scoreCursorMs("tk_a"), 1_000, "B's position never lands on A")
        XCTAssertEqual(engine.replayPositionMs(forTake: "tk_b"), 8_000, "…and B's clock is untouched")
        // Same for the moment B's replay ENDS while A is on screen: A takes the freed clock back
        // to its own cursor rather than adopting where B stopped.
        a.replayEnded()
        XCTAssertEqual(a.positionMs(), 1_000)
        XCTAssertEqual(studio.scoreCursorMs("tk_a"), 1_000)
        XCTAssertTrue(engine.replayClockBelongs(to: "tk_a"))
        // Now that the clock IS A's, A's own lifecycle persists normally.
        engine.parkReplayPosition(atMs: 3_300, forTake: "tk_a")
        a.remember()
        XCTAssertEqual(studio.scoreCursorMs("tk_a"), 3_300)
        XCTAssertNil(studio.scoreCursorMs("tk_b"), "and B's mark was never invented for it")
    }

    /// `remember()` must never CLEAR a good mark: a nil clock (nothing played, or a clock that
    /// isn't ours) leaves the stored position alone rather than forgetting it.
    func testRememberingAnEmptyClockDoesNotForgetTheStoredCursor() {
        let studioURL = url("studiokeep")
        addTeardownBlock {
            try? FileManager.default.removeItem(at: ScoreCursorStore.url(forStudio: studioURL))
            try? FileManager.default.removeItem(at: StudioStore.cuesURL(forStudio: studioURL))
        }
        let studio = StudioStore(fileURL: studioURL)
        studio.setScoreCursorMs(4_000, forTake: "tk_a")
        let engine = InstrumentEngine()                     // no clock at all
        ScoreCursorSession(takeId: "tk_a", instruments: engine, studio: studio).remember()
        XCTAssertEqual(studio.scoreCursorMs("tk_a"), 4_000)
    }

    // MARK: Seeking mid-note — what you HEAR matches what the score paints

    /// A seek lands the score in the state playback would be in having reached that point, so a note
    /// that STARTED earlier and is still sounding there must actually be struck (MIDI chase).
    /// Without it the score rings the "sounding" note over silence, and then sends a note-off for a
    /// note that was never started.
    func testASeekChasesNotesAlreadySounding() {
        let held = StudioNoteEvent(onMs: 200, offMs: 1_800, note: 60, velocity: 100)  // straddles
        let over = StudioNoteEvent(onMs: 0, offMs: 500, note: 55, velocity: 70)       // long done
        let later = StudioNoteEvent(onMs: 1_500, offMs: 1_900, note: 64, velocity: 80)
        let acts = InstrumentEngine.replayActions(events: [held, over, later], from: 1_000)

        let first = try! XCTUnwrap(acts.first)
        XCTAssertEqual(first.ms, 1_000)
        XCTAssertTrue(first.on)
        XCTAssertEqual(first.note, 60, "the held note is struck AT the seek point")
        XCTAssertEqual(first.velocity, 100, "with its own velocity")
        XCTAssertFalse(acts.contains { $0.note == 55 }, "a note finished before the seek is dropped")
        XCTAssertTrue(acts.contains { $0.ms == 1_500 && $0.on && $0.note == 64 })
        // The invariant that makes the sampler's state honest: every note-off has a note-on before
        // it, so no note is stopped that was never started.
        var sounding: Set<Int> = []
        for a in acts {
            if a.on { sounding.insert(a.note) }
            else {
                XCTAssertTrue(sounding.remove(a.note) != nil,
                              "note \(a.note) was stopped without ever being started")
            }
        }
        // from == 0 is the plain, unchased list.
        XCTAssertEqual(InstrumentEngine.replayActions(events: [held, over, later], from: 0).count,
                       InstrumentEngine.replayActions(events: [held, over, later]).count)
    }

    // MARK: Replay resumes from the cursor

    /// ▶ starts from where the cursor was left — the coherent other half of tap-to-seek. Once the
    /// take has played THROUGH, ▶ means "again, from the top" rather than "play the silence after
    /// the last note".
    func testReplayResumesFromTheParkedCursorButRestartsAtTheEnd() {
        let events = [StudioNoteEvent(onMs: 0, offMs: 500, note: 64, velocity: 90),
                      StudioNoteEvent(onMs: 2_000, offMs: 2_500, note: 67, velocity: 90)]
        XCTAssertEqual(StudioTakeReplay.resumeMs(parkedMs: 1_200, events: events), 1_200)
        XCTAssertEqual(StudioTakeReplay.resumeMs(parkedMs: nil, events: events), 0,
                       "nothing played yet ⇒ from the top")
        XCTAssertEqual(StudioTakeReplay.resumeMs(parkedMs: 0, events: events), 0)
        XCTAssertEqual(StudioTakeReplay.resumeMs(parkedMs: 2_500, events: events), 0,
                       "parked AT the end ⇒ replay from the top")
        XCTAssertEqual(StudioTakeReplay.resumeMs(parkedMs: 9_999, events: events), 0,
                       "parked past the end ⇒ replay from the top")
        XCTAssertEqual(StudioTakeReplay.resumeMs(parkedMs: 500, events: []), 0,
                       "an empty take has no resume point")
    }

    // MARK: Polyphonic scheduling (multi-staff replay — pure action math)

    /// Every staff's actions appear, tagged with its channel, globally time-sorted with the
    /// offs-before-ons rule intact — the merged schedule the multitimbral synth dispatches.
    func testPolyphonicActionsContainAllStaffsWithChannels() {
        let staffs: [(events: [StudioNoteEvent], channel: Int)] = [
            ([StudioNoteEvent(onMs: 0, offMs: 500, note: 60, velocity: 96)], 0),
            ([StudioNoteEvent(onMs: 250, offMs: 750, note: 64, velocity: 90)], 1),
            ([StudioNoteEvent(onMs: 500, offMs: 900, note: 67, velocity: 80)], 2),
        ]
        let acts = InstrumentEngine.replayActionsMulti(staffs: staffs)
        XCTAssertEqual(acts.count, 6)
        for (i, staff) in staffs.enumerated() {
            XCTAssertTrue(acts.contains { $0.channel == i && $0.on
                                          && $0.note == staff.events[0].note })
            XCTAssertTrue(acts.contains { $0.channel == i && !$0.on
                                          && $0.note == staff.events[0].note })
        }
        XCTAssertEqual(acts.map(\.ms), acts.map(\.ms).sorted(), "globally ms-sorted")
        // At ms 500: staff 0's OFF (60) sorts before staff 2's ON (67).
        let at500 = acts.filter { $0.ms == 500 }
        XCTAssertEqual(at500.map(\.on), [false, true], "offs before ons at equal ms")
    }

    /// The chase rule holds PER STAFF: a note sounding across `from` in one staff is struck at
    /// `from` on THAT staff's channel; everything earlier is dropped on all channels.
    func testPolyphonicChaseFromSeeksEveryStaff() {
        let staffs: [(events: [StudioNoteEvent], channel: Int)] = [
            ([StudioNoteEvent(onMs: 0, offMs: 400, note: 55, velocity: 70)], 0),    // long done
            ([StudioNoteEvent(onMs: 1_500, offMs: 1_900, note: 64, velocity: 80)], 1),
            ([StudioNoteEvent(onMs: 200, offMs: 1_800, note: 60, velocity: 100)], 2), // straddles
        ]
        let acts = InstrumentEngine.replayActionsMulti(staffs: staffs, from: 1_000)
        let first = acts.first!
        XCTAssertEqual(first.ms, 1_000)
        XCTAssertTrue(first.on)
        XCTAssertEqual(first.note, 60, "the straddling note is chased at the seek point")
        XCTAssertEqual(first.channel, 2, "…on ITS staff's channel")
        XCTAssertFalse(acts.contains { $0.note == 55 }, "finished-before-seek dropped")
        XCTAssertTrue(acts.contains { $0.ms == 1_500 && $0.on && $0.note == 64 && $0.channel == 1 })
        // Sampler-honesty invariant per channel: no off without a prior on.
        var sounding: Set<Int> = []
        for a in acts {
            let key = a.channel << 8 | a.note
            if a.on { sounding.insert(key) }
            else { XCTAssertNotNil(sounding.remove(key),
                                   "note \(a.note) ch \(a.channel) stopped without a start") }
        }
    }

    /// Staff → channel/program assignment: primary on channel 0 with the take's instrument,
    /// extra staff i on channel i+1 with ITS instrument (GM program numbers pinned).
    func testChannelProgramsPerStaffInstrument() {
        let take = StudioTake(id: "tk_p", name: "P", instrument: .piano, fileName: "f.m4a",
                              extraStaffs: [
                                  StudioTakeStaff(id: "stf_1", instrument: .trumpet),
                                  StudioTakeStaff(id: "stf_2", instrument: .harp),
                              ])
        let assigned = InstrumentEngine.channelPrograms(for: take)
        XCTAssertEqual(assigned.map(\.channel), [0, 1, 2])
        XCTAssertEqual(assigned.map(\.program), [0, 56, 46])

        let single = StudioTake(id: "tk_s", name: "S", instrument: .violin, fileName: "g.m4a")
        XCTAssertEqual(InstrumentEngine.channelPrograms(for: single).map(\.channel), [0])
        XCTAssertEqual(InstrumentEngine.channelPrograms(for: single).map(\.program), [40])
    }
}

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
        XCTAssertNil(store.position("tk_a"))
        XCTAssertNil(ScoreCursorStore(fileURL: file).position("tk_a"), "and the file forgot too")
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
        XCTAssertEqual(StudioStore(fileURL: studioURL).scoreCursorMs("tk_1"), 2_400)
        // …and deleting the instrumental takes its cursor with it.
        XCTAssertTrue(studio.deleteTake("tk_1"))
        XCTAssertNil(studio.scoreCursorMs("tk_1"))
        XCTAssertNil(StudioStore(fileURL: studioURL).scoreCursorMs("tk_1"))
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
}

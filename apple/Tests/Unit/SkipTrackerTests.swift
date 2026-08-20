import XCTest
@testable import PocketDJ

/// SkipTracker — the one place the "<50% played" advance-away rule lives. A playback is a SKIP
/// when the user advances away (⏭ / jump / play-now / fresh play / AM systemSkip) with less
/// than half the song played; a verdict marks the history event AND fires the cumulative
/// per-song counter exactly once. Natural ends / repeats / stops never call `noteAdvanceAway`
/// at all (that discipline is SetlistPlayer's, tested in SetlistPlayerTests) — here we test
/// the classification math and the two position caveats (high-water mark, adopt fallback).
@MainActor
final class SkipTrackerTests: XCTestCase {

    private var recordedSkips: [String] = []

    override func setUp() {
        super.setUp()
        recordedSkips = []
    }

    private func makeHistory() -> PlayHistoryStore {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("pdj-skiptracker-\(UUID().uuidString).json")
        addTeardownBlock { try? FileManager.default.removeItem(at: url) }
        return PlayHistoryStore(fileURL: url)
    }

    private func makeTracker(_ history: PlayHistoryStore) -> SkipTracker {
        let t = SkipTracker()
        t.history = history
        t.noteSkip = { [weak self] id in self?.recordedSkips.append(id) }
        return t
    }

    @discardableResult
    private func start(_ tracker: SkipTracker, _ history: PlayHistoryStore,
                       songId: String = "sng_x", at ms: Double = 1_000) -> PlayHistoryStore.PlayEvent {
        let ev = history.record(songId: songId, context: .browser, at: ms)!
        tracker.noteTrackStarted(ev)
        return ev
    }

    // MARK: The live-row key

    func testTrackStartSetsLiveEvent() {
        let history = makeHistory()
        let tracker = makeTracker(history)
        XCTAssertNil(tracker.currentEventId)
        let ev = start(tracker, history, songId: "sng_live")
        XCTAssertEqual(tracker.currentEventId, ev.id, "the live-row key HistoryView matches on")
        XCTAssertEqual(tracker.currentSongId, "sng_live")
    }

    // MARK: The <50% rule

    func testAdvanceAwayBelowHalfMarksSkip() {
        let history = makeHistory()
        let tracker = makeTracker(history)
        let ev = start(tracker, history)
        tracker.noteAdvanceAway(songId: "sng_x", positionMs: 80_000, durationMs: 200_000)  // 40%
        XCTAssertEqual(history.events.first { $0.id == ev.id }?.wasSkipped, true,
                       "the history event carries the per-playback flag")
        XCTAssertEqual(recordedSkips, ["sng_x"], "the cumulative counter fired exactly once")
    }

    func testExactlyHalfIsNotSkip() {
        let history = makeHistory()
        let tracker = makeTracker(history)
        let ev = start(tracker, history)
        tracker.noteAdvanceAway(songId: "sng_x", positionMs: 100_000, durationMs: 200_000)  // 50.0%
        XCTAssertNil(history.events.first { $0.id == ev.id }?.wasSkipped, "strict <, not <=")
        XCTAssertTrue(recordedSkips.isEmpty)
    }

    func testJustBelowHalfIsSkip() {
        let history = makeHistory()
        let tracker = makeTracker(history)
        start(tracker, history)
        tracker.noteAdvanceAway(songId: "sng_x", positionMs: 99_800, durationMs: 200_000)  // 49.9%
        XCTAssertEqual(recordedSkips, ["sng_x"])
    }

    func testJustAboveHalfIsNotSkip() {
        let history = makeHistory()
        let tracker = makeTracker(history)
        start(tracker, history)
        tracker.noteAdvanceAway(songId: "sng_x", positionMs: 100_200, durationMs: 200_000)  // 50.1%
        XCTAssertTrue(recordedSkips.isEmpty)
    }

    func testUnknownDurationNeverSkips() {
        let history = makeHistory()
        let tracker = makeTracker(history)
        let ev = start(tracker, history)
        // No duration passed, none ever sampled → the tracker must not guess against the listener.
        tracker.noteAdvanceAway(songId: "sng_x", positionMs: 1_000, durationMs: nil)
        XCTAssertNil(history.events.first { $0.id == ev.id }?.wasSkipped)
        XCTAssertTrue(recordedSkips.isEmpty)
    }

    // MARK: The two position caveats

    /// The AM systemSkip shape: the detection tick clobbers the provider's clock to ~0 before
    /// the end callback fires, so the live read at advance-away time is a lie. The ticker-fed
    /// high-water mark (60% here) must win — NOT a skip.
    func testHighWaterBeatsClobberedRead() {
        let history = makeHistory()
        let tracker = makeTracker(history)
        start(tracker, history)
        tracker.samplePosition(songId: "sng_x", positionMs: 120_000, durationMs: 200_000)  // 60%
        tracker.noteAdvanceAway(songId: "sng_x", positionMs: 0, durationMs: 200_000)
        XCTAssertTrue(recordedSkips.isEmpty, "the sampled 60% beats the clobbered 0 read")
    }

    /// The adopt shape: the old track's clock is already gone (`positionMs: nil`), so the last
    /// samples decide — 30% sampled ⇒ skip, and the sampled duration stands in for a nil one.
    func testAdoptPathUsesLastSample() {
        let history = makeHistory()
        let tracker = makeTracker(history)
        start(tracker, history)
        tracker.samplePosition(songId: "sng_x", positionMs: 60_000, durationMs: 200_000)  // 30%
        tracker.noteAdvanceAway(songId: "sng_x", positionMs: nil, durationMs: nil)
        XCTAssertEqual(recordedSkips, ["sng_x"])
    }

    // MARK: Classify-once + identity discipline

    func testDoubleAdvanceAwayClassifiesOnce() {
        let history = makeHistory()
        let tracker = makeTracker(history)
        start(tracker, history)
        tracker.noteAdvanceAway(songId: "sng_x", positionMs: 10_000, durationMs: 200_000)
        tracker.noteAdvanceAway(songId: "sng_x", positionMs: 10_000, durationMs: 200_000)
        XCTAssertEqual(recordedSkips.count, 1, "a race between two transports counts once")
    }

    /// A row substituted to its clean/explicit edition advances away under the VARIANT id while
    /// history recorded the base — base-id comparison must still classify it.
    func testVariantIdMatchesBaseId() {
        let history = makeHistory()
        let tracker = makeTracker(history)
        let base = "sng_0123456789ab"
        start(tracker, history, songId: base)
        tracker.noteAdvanceAway(songId: base + "_clean", positionMs: 10_000, durationMs: 200_000)
        XCTAssertEqual(recordedSkips, [base])
    }

    func testMismatchedSongIgnored() {
        let history = makeHistory()
        let tracker = makeTracker(history)
        let ev = start(tracker, history, songId: "sng_current")
        // A stale hook for some OTHER song (a race across a track change) must not classify
        // the live event…
        tracker.noteAdvanceAway(songId: "sng_other", positionMs: 0, durationMs: 200_000)
        XCTAssertNil(history.events.first { $0.id == ev.id }?.wasSkipped)
        XCTAssertTrue(recordedSkips.isEmpty)
        // …and must not burn the classification either — the real advance-away still lands.
        tracker.noteAdvanceAway(songId: "sng_current", positionMs: 0, durationMs: 200_000)
        XCTAssertEqual(recordedSkips, ["sng_current"])
    }

    /// Stale ticks for another song must not pollute the current track's high-water mark.
    func testSamplesForOtherSongsAreDropped() {
        let history = makeHistory()
        let tracker = makeTracker(history)
        start(tracker, history)
        tracker.samplePosition(songId: "sng_other", positionMs: 190_000, durationMs: 200_000)
        tracker.noteAdvanceAway(songId: "sng_x", positionMs: 10_000, durationMs: 200_000)  // 5%
        XCTAssertEqual(recordedSkips, ["sng_x"], "the foreign 95% sample did not mask the skip")
    }

    // MARK: The adopt ORDERING (production order: record first, advance-away after)

    /// THE REAL adopt sequence for a row ▶ jump: the new play's `record` re-arms the tracker
    /// SYNCHRONOUSLY, and only then does the deferred `adoptNowPlayingIfJumped` report the
    /// advance-away from the old track. The one-deep `previous` stash must classify the OLD
    /// event — before it existed, this (the single most common skip gesture) counted 0% of
    /// the time.
    func testRecordThenAdvanceAwayClassifiesThePreviousTrack() {
        let history = makeHistory()
        let tracker = makeTracker(history)
        let old = start(tracker, history, songId: "sng_old", at: 1_000)
        tracker.samplePosition(songId: "sng_old", positionMs: 60_000, durationMs: 200_000)  // 30%
        let new = start(tracker, history, songId: "sng_new", at: 60_000)
        // The adopt shape: old clock gone (nil position), row duration still known.
        tracker.noteAdvanceAway(songId: "sng_old", positionMs: nil, durationMs: 200_000)
        XCTAssertEqual(history.events.first { $0.id == old.id }?.wasSkipped, true,
                       "the OLD track's 30% high-water mark decides — a skip")
        XCTAssertEqual(recordedSkips, ["sng_old"])
        XCTAssertEqual(tracker.currentEventId, new.id, "the live row stays on the NEW track")
        XCTAssertNil(history.events.first { $0.id == new.id }?.wasSkipped,
                     "the new track is untouched by the old one's verdict")
    }

    /// The stashed track keeps its OWN sampled duration — a late advance-away with a nil
    /// duration (foreign single adopt, no queue row to read a length from) still classifies.
    func testLateVerdictFallsBackToThePreviousTracksSamples() {
        let history = makeHistory()
        let tracker = makeTracker(history)
        start(tracker, history, songId: "sng_old", at: 1_000)
        tracker.samplePosition(songId: "sng_old", positionMs: 60_000, durationMs: 200_000)  // 30%
        start(tracker, history, songId: "sng_new", at: 60_000)
        tracker.noteAdvanceAway(songId: "sng_old", positionMs: nil, durationMs: nil)
        XCTAssertEqual(recordedSkips, ["sng_old"], "the stash's sampled duration stood in")
    }

    /// A previous track that played PAST half is not a skip, however late the verdict lands.
    func testLateVerdictAboveHalfIsNotSkip() {
        let history = makeHistory()
        let tracker = makeTracker(history)
        let old = start(tracker, history, songId: "sng_old", at: 1_000)
        tracker.samplePosition(songId: "sng_old", positionMs: 120_000, durationMs: 200_000)  // 60%
        start(tracker, history, songId: "sng_new", at: 60_000)
        tracker.noteAdvanceAway(songId: "sng_old", positionMs: nil, durationMs: nil)
        XCTAssertNil(history.events.first { $0.id == old.id }?.wasSkipped)
        XCTAssertTrue(recordedSkips.isEmpty)
    }

    /// An already-classified previous track ignores a late duplicate (⏭ classified it, THEN
    /// the next track recorded, THEN a stale adopt reported it again) — never double-counted.
    func testLateVerdictForAlreadyClassifiedPreviousIsDropped() {
        let history = makeHistory()
        let tracker = makeTracker(history)
        start(tracker, history, songId: "sng_old", at: 1_000)
        tracker.noteAdvanceAway(songId: "sng_old", positionMs: 10_000, durationMs: 200_000)  // ⏭ classified
        start(tracker, history, songId: "sng_new", at: 60_000)
        tracker.noteAdvanceAway(songId: "sng_old", positionMs: nil, durationMs: 200_000)     // stale dup
        XCTAssertEqual(recordedSkips, ["sng_old"], "exactly once")
    }

    /// The stash is ONE deep: two track starts later, the old verdict is gone for good — a
    /// stale hook can never classify ancient history.
    func testStashIsOneTrackDeep() {
        let history = makeHistory()
        let tracker = makeTracker(history)
        let old = start(tracker, history, songId: "sng_old", at: 1_000)
        tracker.samplePosition(songId: "sng_old", positionMs: 10_000, durationMs: 200_000)
        start(tracker, history, songId: "sng_mid", at: 60_000)
        start(tracker, history, songId: "sng_new", at: 120_000)
        tracker.noteAdvanceAway(songId: "sng_old", positionMs: nil, durationMs: 200_000)
        XCTAssertNil(history.events.first { $0.id == old.id }?.wasSkipped)
        XCTAssertTrue(recordedSkips.isEmpty)
    }

    // MARK: Replays (restart + resume)

    /// A replay that records nothing (repeat-one / per-track repeat / duplicate row) restarts
    /// from 0:00 — `noteTrackRestarted` must re-zero the high-water mark so a genuine ⏭ during
    /// pass 2 counts, instead of pass 1's peak shielding it forever.
    func testRestartRezeroesHighWaterMarkSoReplaySkipCounts() {
        let history = makeHistory()
        let tracker = makeTracker(history)
        start(tracker, history)
        tracker.samplePosition(songId: "sng_x", positionMs: 195_000, durationMs: 200_000)  // pass 1 ~end
        tracker.noteTrackRestarted(songId: "sng_x")                                        // repeat replay
        tracker.noteAdvanceAway(songId: "sng_x", positionMs: 20_000, durationMs: 200_000)  // ⏭ at 10%
        XCTAssertEqual(recordedSkips, ["sng_x"], "pass 1's peak no longer shields the replay ⏭")
    }

    /// A restart signal for some OTHER song (a stale race across a track change) is dropped.
    func testRestartForOtherSongIsIgnored() {
        let history = makeHistory()
        let tracker = makeTracker(history)
        start(tracker, history)
        tracker.samplePosition(songId: "sng_x", positionMs: 150_000, durationMs: 200_000)  // 75%
        tracker.noteTrackRestarted(songId: "sng_other")
        tracker.noteAdvanceAway(songId: "sng_x", positionMs: 0, durationMs: 200_000)
        XCTAssertTrue(recordedSkips.isEmpty, "the 75% mark survived the foreign restart signal")
    }

    /// A 30 s-collapsed replay re-points the tracker at the EXISTING event (`noteTrackResumed`)
    /// — the live row follows the audio — and, having restarted from 0:00, classifies fresh.
    func testResumeReArmsOnTheExistingEvent() {
        let history = makeHistory()
        let tracker = makeTracker(history)
        let a = start(tracker, history, songId: "sng_a", at: 1_000)
        start(tracker, history, songId: "sng_b", at: 60_000)
        // The user replays A inside the window: record() collapses and fires onResume(A).
        tracker.noteTrackResumed(a)
        XCTAssertEqual(tracker.currentEventId, a.id, "the live row moved back onto A's row")
        tracker.noteAdvanceAway(songId: "sng_a", positionMs: 10_000, durationMs: 200_000)
        XCTAssertEqual(history.events.first { $0.id == a.id }?.wasSkipped, true)
        XCTAssertEqual(recordedSkips, ["sng_a"])
    }

    /// Resuming an event that was ALREADY marked skipped arms it classified — the verdict is
    /// spent; a second ⏭ inside the same collapsed listen must not double the cumulative count.
    func testResumeOfSkippedEventDoesNotDoubleCount() {
        let history = makeHistory()
        let tracker = makeTracker(history)
        start(tracker, history, songId: "sng_a", at: 1_000)
        tracker.noteAdvanceAway(songId: "sng_a", positionMs: 10_000, durationMs: 200_000)
        XCTAssertEqual(recordedSkips, ["sng_a"])
        // Replay A within the window: the collapsed record resumes its (now-skipped) event.
        let marked = history.events.first { $0.songId == "sng_a" }!
        tracker.noteTrackResumed(marked)
        tracker.noteAdvanceAway(songId: "sng_a", positionMs: 5_000, durationMs: 200_000)
        XCTAssertEqual(recordedSkips, ["sng_a"], "still exactly once")
    }

    /// A new track start resets classification — the next playback of the same song is its own
    /// verdict (skip counted again), never blocked by the previous one's `classified` latch.
    func testNextTrackStartResetsClassification() {
        let history = makeHistory()
        let tracker = makeTracker(history)
        start(tracker, history, at: 1_000)
        tracker.noteAdvanceAway(songId: "sng_x", positionMs: 10_000, durationMs: 200_000)
        // Same song again, outside the re-count window — a fresh event, a fresh verdict.
        start(tracker, history, at: 60_000)
        tracker.noteAdvanceAway(songId: "sng_x", positionMs: 10_000, durationMs: 200_000)
        XCTAssertEqual(recordedSkips, ["sng_x", "sng_x"])
    }
}

import XCTest
@testable import PocketDJ

/// In the Pocket — the round outcome state machine, driven by history observations exactly as
/// the SkipTracker leaves them: complete, skip at N, pause ≠ skip, ⏮ ≠ foreign, abandon (another
/// song / the sequencer stopped / idle timeout), and the settle window for late verdicts.
final class InThePocketRoundEvaluatorTests: XCTestCase {

    typealias E = InThePocketRoundEvaluator
    let songs = ["a", "b", "c", "d"]
    let t0 = 1_000_000_000_000.0
    let minute = 60_000.0

    private func obs(_ song: String, at minutes: Double, skipped: Bool = false, fraction: Double? = nil) -> E.Observation {
        E.Observation(eventId: UUID(), songId: song, playedAtMs: t0 + minutes * minute, wasSkipped: skipped, fraction: fraction)
    }

    private func eval(_ events: [E.Observation], lostAt: Double? = nil, now minutes: Double) -> E.Verdict {
        E.evaluate(songIds: songs, startedAtMs: t0, events: events,
                   ownershipLostAtMs: lostAt.map { t0 + $0 * minute }, nowMs: t0 + minutes * minute)
    }

    func testNotStartedYetIsPending() {
        let v = eval([], now: 0.5)
        XCTAssertNil(v.outcome)
        XCTAssertEqual(v.states, [.pending, .pending, .pending, .pending])
        XCTAssertNil(v.currentIndex)
    }

    func testAllFourPlayedThroughIsInThePocket() {
        let mid = eval([obs("a", at: 0, fraction: 1), obs("b", at: 4, fraction: 1), obs("c", at: 8)], now: 9)
        XCTAssertNil(mid.outcome)
        XCTAssertEqual(mid.states, [.completed, .completed, .playing, .pending])
        XCTAssertEqual(mid.currentIndex, 2)
        // The last song reaching 90 % decides it at once — no need to wait for the stop.
        let done = eval([obs("a", at: 0), obs("b", at: 4), obs("c", at: 8), obs("d", at: 12, fraction: 0.95)], now: 16)
        XCTAssertEqual(done.outcome, .pocket)
        XCTAssertEqual(done.states, [.completed, .completed, .completed, .completed])
        XCTAssertNil(done.currentIndex)
    }

    func testTheSetEndingNaturallyWaitsForTheCheckpointThenPockets() {
        let events = [obs("a", at: 0), obs("b", at: 4), obs("c", at: 8), obs("d", at: 12)]
        // The sequencer stopped (natural end) but the stop checkpoint's fraction hasn't landed.
        let waiting = eval(events, lostAt: 16, now: 17)
        XCTAssertNil(waiting.outcome, "never guess 'done' before the last song's fraction arrives")
        var withFraction = events
        withFraction[3].fraction = 0.7
        XCTAssertEqual(eval(withFraction, lostAt: 16, now: 17).outcome, .pocket, "≥ 50 % once ended = played through")
    }

    func testASkipBreaksThePocketAtThatSongImmediately() {
        let v = eval([obs("a", at: 0), obs("b", at: 4, skipped: true, fraction: 0.2), obs("c", at: 5)], now: 5.1)
        XCTAssertEqual(v.outcome, .broke(at: 2))
        XCTAssertEqual(v.states, [.completed, .skipped, .playing, .notPlayed])
        let first = eval([obs("a", at: 0, skipped: true, fraction: 0.1), obs("b", at: 0.5)], now: 0.6)
        XCTAssertEqual(first.outcome, .broke(at: 1))
    }

    func testALateSkipVerdictStillBreaksTheRound() {
        // The adopt path classifies the old track AFTER the new one was recorded: the first
        // evaluation sees no skip yet…
        var events = [obs("a", at: 0), obs("b", at: 4)]
        XCTAssertNil(eval(events, now: 4.01).outcome)
        // …the next one does.
        events[0].wasSkipped = true
        XCTAssertEqual(eval(events, now: 4.02).outcome, .broke(at: 1))
    }

    func testPausingIsNotSkipping() {
        // Song b paused for 90 minutes: no new events, the sequencer still owns the round.
        let v = eval([obs("a", at: 0), obs("b", at: 4, fraction: 0.3)], now: 94)
        XCTAssertNil(v.outcome)
        XCTAssertEqual(v.states, [.completed, .playing, .pending, .pending])
    }

    func testReplayingAnEarlierRoundSongIsNotForeign() {
        let v = eval([obs("a", at: 0), obs("b", at: 4), obs("a", at: 5), obs("b", at: 6)], now: 7)
        XCTAssertNil(v.outcome, "⏮ back to song 1 neither skips nor abandons")
        XCTAssertEqual(v.currentIndex, 1)
    }

    func testPlayingSomethingElseAbandonsAfterTheSettleWindow() {
        let events = [obs("a", at: 0), obs("b", at: 4, fraction: 0.3), obs("zzz", at: 5)]
        let settling = E.evaluate(songIds: songs, startedAtMs: t0, events: events, ownershipLostAtMs: nil,
                                  nowMs: t0 + 5 * minute + E.settleMs - 1)
        XCTAssertNil(settling.outcome, "a late skip verdict may still land")
        let v = eval(events, now: 6)
        XCTAssertEqual(v.outcome, .abandoned)
        XCTAssertEqual(v.states, [.completed, .playing, .notPlayed, .notPlayed])
        // …unless the verdict did land: then it's a break, not an abandon.
        var skipped = events
        skipped[1].wasSkipped = true
        XCTAssertEqual(eval(skipped, now: 6).outcome, .broke(at: 2))
    }

    func testStoppingTheSetMidSongAbandons() {
        let v = eval([obs("a", at: 0), obs("b", at: 4, fraction: 0.2)], lostAt: 5, now: 6)
        XCTAssertEqual(v.outcome, .abandoned)
        let before = eval([], lostAt: 0.1, now: 1)
        XCTAssertEqual(before.outcome, .abandoned, "taken over before song 1 started")
        XCTAssertEqual(before.states, [.notPlayed, .notPlayed, .notPlayed, .notPlayed])
    }

    func testIdleTimeoutAbandons() {
        let v = eval([obs("a", at: 0), obs("b", at: 4, fraction: 0.3)], now: 4 + 181)
        XCTAssertEqual(v.outcome, .abandoned)
    }

    func testVariantIdsMatchTheirBaseSong() {
        let ids = ["sng_00000000000a", "sng_00000000000b", "sng_00000000000c"]
        let v = E.evaluate(songIds: ids, startedAtMs: t0,
                           events: [obs(ids[0], at: 0), obs(SongVariant.variantId(ids[1], .clean), at: 4)],
                           ownershipLostAtMs: nil, nowMs: t0 + 4.5 * minute)
        XCTAssertEqual(v.states, [.completed, .playing, .pending], "an edition of the round song is the round song")
        XCTAssertNil(v.outcome)
    }

    func testEventsBeforeTheStartAreIgnored() {
        let v = eval([obs("zzz", at: -10), obs("a", at: 0)], now: 1)
        XCTAssertNil(v.outcome)
        XCTAssertEqual(v.states[0], .playing)
    }
}

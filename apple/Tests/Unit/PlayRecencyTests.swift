import XCTest
@testable import PocketDJ

/// The pure last-played decay — the second play axis, alongside the lifetime count.
///
/// These pin the properties the rest of the feature relies on: absent is an honest ZERO (not a
/// penalty and not "unknown"), the curve is MONOTONE with a real gradient across the range this
/// library actually occupies, and a bad clock cannot manufacture a score above 1.
final class PlayRecencyTests: XCTestCase {

    private let day: Double = 86_400_000

    // MARK: - The curve

    func testDecayIsOneAtZeroAndHalfAtTheHalfLife() {
        XCTAssertEqual(PlayRecency.decay(ageDays: 0), 1, accuracy: 1e-12)
        XCTAssertEqual(PlayRecency.decay(ageDays: PlayRecency.halfLifeDays), 0.5, accuracy: 1e-12)
        XCTAssertEqual(PlayRecency.decay(ageDays: 2 * PlayRecency.halfLifeDays), 0.25, accuracy: 1e-12)
        XCTAssertEqual(PlayRecency.decay(ageDays: 3 * PlayRecency.halfLifeDays), 0.125, accuracy: 1e-12)
    }

    /// A NEGATIVE age (device clock skew, a peer device running ahead, a hand-edited snapshot)
    /// must clamp rather than grow — an unbounded value here would let one bad timestamp
    /// outweigh the entire rest of the library.
    func testFutureStampsClampToOne() {
        XCTAssertEqual(PlayRecency.decay(ageDays: -1), 1, accuracy: 1e-12)
        XCTAssertEqual(PlayRecency.decay(ageDays: -100_000), 1, accuracy: 1e-12)
        let now: Double = 1_700_000_000_000
        XCTAssertEqual(PlayRecency.score(lastPlayedMs: now + 30 * day, nowMs: now), 1, accuracy: 1e-12)
    }

    func testDecayIsMonotonicallyNonIncreasingAndBounded() {
        var previous = Double.infinity
        for ageDays in stride(from: 0.0, through: 4000.0, by: 25.0) {
            let v = PlayRecency.decay(ageDays: ageDays)
            XCTAssertLessThanOrEqual(v, previous, "not monotone at \(ageDays) days")
            XCTAssertGreaterThanOrEqual(v, 0)
            XCTAssertLessThanOrEqual(v, 1)
            previous = v
        }
    }

    /// THE REASON THE HALF-LIFE IS TWO YEARS AND NOT THIRTY DAYS. On the owner's real library the
    /// median played song was last played 2,117 days ago and p10 is 913 days; a 30-day half-life
    /// scores both of those as literally 0.000 and ranks on a ~500-song sliver of a 96k catalog.
    /// This asserts the curve still SEPARATES the range the library actually occupies.
    func testTheRealLibrarysRangeStaysOnALiveGradient() {
        let p10 = PlayRecency.decay(ageDays: 913)
        let median = PlayRecency.decay(ageDays: 2117)
        let p90 = PlayRecency.decay(ageDays: 2963)
        XCTAssertGreaterThan(median, 0.05, "the median real song is not flattened to zero")
        XCTAssertGreaterThan(p10, median)
        XCTAssertGreaterThan(median, p90)
        // A real spread, not four numbers rounding to the same value.
        XCTAssertGreaterThan(p10 / p90, 3, "p10 and p90 are meaningfully different")
    }

    // MARK: - Absent ≡ never played

    /// ABSENT IS ZERO, NOT UNKNOWN — Apple omits the key for a song it has never played, so the
    /// honest answer is 0 (matching how an absent play COUNT is treated). The genuine unknown is
    /// a device with no baseline at all, which is a round-level question, not a per-song one.
    func testAbsentAndGarbageStampsScoreZero() {
        let now: Double = 1_700_000_000_000
        XCTAssertEqual(PlayRecency.score(lastPlayedMs: nil, nowMs: now), 0)
        XCTAssertEqual(PlayRecency.score(lastPlayedMs: 0, nowMs: now), 0)
        XCTAssertEqual(PlayRecency.score(lastPlayedMs: -5, nowMs: now), 0)
        XCTAssertEqual(PlayRecency.score(lastPlayedMs: .nan, nowMs: now), 0)
        XCTAssertEqual(PlayRecency.score(lastPlayedMs: .infinity, nowMs: now), 0)
        XCTAssertEqual(PlayRecency.decay(ageDays: .nan), 0)
    }

    func testScoreConvertsMillisecondsToDaysCorrectly() {
        let now: Double = 1_700_000_000_000
        XCTAssertEqual(PlayRecency.score(lastPlayedMs: now, nowMs: now), 1, accuracy: 1e-12)
        XCTAssertEqual(PlayRecency.score(lastPlayedMs: now - PlayRecency.halfLifeDays * day, nowMs: now),
                       0.5, accuracy: 1e-9)
    }

    // MARK: - The two axes are genuinely different

    /// The design claim in one assertion: recency ORDERS BY DATE ALONE, so it cannot be a
    /// restatement of the play count. A song played once yesterday outranks one played 200 times
    /// five years ago on THIS axis — while the play-count axis says the opposite, and both
    /// answers are available to a caller at the same time.
    func testRecencyRanksByDateIndependentlyOfHowOftenASongWasPlayed() {
        let now: Double = 1_700_000_000_000
        let heavyButOld = PlayRecency.score(lastPlayedMs: now - 1825 * day, nowMs: now)   // 200 plays
        let lightButRecent = PlayRecency.score(lastPlayedMs: now - 1 * day, nowMs: now)   // 1 play
        XCTAssertGreaterThan(lightButRecent, heavyButOld)

        // …and the play-count formula the sampler uses ranks them the other way round, from the
        // same pair of songs. Two axes, two orders — which is the whole point of adding one.
        let heavyCount = 1 + log2(1 + 200.0)
        let lightCount = 1 + log2(1 + 1.0)
        XCTAssertGreaterThan(heavyCount, lightCount)
    }

    /// The Gem Collector multiplier is calibrated against the SHIPPED play-count bias so neither
    /// setting is stronger than the other: both top out near ×9 and both put a mid-distribution
    /// song near ×2.
    func testGemCollectorGainMatchesThePlayCountBiasDynamicRange() {
        let recencyMax = 1 + PlayRecency.gain * 1.0                     // played today
        let playCountMax = 1 + log2(1 + 244.0)                          // the library's most played
        XCTAssertEqual(recencyMax, playCountMax, accuracy: 1.0,
                       "neither bias may be dramatically stronger than the other")

        // The MEDIAN played song lands at essentially the same multiplier on either axis — 2.07
        // vs 2.00 — which is what "equal weights mean equal influence" cashes out to on the real
        // library. (Measured medians there: age 2,117 days, and a play count of 1 — 28,246 of the
        // 56,224 played songs have been played exactly once.)
        let recencyMedian = 1 + PlayRecency.gain * PlayRecency.decay(ageDays: 2117)
        let playCountMedian = 1 + log2(1 + 1.0)
        XCTAssertEqual(recencyMedian, playCountMedian, accuracy: 0.1,
                       "the two biases must not pull with visibly different strength")
    }
}

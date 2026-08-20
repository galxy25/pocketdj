import XCTest
@testable import PocketDJ

/// The Apple Music end-monitor's per-tick verdict (`AppleMusicPlaybackProvider.trackEnded`)
/// — the pure decision extracted from the MusicKit polling loop, which itself can't run
/// headless (needs the entitlement + authorization).
///
/// The load-bearing case is the SYSTEM REMOTE ⏭: iOS delivers the lock-screen / CarPlay
/// next button to MusicKit itself (never our MPRemoteCommandCenter handler), which skips
/// past its one-song queue and parks the player PAUSED at ~0 or pinned at the end. Before
/// this verdict learned those shapes, the monitor read them as an external listener pause
/// and the set froze on the old track ("skip stops the song but never advances").
///
/// The park shape's counterweight: a listener PAUSE in the first second of a track is
/// state-identical to the park (paused, position ≈ 0) — and after a skip the position is
/// near the top by construction, so skip-then-pause used to read as ANOTHER skip and the
/// set advanced ("pausing skips to a random song"). Two extra inputs discriminate:
/// `maxObserved` (a park after real progress is a backward RESET; a pause anchors at the
/// pause point) and `intentionalPause` (the pause came through OUR OWN pause paths).
final class AppleMusicMonitorTests: XCTestCase {

    // MARK: - The states that were always "ended"

    func testStoppedIsEnded() {
        XCTAssertTrue(AppleMusicPlaybackProvider.trackEnded(
            stopped: true, paused: false, playbackTime: 42, expectedDuration: 180,
            maxObserved: 42, intentionalPause: false))
    }

    func testPlayedPastDurationIsEnded() {
        XCTAssertTrue(AppleMusicPlaybackProvider.trackEnded(
            stopped: false, paused: false, playbackTime: 179.6, expectedDuration: 180,
            maxObserved: 179.6, intentionalPause: false))
    }

    func testPlayingMidSongIsNotEnded() {
        XCTAssertFalse(AppleMusicPlaybackProvider.trackEnded(
            stopped: false, paused: false, playbackTime: 90, expectedDuration: 180,
            maxObserved: 90, intentionalPause: false))
    }

    func testPlayingWithUnknownDurationIsNotEnded() {
        // No catalog duration (expected 0) → the past-duration backstop must never fire.
        XCTAssertFalse(AppleMusicPlaybackProvider.trackEnded(
            stopped: false, paused: false, playbackTime: 500, expectedDuration: 0,
            maxObserved: 500, intentionalPause: false))
    }

    // MARK: - A real listener pause must still NOT advance

    func testPausedMidSongIsNotEnded() {
        // External pause from MusicKit's own card anchors AT the pause position —
        // the monitor keeps waiting, it must not skip the listener forward.
        XCTAssertFalse(AppleMusicPlaybackProvider.trackEnded(
            stopped: false, paused: true, playbackTime: 90, expectedDuration: 180,
            maxObserved: 90, intentionalPause: false))
    }

    func testPausedMidSongWithUnknownDurationIsNotEnded() {
        XCTAssertFalse(AppleMusicPlaybackProvider.trackEnded(
            stopped: false, paused: true, playbackTime: 50, expectedDuration: 0,
            maxObserved: 50, intentionalPause: false))
    }

    // MARK: - The system-skip parked states (the lock-screen/CarPlay ⏭ bug)

    func testPausedParkedAtZeroIsEnded() {
        // System ⏭ exhausted MusicKit's one-song queue mid-listen → paused with the
        // position RESET (maxObserved holds where the listener actually was).
        XCTAssertTrue(AppleMusicPlaybackProvider.trackEnded(
            stopped: false, paused: true, playbackTime: 0, expectedDuration: 180,
            maxObserved: 120, intentionalPause: false))
    }

    func testPausedParkedAtZeroWithUnknownDurationIsEnded() {
        XCTAssertTrue(AppleMusicPlaybackProvider.trackEnded(
            stopped: false, paused: true, playbackTime: 0.2, expectedDuration: 0,
            maxObserved: 90, intentionalPause: false))
    }

    func testPausedPinnedAtEndIsEnded() {
        XCTAssertTrue(AppleMusicPlaybackProvider.trackEnded(
            stopped: false, paused: true, playbackTime: 179.8, expectedDuration: 180,
            maxObserved: 179.8, intentionalPause: false))
    }

    // MARK: - The boundary of the parked-at-top window

    func testPausedJustInsideTopWindowIsEnded() {
        XCTAssertTrue(AppleMusicPlaybackProvider.trackEnded(
            stopped: false, paused: true, playbackTime: 1.0, expectedDuration: 180,
            maxObserved: 30, intentionalPause: false))
    }

    func testPausedJustPastTopWindowIsNotEnded() {
        XCTAssertFalse(AppleMusicPlaybackProvider.trackEnded(
            stopped: false, paused: true, playbackTime: 1.5, expectedDuration: 180,
            maxObserved: 30, intentionalPause: false))
    }

    // MARK: - The system-⏮ rewind (trackRestarted) — playbackTime's backward jump

    func testRestartDetectedAfterDeepPlayback() {
        // System ⏮ rewound MusicKit's one-song queue to 0:00 from 90s in.
        XCTAssertTrue(AppleMusicPlaybackProvider.trackRestarted(
            playbackTime: 0, maxObserved: 90))
    }

    func testNormalPlaybackIsNotARestart() {
        XCTAssertFalse(AppleMusicPlaybackProvider.trackRestarted(
            playbackTime: 91, maxObserved: 91))
    }

    func testEarlyRewindIsNotDetected() {
        // Inside the first ~10s a rewind is indistinguishable from MusicKit's laggy
        // position reads — an early ⏮ just restarts the song (no set step-back).
        XCTAssertFalse(AppleMusicPlaybackProvider.trackRestarted(
            playbackTime: 0, maxObserved: 8))
    }

    func testLaggyPositionReadIsNotARestart() {
        // A stale read a few seconds behind the high-water mark must not fire.
        XCTAssertFalse(AppleMusicPlaybackProvider.trackRestarted(
            playbackTime: 84, maxObserved: 90))
    }

    func testRestartWindowBoundaries() {
        XCTAssertTrue(AppleMusicPlaybackProvider.trackRestarted(
            playbackTime: 1.9, maxObserved: 10.1))
        XCTAssertFalse(AppleMusicPlaybackProvider.trackRestarted(
            playbackTime: 2.0, maxObserved: 10.1))   // not near the top → no fire
        XCTAssertFalse(AppleMusicPlaybackProvider.trackRestarted(
            playbackTime: 1.9, maxObserved: 10.0))   // baseline too shallow → no fire
    }

    // MARK: - endReason: WHY it ended (repeat-one must not swallow a system ⏭)

    /// The skip-park shape (paused, position reset to ~0, not at the end) is a `.systemSkip`
    /// — the set must ADVANCE even under repeat-one. Every other ended shape is `.natural`
    /// (stopped, played past the duration, parked pinned AT the end), which repeat-one may
    /// replay. Before the discriminator existed, repeat-one replayed the same song on every
    /// CarPlay/lock-screen ⏭ and the set could never advance from the car.
    func testSkipParkAtZeroIsSystemSkip() {
        XCTAssertEqual(AppleMusicPlaybackProvider.endReason(
            stopped: false, paused: true, playbackTime: 0.3, expectedDuration: 200,
            maxObserved: 45, intentionalPause: false), .systemSkip)
    }

    func testSkipParkWithUnknownDurationIsSystemSkip() {
        XCTAssertEqual(AppleMusicPlaybackProvider.endReason(
            stopped: false, paused: true, playbackTime: 0, expectedDuration: 0,
            maxObserved: 30, intentionalPause: false), .systemSkip)
    }

    func testParkedPinnedAtTheEndIsNatural() {
        XCTAssertEqual(AppleMusicPlaybackProvider.endReason(
            stopped: false, paused: true, playbackTime: 199.8, expectedDuration: 200,
            maxObserved: 199.8, intentionalPause: false), .natural)
    }

    func testStoppedIsNatural() {
        XCTAssertEqual(AppleMusicPlaybackProvider.endReason(
            stopped: true, paused: false, playbackTime: 42, expectedDuration: 180,
            maxObserved: 42, intentionalPause: false), .natural)
    }

    func testPlayedPastDurationIsNatural() {
        XCTAssertEqual(AppleMusicPlaybackProvider.endReason(
            stopped: false, paused: false, playbackTime: 179.6, expectedDuration: 180,
            maxObserved: 179.6, intentionalPause: false), .natural)
    }

    func testListenerPauseMidSongHasNoEndReason() {
        XCTAssertNil(AppleMusicPlaybackProvider.endReason(
            stopped: false, paused: true, playbackTime: 90, expectedDuration: 180,
            maxObserved: 90, intentionalPause: false))
    }

    /// A ≤1 s track (jingle) parked at its end is BOTH ≤1.0 and atEnd — atEnd wins: natural.
    func testTinyTrackParkedAtItsEndIsNatural() {
        XCTAssertEqual(AppleMusicPlaybackProvider.endReason(
            stopped: false, paused: true, playbackTime: 0.8, expectedDuration: 1.0,
            maxObserved: 0.8, intentionalPause: false), .natural)
    }

    // MARK: - Pause vs park: the skip-storm-then-pause discriminator (Levi, 2026-08-20)

    /// THE bug: skip to a new track, then pause it within the first second. Position is
    /// near the top by construction (they just skipped there), so the old verdict read the
    /// pause as a park → `.systemSkip` → the set advanced to "a random song" on pause.
    /// An OUR-OWN pause of a barely-started track has no end reason at all.
    func testPauseOfJustStartedTrackIsNotASkip() {
        XCTAssertNil(AppleMusicPlaybackProvider.endReason(
            stopped: false, paused: true, playbackTime: 0.3, expectedDuration: 200,
            maxObserved: 0.3, intentionalPause: true))
    }

    func testPauseOfJustStartedTrackWithUnknownDurationIsNotASkip() {
        XCTAssertNil(AppleMusicPlaybackProvider.endReason(
            stopped: false, paused: true, playbackTime: 0, expectedDuration: 0,
            maxObserved: 0, intentionalPause: true))
    }

    /// Pause at 0:30, THEN the car ⏭: the park resets the position to 0 while `maxObserved`
    /// still holds 30 — a backward RESET can only be the system skip (a pause anchors at
    /// the pause point), so it must advance even though a pause was requested moments ago.
    func testCarSkipAfterIntentionalPauseStillAdvances() {
        XCTAssertEqual(AppleMusicPlaybackProvider.endReason(
            stopped: false, paused: true, playbackTime: 0, expectedDuration: 200,
            maxObserved: 30, intentionalPause: true), .systemSkip)
    }

    /// A rapid CarPlay ⏭ storm: the second press lands before the new track is 2 s in.
    /// No intentional pause was requested → still a skip, the set keeps advancing.
    func testRapidStormSecondSkipStillAdvances() {
        XCTAssertEqual(AppleMusicPlaybackProvider.endReason(
            stopped: false, paused: true, playbackTime: 0.2, expectedDuration: 200,
            maxObserved: 0.5, intentionalPause: false), .systemSkip)
    }

    /// The reset threshold: ≥2 s of real progress makes the park unambiguous (overrides the
    /// intentional-pause flag); below it, an intentional pause holds.
    func testResetThresholdBoundary() {
        XCTAssertEqual(AppleMusicPlaybackProvider.endReason(
            stopped: false, paused: true, playbackTime: 0, expectedDuration: 200,
            maxObserved: 2.0, intentionalPause: true), .systemSkip)
        XCTAssertNil(AppleMusicPlaybackProvider.endReason(
            stopped: false, paused: true, playbackTime: 0, expectedDuration: 200,
            maxObserved: 1.9, intentionalPause: true))
    }

    /// An intentional pause that happens to land pinned AT the end is still a natural end —
    /// the atEnd check outranks the pause flag (the track is over either way).
    func testIntentionalPausePinnedAtEndIsStillNatural() {
        XCTAssertEqual(AppleMusicPlaybackProvider.endReason(
            stopped: false, paused: true, playbackTime: 199.8, expectedDuration: 200,
            maxObserved: 199.8, intentionalPause: true), .natural)
    }
}

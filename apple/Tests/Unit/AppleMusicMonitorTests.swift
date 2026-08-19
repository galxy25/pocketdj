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
final class AppleMusicMonitorTests: XCTestCase {

    // MARK: - The states that were always "ended"

    func testStoppedIsEnded() {
        XCTAssertTrue(AppleMusicPlaybackProvider.trackEnded(
            stopped: true, paused: false, playbackTime: 42, expectedDuration: 180))
    }

    func testPlayedPastDurationIsEnded() {
        XCTAssertTrue(AppleMusicPlaybackProvider.trackEnded(
            stopped: false, paused: false, playbackTime: 179.6, expectedDuration: 180))
    }

    func testPlayingMidSongIsNotEnded() {
        XCTAssertFalse(AppleMusicPlaybackProvider.trackEnded(
            stopped: false, paused: false, playbackTime: 90, expectedDuration: 180))
    }

    func testPlayingWithUnknownDurationIsNotEnded() {
        // No catalog duration (expected 0) → the past-duration backstop must never fire.
        XCTAssertFalse(AppleMusicPlaybackProvider.trackEnded(
            stopped: false, paused: false, playbackTime: 500, expectedDuration: 0))
    }

    // MARK: - A real listener pause must still NOT advance

    func testPausedMidSongIsNotEnded() {
        // External pause from MusicKit's own card anchors AT the pause position —
        // the monitor keeps waiting, it must not skip the listener forward.
        XCTAssertFalse(AppleMusicPlaybackProvider.trackEnded(
            stopped: false, paused: true, playbackTime: 90, expectedDuration: 180))
    }

    func testPausedMidSongWithUnknownDurationIsNotEnded() {
        XCTAssertFalse(AppleMusicPlaybackProvider.trackEnded(
            stopped: false, paused: true, playbackTime: 50, expectedDuration: 0))
    }

    // MARK: - The system-skip parked states (the lock-screen/CarPlay ⏭ bug)

    func testPausedParkedAtZeroIsEnded() {
        // System ⏭ exhausted MusicKit's one-song queue → paused with the position reset.
        XCTAssertTrue(AppleMusicPlaybackProvider.trackEnded(
            stopped: false, paused: true, playbackTime: 0, expectedDuration: 180))
    }

    func testPausedParkedAtZeroWithUnknownDurationIsEnded() {
        XCTAssertTrue(AppleMusicPlaybackProvider.trackEnded(
            stopped: false, paused: true, playbackTime: 0.2, expectedDuration: 0))
    }

    func testPausedPinnedAtEndIsEnded() {
        XCTAssertTrue(AppleMusicPlaybackProvider.trackEnded(
            stopped: false, paused: true, playbackTime: 179.8, expectedDuration: 180))
    }

    // MARK: - The boundary of the parked-at-top window

    func testPausedJustInsideTopWindowIsEnded() {
        XCTAssertTrue(AppleMusicPlaybackProvider.trackEnded(
            stopped: false, paused: true, playbackTime: 1.0, expectedDuration: 180))
    }

    func testPausedJustPastTopWindowIsNotEnded() {
        XCTAssertFalse(AppleMusicPlaybackProvider.trackEnded(
            stopped: false, paused: true, playbackTime: 1.5, expectedDuration: 180))
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
            stopped: false, paused: true, playbackTime: 0.3, expectedDuration: 200), .systemSkip)
    }

    func testSkipParkWithUnknownDurationIsSystemSkip() {
        XCTAssertEqual(AppleMusicPlaybackProvider.endReason(
            stopped: false, paused: true, playbackTime: 0, expectedDuration: 0), .systemSkip)
    }

    func testParkedPinnedAtTheEndIsNatural() {
        XCTAssertEqual(AppleMusicPlaybackProvider.endReason(
            stopped: false, paused: true, playbackTime: 199.8, expectedDuration: 200), .natural)
    }

    func testStoppedIsNatural() {
        XCTAssertEqual(AppleMusicPlaybackProvider.endReason(
            stopped: true, paused: false, playbackTime: 42, expectedDuration: 180), .natural)
    }

    func testPlayedPastDurationIsNatural() {
        XCTAssertEqual(AppleMusicPlaybackProvider.endReason(
            stopped: false, paused: false, playbackTime: 179.6, expectedDuration: 180), .natural)
    }

    func testListenerPauseMidSongHasNoEndReason() {
        XCTAssertNil(AppleMusicPlaybackProvider.endReason(
            stopped: false, paused: true, playbackTime: 90, expectedDuration: 180))
    }

    /// A ≤1 s track (jingle) parked at its end is BOTH ≤1.0 and atEnd — atEnd wins: natural.
    func testTinyTrackParkedAtItsEndIsNatural() {
        XCTAssertEqual(AppleMusicPlaybackProvider.endReason(
            stopped: false, paused: true, playbackTime: 0.8, expectedDuration: 1.0), .natural)
    }
}

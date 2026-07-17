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
}

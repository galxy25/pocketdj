import XCTest
@testable import PocketDJ

/// Pure mute / solo / audibility logic for the synced stem player + the audition panel's clock
/// formatter — the "play all, then mute specific stems" semantics the SongDetail stem panel is
/// built to test. Actual multi-file AVAudioEngine playback needs real audio + a device and is
/// exercised manually (see the PR notes), not here; with no files loaded `startSynced` is a no-op,
/// so these exercise the state machine in isolation.
@MainActor
final class StemPlayerTests: XCTestCase {

    func testStemsAreTheFourCanonicalNames() {
        XCTAssertEqual(StemPlayer.stems, ["vocals", "drums", "bass", "other"])
    }

    func testFreshPlayerHasEveryStemAudible() {
        let p = StemPlayer()
        for name in StemPlayer.stems { XCTAssertTrue(p.isAudible(name)) }
        XCTAssertNil(p.soloed)
        XCTAssertFalse(p.isPlaying)
    }

    func testToggleMuteSilencesOnlyThatStem() {
        let p = StemPlayer()
        p.toggleMute("drums")
        XCTAssertFalse(p.isAudible("drums"))
        XCTAssertTrue(p.isAudible("vocals"))
        XCTAssertTrue(p.isAudible("bass"))
        XCTAssertTrue(p.isAudible("other"))
        p.toggleMute("drums")                    // un-mute
        XCTAssertTrue(p.isAudible("drums"))
    }

    func testSoloIsolatesAStemAndTogglesOff() {
        let p = StemPlayer()
        p.solo("vocals")
        XCTAssertEqual(p.soloed, "vocals")
        XCTAssertTrue(p.isAudible("vocals"))
        XCTAssertFalse(p.isAudible("drums"))
        XCTAssertFalse(p.isAudible("bass"))
        XCTAssertFalse(p.isAudible("other"))
        p.solo("vocals")                         // tapping the soloed stem again clears solo
        XCTAssertNil(p.soloed)
        for name in StemPlayer.stems { XCTAssertTrue(p.isAudible(name)) }
    }

    func testMutingClearsAnActiveSolo() {
        let p = StemPlayer()
        p.solo("bass")
        XCTAssertEqual(p.soloed, "bass")
        p.toggleMute("drums")                    // a mute toggle is independent of solo → clears it
        XCTAssertNil(p.soloed)
        XCTAssertFalse(p.isAudible("drums"))
        XCTAssertTrue(p.isAudible("bass"))
        XCTAssertTrue(p.isAudible("vocals"))
    }

    func testPlayAllResetsMuteAndSolo() {
        let p = StemPlayer()
        p.toggleMute("vocals")
        p.solo("drums")
        p.playAll()                              // "Play All" → every stem audible, in sync, from 0
        XCTAssertNil(p.soloed)
        for name in StemPlayer.stems { XCTAssertTrue(p.isAudible(name)) }
    }

    func testNotReadyUntilFilesLoad() {
        let p = StemPlayer()
        XCTAssertFalse(p.ready)
        XCTAssertNil(p.loadedSongId)
        XCTAssertEqual(p.duration, 0)
    }

    // MARK: Audition-panel clock

    func testClockFormatsMinutesSeconds() {
        XCTAssertEqual(StemAuditionPanel.clock(0), "0:00")
        XCTAssertEqual(StemAuditionPanel.clock(5), "0:05")
        XCTAssertEqual(StemAuditionPanel.clock(65), "1:05")
        XCTAssertEqual(StemAuditionPanel.clock(600), "10:00")
    }

    func testClockGuardsBadInput() {
        XCTAssertEqual(StemAuditionPanel.clock(-1), "0:00")
        XCTAssertEqual(StemAuditionPanel.clock(.infinity), "0:00")
        XCTAssertEqual(StemAuditionPanel.clock(.nan), "0:00")
    }
}

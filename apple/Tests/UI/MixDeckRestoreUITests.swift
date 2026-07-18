import XCTest

/// Durable Mix deck sessions — the restore UX. Launching with a persisted mid-mix snapshot
/// (the `PDJ_SEED_MIX_DECK_SESSION` seam writes one to the session file, exercising the REAL
/// load path; `PDJ_SEED_STUDIO` supplies the fixture items whose audio files actually exist)
/// rehydrates the Mix tab: both decks re-loaded ("Seeded Sample" / "Seeded Loop"), the Auto-DJ
/// queue back and SUSPENDED ("Auto-mix paused" banner = the up-next machine survived) — and
/// NOTHING auto-plays (the master transport still offers "Play both decks", and keeps offering
/// it). iPhone/iPad; macOS UI automation is unavailable headless in this environment.
final class MixDeckRestoreUITests: XCTestCase {
    override func setUp() { continueAfterFailure = false }

    func testRestoredMixShowsHeldDecksAndSuspendedAutoWithoutAutoPlay() throws {
        #if os(macOS)
        throw XCTSkip("restore deck exercised on iOS (macOS UI automation unavailable headless)")
        #else
        let app = XCUIApplication()
        app.launchEnvironment["PDJ_USE_FIXTURE"] = "1"
        app.launchEnvironment["PDJ_SEED_STUDIO"] = "1"            // fixture items + real audio files
        app.launchEnvironment["PDJ_SEED_MIX_DECK_SESSION"] = "1"  // the mid-mix snapshot on disk
        app.launchEnvironment["PDJ_START_SECTION"] = "Mix"
        app.launch()

        // Both decks came back from the snapshot — titles render from the SELF-CONTAINED
        // track refs (no catalog involvement; the audio resolved through the studio store).
        XCTAssertTrue(app.staticTexts["Seeded Sample"].waitForExistence(timeout: 25),
                      "Deck A restores its track")
        if !app.staticTexts["Seeded Loop"].exists { app.swipeUp() }   // stacked layout: B below the fold
        XCTAssertTrue(app.staticTexts["Seeded Loop"].waitForExistence(timeout: 8),
                      "Deck B restores its track")

        // The Auto-DJ queue restored SUSPENDED — the banner shows the paused machine (up
        // next intact behind it), never a silently self-resumed mix.
        app.swipeDown()
        XCTAssertTrue(app.staticTexts["Auto-mix paused"].waitForExistence(timeout: 8),
                      "the Auto-DJ comes back suspended, with its queue")
        XCTAssertTrue(app.descendants(matching: .any).matching(identifier: "mix-auto-resume")
                        .firstMatch.exists, "the existing Resume control re-arms it")

        // NOTHING auto-plays: the master transport still offers Play — and stays that way.
        let play = app.descendants(matching: .any).matching(identifier: "mix-play").firstMatch
        XCTAssertTrue(play.waitForExistence(timeout: 8))
        XCTAssertTrue(play.label.contains("Play"), "restore must not start audio (label was: \(play.label))")
        sleep(2)
        XCTAssertTrue(play.label.contains("Play"), "…and it stays held until the user acts")

        let shot = XCTAttachment(screenshot: app.screenshot())
        shot.name = "mix-restored-held"; shot.lifetime = .keepAlways; add(shot)
        #endif
    }
}

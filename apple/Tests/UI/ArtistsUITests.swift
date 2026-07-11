import XCTest

/// Artists browse kind — the 3rd Browser segment. Switch to Artists (⌘3 / the segment), see artist
/// rows, drill into an artist and confirm the detail page with Play all / Shuffle all.
/// Fixture (PDJ_USE_FIXTURE): artists Aria / Bento / Cobalt.
final class ArtistsUITests: XCTestCase {

    private func launch() -> XCUIApplication {
        let app = XCUIApplication()
        app.launchEnvironment["PDJ_USE_FIXTURE"] = "1"
        app.launchEnvironment["PDJ_START_SECTION"] = "Browser"
        app.launch()
        return app
    }

    @MainActor
    func testArtistsSegmentListsArtistsAndOpensDetail() {
        let app = launch()
        XCTAssertTrue(app.el("album-alb_1").waitForExistence(timeout: 20), "Browser should load")

        app.el("Artists").tap()   // the Albums | Songs | Artists segment
        XCTAssertTrue(app.any("artist-Aria").waitForExistence(timeout: 8), "artist rows should render")
        XCTAssertTrue(app.any("artist-Bento").exists)

        app.any("artist-Aria").tap()
        XCTAssertTrue(app.any("artist-detail").waitForExistence(timeout: 8), "artist detail should open")
        XCTAssertTrue(app.el("artist-play-all").exists)
        XCTAssertTrue(app.el("artist-shuffle-all").exists)
    }
}

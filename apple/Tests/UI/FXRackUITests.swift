import XCTest

/// The FX RACK on a Mix deck: four positional slots, each swappable to any effect (duplicates
/// allowed) with a variety picker flanking the strength control. Drives the real UI and writes a PNG
/// of each state so the layout can be eyeballed.
///
/// NOTE on timing: the revealed face auto-reverts after 3 s idle, so every interaction happens
/// IMMEDIATELY after its reveal — screenshots are taken from the settled chip, never mid-reveal.
/// XCUITest's synthetic press also needs to sit well past the 0.4 s `minimumDuration` to beat the
/// chip's tap gesture, hence 1.5 s.
final class FXRackUITests: XCTestCase {

    func testRackRendersFourSlotsWithEffectAndVarietyPickers() {
        let app = XCUIApplication()
        app.launchEnvironment["PDJ_USE_FIXTURE"] = "1"
        app.launchEnvironment["PDJ_START_SECTION"] = "Mix"
        app.launch()

        // --- All four slots render, in the default (pre-rack) layout ---
        XCTAssertTrue(app.any("deck-A-fx-slot-0").waitForExistence(timeout: 20),
                      "rack slot 0 should exist")
        for i in 0..<4 {
            XCTAssertTrue(app.any("deck-A-fx-slot-\(i)").exists, "rack slot \(i) should exist")
        }
        // The chips are labelled by SLOT + effect + variety (name-keyed ids can't work with
        // duplicates), and the default layout must match the pre-rack grid.
        XCTAssertEqual(app.any("deck-A-fx-slot-0").label, "Slot 1, Comp, Punch")
        XCTAssertEqual(app.any("deck-A-fx-slot-1").label, "Slot 2, Reverb, Hall")
        XCTAssertEqual(app.any("deck-A-fx-slot-2").label, "Slot 3, Flanger, Flanger")
        XCTAssertEqual(app.any("deck-A-fx-slot-3").label, "Slot 4, Filter, Low-pass")
        save(app, "01-rack-default-layout")

        // --- Long-press reveals the effect picker (LEFT) + variety picker (RIGHT) around strength ---
        app.any("deck-A-fx-slot-0").press(forDuration: 1.5)
        XCTAssertTrue(app.any("deck-A-fx-slot-0-effect").waitForExistence(timeout: 5),
                      "the effect picker should be revealed on the LEFT")
        XCTAssertTrue(app.any("deck-A-fx-slot-0-variant").exists,
                      "the variety picker should be revealed on the RIGHT")
        XCTAssertTrue(app.any("deck-A-fx-slot-0-strength").exists,
                      "the strength control should sit between them")
        save(app, "02-slot-revealed-with-both-pickers")
    }

    /// Swapping a slot's effect through the LEFT menu, verified on the chip itself. Kept separate
    /// from the render test so a menu-presentation flake can't mask the layout assertions.
    func testEffectMenuSwapsTheSlotsEffect() {
        let app = XCUIApplication()
        app.launchEnvironment["PDJ_USE_FIXTURE"] = "1"
        app.launchEnvironment["PDJ_START_SECTION"] = "Mix"
        app.launch()
        XCTAssertTrue(app.any("deck-A-fx-slot-0").waitForExistence(timeout: 20))
        XCTAssertEqual(app.any("deck-A-fx-slot-0").label, "Slot 1, Comp, Punch", "the default")

        // Reveal → open the effect menu → pick Filter, back-to-back (the face idle-reverts in 3 s).
        app.any("deck-A-fx-slot-0").press(forDuration: 1.5)
        let menu = app.any("deck-A-fx-slot-0-effect")
        XCTAssertTrue(menu.waitForExistence(timeout: 5), "effect menu should be revealed")
        menu.tap()
        let item = app.any("deck-A-fx-slot-0-effect-filter")
        XCTAssertTrue(item.waitForExistence(timeout: 5), "the menu should offer every effect family")
        item.tap()

        XCTAssertTrue(app.any("deck-A-fx-slot-0").waitForExistence(timeout: 5))
        XCTAssertEqual(app.any("deck-A-fx-slot-0").label, "Slot 1, Filter, Low-pass",
                       "slot 0 should now hold Filter at its family default variety")
        save(app, "03-slot0-swapped-to-filter")
    }

    // MARK: - Helpers (mirror the other Mix UI tests)

    private func save(_ app: XCUIApplication, _ name: String) {
        let shot = XCTAttachment(screenshot: app.screenshot())
        shot.name = name
        shot.lifetime = .keepAlways
        add(shot)
        let png = app.screenshot().pngRepresentation
        try? png.write(to: URL(fileURLWithPath: "/tmp/pdj-fxrack-\(name).png"))
    }
}

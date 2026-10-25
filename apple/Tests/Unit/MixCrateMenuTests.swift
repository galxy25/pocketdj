import SwiftUI
import XCTest
@testable import PocketDJ

/// The Mix crate picker must NOT re-render while a download run ticks (an open Menu that
/// re-renders snaps back to the top — the next crate could never be scrolled to). Equality is
/// what SwiftUI's `.equatable()` uses to skip those re-renders.
@MainActor
final class MixCrateMenuTests: XCTestCase {
    private let entries = [
        MixCrateEntry(section: "Pockets", name: "Chill", source: .pocket("p1")),
        MixCrateEntry(section: "Playlists", name: "Drive", source: .playlist("l1")),
        MixCrateEntry(section: "Pockets", name: "Hype", source: .pocket("p2")),
    ]

    private func menu(_ e: [MixCrateEntry], label: String, pick: @escaping (MixSource?) -> Void = { _ in })
        -> MixCrateMenu<Text> {
        MixCrateMenu(entries: e, labelText: label, onPick: pick) { Text(label) }
    }

    func testEqualityIgnoresThePickClosure() {
        var picked = 0
        XCTAssertEqual(menu(entries, label: "A · Chill"), menu(entries, label: "A · Chill", pick: { _ in picked += 1 }),
                       "a parent re-render rebuilds the closure — that alone must not re-render the menu")
    }

    func testLabelOrEntryChangesStillReRender() {
        XCTAssertNotEqual(menu(entries, label: "A · Chill"), menu(entries, label: "A · Drive"))
        XCTAssertNotEqual(menu(entries, label: "A · Chill"), menu(Array(entries.dropLast()), label: "A · Chill"))
    }

    func testSectionsKeepFirstAppearanceOrder() {
        XCTAssertEqual(MixCrateMenu<Text>.sections(entries), ["Pockets", "Playlists"])
    }

    func testEntryIdsAreUniquePerSource() {
        let same = [MixCrateEntry(section: "Pockets", name: "X", source: .pocket("a")),
                    MixCrateEntry(section: "Pockets", name: "X", source: .pocket("b"))]
        XCTAssertEqual(Set(same.map(\.id)).count, 2, "two pockets with one name are still two rows")
    }
}

import XCTest
@testable import PocketDJ

/// `AddToActions` — the add/remove/membership/quick-target logic the Add-to sheet and the
/// context-menu "Add to Playlist" submenu share.
@MainActor
final class AddToActionsTests: XCTestCase {

    private func makeStore(_ name: String = #function) -> CollectionsStore {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("pdj-addto-\(name)-\(UUID().uuidString).json")
        return CollectionsStore(fileURL: url)
    }

    func testToggleAddsThenRemovesAndMembershipFollows() {
        let store = makeStore()
        let pl = store.createPlaylist("Set")
        let target = AddTarget(kind: .playlist, id: pl.id, sequenceId: pl.sequences.first?.nodeId)
        let actions = AddToActions(item: .song("sng_1"), collections: store)
        XCTAssertFalse(actions.isMember(target))
        actions.toggle(target)
        XCTAssertTrue(actions.isMember(target))
        XCTAssertTrue(store.playlist(pl.id, contains: "sng_1"))
        actions.toggle(target)
        XCTAssertFalse(actions.isMember(target))
    }

    func testBatchAddReportsNothingLandedAndMemberOnlyWhenAllPresent() {
        let store = makeStore()
        let p = store.createPocket("Crate")
        let target = AddTarget(kind: .pocket, id: p.id)
        store.addSong("sng_1", toPocket: p.id)
        let actions = AddToActions(item: .songs(["sng_1", "sng_2"]), collections: store)
        XCTAssertFalse(actions.isMember(target))
        XCTAssertTrue(actions.add(target))
        XCTAssertTrue(actions.isMember(target))
        XCTAssertFalse(actions.add(target), "every id already present ⇒ nothing landed")
    }

    func testSuggestedDedupesAgainstRecentAndDropsUnresolvable() {
        let store = makeStore()
        let a = store.createPlaylist("A"), b = store.createPlaylist("B")
        let actions = AddToActions(item: .song("sng_9"), collections: store)
        actions.add(AddTarget(kind: .playlist, id: a.id))   // A is now Recent
        let recent = actions.recentTargets(limit: 5)
        XCTAssertEqual(recent.map(\.id), [a.id])
        let wire = [RecCollectionSuggestionWire(id: a.id, kind: "playlist"),
                    RecCollectionSuggestionWire(id: "pls_gone", kind: "playlist"),
                    RecCollectionSuggestionWire(id: b.id, kind: "playlist")]
        XCTAssertEqual(actions.suggestedTargets(wire, excluding: recent, limit: 5).map(\.id), [b.id])
    }
}

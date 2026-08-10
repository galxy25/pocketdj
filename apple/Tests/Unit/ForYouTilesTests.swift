import XCTest
@testable import PocketDJ

/// The tile ORDER is the owner's spec ("this and New should always be the top 2 tiles"), so it is
/// tested here rather than left to wherever a `ForEach` happens to put things.
final class ForYouTilesTests: XCTestCase {

    private func collections(_ counts: [(String, Int)]) -> [(id: String, kind: String, name: String, suggestions: [String])] {
        counts.map { name, n in
            (id: "c-\(name)", kind: "playlist", name: name,
             suggestions: (0..<n).map { "s\($0)" })
        }
    }

    // MARK: - The pinned pair

    func testNewIsAlwaysFirstAndZoneAlwaysSecond() {
        let tiles = ForYouTiles.build(newReleaseCount: 4, zone: ["a", "b"],
                                      collections: collections([("Gym", 30), ("Chill", 12)]))
        XCTAssertEqual(tiles[0].id, "new")
        XCTAssertEqual(tiles[1].id, "zone")
    }

    func testThePinnedPairSurvivesEvenWhenBothAreEmpty() {
        // A tile that vanishes at zero would make the fixed pair jump around, and "no releases
        // this month" is a real answer worth showing.
        let tiles = ForYouTiles.build(newReleaseCount: 0, zone: [], collections: [])
        XCTAssertEqual(tiles.map(\.id), ["new", "zone"])
        XCTAssertEqual(tiles[0].count, 0)
        XCTAssertEqual(tiles[1].count, 0)
        XCTAssertTrue(tiles.allSatisfy(\.isPinned))
    }

    func testAFloodOfCollectionsCannotDisplaceThePinnedPair() {
        let many = collections((0..<50).map { ("C\($0)", 100 - $0) })
        let tiles = ForYouTiles.build(newReleaseCount: 1, zone: ["x"], collections: many)
        XCTAssertEqual(tiles[0].id, "new")
        XCTAssertEqual(tiles[1].id, "zone")
        XCTAssertEqual(tiles.count, 52)
    }

    func testEmptyStateSubtitlesExplainThemselves() {
        let empty = ForYouTiles.build(newReleaseCount: 0, zone: [], collections: [])
        XCTAssertTrue(empty[0].subtitle.contains("No releases"))
        XCTAssertTrue(empty[1].subtitle.lowercased().contains("play"))
        let full = ForYouTiles.build(newReleaseCount: 3, zone: ["a"], collections: [])
        XCTAssertFalse(full[0].subtitle.contains("No releases"))
    }

    // MARK: - Counts + routes

    func testTileCountsReportTheUnderlyingSetSizes() {
        let tiles = ForYouTiles.build(newReleaseCount: 7, zone: Array(repeating: "s", count: 42),
                                      collections: collections([("Gym", 9)]))
        XCTAssertEqual(tiles[0].count, 7)
        XCTAssertEqual(tiles[1].count, 42)
        XCTAssertEqual(tiles[2].count, 9)
    }

    func testRoutesCarryTheKindAndTheCollectionId() {
        let tiles = ForYouTiles.build(newReleaseCount: 1, zone: ["a"],
                                      collections: collections([("Gym", 9)]))
        XCTAssertEqual(tiles[0].route.kind, .new)
        XCTAssertNil(tiles[0].route.collectionId)
        XCTAssertEqual(tiles[1].route.kind, .zone)
        XCTAssertEqual(tiles[2].route.kind, .collection)
        XCTAssertEqual(tiles[2].route.collectionId, "c-Gym")
        XCTAssertEqual(tiles[2].route.title, "Gym")
    }

    // MARK: - Which collections earn a tile

    func testACollectionWithTooFewSuggestionsGetsNoTile() {
        let tiles = ForYouTiles.build(
            newReleaseCount: 0, zone: [],
            collections: collections([("Thin", ForYouTiles.minCollectionSuggestions - 1),
                                      ("Fat", ForYouTiles.minCollectionSuggestions)]))
        XCTAssertEqual(tiles.map(\.title), ["New", "In Da Zone", "Fat"],
                       "only collections with something real to add get a tile")
    }

    func testCollectionTilesAreOrderedByHowMuchThereIsToAdd() {
        let tiles = ForYouTiles.build(newReleaseCount: 0, zone: [],
                                      collections: collections([("Small", 6), ("Big", 40),
                                                                ("Mid", 20)]))
        XCTAssertEqual(tiles.dropFirst(2).map(\.title), ["Big", "Mid", "Small"])
    }

    func testEqualCollectionsBreakTiesByNameForDeterminism() {
        let tiles = ForYouTiles.build(newReleaseCount: 0, zone: [],
                                      collections: collections([("Zulu", 8), ("Alpha", 8)]))
        XCTAssertEqual(tiles.dropFirst(2).map(\.title), ["Alpha", "Zulu"])
    }

    func testPocketAndPlaylistTilesUseDifferentSymbols() {
        let mixed: [(id: String, kind: String, name: String, suggestions: [String])] = [
            (id: "p1", kind: "pocket", name: "Pocket", suggestions: Array(repeating: "s", count: 9)),
            (id: "l1", kind: "playlist", name: "List", suggestions: Array(repeating: "s", count: 9)),
        ]
        let tiles = ForYouTiles.build(newReleaseCount: 0, zone: [], collections: mixed)
        let byTitle = Dictionary(uniqueKeysWithValues: tiles.map { ($0.title, $0) })
        XCTAssertEqual(byTitle["Pocket"]?.symbol, "square.stack")
        XCTAssertEqual(byTitle["List"]?.symbol, "music.note.list")
        XCTAssertEqual(byTitle["Pocket"]?.subtitle, "Suggested for this pocket")
    }

    // MARK: - The cloud engine's tile

    func testNoSuggestedTileWhenTheCloudEngineHasNothing() {
        // The engine is default-OFF, so this is the normal case: no empty tile for a feature the
        // user has not turned on.
        let tiles = ForYouTiles.build(newReleaseCount: 0, zone: [], collections: [],
                                      cloudSuggestionCount: 0)
        XCTAssertFalse(tiles.contains { $0.id == "suggested" })
    }

    func testSuggestedTileSitsAfterThePinnedPairAndBeforeCollections() {
        let tiles = ForYouTiles.build(newReleaseCount: 0, zone: [],
                                      collections: collections([("Gym", 9)]),
                                      cloudSuggestionCount: 12)
        XCTAssertEqual(tiles.map(\.id), ["new", "zone", "suggested", "col-c-Gym"])
        XCTAssertEqual(tiles[2].count, 12)
        XCTAssertEqual(tiles[2].route.kind, .suggested)
        XCTAssertFalse(tiles[2].isPinned)
    }

    func testTileIdsAreUniqueSoTheGridDoesNotCollapseRows() {
        let tiles = ForYouTiles.build(newReleaseCount: 1, zone: ["a"],
                                      collections: collections([("A", 9), ("B", 9)]),
                                      cloudSuggestionCount: 3)
        XCTAssertEqual(Set(tiles.map(\.id)).count, tiles.count)
    }
}

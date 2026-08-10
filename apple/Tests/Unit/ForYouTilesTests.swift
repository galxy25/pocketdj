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

    /// The New tile's badge counts BOTH states, but only one of them is bounded by 30 days —
    /// `classify` puts no upper bound on the future side, so a pre-order shipping in three months
    /// is in that number. "last 30 days" over a count containing it is false in a way the reader
    /// cannot detect, because the number itself looks right.
    func testNewSubtitleDoesNotClaimThirtyDaysOverFutureDatedReleases() {
        let soonOnly = ForYouTiles.build(newReleaseCount: 2, comingSoonCount: 2, zone: [],
                                         collections: [])
        XCTAssertEqual(soonOnly[0].count, 2)
        XCTAssertFalse(soonOnly[0].subtitle.contains("30 days"),
                       "nothing is out yet — do not date the tile by a window it does not use")
        XCTAssertTrue(soonOnly[0].subtitle.lowercased().contains("upcoming"))

        let mixed = ForYouTiles.build(newReleaseCount: 5, comingSoonCount: 2, zone: [],
                                      collections: [])
        XCTAssertEqual(mixed[0].count, 5, "the badge is still the whole feed")
        XCTAssertTrue(mixed[0].subtitle.contains("30 days"))
        XCTAssertTrue(mixed[0].subtitle.lowercased().contains("upcoming"))

        let pastOnly = ForYouTiles.build(newReleaseCount: 4, comingSoonCount: 0, zone: [],
                                         collections: [])
        XCTAssertEqual(pastOnly[0].subtitle, "From artists you play · last 30 days")
        XCTAssertFalse(pastOnly[0].subtitle.lowercased().contains("upcoming"))
    }

    func testNewSubtitleStaysTheEmptyAnswerWhenNothingIsInTheFeedAtAll() {
        XCTAssertEqual(ForYouTiles.newReleaseSubtitle(outNow: 0, comingSoon: 0),
                       "No releases in the last 30 days")
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

    /// The owner's wording is the spec: "one tile for **each** collection that we have suggestions
    /// of items to add to". The threshold was 5 for a while, which quietly gave a collection with
    /// three genuinely good additions no way in — a product opinion overriding an instruction.
    func testACollectionWithASingleSuggestionStillEarnsItsTile() {
        XCTAssertEqual(ForYouTiles.minCollectionSuggestions, 1,
                       "having a suggestion IS having something to add")
        let tiles = ForYouTiles.build(newReleaseCount: 0, zone: [],
                                      collections: collections([("Sparse", 1), ("Three", 3)]))
        XCTAssertEqual(tiles.map(\.title), ["New", "In Da Zone", "Three", "Sparse"])
    }

    /// …and a collection with genuinely nothing to add still gets nothing. That is the only
    /// emptiness this function has to enforce; the rest is upstream.
    func testACollectionWithNoSuggestionsGetsNoTile() {
        let tiles = ForYouTiles.build(newReleaseCount: 0, zone: [],
                                      collections: collections([("Nothing", 0)]))
        XCTAssertEqual(tiles.map(\.id), ["new", "zone"])
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

    func testTileIdsAreUniqueSoTheGridDoesNotCollapseRows() {
        let tiles = ForYouTiles.build(newReleaseCount: 1, zone: ["a"],
                                      collections: collections([("A", 9), ("B", 9)]))
        XCTAssertEqual(Set(tiles.map(\.id)).count, tiles.count)
    }

    // ========================================================================
    // MARK: - The Suggested tile is GONE
    // ========================================================================

    /// Owner, verbatim: *"remove Suggested tile (that is what New and In Da Zone [are])"*. The
    /// engine's content did not disappear with it — it moved INSIDE In Da Zone — so the thing to
    /// protect is that no third whole-library tile can come back by accident.
    func testThereIsNoSuggestedTileUnderAnyInput() {
        for cloud in [ForYouTileSource.onDevice, .cloud] {
            let tiles = ForYouTiles.build(newReleaseCount: 3, zone: ["a", "b"], zoneSource: cloud,
                                          collections: collections([("Gym", 9)]))
            XCTAssertEqual(tiles.map(\.id), ["new", "zone", "col-c-Gym"],
                           "the grid is New, In Da Zone, then collections — nothing between them")
            XCTAssertFalse(tiles.contains { $0.title == "Suggested" })
        }
    }

    // ========================================================================
    // MARK: - Source attribution
    // ========================================================================

    /// Without this the owner cannot tell a cloud regression from an on-device one — the tile
    /// looks identical either way, and a week of silent fallback is indistinguishable from a
    /// working engine.
    func testTheZoneTileSaysWhichRankerProducedIt() {
        let cloud = ForYouTiles.build(newReleaseCount: 0, zone: ["a", "b"], zoneSource: .cloud,
                                      collections: [])
        XCTAssertEqual(cloud[1].source, .cloud)
        XCTAssertTrue(cloud[1].subtitle.lowercased().contains("recommendation engine"),
                      "the attribution is legible on the card, not only in a log")

        let local = ForYouTiles.build(newReleaseCount: 0, zone: ["a", "b"], zoneSource: .onDevice,
                                      collections: [])
        XCTAssertEqual(local[1].source, .onDevice)
        XCTAssertFalse(local[1].subtitle.lowercased().contains("recommendation engine"))
        XCTAssertNotEqual(cloud[1].subtitle, local[1].subtitle,
                          "two rankers, two readable answers")
    }

    /// The default is the on-device path, because the engine is opt-in and ships OFF. A caller
    /// that says nothing about the source must never claim the cloud produced its tile.
    func testTilesDefaultToTheOnDeviceAttribution() {
        let tiles = ForYouTiles.build(newReleaseCount: 2, zone: ["a"],
                                      collections: collections([("Gym", 4)]))
        XCTAssertTrue(tiles.allSatisfy { $0.source == .onDevice })
    }

    /// NEW IS ALWAYS ON-DEVICE, and that is a finding rather than an oversight: `/recs/songs`
    /// ranks over the user's OWN catalog, and New is by definition the releases he does not own.
    func testNewIsAlwaysAttributedToTheDeviceEvenWhileTheZoneIsCloudRanked() {
        let tiles = ForYouTiles.build(newReleaseCount: 5, zone: ["a"], zoneSource: .cloud,
                                      collections: [])
        XCTAssertEqual(tiles[0].source, .onDevice)
        XCTAssertEqual(tiles[1].source, .cloud)
    }

    /// An empty tile has one useful thing to say and it is not the name of the ranker that found
    /// nothing.
    func testAnEmptyZoneTellsTheOwnerWhatToDoRatherThanWhoRankedIt() {
        for source in [ForYouTileSource.onDevice, .cloud] {
            let subtitle = ForYouTiles.zoneSubtitle(count: 0, source: source)
            XCTAssertEqual(subtitle, "Play a few songs to build your zone")
        }
    }
}

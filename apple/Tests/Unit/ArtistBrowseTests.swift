import XCTest
@testable import PocketDJ

/// The Artists browse kind: AppModel groups albums by artist, and the shared FilterEngine/SortEngine
/// work over artist rows (name + album/song counts) with no artist-specific engine.
/// Fixture (StubLoader): alb_1 Aria (sng_1,2,3), alb_2 Bento (sng_4,5), alb_3 Cobalt (sng_6,7).
@MainActor
final class ArtistBrowseTests: XCTestCase {

    private func artistTuples(_ items: [BrowseItem]) -> [(name: String, albums: Int, songs: Int)] {
        items.compactMap { if case .artist(let n, let a, let s, _) = $0 { return (n, a, s) } else { return nil } }
    }

    func testArtistBrowseItemsGroupAlbumsByArtistInOrder() async {
        let app = AppModel(loader: TestData.StubLoader())
        await app.loadIfNeeded()
        let artists = artistTuples(app.artistBrowseItems)
        XCTAssertEqual(artists.map(\.name), ["Aria", "Bento", "Cobalt"])   // artist order
        let aria = artists.first { $0.name == "Aria" }
        XCTAssertEqual(aria?.albums, 1)
        XCTAssertEqual(aria?.songs, 3)
        XCTAssertEqual(artists.first { $0.name == "Bento" }?.songs, 2)
        // browseItems(.artist) returns the same set; searchKeys are parallel + folded.
        XCTAssertEqual(app.browseItems(.artist).count, 3)
        XCTAssertEqual(app.searchKeys(.artist).count, 3)
        XCTAssertTrue(app.searchKeys(.artist).contains { $0.contains("aria") })   // folded lowercase
    }

    /// A merged catalog whose sources disagree on artist-name casing must still collapse to ONE
    /// artist row (case-insensitive grouping matches the case-insensitive album sort) — else the
    /// artist splits into rows with a duplicate `artist:<name>` id.
    func testArtistGroupingIsCaseInsensitive() throws {
        let json = """
        [ {"id":"a1","artist":"OutKast","name":"Aquemini","trackList":["s1"]},
          {"id":"a2","artist":"Outkast","name":"Idlewild","trackList":["s2"]},
          {"id":"a3","artist":"OUTKAST","name":"Stankonia","trackList":["s3","s4"]} ]
        """.data(using: .utf8)!
        let albums = try JSONDecoder().decode([IndexAlbum].self, from: json)
        let eff = AppModel.buildEffective(rawAlbums: albums, rawSongs: [],
                                          albumSourceById: [:], songSourceById: [:],
                                          albumEdits: [:], songEdits: [:])
        let artists = artistTuples(eff.artistBrowseItems)
        XCTAssertEqual(artists.count, 1, "case-only variants must be ONE artist, not three rows")
        XCTAssertEqual(artists.first?.albums, 3)
        XCTAssertEqual(artists.first?.songs, 4)
        // No duplicate artist ids.
        let ids = eff.artistBrowseItems.map(\.id)
        XCTAssertEqual(Set(ids).count, ids.count)
    }

    private func artist(_ name: String, _ albums: Int, _ songs: Int) -> BrowseItem {
        .artist(name: name, albumCount: albums, songCount: songs)
    }

    func testArtistSortAndFilterThroughSharedEngine() {
        let items = [artist("Cobalt", 1, 2), artist("Aria", 3, 12), artist("Bento", 2, 5)]
        // Sort by artist name.
        XCTAssertEqual(SortEngine.apply(items, [SortKey(field: "artist", dir: .asc)]).map(\.id),
                       ["artist:Aria", "artist:Bento", "artist:Cobalt"])
        // Sort by album count (desc).
        XCTAssertEqual(SortEngine.apply(items, [SortKey(field: "albumCount", dir: .desc)]).map(\.id),
                       ["artist:Aria", "artist:Bento", "artist:Cobalt"])
        // Filter: artists with ≥ 2 albums.
        var c = Clause(field: "albumCount", op: .between); c.min = 2; c.max = 99
        XCTAssertEqual(Set(FilterEngine.apply(items, [c]).map(\.id)), ["artist:Aria", "artist:Bento"])
    }
}

import XCTest
@testable import PocketDJ

/// CollectionsStore.historyContext — resolves the Play-History source-kind + name for a
/// sequencer run tagged with `sourceSetlistId`. Album / playlist / pocket / single all realize
/// into the ONE reserved Now Playing setlist, so the kind comes from `nowPlayingSource` (stamped
/// by playNow) while the name is the reserved setlist's (which playNow names after the source).
@MainActor
final class PlayHistoryContextTests: XCTestCase {

    private var heldApp: AppModel?
    override func tearDown() { heldApp = nil; super.tearDown() }

    private func wiredStore() async -> CollectionsStore {
        let app = AppModel(loader: TestData.StubLoader())
        await app.loadIfNeeded()
        heldApp = app
        let s = CollectionsStore(fileURL: FileManager.default.temporaryDirectory
            .appendingPathComponent("pdj-histctx-\(UUID().uuidString).json"))
        s.app = app
        return s
    }

    /// The id the sequencer is tagged with for album/playlist/pocket/single plays.
    private func nowPlayingId(_ s: CollectionsStore) -> String? { s.nowPlayingSetlist()?.id }

    func testPlaylistPlayResolvesToPlaylistKindAndName() async {
        let s = await wiredStore()
        let pl = s.createPlaylist("Roadtrip")
        s.addSong("sng_1", toPlaylist: pl.id)
        s.playNow(playlistId: pl.id)
        let ctx = s.historyContext(forSourceSetlistId: nowPlayingId(s))
        XCTAssertEqual(ctx.source, .playlist)
        XCTAssertEqual(ctx.name, "Roadtrip")
    }

    func testPocketPlayResolvesToPocketKindAndName() async {
        let s = await wiredStore()
        let p = s.createPocket("Warmup")
        s.addSong("sng_1", toPocket: p.id)
        s.playNow(pocketId: p.id)
        let ctx = s.historyContext(forSourceSetlistId: nowPlayingId(s))
        XCTAssertEqual(ctx.source, .pocket)
        XCTAssertEqual(ctx.name, "Warmup")
    }

    func testAlbumPlayResolvesToAlbumKindAndName() async {
        let s = await wiredStore()
        s.playNow(songIds: ["sng_1", "sng_2"], name: "Greatest Hits", source: .album)
        let ctx = s.historyContext(forSourceSetlistId: nowPlayingId(s))
        XCTAssertEqual(ctx.source, .album)
        XCTAssertEqual(ctx.name, "Greatest Hits")
    }

    /// A single-song play (`.browser`) carries no set name — the row reads just "Browser".
    func testSingleSongPlayResolvesToBrowserWithNoName() async {
        let s = await wiredStore()
        s.playNow(songIds: ["sng_1"], name: "Some Song", source: .browser)
        let ctx = s.historyContext(forSourceSetlistId: nowPlayingId(s))
        XCTAssertEqual(ctx.source, .browser)
        XCTAssertNil(ctx.name)
    }

    /// nil / unknown source id → a generic set list (defensive default).
    func testNilSourceDefaultsToSetlist() async {
        let s = await wiredStore()
        let ctx = s.historyContext(forSourceSetlistId: nil)
        XCTAssertEqual(ctx.source, .setlist)
        XCTAssertNil(ctx.name)
    }
}

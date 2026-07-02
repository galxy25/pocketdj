import XCTest
@testable import PocketDJ

/// Tests for `AppModel.album(forSongId:)` — the resolver that backs the lock-screen /
/// Control Center Now Playing card's cover art (song id → its album's `artCandidates`,
/// which `PlayerEngine` fetches + attaches to `MPNowPlayingInfoCenter`). Runs against
/// the shared TestData catalog: alb_1 = sng_1, sng_2, sng_3.
@MainActor
final class NowPlayingArtworkTests: XCTestCase {

    private func loadedApp() async -> AppModel {
        let app = AppModel(loader: TestData.StubLoader())
        await app.loadIfNeeded()
        return app
    }

    /// A catalog song resolves to the album that lists it — the URL source the card uses.
    func testAlbumForSongIdResolvesOwningAlbum() async {
        let app = await loadedApp()
        let album = app.album(forSongId: "sng_1")
        XCTAssertNotNil(album, "sng_1 should resolve to its owning album")
        XCTAssertTrue(album?.trackList.contains("sng_1") == true,
                      "resolved album must list the song it was looked up by")
    }

    /// An id with no catalog song (e.g. an ad-hoc rip) resolves to nil ⇒ the card shows
    /// title + artist only, no artwork ("if available").
    func testAlbumForUnknownSongIdIsNil() async {
        let app = await loadedApp()
        XCTAssertNil(app.album(forSongId: "sng_does_not_exist"),
                     "an unindexed song id must resolve to nil (no artwork attached)")
    }
}

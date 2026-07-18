import XCTest
@testable import PocketDJ

/// The Up Next header's collection button — origin capture + durable-session round-trip
/// (the ghost-state fix): playNow records the origin collection, originCollection maps a
/// run's sourceSetlistId to it, and SourceRef persists/decodes it (old snapshots too).
@MainActor
final class UpNextOriginTests: XCTestCase {

    private func store() -> CollectionsStore {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("pdj-upnext-\(UUID().uuidString).json")
        addTeardownBlock { try? FileManager.default.removeItem(at: url) }
        return CollectionsStore(fileURL: url)
    }

    func testPlaylistPlayNowRecordsOrigin() async {
        let app = AppModel(loader: TestData.StubLoader())
        await app.loadIfNeeded()
        let s = store()
        s.app = app
        let pl = s.createPlaylist("Warmup")
        s.addSong("sng_1", toPlaylist: pl.id)
        _ = s.playNow(playlistId: pl.id)

        let origin = s.originCollection(forSourceSetlistId: nowPlayingSetlistId)
        XCTAssertEqual(origin?.kind, .playlist)
        XCTAssertEqual(origin?.id, pl.id)
    }

    func testDirectSongIdsPlayHasNoOrigin() async {
        let app = AppModel(loader: TestData.StubLoader())
        await app.loadIfNeeded()
        let s = store()
        s.app = app
        _ = s.playNow(songIds: ["sng_1"], name: "Single", source: .browser)
        XCTAssertNil(s.originCollection(forSourceSetlistId: nowPlayingSetlistId),
                     "browser singles have no navigable origin — the button hides")
    }

    func testRealSetlistIsItsOwnOrigin() async {
        let app = AppModel(loader: TestData.StubLoader())
        await app.loadIfNeeded()
        let s = store()
        s.app = app
        guard let sl = s.realize(songIds: ["sng_1"], name: "Frozen Set") else {
            return XCTFail("realize failed")
        }
        let origin = s.originCollection(forSourceSetlistId: sl.id)
        XCTAssertEqual(origin?.kind, .setlist)
        XCTAssertEqual(origin?.id, sl.id)
    }

    /// SourceRef gained originKind/originId as OPTIONAL keys — a pre-existing snapshot
    /// (no keys) must still decode, and a new one must round-trip them.
    func testSourceRefOriginRoundTripAndBackCompat() throws {
        let new = PlaybackSessionStore.SourceRef(kind: "playlist", id: "set_now_playing",
                                                 name: "Warmup", originKind: "playlist",
                                                 originId: "pls_1")
        let decoded = try JSONDecoder().decode(PlaybackSessionStore.SourceRef.self,
                                               from: JSONEncoder().encode(new))
        XCTAssertEqual(decoded.originKind, "playlist")
        XCTAssertEqual(decoded.originId, "pls_1")

        let legacy = #"{"kind":"setlist","id":"set_1","name":"Old"}"#.data(using: .utf8)!
        let old = try JSONDecoder().decode(PlaybackSessionStore.SourceRef.self, from: legacy)
        XCTAssertNil(old.originKind)
        XCTAssertNil(old.originId)
    }
}

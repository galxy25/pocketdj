import XCTest
@testable import PocketDJ

/// WS2 Apple Music playlist sync — the testable (non-device) logic: the PUSH payload resolution
/// (PocketDJ playlists -> Apple Music catalog ids, dropping the un-hostable) and the PULL decode.
/// The token mint + live HTTP are device-only and verified separately (server side via curl).
@MainActor
final class AMPlaylistSyncTests: XCTestCase {

    private func tempURL(_ tag: String) -> URL {
        let u = FileManager.default.temporaryDirectory
            .appendingPathComponent("pdj-\(tag)-\(UUID().uuidString).json")
        addTeardownBlock { try? FileManager.default.removeItem(at: u) }
        return u
    }

    private func song(_ id: String, am: String?) -> IndexSong {
        var o: [String: Any] = ["id": id, "name": id, "artist": "A"]
        if let am { o["appleMusicId"] = am }
        return try! JSONDecoder().decode(IndexSong.self, from: try! JSONSerialization.data(withJSONObject: o))
    }

    /// resolveOutgoing keeps only playlists with Apple-Music-hostable songs, mapping each song id to
    /// its catalog id (appleMusicId) in order and dropping songs (and whole playlists) without one.
    func testResolveOutgoingResolvesCatalogIdsAndDropsEmpties() {
        let app = AppModel()
        app.injectDiscoverAdd(song("s1", am: "111"))
        app.injectDiscoverAdd(song("s2", am: "222"))
        app.injectDiscoverAdd(song("s3", am: nil))   // no catalog id -> never pushed
        let collections = CollectionsStore(fileURL: tempURL("col"))
        collections.app = app
        _ = collections.createPlaylist("Mix", songIds: ["s1", "s3", "s2"])
        _ = collections.createPlaylist("NoneHostable", songIds: ["s3"])

        let out = PlaylistAppleMusicSync.resolveOutgoing(collections: collections, app: app)
        // Only "Mix" survives (it has hostable songs); "NoneHostable" is dropped entirely.
        XCTAssertEqual(out.count, 1)
        XCTAssertEqual(out.first?.name, "Mix")
        // s3 (no appleMusicId) is dropped; order of the survivors is preserved.
        XCTAssertEqual(out.first?.trackCatalogIds, ["111", "222"])
    }

    /// A remote playlist row from the Lambda's /pull decodes (optional fields tolerated).
    func testRemotePlaylistDecodes() throws {
        let pl = try JSONDecoder().decode(AMPlaylistSyncClient.RemotePlaylist.self, from: Data("""
        {"id":"p.1","name":"Faves","canEdit":true,"trackCatalogIds":["111","222"]}
        """.utf8))
        XCTAssertEqual(pl.id, "p.1")
        XCTAssertEqual(pl.name, "Faves")
        XCTAssertEqual(pl.canEdit, true)
        XCTAssertEqual(pl.trackCatalogIds, ["111", "222"])
        XCTAssertNil(pl.trackTitles)
    }

    /// A push result (created + errors) decodes.
    func testPushResultDecodes() throws {
        let r = try JSONDecoder().decode(AMPlaylistSyncClient.PushResult.self, from: Data("""
        {"created":[{"name":"Mix","id":"p.abc"}],"errors":[{"name":"Bad","error":"AM POST -> 403"}]}
        """.utf8))
        XCTAssertEqual(r.created.first?.id, "p.abc")
        XCTAssertEqual(r.errors.first?.name, "Bad")
    }
}

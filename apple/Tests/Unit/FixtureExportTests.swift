import XCTest
@testable import PocketDJ

/// OPT-IN fixture exporter (ANS-SVC-2). Skips unless `PDJ_FIXTURE_OUT` names a directory.
/// Builds a representative SYNTHETIC store (no real library data) and runs the REAL exporters
/// (BackupZip / PocketZip / PlaylistZip via the store) so the Android JVM tests can import bytes
/// iOS actually wrote. Driven by `apple/scripts/export-android-fixtures.sh`.
///
/// Fixed ids/names matter: `IosRealFixtureTest.kt` asserts them.
final class FixtureExportTests: XCTestCase {

    @MainActor
    func testExportAndroidFixtures() async throws {
        guard let out = ProcessInfo.processInfo.environment["PDJ_FIXTURE_OUT"], !out.isEmpty else {
            throw XCTSkip("PDJ_FIXTURE_OUT not set — opt-in fixture export")
        }
        let dir = URL(fileURLWithPath: out, isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)

        let app = AppModel(loader: TestData.StubLoader())
        await app.loadIfNeeded()
        let tmp = FileManager.default.temporaryDirectory
        let s = CollectionsStore(fileURL: tmp.appendingPathComponent("pdj-fx-\(UUID().uuidString).json"))
        s.app = app

        // Folder + nested pockets (Warmups > Chill), flags, repeats, a note.
        let folder = s.createFolder("Gigs")
        let chill = s.createPocket("Chill", songIds: ["sng_3", "sng_5"])
        let warm = s.createPocket("Warmups", songIds: ["sng_1", "sng_2"])
        s.addAlbum("alb_2", toPocket: warm.id)
        XCTAssertTrue(s.addChildPocket(chill.id, toPocket: warm.id))
        s.setSongRepeat("sng_1", count: 3, inPocket: warm.id)
        _ = s.addNote("Open with the horns", toPocket: warm.id)
        s.setCleanOnly(true, forPocket: warm.id)
        s.setRecommendationsEnabled(false, forPocket: warm.id)
        s.setAMSyncDirection(.pull, forPocket: warm.id)
        s.setPocketFolder(warm.id, folderId: folder.id)

        // Multi-chapter playlist referencing the pocket, an album, a text cue.
        let pl = s.createPlaylist("Night Set", songIds: ["sng_6", "sng_7"])
        s.addPocketRef(warm.id, toPlaylist: pl.id)
        s.addAlbum("alb_3", toPlaylist: pl.id)
        s.addSequence("Peak", toPlaylist: pl.id)
        let peak = try XCTUnwrap(s.playlist(pl.id)?.sequences.last?.nodeId)
        s.addSong("sng_4", toPlaylist: pl.id, sequenceId: peak, repeatCount: 2)
        s.addText("Lights down", toPlaylist: pl.id, sequenceId: peak)
        s.setCleanOnly(true, forPlaylist: pl.id)
        s.setRecommendationsEnabled(false, forPlaylist: pl.id)
        s.setAMSyncDirection(.push, forPlaylist: pl.id)
        s.setPlaylistFolder(pl.id, folderId: folder.id)
        _ = s.realize(playlistId: pl.id, seed: "fixture-seed")
        // amPlaylistId must NEVER travel (ANS-COL-1).
        s.linkToAppleMusic(pocketId: warm.id, amPlaylistId: "p.FIXTURE_AM_POCKET")
        s.linkToAppleMusic(playlistId: pl.id, amPlaylistId: "p.FIXTURE_AM_PLAYLIST")

        // Favorites (+ tombstone) and edits.
        let fav = FavoritesStore(fileURL: tmp.appendingPathComponent("pdj-fx-fav-\(UUID().uuidString).json"))
        fav.set("sng_1", favorited: true, appleMusicId: "111")
        fav.set("sng_2", favorited: true, appleMusicId: nil)
        fav.set("sng_3", favorited: false, appleMusicId: nil)
        let edits = EditsStore(fileURL: tmp.appendingPathComponent("pdj-fx-edits-\(UUID().uuidString).json"))
        var ae = AlbumEdit(); ae.year = 1999; ae.genre = "Fixture"
        edits.setAlbum("alb_1", ae)
        var se = SongEdit(); se.bpm = 101; se.name = "Neon (Edit)"
        edits.setSong("sng_1", se)

        let sources = [SourceConfig(name: "Fixture Crate", urlString: "https://example.com/index.json")]
        let backup = try BackupZip.export(sources: sources, pockets: s.pockets, playlists: s.playlists,
                                          setlists: s.setlists, folders: s.folders,
                                          editsData: try edits.exportData(), favoritesData: fav.exportData())
        try backup.write(to: dir.appendingPathComponent("backup.pocketdj.zip"))
        try XCTUnwrap(try s.exportPocketZip(warm.id)).write(to: dir.appendingPathComponent("pocket.pdjcollection"))
        try XCTUnwrap(try s.exportPlaylistZip(pl.id)).write(to: dir.appendingPathComponent("playlist.pdjcollection"))
    }
}

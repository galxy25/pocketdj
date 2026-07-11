import XCTest
@testable import PocketDJ

/// CarPlayModel — the template-agnostic heart of the CarPlay app (browse lists → songs,
/// title/artist search, play a collection/song, add a song to a pocket/playlist). The CarPlay
/// scene is a thin adapter over these, so this is where the CarPlay logic is verified.
///
/// Catalog (TestData): alb_1 "Night Drive"/Aria = sng_1 "Neon", sng_2, sng_3; alb_2 = sng_4,5; alb_3 = sng_6,7.
@MainActor
final class CarPlayModelTests: XCTestCase {

    private func makeModel() async -> (CarPlayModel, IntentServices, CollectionsStore) {
        let app = AppModel(loader: TestData.StubLoader())
        await app.loadIfNeeded()
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("pdj-cp-\(UUID().uuidString).json")
        addTeardownBlock { try? FileManager.default.removeItem(at: url) }
        let collections = CollectionsStore(fileURL: url)
        collections.app = app
        let settings = SettingsStore(defaults: UserDefaults(suiteName: "test.\(UUID())")!)
        let rips = RipsStore(ripsBase: URL(string: "https://rips.test")!, session: URLSession(configuration: .ephemeral))
        let player = PlayerEngine()
        let burnsURL = FileManager.default.temporaryDirectory.appendingPathComponent("pdj-cp-burns-\(UUID().uuidString).json")
        addTeardownBlock { try? FileManager.default.removeItem(at: burnsURL) }
        let burns = BurnStore(rips: rips, fileURL: burnsURL)
        let coordinator = PlaybackCoordinator(
            ripProvider: RipServerPlaybackProvider(rips: rips, player: player),
            appleMusic: AppleMusicPlaybackProvider(provider: AppleMusicProvider()))
        let sequencer = SetlistPlayer(player: player, rips: rips, burns: burns, coordinator: coordinator)
        let services = IntentServices(app: app, settings: settings, collections: collections,
                                      setlistPlayer: sequencer, mix: MixEngine(burns: burns), burns: burns, rips: rips)
        return (CarPlayModel(services: services), services, collections)
    }

    // MARK: Browse

    func testAlbumsListCatalogAlbums() async {
        let (model, _, _) = await makeModel()
        let albums = model.albums()
        XCTAssertTrue(albums.contains { $0.id == "alb_1" && $0.title == "Night Drive" && $0.subtitle == "Aria" })
        XCTAssertFalse(albums.first { $0.id == "alb_1" }!.isSong)
    }

    func testSongsInAlbumResolvesOrderedTrackList() async {
        let (model, _, _) = await makeModel()
        let rows = model.songs(inAlbum: "alb_1")
        XCTAssertEqual(rows.map(\.id), ["sng_1", "sng_2", "sng_3"])
        XCTAssertEqual(rows[0].title, "Neon")
        XCTAssertEqual(rows[0].subtitle, "Aria")
        XCTAssertTrue(rows[0].isSong)
        XCTAssertEqual(rows[0].artworkAlbumId, "alb_1")
    }

    func testPlaylistsAndPocketsListWithCountsAndDrill() async {
        let (model, _, collections) = await makeModel()
        let pl = collections.createPlaylist("Evening")
        collections.addSong("sng_1", toPlaylist: pl.id)
        collections.addSong("sng_4", toPlaylist: pl.id)
        let pk = collections.createPocket("Warmup")
        collections.addSong("sng_2", toPocket: pk.id)

        let playlists = model.playlists()
        XCTAssertEqual(playlists.first { $0.id == pl.id }?.subtitle, "2 songs")
        XCTAssertEqual(model.songs(inPlaylist: pl.id).map(\.id), ["sng_1", "sng_4"])
        XCTAssertEqual(model.pockets().first { $0.id == pk.id }?.subtitle, "1 song")
        XCTAssertEqual(model.songs(inPocket: pk.id).map(\.id), ["sng_2"])
    }

    /// The subtitle count must match the rows actually shown: playableIds keeps STUDIO ids
    /// (which have no IndexSong and are dropped from the drill-in list), so the count is of the
    /// RESOLVED catalog songs, not raw playableIds — else "2 songs" would open a 1-row list.
    func testCollectionCountMatchesRenderedRowsWhenStudioIdsPresent() async {
        let (model, _, collections) = await makeModel()
        collections.studioLookup = { id in
            id == "lp_x" ? (title: "Loop X", lengthMs: 4000, bpm: 120, camelot: "8A") : nil
        }
        let pl = collections.createPlaylist("Mixed")
        collections.addSong("sng_1", toPlaylist: pl.id)   // catalog song
        collections.addSong("lp_x", toPlaylist: pl.id)    // studio loop (kept by playableIds, no IndexSong)

        let rows = model.songs(inPlaylist: pl.id)
        let subtitle = model.playlists().first { $0.id == pl.id }?.subtitle
        XCTAssertEqual(rows.map(\.id), ["sng_1"])         // only the catalog song renders
        XCTAssertEqual(subtitle, "1 song")               // count matches the rendered rows, not raw playableIds
    }

    /// CarPlay Playlists must include the catalog's Apple Music / source playlists (which have no
    /// CollectionsStore setlist), and playing one builds a fresh Now Playing setlist from its ids.
    func testPlaylistsIncludeAppleMusicSourcePlaylistsAndPlayThem() async {
        let (model, services, collections) = await makeModel()
        services.app.indexPlaylists = [
            SourcePlaylist(playlist: IndexPlaylist(id: "ip_1", name: "AM Faves", songIds: ["sng_1", "sng_2"]),
                           sourceName: "Apple Music")
        ]
        let rows = model.playlists()
        XCTAssertTrue(rows.contains { $0.id == "src:ip_1" && $0.title == "AM Faves" },
                      "Apple Music source playlists should appear in CarPlay Playlists")
        XCTAssertEqual(model.songs(inPlaylist: "src:ip_1").map(\.id), ["sng_1", "sng_2"])

        await model.playPlaylist(id: "src:ip_1")
        XCTAssertEqual(collections.nowPlayingSetlist()?.tracks.map(\.songId), ["sng_1", "sng_2"])
        XCTAssertEqual(collections.nowPlayingSetlist()?.name, "AM Faves")
    }

    // MARK: Artists

    func testArtistsTabListsAndPlaysDiscography() async {
        let (model, _, collections) = await makeModel()
        XCTAssertEqual(Set(model.artists().map(\.title)), ["Aria", "Bento", "Cobalt"])
        XCTAssertEqual(model.albums(byArtist: "Aria").map(\.id), ["alb_1"])
        XCTAssertEqual(model.artists().first { $0.title == "Aria" }?.subtitle, "1 album · 3 songs")

        await model.playArtist(name: "Aria")
        XCTAssertEqual(collections.nowPlayingSetlist()?.tracks.map(\.songId), ["sng_1", "sng_2", "sng_3"])
        XCTAssertEqual(collections.nowPlayingSource, .artist)     // History attributes as Artist
        XCTAssertEqual(collections.nowPlayingSetlist()?.name, "Aria")
    }

    // MARK: Search (title/artist only)

    func testSearchByCategory() async {
        let (model, _, collections) = await makeModel()
        _ = collections.createPlaylist("Roadtrip")
        // Songs — by title and by artist, case-insensitive; empty/no-match → empty.
        let neon = await model.search("neon", category: .songs)
        XCTAssertEqual(neon.map(\.id), ["sng_1"])
        let aria = await model.search("ARIA", category: .songs)
        XCTAssertEqual(Set(aria.map(\.id)), ["sng_1", "sng_2", "sng_3"])
        let empty = await model.search("", category: .songs)
        XCTAssertTrue(empty.isEmpty)
        let noMatch = await model.search("zzz-no-match", category: .songs)
        XCTAssertTrue(noMatch.isEmpty)
        // Albums / Artists / Playlists categories scope the results.
        let albHits = await model.search("night", category: .albums)
        XCTAssertEqual(albHits.map(\.id), ["alb_1"])
        let artHits = await model.search("cobalt", category: .artists)
        XCTAssertEqual(artHits.map(\.id), ["artist:Cobalt"])
        let plHits = await model.search("road", category: .playlists)
        XCTAssertTrue(plHits.contains { $0.title == "Roadtrip" })
        let neonAsAlbum = await model.search("neon", category: .albums)
        XCTAssertTrue(neonAsAlbum.isEmpty)   // a song title is not an album match
        let capped = await model.search("aria", category: .songs, limit: 2)
        XCTAssertTrue(capped.count <= 2)
    }

    // MARK: Play (routes through the shared sequencer)

    func testPlayAlbumStartsSequencerWithAlbumSource() async {
        let (model, services, collections) = await makeModel()
        await model.playAlbum(id: "alb_1")
        XCTAssertTrue(services.setlistPlayer.isRunning)
        XCTAssertEqual(services.setlistPlayer.queue.map(\.id), ["sng_1", "sng_2", "sng_3"])
        XCTAssertEqual(collections.nowPlayingSource, .album)               // History attributes as Album
        XCTAssertEqual(collections.nowPlayingSetlist()?.name, "Night Drive")
    }

    func testPlaySongStartsSequencerAsBrowserSingle() async {
        let (model, services, collections) = await makeModel()
        await model.playSong(id: "sng_1")
        XCTAssertEqual(services.setlistPlayer.queue.map(\.id), ["sng_1"])
        XCTAssertEqual(collections.nowPlayingSource, .browser)
    }

    func testPlayPlaylistStartsSequencer() async {
        let (model, services, collections) = await makeModel()
        let pl = collections.createPlaylist("Set")
        collections.addSong("sng_2", toPlaylist: pl.id)
        await model.playPlaylist(id: pl.id)
        XCTAssertTrue(services.setlistPlayer.isRunning)
        XCTAssertEqual(collections.nowPlayingSource, .playlist)
    }

    // MARK: Up Next (running-queue view + edit)

    func testUpNextReflectsQueueAndRemoveEditsIt() async {
        let (model, services, _) = await makeModel()
        services.setlistPlayer.play([.init(id: "sng_1", title: "One", artist: "A"),
                                     .init(id: "sng_2", title: "Two", artist: "A"),
                                     .init(id: "sng_3", title: "Three", artist: "A")])
        // Up Next is everything AFTER the current (index 0) track.
        let up = model.upNext()
        XCTAssertEqual(up.map(\.title), ["Two", "Three"])
        XCTAssertEqual(up.first?.albumId, "alb_1")           // resolved from the catalog

        model.removeFromQueue(uid: up[0].uid)                // remove "Two"
        XCTAssertEqual(model.upNext().map(\.title), ["Three"])

        model.moveToEnd(uid: model.upNext()[0].uid)          // no-op with one item, but exercises the path
        XCTAssertEqual(model.upNext().map(\.title), ["Three"])
        services.setlistPlayer.stop()
        XCTAssertTrue(model.upNext().isEmpty)                 // nothing up next when idle
    }

    /// Playing a playlist/pocket in CarPlay rebuilds a FRESH snapshot from the collection's CURRENT
    /// songs each time (into the reserved Now Playing setlist, overwriting the prior one), so a
    /// playlist with no pre-existing setlist plays, and songs added since last play are included.
    func testReplayingPlaylistPicksUpNewlyAddedSongs() async {
        let (model, _, collections) = await makeModel()
        let pl = collections.createPlaylist("Fresh")
        collections.addSong("sng_1", toPlaylist: pl.id)
        await model.playPlaylist(id: pl.id)
        XCTAssertEqual(collections.nowPlayingSetlist()?.tracks.map(\.songId), ["sng_1"])

        collections.addSong("sng_2", toPlaylist: pl.id)     // update the playlist…
        await model.playPlaylist(id: pl.id)                 // …replay → fresh snapshot includes it
        XCTAssertEqual(collections.nowPlayingSetlist()?.tracks.map(\.songId), ["sng_1", "sng_2"])
    }

    // MARK: Add-to

    func testAddTargetsAndAddSong() async {
        let (model, _, collections) = await makeModel()
        let pk = collections.createPocket("Faves")
        let pl = collections.createPlaylist("Evening")

        let targets = model.addTargets()
        XCTAssertTrue(targets.contains { $0.id == "pkt:\(pk.id)" && $0.title == "Faves" && $0.subtitle == "Pocket" })
        XCTAssertTrue(targets.contains { $0.id == "pls:\(pl.id)" && $0.title == "Evening" && $0.subtitle == "Playlist" })

        XCTAssertEqual(model.addSong("sng_1", toTargetId: "pkt:\(pk.id)"), "Faves")
        XCTAssertTrue(collections.pocket(pk.id)!.songIds.contains("sng_1"))

        XCTAssertEqual(model.addSong("sng_2", toTargetId: "pls:\(pl.id)"), "Evening")
        XCTAssertEqual(collections.songIds(forPlaylist: pl.id), ["sng_2"])

        XCTAssertNil(model.addSong("sng_1", toTargetId: "pkt:nonexistent"))   // unknown target
        XCTAssertNil(model.addSong("sng_1", toTargetId: "garbage"))
    }
}

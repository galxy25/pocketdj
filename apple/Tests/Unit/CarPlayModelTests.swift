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
        let studioURL = FileManager.default.temporaryDirectory.appendingPathComponent("pdj-cp-studio-\(UUID().uuidString).json")
        addTeardownBlock { try? FileManager.default.removeItem(at: studioURL) }
        let studio = StudioStore(fileURL: studioURL)
        let favURL = FileManager.default.temporaryDirectory.appendingPathComponent("pdj-cp-fav-\(UUID().uuidString).json")
        addTeardownBlock { try? FileManager.default.removeItem(at: favURL) }
        let favorites = FavoritesStore(fileURL: favURL)
        let services = IntentServices(app: app, settings: settings, collections: collections,
                                      setlistPlayer: sequencer, mix: MixEngine(burns: burns), burns: burns,
                                      studio: studio, rips: rips, favorites: favorites)
        return (CarPlayModel(services: services), services, collections)
    }

    /// Like `makeModel`, but with a REAL `PlaybackSessionStore` wired to the sequencer and a
    /// snapshot already on disk. Without the store, `restorePersistedSessionIfIdle` returns on its
    /// `guard let sessionStore` and every restore assertion below would pass for the wrong reason.
    private func makeModelWithSession(seed: Bool = true) async
        -> (CarPlayModel, IntentServices, SetlistPlayer, PlaybackSessionStore) {
        let (model, services, _) = await makeModel()
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("pdj-cp-session-\(UUID().uuidString).json")
        addTeardownBlock { try? FileManager.default.removeItem(at: url) }
        let store = PlaybackSessionStore(fileURL: url)
        let seq = services.setlistPlayer
        seq.sessionStore = store
        if seed {
            store.save(PlaybackSessionStore.Snapshot(
                sessionId: "pses_car",
                source: .init(kind: "playlist", id: "pls_car", name: "Roadtrip"),
                queue: [.init(songId: "s_1", title: "One", artist: "Aria", lengthMs: 200_000, repeatCount: nil),
                        .init(songId: "s_2", title: "Two", artist: "Aria", lengthMs: 180_000, repeatCount: nil)],
                index: 1, positionMs: 42_000, isPlaying: true, updatedAt: 0), now: 1_000)
            store.flush(now: 1_000)
        }
        return (model, services, seq, store)
    }

    // MARK: Durable session on a CarPlay connect (R2)

    /// The bug: plugging into the car after a force-quit came up with an EMPTY deck. The CarPlay
    /// scene is its own `UIScene`, so it never runs RootView's launch task — the only caller of
    /// `restorePersistedSessionIfIdle`. `ensureReady()` now performs the restore itself.
    func testEnsureReadyRestoresThePersistedSession() async {
        let (model, _, seq, _) = await makeModelWithSession()
        XCTAssertFalse(seq.isRunning, "nothing restored before the scene connects")

        await model.ensureReady()

        XCTAssertTrue(seq.isRunning, "connecting to CarPlay rehydrates the set that was playing")
        XCTAssertTrue(seq.isHeldForResume, "…HELD — connecting must never start audio on its own")
        XCTAssertEqual(seq.index, 1)
        XCTAssertEqual(seq.currentSongId, "s_2")
        seq.stop()
    }

    /// Idempotent: `ensureReady()` runs on every scene connect, so it must never disturb a set that
    /// is already running (e.g. the phone was playing when the driver plugged in).
    func testEnsureReadyDoesNotClobberARunningSet() async {
        let (model, _, seq, store) = await makeModelWithSession()
        seq.restore(from: store.load()!)
        seq.resumeFromHold()
        XCTAssertFalse(seq.isHeldForResume, "the set is LIVE, not held")
        let liveIndex = seq.index
        let liveQueue = seq.queue.map(\.id)

        await model.ensureReady()

        XCTAssertEqual(seq.index, liveIndex, "a live run is never replaced by the stored one")
        XCTAssertEqual(seq.queue.map(\.id), liveQueue)
        XCTAssertFalse(seq.isHeldForResume,
                       "a clobbering restore would re-park the deck as held — it must not")
        seq.stop()
    }

    /// Same veto every mutating intent honors: a device that hasn't finished the zero-to-hero flow
    /// must not materialize synced documents from a CarPlay connect.
    func testEnsureReadyRestoreIsVetoedDuringOnboarding() async {
        let (model, services, seq, _) = await makeModelWithSession()
        services.onboardingIncomplete = { true }

        await model.ensureReady()

        XCTAssertFalse(seq.isRunning, "onboarding incomplete ⇒ no restore")
    }

    /// The affordance that makes the restore reachable without touching the phone.
    func testResumableSessionRowAppearsOnlyWhileHeld() async {
        let (model, _, seq, _) = await makeModelWithSession()
        XCTAssertNil(model.resumableSession(), "nothing held yet")

        await model.ensureReady()
        let row = model.resumableSession()
        XCTAssertEqual(row?.title, "Two", "the row names the track the set is parked on")
        XCTAssertEqual(row?.subtitle, "Aria · Continue")

        model.resumeHeldSession()
        XCTAssertFalse(seq.isHeldForResume)
        XCTAssertNil(model.resumableSession(), "once resumed there is nothing to continue")
        seq.stop()
    }

    // MARK: Browse
    //
    // Albums and Artists are GONE from CarPlay — the owner replaced both tabs with For You (see
    // `CarPlayForYouTests`), and the browse lists that existed only to fill them went with them.
    // Their tests went too rather than being left asserting over unreachable code.

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

    // MARK: Play (routes through the shared sequencer)

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

    /// "Play now" on an Up Next row: `jump(uid:)` shifts playback to EXACTLY the tapped queue
    /// row — it becomes `nowPlaying()`, rows before it leave the Up Next view (played region),
    /// and rows after it remain upcoming. A stale uid (row removed under the tap) is a no-op.
    func testJumpStartsTappedUpNextRowPlaying() async {
        let (model, services, _) = await makeModel()
        services.setlistPlayer.play([.init(id: "sng_1", title: "One", artist: "A"),
                                     .init(id: "sng_2", title: "Two", artist: "A"),
                                     .init(id: "sng_3", title: "Three", artist: "A")])
        let up = model.upNext()                          // ["Two", "Three"]
        model.jump(uid: up[1].uid)                       // tap "Three"
        XCTAssertEqual(model.nowPlaying()?.title, "Three", "the tapped row is now the current track")
        XCTAssertEqual(model.nowPlaying()?.uid, up[1].uid, "…and it's the exact tapped ROW (uid)")
        XCTAssertTrue(model.upNext().isEmpty, "jumped-over rows left the Up Next view")
        XCTAssertTrue(services.setlistPlayer.isRunning)

        model.jump(uid: up[0].uid)                       // "Two" is now PLAYED — stale tap no-ops
        XCTAssertEqual(model.nowPlaying()?.title, "Three")
        services.setlistPlayer.stop()
    }

    /// The current track is surfaced separately from the upcoming queue, so PocketDJ's own CarPlay
    /// UI can pin a "Now Playing" row above Up Next — read straight off `queue[index]`, which is
    /// correct even for an Apple Music set that never sets `rips.nowPlaying`.
    func testNowPlayingReflectsCurrentTrackDistinctFromUpNext() async {
        let (model, services, _) = await makeModel()
        XCTAssertNil(model.nowPlaying())                 // nothing playing → nil
        services.setlistPlayer.play([.init(id: "sng_1", title: "One", artist: "A"),
                                     .init(id: "sng_2", title: "Two", artist: "A"),
                                     .init(id: "sng_3", title: "Three", artist: "A")])
        let now = model.nowPlaying()
        XCTAssertEqual(now?.title, "One")                // the current (index 0) track…
        XCTAssertEqual(now?.albumId, "alb_1")            // …with resolved artwork
        XCTAssertFalse(model.upNext().contains { $0.title == "One" })   // …and NOT duplicated in Up Next
        XCTAssertEqual(model.upNext().map(\.title), ["Two", "Three"])
        services.setlistPlayer.stop()
        XCTAssertNil(model.nowPlaying())                 // idle again → nil
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

    // MARK: Favorite (the ♥ on the CarPlay Now Playing template)

    /// The heart reads/writes the CURRENT track's favorite through the shared FavoritesStore,
    /// keyed on `queue[index]` (so it's correct for an Apple Music set too). Idle ⇒ false + no-op.
    func testCurrentFavoriteReflectsAndTogglesTheStore() async {
        let (model, services, _) = await makeModel()
        // Idle: nothing playing → not favorited, and a toggle is a safe no-op.
        XCTAssertFalse(model.isCurrentFavorite())
        model.toggleCurrentFavorite()
        XCTAssertTrue(services.favorites.favoriteIds.isEmpty)

        services.setlistPlayer.play([.init(id: "sng_1", title: "Neon", artist: "Aria"),
                                     .init(id: "sng_2", title: "Pulse", artist: "Aria")])
        XCTAssertFalse(model.isCurrentFavorite(), "the current track starts unfavorited")

        model.toggleCurrentFavorite()                       // ♥ the current track (sng_1)
        XCTAssertTrue(model.isCurrentFavorite())
        XCTAssertTrue(services.favorites.isFavorite("sng_1"))
        // The catalog id rides the toggle so an owner push can run — sng_1 carries one in TestData.
        XCTAssertEqual(services.favorites.entry("sng_1")?.appleMusicId,
                       services.app.songsById["sng_1"]?.appleMusicId)

        model.toggleCurrentFavorite()                       // un-♥
        XCTAssertFalse(model.isCurrentFavorite())
        XCTAssertFalse(services.favorites.isFavorite("sng_1"))

        // The heart tracks the CURRENT track: advance, and it reads the next song's state.
        services.setlistPlayer.skipNext()                   // now on sng_2
        XCTAssertFalse(model.isCurrentFavorite())
        services.favorites.toggle("sng_2", appleMusicId: nil)
        XCTAssertTrue(model.isCurrentFavorite(), "heart follows the current track to sng_2")
        XCTAssertFalse(services.favorites.isFavorite("sng_1"), "…and sng_1 stayed un-favorited")
        services.setlistPlayer.stop()
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

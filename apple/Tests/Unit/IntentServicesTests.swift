import XCTest
@testable import PocketDJ

/// The App Intents operations layer (`IntentServices`) — the thin, testable methods
/// every intent struct calls. Proves: ▶/🔀 playlist/pocket snapshot into the reserved
/// Now Playing setlist AND start the app-scoped sequencer; the speakable errors fire
/// for missing/empty collections and un-burned auto-mix sources; pause/resume drive
/// the MixEngine's lock-screen (suspend/resume) seam; and the entity builders expose
/// exactly the speakable collections (Now Playing filtered, name matching).
@MainActor
final class IntentServicesTests: XCTestCase {

    // MARK: Fixtures

    /// `burnedIds` non-nil ⇒ the BurnStore is a `MixBurnFixture` ledger with REAL on-disk WAVs for
    /// those ids (an auto-mix success path needs loadable burns; see the fixture's doc).
    private func makeServices(burnedIds: [String]? = nil) async -> (IntentServices, CollectionsStore, AppModel) {
        let app = AppModel(loader: TestData.StubLoader())
        await app.loadIfNeeded()
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("pdj-intents-\(UUID().uuidString).json")
        addTeardownBlock { try? FileManager.default.removeItem(at: url) }
        let collections = CollectionsStore(fileURL: url)
        collections.app = app
        let settings = SettingsStore(defaults: UserDefaults(suiteName: "test.\(UUID())")!)
        // Hermetic rips store (ensureReady fire-and-forgets a manifest refresh — it must
        // never reach the production S3 bucket from a unit test).
        let rips = RipsStore(ripsBase: URL(string: "https://rips.test")!,
                             session: URLSession(configuration: .ephemeral))
        let player = PlayerEngine()
        let burns: BurnStore
        if let burnedIds {
            burns = try! MixBurnFixture.burnStore(ids: burnedIds, rips: rips)
        } else {
            let burnsURL = FileManager.default.temporaryDirectory
                .appendingPathComponent("pdj-intents-burns-\(UUID().uuidString).json")
            addTeardownBlock { try? FileManager.default.removeItem(at: burnsURL) }
            burns = BurnStore(rips: rips, fileURL: burnsURL)
        }
        let coordinator = PlaybackCoordinator(
            ripProvider: RipServerPlaybackProvider(rips: rips, player: player),
            appleMusic: AppleMusicPlaybackProvider(provider: AppleMusicProvider()))
        let sequencer = SetlistPlayer(player: player, rips: rips, burns: burns, coordinator: coordinator)
        let mix = MixEngine(burns: burns)
        let studioURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("pdj-intents-studio-\(UUID().uuidString).json")
        addTeardownBlock { try? FileManager.default.removeItem(at: studioURL) }
        let studio = StudioStore(fileURL: studioURL)
        let favURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("pdj-intents-fav-\(UUID().uuidString).json")
        addTeardownBlock { try? FileManager.default.removeItem(at: favURL) }
        let favorites = FavoritesStore(fileURL: favURL)
        let services = IntentServices(app: app, settings: settings, collections: collections,
                                      setlistPlayer: sequencer, mix: mix, burns: burns,
                                      studio: studio, rips: rips, favorites: favorites)
        return (services, collections, app)
    }

    // MARK: Play playlist / pocket

    func testPlayPlaylistSnapshotsNowPlayingAndStartsSequencer() async throws {
        let (services, collections, _) = await makeServices()
        let pl = collections.createPlaylist("Evening Set")
        collections.addSong("sng_1", toPlaylist: pl.id)
        collections.addSong("sng_2", toPlaylist: pl.id)

        let name = try await services.playPlaylist(id: pl.id, shuffle: false)

        XCTAssertEqual(name, "Evening Set")
        let nowPlaying = collections.nowPlayingSetlist()
        XCTAssertEqual(nowPlaying?.tracks.map(\.songId), ["sng_1", "sng_2"])   // literal order
        XCTAssertTrue(services.setlistPlayer.isRunning)
        XCTAssertEqual(services.setlistPlayer.sourceSetlistId, nowPlayingSetlistId)
        XCTAssertEqual(services.setlistPlayer.queue.map(\.id), ["sng_1", "sng_2"])
    }

    func testPlayPocketResolvesDAGAndStartsSequencer() async throws {
        let (services, collections, _) = await makeServices()
        let pocket = collections.createPocket("Warmup")
        collections.addSong("sng_2", toPocket: pocket.id)
        collections.addSong("sng_1", toPocket: pocket.id)

        let name = try await services.playPocket(id: pocket.id, shuffle: false)

        XCTAssertEqual(name, "Warmup")
        XCTAssertEqual(services.setlistPlayer.queue.map(\.id), ["sng_2", "sng_1"])
    }

    /// The iOS 27 playAudio schema's song case rides this seam: one catalog song
    /// becomes a one-track Now Playing set on the shared sequencer.
    func testPlaySongBuildsOneTrackNowPlaying() async throws {
        let (services, collections, _) = await makeServices()

        let name = try await services.playSong(id: "sng_3")

        XCTAssertEqual(name, "Drift")
        XCTAssertEqual(collections.nowPlayingSetlist()?.tracks.map(\.songId), ["sng_3"])
        XCTAssertEqual(services.setlistPlayer.queue.map(\.id), ["sng_3"])
        XCTAssertTrue(services.setlistPlayer.isRunning)

        do {
            _ = try await services.playSong(id: "sng_missing")
            XCTFail("expected songNotFound")
        } catch let e as PocketDJIntentError {
            XCTAssertEqual("\(e)", "\(PocketDJIntentError.songNotFound)")
        } catch { XCTFail("unexpected \(error)") }
    }

    func testPlayUnknownIdsThrowSpeakableErrors() async {
        let (services, _, _) = await makeServices()
        do {
            _ = try await services.playPlaylist(id: "pls_missing", shuffle: false)
            XCTFail("expected playlistNotFound")
        } catch let e as PocketDJIntentError {
            XCTAssertEqual("\(e)", "\(PocketDJIntentError.playlistNotFound)")
        } catch { XCTFail("unexpected \(error)") }
        do {
            _ = try await services.playPocket(id: "pkt_missing", shuffle: false)
            XCTFail("expected pocketNotFound")
        } catch let e as PocketDJIntentError {
            XCTAssertEqual("\(e)", "\(PocketDJIntentError.pocketNotFound)")
        } catch { XCTFail("unexpected \(error)") }
    }

    func testPlayEmptyPlaylistThrowsAndSequencerStaysIdle() async {
        let (services, collections, _) = await makeServices()
        let pl = collections.createPlaylist("Empty")
        do {
            _ = try await services.playPlaylist(id: pl.id, shuffle: false)
            XCTFail("expected emptyCollection")
        } catch let e as PocketDJIntentError {
            if case .emptyCollection(let name) = e { XCTAssertEqual(name, "Empty") }
            else { XCTFail("unexpected \(e)") }
        } catch { XCTFail("unexpected \(error)") }
        XCTAssertFalse(services.setlistPlayer.isRunning)
    }

    /// The two-crate start (the CarPlay/TV Mix remote's deck A + B): per-crate order is
    /// preserved and interleaved A0,B0,A1,… onto the engine's strict deck alternation, a song
    /// in both crates plays ONCE (deck A's copy wins), the label names both crates, and the
    /// downloader run tracks the UNION so late landings from either crate join the queue.
    func testTwoCrateAutoMixInterleavesDedupsAndTracksBothCrates() async throws {
        let (services, collections, _) = await makeServices(burnedIds: ["sng_1", "sng_2", "sng_3"])
        services.mix.ensureEngine()
        try XCTSkipUnless(services.mix.isReady, "no audio device on this test host")
        let a = collections.createPocket("Crate A")
        collections.addSong("sng_1", toPocket: a.id)
        collections.addSong("sng_2", toPocket: a.id)      // sng_2 lives in BOTH crates
        let b = collections.createPocket("Crate B")
        collections.addSong("sng_2", toPocket: b.id)
        collections.addSong("sng_3", toPocket: b.id)
        let d = CollectionMixDownloader(engine: services.mix, burns: services.burns,
                                        rips: services.rips, transfers: nil)
        d.resolveRipIds = { src in
            src == .pocket(a.id) ? ["sng_1", "sng_2"] : ["sng_2", "sng_3"]
        }
        d.resolveLoadables = { _ in [] }
        services.mixDownloader = d

        let (name, count) = try await services.startAutoMix(
            deckA: .pocket(a.id), deckB: .pocket(b.id), shuffle: false)

        XCTAssertEqual(name, "Crate A + Crate B")
        XCTAssertEqual(count, 3, "the shared song plays once")
        XCTAssertTrue(services.mix.autoMixing)
        XCTAssertEqual(services.mix.onAirTrack?.songId, "sng_1", "A's first track opens on deck A")
        XCTAssertEqual(services.mix.autoUpcoming.map(\.songId), ["sng_3", "sng_2"],
                       "interleave: B0 next (B's sng_2 deduped to A's copy), then A1")
        XCTAssertEqual(d.sources, [.pocket(a.id), .pocket(b.id)],
                       "the download run tracks BOTH crates")
        XCTAssertEqual(d.totalCount, 3, "…as a UNION, the shared song tracked once")
        services.mix.stopAutoMix()
    }

    /// The remote surfaces' explicit "Resume Mix" must clear a pause that ORIGINATED in-app
    /// (`pauseAuto`) — `remotePlay` alone no-ops on that state by design (the lock-screen ▶'s
    /// gesture is ambiguous; a labeled Resume row is not), which made the car's row a dead
    /// control whenever the pause came from the phone.
    func testCarResumeClearsAnInAppPause() async throws {
        let (services, collections, _) = await makeServices(burnedIds: ["sng_1", "sng_2"])
        services.mix.ensureEngine()
        try XCTSkipUnless(services.mix.isReady, "no audio device on this test host")
        let pocket = collections.createPocket("Road Crate")
        collections.addSong("sng_1", toPocket: pocket.id)
        collections.addSong("sng_2", toPocket: pocket.id)
        _ = try await services.startAutoMix(source: .pocket(pocket.id), shuffle: false)
        XCTAssertTrue(services.mix.autoMixing)

        services.mix.pauseAuto()                  // the PHONE's in-app hand-mixing pause
        XCTAssertTrue(services.mix.autoPaused)

        CarPlayModel(services: services).resumeMix()
        XCTAssertFalse(services.mix.autoPaused, "the labeled Resume row resumes the machine")
        services.mix.stopAutoMix()
    }

    // MARK: 👍 on what is playing (For You collection queue)

    /// The owner's contract for a collection tile's 👍 — "send positive signal AND add the song
    /// to the collection" — honoured from the TRANSPORT surfaces (deck, mini bar, CarPlay,
    /// widget, lock screen), which all land in `recordNowPlayingFeedback`. For a collection tile
    /// the playing scope IS the target collection id, so an accept adds the track there; the
    /// undo never un-adds; a re-accept never duplicates.
    func testNowPlayingThumbsUpAddsTheSongToThePlayingForYouCollection() async throws {
        let (services, collections, _) = await makeServices()
        let fbURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("pdj-intents-fb-\(UUID().uuidString).json")
        addTeardownBlock { try? FileManager.default.removeItem(at: fbURL) }
        let store = RecFeedbackStore(fileURL: fbURL)
        services.recFeedback = store
        let pocket = collections.createPocket("808s and Swinging")
        collections.addSong("sng_1", toPocket: pocket.id)

        // Play a SUGGESTED track (not yet a member), scope-stamped the way every For You play
        // path stamps it: with the tile's collection id.
        _ = try await services.playSong(id: "sng_3")
        store.beginPlayback(scope: pocket.id, songIds: ["sng_3"])

        let landed = services.recordNowPlayingFeedback(.accepted, surface: .nowPlaying)
        XCTAssertEqual(landed, .accepted)
        XCTAssertEqual(collections.songIds(forPocket: pocket.id), ["sng_1", "sng_3"],
                       "the 👍 adds the playing suggestion to the collection it was suggested for")

        // The second tap is an UNDO of the verdict — never an un-add.
        XCTAssertNil(services.recordNowPlayingFeedback(.accepted, surface: .nowPlaying))
        XCTAssertEqual(collections.songIds(forPocket: pocket.id), ["sng_1", "sng_3"])

        // A third tap re-accepts; membership is checked, so no duplicate node is minted.
        XCTAssertEqual(services.recordNowPlayingFeedback(.accepted, surface: .nowPlaying), .accepted)
        XCTAssertEqual(collections.songIds(forPocket: pocket.id), ["sng_1", "sng_3"])
    }

    /// Reserved scopes (In Da Zone / New) have no implicit collection — a 👍 there stays pure
    /// feedback — and playlists (whose single-song `addSong` is deliberately the duplication
    /// path) dedup through the same helper.
    func testAcceptedAddIsScopeGuardedAndDedupsOnPlaylists() async {
        let (_, collections, _) = await makeServices()
        XCTAssertFalse(collections.addAcceptedSong("sng_1",
                                                   scopedTo: ForYouTileRoute.Kind.zone.rawValue),
                       "a reserved scope resolves to no collection and adds nothing")

        let pl = collections.createPlaylist("Late Night")
        collections.addSong("sng_1", toPlaylist: pl.id)
        XCTAssertTrue(collections.addAcceptedSong("sng_2", scopedTo: pl.id))
        XCTAssertFalse(collections.addAcceptedSong("sng_2", scopedTo: pl.id),
                       "an accept replay must not mint a duplicate playlist node")
        XCTAssertEqual(collections.songIds(forPlaylist: pl.id), ["sng_1", "sng_2"])
    }

    // MARK: Auto-mix

    func testAutoMixWithNoBurnedSongsThrows() async {
        let (services, collections, _) = await makeServices()
        let pocket = collections.createPocket("Unburned")
        collections.addSong("sng_1", toPocket: pocket.id)
        do {
            _ = try await services.startAutoMix(source: .pocket(pocket.id), shuffle: false)
            XCTFail("expected noBurnedSongs")
        } catch let e as PocketDJIntentError {
            if case .noBurnedSongs(let name) = e { XCTAssertEqual(name, "Unburned") }
            else { XCTFail("unexpected \(e)") }
        } catch { XCTFail("unexpected \(error)") }
        XCTAssertFalse(services.mix.autoMixing)
    }

    /// An intent-started auto-mix kicks the SAME collection download run MixView's ▶ does and
    /// arms progressive eligibility (tracks that finish downloading later join this mix's queue).
    func testStartAutoMixKicksCollectionDownloadAndArmsContinuation() async throws {
        let (services, collections, _) = await makeServices(burnedIds: ["sng_1", "sng_2"])
        services.mix.ensureEngine()
        try XCTSkipUnless(services.mix.isReady, "no audio device on this test host")
        let d = CollectionMixDownloader(engine: services.mix, burns: services.burns,
                                        rips: services.rips, transfers: nil)
        d.resolveRipIds = { _ in ["sng_1", "sng_2"] }
        d.resolveLoadables = { _ in [] }
        services.mixDownloader = d
        let pocket = collections.createPocket("Deep Cuts")
        collections.addSong("sng_1", toPocket: pocket.id)
        collections.addSong("sng_2", toPocket: pocket.id)

        let (name, count) = try await services.startAutoMix(source: .pocket(pocket.id), shuffle: false)

        XCTAssertEqual(name, "Deep Cuts")
        XCTAssertEqual(count, 2)
        XCTAssertTrue(services.mix.autoMixing)
        XCTAssertEqual(d.source, .pocket(pocket.id), "the intent kicked the download run")
        XCTAssertEqual(d.totalCount, 2)
        XCTAssertEqual(d.downloadedCount, 2, "the seed pass found both burns on disk")
        XCTAssertFalse(d.isActive, "nothing left to download ⇒ no bar")
        XCTAssertTrue(d.autoArmedForTesting, "landings would join this mix's queue")
        XCTAssertEqual(d.initialAutoIdsForTesting, ["sng_1", "sng_2"])
        XCTAssertEqual(d.autoLabelForTesting, "Deep Cuts", "append targets OUR mix, by label")
        XCTAssertFalse(d.autoStartPendingForTesting, "a running mix never has a pending start")
        services.mix.stopAutoMix()
        services.mix.teardown()
    }

    func testAutoMixUnknownSourceThrows() async {
        let (services, _, _) = await makeServices()
        do {
            _ = try await services.startAutoMix(source: .pocket("pkt_gone"), shuffle: true)
            XCTFail("expected mixSourceNotFound")
        } catch let e as PocketDJIntentError {
            XCTAssertEqual("\(e)", "\(PocketDJIntentError.mixSourceNotFound)")
        } catch { XCTFail("unexpected \(error)") }
    }

    func testPauseResumeDriveTheLockScreenSeam() async throws {
        let (services, _, _) = await makeServices()
        // No mix running → both throw.
        XCTAssertThrowsError(try services.pauseAutoMix())
        XCTAssertThrowsError(try services.resumeAutoMix())

        // Start an auto-mix directly on the engine. startAutoMix ejects + re-loads both
        // decks from its queue now, so the item must RESOLVE — wire the studio seam
        // (the MixDeckSessionTests idiom) with a real WAV.
        let wav = FileManager.default.temporaryDirectory
            .appendingPathComponent("pdj-intents-\(UUID().uuidString).wav")
        try MixBurnFixture.writeSineWAV(to: wav, seconds: 2)
        addTeardownBlock { try? FileManager.default.removeItem(at: wav) }
        services.mix.studioResolve = { id in
            id == "smp_1" ? (url: wav, release: nil, title: "T", lengthMs: 2_000) : nil
        }
        let item = MixEngine.AutoMixItem(
            loadable: MixLoadable(songId: "smp_1", title: "T", artist: "A", bpm: nil,
                                  camelot: nil, key: nil, albumId: nil, lengthMs: 180_000),
            durationMs: 180_000)
        services.mix.startAutoMix([item], shuffled: false, lead: 15, fade: 3)
        XCTAssertTrue(services.mix.autoMixing)

        // Resume before any pause → speakable "not paused" error.
        XCTAssertThrowsError(try services.resumeAutoMix()) { error in
            guard let e = error as? PocketDJIntentError, case .autoMixNotPaused = e else {
                return XCTFail("unexpected \(error)")
            }
        }

        try services.pauseAutoMix()
        XCTAssertTrue(services.mix.autoPaused)      // suspended, not ended
        XCTAssertTrue(services.mix.autoMixing)

        try services.resumeAutoMix()
        XCTAssertFalse(services.mix.autoPaused)
        XCTAssertTrue(services.mix.autoMixing)
    }

    // MARK: Entity builders (what Siri can speak / Shortcuts list)

    func testEntityBuildersFilterNowPlayingAndMatchByName() async throws {
        let (services, collections, _) = await makeServices()
        let pl = collections.createPlaylist("Deep Cuts")
        collections.addSong("sng_1", toPlaylist: pl.id)
        let pocket = collections.createPocket("Deep Pocket")
        _ = try await services.playPlaylist(id: pl.id, shuffle: false)   // upserts Now Playing

        // The reserved Now Playing setlist (+ its synthetic playlist) never surfaces.
        XCTAssertEqual(PlaylistEntity.all(in: collections).map(\.name), ["Deep Cuts"])
        let sources = AutoMixSourceEntity.all(in: collections)
        XCTAssertFalse(sources.contains { $0.id.contains(nowPlayingSetlistId) })
        XCTAssertTrue(sources.contains { $0.name == "Deep Pocket" && $0.kindLabel == "Pocket" })

        // Case-insensitive name matching (EntityStringQuery's contract).
        XCTAssertEqual(PlaylistEntity.matching("deep", in: collections).count, 1)
        XCTAssertEqual(PocketEntity.matching("DEEP", in: collections).map(\.name), ["Deep Pocket"])
        XCTAssertTrue(PlaylistEntity.matching("zzz", in: collections).isEmpty)

        // Auto-mix source ids round-trip through MixSource.
        let pocketSource = sources.first { $0.name == "Deep Pocket" }
        XCTAssertEqual(pocketSource?.mixSource, MixSource.pocket(pocket.id))
    }
}

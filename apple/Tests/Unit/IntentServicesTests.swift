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

    private func makeServices() async -> (IntentServices, CollectionsStore, AppModel) {
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
        let burnsURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("pdj-intents-burns-\(UUID().uuidString).json")
        addTeardownBlock { try? FileManager.default.removeItem(at: burnsURL) }
        let burns = BurnStore(rips: rips, fileURL: burnsURL)
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

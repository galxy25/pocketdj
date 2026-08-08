import XCTest
@testable import PocketDJ

/// The "a card on screen is a song you can hear" contract, at both levels it lives at:
/// the SAMPLER (only songs whose audio can start now enter the pool) and the ENGINE (the
/// ticker re-arms the shared player when a round's audio dies under it).
///
/// Both defects shipped: the sampler drew from the whole catalog, so most cards had no
/// resolvable source, and in cloud mode each unresolvable track makes `SetlistPlayer`
/// advance immediately — a queue of them burned down to `stop()` within a frame and the
/// round played out in total silence with nothing left to notice.
@MainActor
final class PuzzlePlayabilityTests: XCTestCase {

    // MARK: - Sampler

    private func songs(_ ids: [String], appleMusicIds: [String: String] = [:]) -> [IndexSong] {
        ids.map { IndexSong.minimal(id: $0, name: "Song \($0)", artist: "A",
                                    appleMusicId: appleMusicIds[$0]) }
    }

    private func inputs(_ songs: [IndexSong], playable: Set<String> = [],
                        canStream: Bool = false) -> PuzzleSampler.Inputs {
        PuzzleSampler.Inputs(songs: songs, genreBySongId: [:], favoriteIds: [],
                             playCounts: [:], membershipUnion: [], perTargetMembership: [],
                             playableNowIds: playable, canStreamAppleMusic: canStream)
    }

    func testPoolKeepsOnlySongsWhoseAudioCanStartNow() {
        let all = songs(["a", "b", "c", "d"])
        let pool = PuzzleSampler.pool(settings: PuzzleSettings(),
                                      inputs: inputs(all, playable: ["b", "d"]))
        XCTAssertEqual(pool.map(\.song.id).sorted(), ["b", "d"],
                       "only the burned/ripped songs may be dealt into a round")
    }

    func testStreamableSongsCountAsPlayableWhenAppleMusicIsReady() {
        let all = songs(["a", "b", "c"], appleMusicIds: ["c": "1234"])
        let ready = PuzzleSampler.pool(settings: PuzzleSettings(),
                                       inputs: inputs(all, playable: ["a"], canStream: true))
        XCTAssertEqual(ready.map(\.song.id).sorted(), ["a", "c"],
                       "a catalog id is playable audio while Apple Music is authorized")
        // …and NOT when it isn't: no subscription ⇒ the catalog id can't make sound.
        let notReady = PuzzleSampler.pool(settings: PuzzleSettings(),
                                          inputs: inputs(all, playable: ["a"], canStream: false))
        XCTAssertEqual(notReady.map(\.song.id), ["a"])
    }

    func testPlayabilityDegradesToOffWhenNothingIsPlayableAnywhere() {
        // A device with no rips, no burns and no subscription must still be able to PLAY the
        // game — an empty pool would make it unstartable, which is worse than a silent round.
        let all = songs(["a", "b", "c"])
        let pool = PuzzleSampler.pool(settings: PuzzleSettings(), inputs: inputs(all))
        XCTAssertEqual(pool.count, 3, "no known audio at all ⇒ the filter stands down")
    }

    func testPlayabilityDegradesWhenTheUsersFILTERSLeaveNoPlayableSong() {
        // The subtler unstartable case: audio EXISTS on the device, just not for anything the
        // chosen filters match. The fallback must key on the empty RESULT, not on "this device
        // has some audio somewhere", or Start would sit disabled forever.
        var year = PuzzleSettings()
        year.yearMin = 1990
        year.yearMax = 1999
        var nineties = IndexSong.minimal(id: "old", name: "Old", artist: "A")
        nineties = withYear(nineties, 1995)
        let inputs = PuzzleSampler.Inputs(
            songs: [nineties] + songs(["playable"]), genreBySongId: [:], favoriteIds: [],
            playCounts: [:], membershipUnion: [], perTargetMembership: [],
            playableNowIds: ["playable"], canStreamAppleMusic: false)
        let pool = PuzzleSampler.pool(settings: year, inputs: inputs)
        XCTAssertEqual(pool.map(\.song.id), ["old"],
                       "the only song matching the filters is unplayable — deal it rather than nothing")
    }

    /// `IndexSong` decodes from JSON; give one a year without reaching into its storage.
    private func withYear(_ song: IndexSong, _ year: Int) -> IndexSong {
        let obj: [String: Any] = ["id": song.id, "name": song.name, "artist": song.artist,
                                  "year": year]
        let data = try! JSONSerialization.data(withJSONObject: obj)
        return try! JSONDecoder().decode(IndexSong.self, from: data)
    }

    func testRawInputsBuildThePlayableSetOffTheMainActor() {
        let raw = PuzzleSampler.RawInputs(
            songs: songs(["a", "b"]), albumsById: [:], favoriteIds: [], playCounts: [:],
            membershipCollections: [], targetCollections: [],
            ripManifest: ["a": RipsStore.ManifestEntry(key: "rips/a.mp3")],
            burnedIds: ["b"], canStreamAppleMusic: true)
        let built = PuzzleSampler.Inputs(raw: raw)
        XCTAssertEqual(built.playableNowIds, ["a", "b"],
                       "the rip manifest and the burn index union into one playable set")
        XCTAssertTrue(built.canStreamAppleMusic, "the streaming flag rides through the snapshot")
    }

    // MARK: - Engine

    private struct Stack {
        let sequencer: SetlistPlayer
        let collections: CollectionsStore
        let engine: CollectorsPuzzleEngine
    }

    private func tempURL(_ tag: String) -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("pdj-play-\(tag)-\(UUID().uuidString).json")
        addTeardownBlock { try? FileManager.default.removeItem(at: url) }
        return url
    }

    private func makeStack() async -> Stack {
        let app = AppModel(loader: TestData.StubLoader())
        await app.loadIfNeeded()
        let rips = RipsStore(ripsBase: URL(string: "https://rips.test")!,
                             session: URLSession(configuration: .ephemeral))
        let burns = BurnStore(rips: rips, fileURL: tempURL("burns"))
        let player = PlayerEngine()
        let coordinator = PlaybackCoordinator(
            ripProvider: RipServerPlaybackProvider(rips: rips, player: player),
            appleMusic: AppleMusicPlaybackProvider(provider: AppleMusicProvider()))
        let sequencer = SetlistPlayer(player: player, rips: rips, burns: burns, coordinator: coordinator)
        let collections = CollectionsStore(fileURL: tempURL("coll"))
        collections.app = app
        let engine = CollectorsPuzzleEngine(
            app: app, sequencer: sequencer, collections: collections,
            favorites: FavoritesStore(fileURL: tempURL("fav")),
            playStats: PlayStatsStore(fileURL: tempURL("stats")),
            scoreboard: GameScoreboardStore(fileURL: tempURL("scores")),
            decisions: PuzzleDecisionStore(fileURL: tempURL("dec")),
            defaults: UserDefaults(suiteName: "test.play.\(UUID().uuidString)")!)
        engine.countdownEnabled = false
        engine.rng = PRNG.seededRng("playability")
        var settings = PuzzleSettings()
        settings.targetCollectionIds = [collections.createPocket("Crate", songIds: [], description: nil).id]
        engine.updateSettings(settings)
        return Stack(sequencer: sequencer, collections: collections, engine: engine)
    }

    /// The audio watchdog: when the run the round handed the sequencer dies (every source
    /// failed, or the queue drained), the next tick re-arms audio from the card on screen.
    func testTickReArmsAudioWhenTheRoundsRunDies() async {
        let s = await makeStack()
        await s.engine.startRound()
        XCTAssertTrue(s.sequencer.isRunning)
        let tag = s.sequencer.sourceSetlistId
        s.engine.skip()                       // now showing card #1
        XCTAssertEqual(s.engine.queueIndex, 1)

        s.sequencer.stop()                    // the run dies under the round (unresolvable sources)
        XCTAssertFalse(s.sequencer.isRunning)
        s.engine.tickOnce()

        XCTAssertTrue(s.sequencer.isRunning, "the ticker must put the round's audio back")
        XCTAssertEqual(s.sequencer.sourceSetlistId, tag, "…still tagged as THIS round's run")
        XCTAssertEqual(s.sequencer.queue.first?.id, s.engine.current?.id,
                       "audio resumes at the card the round is SHOWING, not back at the top")
        XCTAssertEqual(s.engine.queueIndex, 1, "re-arming must not advance the round")
    }

    /// The re-arm hands over only the TAIL of the queue, so the sequencer's index restarts
    /// at 0 against a later song. The drift re-sync has to account for that or it would
    /// stop following the audio (and, worse, mark songs "expired" at the wrong positions).
    func testDriftReSyncStaysCorrectAfterAReArm() async {
        let s = await makeStack()
        await s.engine.startRound()
        s.engine.skip(); s.engine.skip()      // showing card #2
        s.sequencer.stop()
        s.engine.tickOnce()                   // re-arm from card #2 (sequencer index 0)
        XCTAssertEqual(s.engine.queueIndex, 2)

        s.engine.tickOnce()                   // audio hasn't moved → the round mustn't either
        XCTAssertEqual(s.engine.queueIndex, 2, "a re-armed run's index 0 is NOT round position 0")

        s.sequencer.skipNext()                // the audio advances one track on its own
        s.engine.tickOnce()
        XCTAssertEqual(s.engine.queueIndex, 3, "the round follows the audio past the re-arm point")
    }

    /// The watchdog arms at most once per card, so audio that genuinely cannot start
    /// costs one retry — never a tick-rate restart loop.
    func testWatchdogArmsAtMostOncePerCard() async {
        let s = await makeStack()
        await s.engine.startRound()
        s.engine.skip()
        s.sequencer.stop()
        s.engine.tickOnce()
        XCTAssertTrue(s.sequencer.isRunning, "the first failure on this card is retried once")

        s.sequencer.stop()
        s.engine.tickOnce()
        XCTAssertFalse(s.sequencer.isRunning, "a second failure on the SAME card must not re-arm")

        // Moving to the NEXT card re-opens the one retry.
        s.engine.skip()
        s.engine.tickOnce()
        XCTAssertTrue(s.sequencer.isRunning, "a new card gets its own arm")
    }

    /// A target collection deleted since the last round must not survive the reload as a
    /// phantom: it left Start enabled with nothing checked, and a round would file songs
    /// into an assign button that writes nowhere.
    func testDeletedTargetCollectionsArePrunedOnLoad() async {
        let app = AppModel(loader: TestData.StubLoader())
        await app.loadIfNeeded()
        let collections = CollectionsStore(fileURL: tempURL("coll2"))
        collections.app = app
        let live = collections.createPlaylist("Still here")
        var settings = PuzzleSettings()
        settings.targetCollectionIds = [live.id, "pls_deleted"]
        settings.membershipCollectionIds = ["pkt_gone"]
        let suite = UserDefaults(suiteName: "test.prune.\(UUID().uuidString)")!
        suite.set(try! JSONEncoder().encode(settings), forKey: "pdj.puzzle.settings.v1")

        let rips = RipsStore(ripsBase: URL(string: "https://rips.test")!,
                             session: URLSession(configuration: .ephemeral))
        let burns = BurnStore(rips: rips, fileURL: tempURL("burns2"))
        let player = PlayerEngine()
        let coordinator = PlaybackCoordinator(
            ripProvider: RipServerPlaybackProvider(rips: rips, player: player),
            appleMusic: AppleMusicPlaybackProvider(provider: AppleMusicProvider()))
        let engine = CollectorsPuzzleEngine(
            app: app,
            sequencer: SetlistPlayer(player: player, rips: rips, burns: burns, coordinator: coordinator),
            collections: collections,
            favorites: FavoritesStore(fileURL: tempURL("fav2")),
            playStats: PlayStatsStore(fileURL: tempURL("stats2")),
            scoreboard: GameScoreboardStore(fileURL: tempURL("scores2")),
            decisions: PuzzleDecisionStore(fileURL: tempURL("dec2")),
            defaults: suite)
        XCTAssertEqual(engine.settings.targetCollectionIds, [live.id],
                       "the deleted target is dropped, the live one kept")
        XCTAssertTrue(engine.settings.membershipCollectionIds.isEmpty,
                      "a deleted membership filter is dropped too")
    }
}

import XCTest
@testable import PocketDJ

/// 1.0.4 Siri — the song matcher (pure), and the `IntentServices+Siri` operations every Siri /
/// Shortcuts / Siri AI request lands on: add a song to a collection by name (fuzzy song + collection
/// resolution, "this song" = the playing song, already-a-member says so and writes nothing), Now
/// Playing Mix Mode on/off, and each stem muted / unmuted by name — including the Mix-Mode-off path
/// a mute takes (Mix Mode on → engage → Stems on → mute), on the REAL sequencer + `NowPlayingDSP`.
@MainActor
final class IntentSongMatcherTests: XCTestCase {

    private let rows: [IntentSongMatcher.Row] = [
        .init(id: "a", name: "Make Me Proud", artist: "Drake"),
        .init(id: "a2", name: "Make Me Proud", artist: "Drake"),                  // same recording, 2nd source
        .init(id: "b", name: "Make Me Proud (feat. Nicki Minaj)", artist: "Drake"),
        .init(id: "c", name: "Stand by Me", artist: "Ben E. King"),
        .init(id: "d", name: "Stand", artist: "R.E.M."),
        .init(id: "e", name: "Proud Mary", artist: "Creedence Clearwater Revival"),
        .init(id: "f", name: "Hello", artist: "Adele"),
        .init(id: "g", name: "Hello", artist: "Lionel Richie"),
        .init(id: "h", name: "Café del Mar - 2011 Remaster", artist: "Energy 52"),
    ]

    private func ids(_ q: String, prefer: Set<String> = []) -> [String] {
        IntentSongMatcher.rank(q, rows: rows, prefer: { prefer.contains($0) }).map(\.id)
    }

    func testExactTitleWinsAndCopiesOfOneRecordingCollapse() {
        let got = ids("make me proud")
        XCTAssertEqual(got.first, "a", "exact title first; the second source's copy is the same recording")
        XCTAssertFalse(got.contains("a2"))
        XCTAssertFalse(got.contains("e"), "a substring hit on another title isn't in the top tier")
    }

    func testPreferPicksWhichCopyOfARecordingIsReturned() {
        XCTAssertEqual(ids("Make Me Proud", prefer: ["a2"]).first, "a2", "the copy already in a collection / playing")
    }

    func testByArtistNarrowsAndTheWholePhraseStillMatchesATitleContainingBy() {
        XCTAssertEqual(ids("Hello by Adele"), ["f"])
        XCTAssertEqual(ids("hello by lionel richie"), ["g"])
        XCTAssertEqual(ids("Stand by Me").first, "c", "\"by\" inside a real title is not an artist split")
    }

    func testAmbiguousTitleReturnsEveryEquallyPlausibleRecording() {
        XCTAssertEqual(Set(ids("hello")), ["f", "g"], "two artists' Hello — Siri asks which")
    }

    func testTyposAndPunctuationAndVersionTails() {
        XCTAssertEqual(ids("make me prowd").first, "a", "one typo")
        XCTAssertEqual(ids("Make me proud!").first, "a")
        XCTAssertEqual(ids("cafe del mar").first, "h", "diacritics folded, \" - 2011 Remaster\" tail ignored")
        XCTAssertEqual(ids("the song Hello by Adele"), ["f"], "Siri's leading filler")
    }

    func testNoMatchIsEmpty() {
        XCTAssertEqual(ids("zzzz qqqq"), [])
        XCTAssertEqual(ids("   "), [])
    }

    func testCollectionNameRankingIgnoresFillerAndPrefersExact() {
        let names = ["Workout", "Workout Warmup", "Wind Down", "Late Night"]
        XCTAssertEqual(CollectionEntity.rankByName("my workout playlist", names, name: { $0 }), ["Workout"])
        XCTAssertEqual(CollectionEntity.rankByName("workot", names, name: { $0 }).first, "Workout", "typo")
        XCTAssertEqual(CollectionEntity.rankByName("late nite", names, name: { $0 }).first, "Late Night")
        XCTAssertEqual(CollectionEntity.rankByName("xyzzy", names, name: { $0 }), [])
    }

    /// An add WRITES, and Siri runs a lone match without asking — so a spoken name never lands
    /// on a collection it only resembles by initials or by a typo buried in a longer name.
    func testCollectionNameRankingNeverGuessesFromInitialsOrBuriedTypos() {
        let names = ["Rainy Afternoon Pop", "Friday Night Mix", "Sunday Morning Workout Warmup"]
        XCTAssertEqual(CollectionEntity.rankByName("rap", names, name: { $0 }), [],
                       "R…a…p is a subsequence of Rainy Afternoon Pop — not a match for a spoken name")
        XCTAssertEqual(CollectionEntity.rankByName("fnm", names, name: { $0 }), [])
        XCTAssertEqual(CollectionEntity.rankByName("workot", names, name: { $0 }), [],
                       "a one-letter typo of a word inside a long name is not that name")
        XCTAssertEqual(CollectionEntity.rankByName("friday night", names, name: { $0 }), ["Friday Night Mix"],
                       "a literal prefix still resolves")
        XCTAssertEqual(CollectionEntity.rankByName("Workout 🏋️", ["Workout 🏋️", "Workout Warmup"], name: { $0 }),
                       ["Workout 🏋️"], "an emoji-named collection matches exactly")
        XCTAssertEqual(Set(CollectionEntity.rankByName("workout", ["Workout", "Workout 🏋️"], name: { $0 })),
                       ["Workout", "Workout 🏋️"], "names equal once folded tie — Siri asks which")
    }
}

@MainActor
final class SiriIntentServicesTests: XCTestCase {

    // MARK: Fixtures

    private struct Rig {
        let services: IntentServices
        let collections: CollectionsStore
        let seq: SetlistPlayer
        let dsp: NowPlayingDSP
        let burnDir: URL
    }

    /// `burned`: songs on the device (12 s WAVs). `stemsOnDisk`: song → its burned stem parts.
    private func rig(burned: [String] = [], stemsOnDisk: [String: [String]] = [:]) async throws -> Rig {
        let app = AppModel(loader: TestData.StubLoader())
        await app.loadIfNeeded()
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("pdj-siri-\(UUID().uuidString).json")
        addTeardownBlock { try? FileManager.default.removeItem(at: url) }
        let collections = CollectionsStore(fileURL: url)
        collections.app = app
        let settings = SettingsStore(defaults: UserDefaults(suiteName: "test.\(UUID())")!)
        let rips = RipsStore(ripsBase: URL(string: "https://rips.test")!, session: URLSession(configuration: .ephemeral))
        var m: [String: RipsStore.ManifestEntry] = [:]
        for id in burned {
            m[id] = .init(key: "rips/\(id).mp3", source: "digital",
                          stems: stemsOnDisk[id] == nil ? nil
                            : .init(vocals: "stems/\(id)/vocals.mp3", drums: "stems/\(id)/drums.mp3",
                                    bass: "stems/\(id)/bass.mp3", other: "stems/\(id)/other.mp3"))
        }
        rips.setManifest(m)
        let burns = try MixBurnFixture.burnStore(ids: burned, rips: rips,
                                                 lengths: Dictionary(uniqueKeysWithValues: burned.map { ($0, 12.0) }))
        let player = PlayerEngine()
        let coord = PlaybackCoordinator(ripProvider: RipServerPlaybackProvider(rips: rips, player: player),
                                        appleMusic: AppleMusicPlaybackProvider(provider: AppleMusicProvider()))
        let seq = SetlistPlayer(player: player, rips: rips, burns: burns, coordinator: coord)
        let dsp = NowPlayingDSP(burns: burns)
        seq.dsp = dsp
        let mix = MixEngine(burns: burns)
        let studioURL = FileManager.default.temporaryDirectory.appendingPathComponent("pdj-siri-studio-\(UUID().uuidString).json")
        let favURL = FileManager.default.temporaryDirectory.appendingPathComponent("pdj-siri-fav-\(UUID().uuidString).json")
        addTeardownBlock {
            try? FileManager.default.removeItem(at: studioURL); try? FileManager.default.removeItem(at: favURL)
        }
        let services = IntentServices(app: app, settings: settings, collections: collections,
                                      setlistPlayer: seq, mix: mix, burns: burns,
                                      studio: StudioStore(fileURL: studioURL), rips: rips,
                                      favorites: FavoritesStore(fileURL: favURL))
        addTeardownBlock { @MainActor in seq.stop(); dsp.disengage() }
        let r = Rig(services: services, collections: collections, seq: seq, dsp: dsp,
                    burnDir: burns.appBurnsDirOverride!)
        let stemData = stemsOnDisk.isEmpty ? Data() : try StemAudioProbe.bundled("stem-noise-12s", in: Self.self)
        for (id, parts) in stemsOnDisk {
            for p in parts { try stemData.write(to: r.burnDir.appendingPathComponent("stem-\(id)-\(p).mp3")) }
        }
        return r
    }

    private func waitUntil(_ message: String, timeout: TimeInterval = 5, _ predicate: () -> Bool) async {
        await StemAudioProbe.wait(timeout: timeout, until: predicate)
        XCTAssertTrue(predicate(), "timed out waiting: \(message)")
    }

    private func item(_ id: String, title: String? = nil) -> SetlistPlayer.Item {
        .init(id: id, title: title ?? id, artist: "A")
    }

    // MARK: Song + collection resolution

    func testSongQueryResolvesSpokenTitlesFromTheCatalog() async throws {
        let r = try await rig()
        XCTAssertEqual(r.services.matchSongs("get down by cobalt").map(\.id), ["sng_6"])
        XCTAssertEqual(r.services.matchSongs("Slow burn").map(\.id), ["sng_7"])
        XCTAssertEqual(r.services.matchSongs("swing lo").map(\.id), ["sng_4"], "prefix")
        XCTAssertEqual(r.services.matchSongs("blue noet").map(\.id), ["sng_5"], "typo")
        XCTAssertEqual(r.services.matchSongs("nothing like this").map(\.id), [])
    }

    func testCollectionEntitiesCoverPocketsAndPlaylistsAndMatchByName() async throws {
        let r = try await rig()
        let w = r.collections.createPocket("Workout")
        let pl = r.collections.createPlaylist("Late Night Drive")
        let all = CollectionEntity.all(in: r.collections)
        XCTAssertEqual(Set(all.map(\.id)), [MixSource.pocket(w.id).id, MixSource.playlist(pl.id).id],
                       "pockets + playlists, the Now Playing scratch playlist never offered")
        XCTAssertEqual(CollectionEntity.matching("workout", in: r.collections).map(\.name), ["Workout"])
        XCTAssertEqual(CollectionEntity.matching("the late night drive playlist", in: r.collections).map(\.name),
                       ["Late Night Drive"])
        XCTAssertEqual(CollectionEntity.resolve(ids: [MixSource.playlist(pl.id).id, "pocket:gone"], in: r.collections)
                        .map(\.name), ["Late Night Drive"])
    }

    // MARK: Add to collection

    func testAddNamedSongToAPocketLandsThroughTheAddToPath() async throws {
        let r = try await rig()
        let w = r.collections.createPocket("Workout")
        let res = try await r.services.addSongToCollection(songId: "sng_6", collectionId: MixSource.pocket(w.id).id)
        XCTAssertEqual(res, .init(songTitle: "Get Down", collectionName: "Workout", alreadyMember: false))
        XCTAssertEqual(res.dialog, "Added Get Down to Workout.")
        XCTAssertEqual(r.collections.pocket(w.id)?.songIds, ["sng_6"])
        XCTAssertEqual(r.collections.recentAddTargets.first?.id, w.id, "a normal add: the Recent row learns it")
    }

    func testAddToAPlaylistLandsInItsDefaultChapter() async throws {
        let r = try await rig()
        let pl = r.collections.createPlaylist("Evening")
        try await r.services.addSongToCollection(songId: "sng_1", collectionId: MixSource.playlist(pl.id).id)
        XCTAssertTrue(r.collections.playlist(pl.id, contains: "sng_1"))
        XCTAssertEqual(r.collections.lastAddTarget?.sequenceId, r.collections.playlist(pl.id)?.sequences.first?.nodeId,
                       "the same chapter the Add sheet's row tap uses")
    }

    func testAlreadyAMemberSaysSoAndWritesNothing() async throws {
        let r = try await rig()
        let w = r.collections.createPocket("Workout")
        r.collections.addSong("sng_2", toPocket: w.id)
        let res = try await r.services.addSongToCollection(songId: "sng_2", collectionId: MixSource.pocket(w.id).id)
        XCTAssertTrue(res.alreadyMember)
        XCTAssertEqual(res.dialog, "Pulse is already in Workout.")
        XCTAssertEqual(r.collections.pocket(w.id)?.songIds, ["sng_2"], "no duplicate, and never a toggle-off")
    }

    func testThisSongDefaultsToTheNowPlayingTrack() async throws {
        let r = try await rig()
        let w = r.collections.createPocket("Workout")
        do {
            _ = try await r.services.addSongToCollection(songId: nil, collectionId: MixSource.pocket(w.id).id)
            XCTFail("nothing playing must throw")
        } catch PocketDJIntentError.nothingPlaying {}
        r.seq.play([item("sng_3", title: "Drift"), item("sng_4")])
        XCTAssertEqual(r.services.currentSongId(), "sng_3")
        let res = try await r.services.addSongToCollection(songId: nil, collectionId: MixSource.pocket(w.id).id)
        XCTAssertEqual(res.dialog, "Added Drift to Workout.")
        XCTAssertEqual(r.collections.pocket(w.id)?.songIds, ["sng_3"])
    }

    func testMissingCollectionAndOnboardingVeto() async throws {
        let r = try await rig()
        do {
            _ = try await r.services.addSongToCollection(songId: "sng_1", collectionId: "pocket:gone")
            XCTFail("a deleted collection must throw")
        } catch PocketDJIntentError.collectionNotFound {}
        let w = r.collections.createPocket("Workout")
        r.services.onboardingIncomplete = { true }
        do {
            _ = try await r.services.addSongToCollection(songId: "sng_1", collectionId: MixSource.pocket(w.id).id)
            XCTFail("onboarding veto")
        } catch PocketDJIntentError.setupIncomplete {}
        XCTAssertEqual(r.collections.pocket(w.id)?.songIds, [])
    }

    func testPlayCollectionDispatchesByKind() async throws {
        let r = try await rig()
        let w = r.collections.createPocket("Workout")
        r.collections.addSong("sng_1", toPocket: w.id)
        let name = try await r.services.playCollection(id: MixSource.pocket(w.id).id, shuffle: false)
        XCTAssertEqual(name, "Workout")
        XCTAssertEqual(r.seq.queue.map(\.id), ["sng_1"])
    }

    // MARK: Mix Mode

    func testMixModeOnAndOff() async throws {
        let r = try await rig()
        XCTAssertThrowsError(try r.services.setNowPlayingMixMode(true), "no session") {
            guard case PocketDJIntentError.nothingPlaying = $0 else { return XCTFail("\($0)") }
        }
        r.seq.play([item("sng_1")])
        XCTAssertFalse(r.seq.mixMode.enabled)
        XCTAssertTrue(try r.services.setNowPlayingMixMode(true).hasPrefix("Mix Mode is on"))
        XCTAssertTrue(r.seq.mixMode.enabled)
        XCTAssertEqual(try r.services.setNowPlayingMixMode(true), "Mix Mode is already on.")
        XCTAssertEqual(try r.services.setNowPlayingMixMode(false), "Mix Mode is off.")
        XCTAssertFalse(r.seq.mixMode.enabled)
    }

    // MARK: Stems

    private let allStems = MixEngine.stemNames

    /// A burned song with stems on disk, playing, DSP not yet engaged, Mix Mode OFF.
    private func playingWithStems(_ id: String = "s1") async throws -> Rig {
        let r = try await rig(burned: [id], stemsOnDisk: [id: allStems])
        r.seq.play([item(id)])
        await waitUntil("\(id) playing") { r.services.rips.nowPlaying?.songId == id }
        return r
    }

    /// The DSP builds its graph lazily on the first engage, so "no audio device" is only known
    /// AFTER the operation under test engaged it.
    private func requireAudio(_ r: Rig) throws {
        try XCTSkipUnless(r.dsp.isReady, "no audio device on this test host")
    }

    func testMuteWithMixModeOffTurnsMixModeOnEngagesAndMutes() async throws {
        let r = try await playingWithStems()
        XCTAssertFalse(r.seq.mixMode.enabled)
        XCTAssertFalse(r.seq.mixEngaged)
        let said = try r.services.setStem(.vocals, muted: true)
        try requireAudio(r)
        XCTAssertTrue(said.hasPrefix("Turned on Mix Mode and muted the vocals"), said)
        XCTAssertTrue(r.seq.mixMode.enabled, "the mute engaged Mix Mode first")
        XCTAssertTrue(r.seq.mixEngaged, "the DSP owns the track (the panel's first-touch hand-off)")
        XCTAssertTrue(r.dsp.stemMode || r.dsp.stemsLoading, "the Stems toggle is on")
        XCTAssertTrue(r.dsp.isStemMuted("vocals"))
        await waitUntil("stems on air") { r.dsp.stemsOnAir }
        XCTAssertEqual(r.dsp.stemNodeVolume("vocals"), 0, "audibly muted")
        for other in ["drums", "bass", "other"] { XCTAssertFalse(r.dsp.isStemMuted(other)) }
    }

    func testEachStemMutesAndUnmutesByName() async throws {
        let r = try await playingWithStems()
        for stem in StemPart.allCases {
            let said = try r.services.setStem(stem, muted: true)
            try requireAudio(r)
            XCTAssertFalse(said.contains("can't"), said)
            XCTAssertTrue(r.dsp.isStemMuted(stem.stemName), "\(stem) muted")
            XCTAssertTrue(try r.services.setStem(stem, muted: true).contains("already muted"), "idempotent")
            XCTAssertEqual(try r.services.setStem(stem, muted: false), "Unmuted \(stem.spoken).")
            XCTAssertFalse(r.dsp.isStemMuted(stem.stemName), "\(stem) back")
        }
        XCTAssertTrue(try r.services.setStem(.drums, muted: false).contains("already playing"))
    }

    func testMuteWithMixModeAlreadyOnJustMutes() async throws {
        let r = try await playingWithStems()
        r.seq.setMixMode(true)
        let said = try r.services.setStem(.bass, muted: true)
        try requireAudio(r)
        XCTAssertTrue(said.hasPrefix("Muted the bass"), said)
        XCTAssertTrue(r.dsp.isStemMuted("bass"))
    }

    func testUnmuteWithNothingEngagedTouchesNothing() async throws {
        let r = try await playingWithStems()
        XCTAssertEqual(try r.services.setStem(.vocals, muted: false), "The vocals are already playing.")
        XCTAssertFalse(r.seq.mixEngaged, "an unmute never engages the DSP")
        XCTAssertFalse(r.seq.mixMode.enabled, "…or turns Mix Mode on")
    }

    func testSongWithoutStemsSaysWhyAfterTurningMixModeOn() async throws {
        let r = try await rig(burned: ["n1"])
        r.seq.play([item("n1")])
        await waitUntil("n1 playing") { r.services.rips.nowPlaying?.songId == "n1" }
        let said = try r.services.setStem(.vocals, muted: true)
        try requireAudio(r)
        XCTAssertTrue(said.hasPrefix("Mix Mode is on, but this song has no stems yet"), said)
        XCTAssertTrue(r.seq.mixMode.enabled)
        XCTAssertFalse(r.dsp.isStemMuted("vocals"))
    }

    func testStemWithNothingPlayingThrows() async throws {
        let r = try await rig()
        XCTAssertThrowsError(try r.services.setStem(.drums, muted: true)) {
            guard case PocketDJIntentError.nothingPlaying = $0 else { return XCTFail("\($0)") }
        }
    }

    func testStemSynonymsMapToTheEnginesNames() {
        XCTAssertEqual(StemPart.allCases.map(\.stemName), MixEngine.stemNames)
        let syn = StemPart.caseDisplayRepresentations
        XCTAssertTrue(syn[.vocals]?.synonyms.contains("vocal") == true)
        XCTAssertTrue(syn[.vocals]?.synonyms.contains("voice") == true)
        XCTAssertTrue(syn[.drums]?.synonyms.contains("drum") == true)
        XCTAssertTrue(syn[.other]?.synonyms.contains("instruments") == true)
        XCTAssertTrue(syn[.other]?.synonyms.contains("music") == true)
    }
}

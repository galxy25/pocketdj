import XCTest
@testable import PocketDJ

/// Jukebox Hero — the request line's DJ brain + queue plumbing (docs/design/jukebox-hero.md).
/// Pure matching (normalized-exact + fuzzy ranking), the matcher orchestration with a
/// STUBBED pick model + Apple Music search (the PocketBriefModel testing doctrine — no
/// FoundationModels, no MusicKit), the SetlistPlayer "Surprise Slot" random insert
/// (injectable slot), the state snapshots guests see (incl. View + Hear gating), and the
/// host decision flow into the live queue. State-only throughout — no audio, no network
/// (the queue tests mirror NowPlayingQueueTests' synchronous style).
@MainActor
final class JukeboxTests: XCTestCase {

    // MARK: Fixtures

    private func makeApp() async -> AppModel {
        let app = AppModel(loader: TestData.StubLoader())
        await app.loadIfNeeded()
        return app
    }

    private struct Stack {
        let rips: RipsStore
        let burns: BurnStore
        let player: PlayerEngine
        let coordinator: PlaybackCoordinator
        let sequencer: SetlistPlayer
        let mix: MixEngine
    }

    private func makeStack() -> Stack {
        let rips = RipsStore(ripsBase: URL(string: "https://rips.test")!,
                             session: URLSession(configuration: .ephemeral))
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("pdj-jukebox-\(UUID().uuidString).json")
        addTeardownBlock { try? FileManager.default.removeItem(at: url) }
        let burns = BurnStore(rips: rips, fileURL: url)
        let player = PlayerEngine()
        let coordinator = PlaybackCoordinator(
            ripProvider: RipServerPlaybackProvider(rips: rips, player: player),
            appleMusic: AppleMusicPlaybackProvider(provider: AppleMusicProvider()))
        let sequencer = SetlistPlayer(player: player, rips: rips, burns: burns, coordinator: coordinator)
        let mix = MixEngine(burns: burns)
        return Stack(rips: rips, burns: burns, player: player, coordinator: coordinator,
                     sequencer: sequencer, mix: mix)
    }

    private func makeStore(_ app: AppModel, _ s: Stack) -> JukeboxStore {
        let store = JukeboxStore(app: app, sequencer: s.sequencer, player: s.player,
                                 coordinator: s.coordinator, rips: s.rips,
                                 mix: s.mix, burns: s.burns,
                                 defaults: UserDefaults(suiteName: "test.jukebox.\(UUID().uuidString)")!)
        store.makePickModel = { nil }   // tests never touch FoundationModels
        return store
    }

    private func item(_ id: String) -> SetlistPlayer.Item {
        .init(id: id, title: id.uppercased(), artist: "A")
    }

    /// A stubbed pick model: returns a canned answer (or throws).
    private struct StubPick: JukeboxPickModel {
        var answer: Int?
        var error: Error?
        func pick(title: String, artist: String, candidates: [JukeboxPickCandidate]) async throws -> Int? {
            if let error { throw error }
            return answer
        }
    }

    private func amTrack(_ storeID: String, title: String, artist: String) -> StreamingTrack {
        StreamingTrack(id: "appleMusic:\(storeID)", kind: .appleMusic, providerTrackID: storeID,
                       title: title, artist: artist, artworkURL: nil, durationSeconds: 200)
    }

    // MARK: Pure matching

    func testExactMatchNormalizesEditionNoiseAndChecksArtist() async {
        let app = await makeApp()
        // "(Live)" tail + casing noise must not block the hit (ShazamCatalogMatch.norm).
        XCTAssertEqual(JukeboxMatching.exact(title: "neon (Live)", artist: "ARIA", in: app.songs)?.id, "sng_1")
        // Compatible artist = containment either way ("Aria feat. Bento" ⊇ "Aria").
        XCTAssertEqual(JukeboxMatching.exact(title: "Neon", artist: "Aria feat. Bento", in: app.songs)?.id, "sng_1")
        // A wrong artist must NOT match another artist's song of the same title.
        XCTAssertNil(JukeboxMatching.exact(title: "Neon", artist: "Cobalt", in: app.songs))
    }

    func testFuzzyCandidatesRankTitleCoverageAndArtist() async {
        let app = await makeApp()
        let hits = JukeboxMatching.candidates(title: "get down", artist: "cobalt", in: app.songs)
        XCTAssertEqual(hits.first?.id, "sng_6")
        // At least one TITLE token must hit — an artist alone must not drag in a discography.
        XCTAssertTrue(JukeboxMatching.candidates(title: "zzz", artist: "Cobalt", in: app.songs).isEmpty)
        XCTAssertTrue(JukeboxMatching.candidates(title: "", artist: "Cobalt", in: app.songs).isEmpty)
        // Partial title tokens still surface the song ("slow" → Slow Burn, not Swing Low).
        XCTAssertEqual(JukeboxMatching.candidates(title: "slow", artist: "", in: app.songs).first?.id, "sng_7")
    }

    // MARK: Matcher orchestration (stub model + stub Apple Music)

    func testExactHitShortCircuitsBeforeTheModel() async {
        let app = await makeApp()
        struct MustNotRun: JukeboxPickModel {
            func pick(title: String, artist: String, candidates: [JukeboxPickCandidate]) async throws -> Int? {
                XCTFail("exact hit must not consult the model"); return nil
            }
        }
        let matcher = JukeboxMatcher(model: MustNotRun(), searchAppleMusic: nil)
        let match = await matcher.match(title: "Neon", artist: "Aria", app: app)
        XCTAssertEqual(match, .catalog(app.songsById["sng_1"]!))
    }

    func testModelPickChoosesAmongFuzzyCandidates() async {
        let app = await makeApp()
        // "blue swing" fuzzy-hits both Bento songs; the model picks #2.
        let fuzzy = JukeboxMatching.candidates(title: "blue swing", artist: "bento", in: app.songs)
        XCTAssertTrue(fuzzy.count >= 2)
        let matcher = JukeboxMatcher(model: StubPick(answer: 2), searchAppleMusic: nil)
        let match = await matcher.match(title: "blue swing", artist: "bento", app: app)
        XCTAssertEqual(match, .catalog(fuzzy[1]))
    }

    func testModelRejectionFallsThroughToAppleMusic() async {
        let app = await makeApp()
        // Fuzzy candidates exist ("pulse"), the model says NONE is the song → AM search runs.
        let matcher = JukeboxMatcher(model: StubPick(answer: nil),
                                     searchAppleMusic: { _ in [self.amTrack("555", title: "Pulse 2049", artist: "Other")] })
        let match = await matcher.match(title: "pulse", artist: "someone else", app: app)
        XCTAssertEqual(match, .appleMusic(storeID: "555", title: "Pulse 2049", artist: "Other"))
    }

    func testModelFailureFallsBackToTopCandidate() async {
        let app = await makeApp()
        let matcher = JukeboxMatcher(model: StubPick(error: URLError(.timedOut)), searchAppleMusic: nil)
        let match = await matcher.match(title: "get down", artist: "cobalt", app: app)
        XCTAssertEqual(match, .catalog(app.songsById["sng_6"]!))
    }

    func testNoModelUsesTopCandidate() async {
        let app = await makeApp()
        let matcher = JukeboxMatcher(model: nil, searchAppleMusic: nil)
        let match = await matcher.match(title: "swing low", artist: "", app: app)
        XCTAssertEqual(match, .catalog(app.songsById["sng_4"]!))
    }

    func testAppleMusicHitMapsBackToTheCatalogWhenIndexed() async {
        let app = await makeApp()
        // Nothing in the catalog fuzzy-matches "zulu", but the AM result's title+artist
        // IS an indexed song → the match folds back to the catalog id (play the rip,
        // not a second AM copy). AppleMusicRecognition.indexSong is the mapper.
        let matcher = JukeboxMatcher(model: nil,
                                     searchAppleMusic: { _ in [self.amTrack("999", title: "Neon", artist: "Aria")] })
        let match = await matcher.match(title: "zulu", artist: "", app: app)
        XCTAssertEqual(match, .catalog(app.songsById["sng_1"]!))
    }

    func testNothingAnywhereIsNone() async {
        let app = await makeApp()
        let matcher = JukeboxMatcher(model: nil, searchAppleMusic: { _ in [] })
        let match = await matcher.match(title: "zulu", artist: "", app: app)
        XCTAssertEqual(match, JukeboxMatch.none)
    }

    // MARK: Surprise Slot (random insert)

    func testInsertRandomInQueueBoundsAndPlacement() {
        let seq = makeStack().sequencer
        seq.play([item("a"), item("b"), item("c")], sourceSetlistId: nil)
        // Injected slot at the LOW bound → right after the current track.
        seq.insertRandomInQueue([item("x")], slot: { $0.lowerBound })
        XCTAssertEqual(seq.queue.map(\.id), ["a", "x", "b", "c"])
        // Injected slot at the HIGH bound → the very end.
        seq.insertRandomInQueue([item("y")], slot: { $0.upperBound })
        XCTAssertEqual(seq.queue.map(\.id), ["a", "x", "b", "c", "y"])
        // The current track is never disturbed, and the DEFAULT random slot stays legal.
        for _ in 0..<20 {
            seq.insertRandomInQueue([item("z")])
        }
        XCTAssertEqual(seq.queue[seq.index].id, "a")
        XCTAssertEqual(seq.queue.count, 25)
        seq.stop()
        // Idle ⇒ no-op (the live-edit contract).
        seq.insertRandomInQueue([item("w")])
        XCTAssertTrue(seq.queue.isEmpty)
    }

    // MARK: State snapshots (what guests see)

    func testSnapshotIdleThenRunningThenHear() async {
        let app = await makeApp()
        let stack = makeStack()
        let store = makeStore(app, stack)

        // Idle: nothing playing, view-only.
        var snap = store.stateSnapshot()
        XCTAssertNil(snap.nowPlaying)
        XCTAssertFalse(snap.hear)
        XCTAssertTrue(snap.upNext.isEmpty)

        // Running: current + the upcoming tail, no stream URL while view-only.
        stack.sequencer.play([item("a"), item("b"), item("c")], sourceSetlistId: nil)
        snap = store.stateSnapshot()
        XCTAssertEqual(snap.nowPlaying?.title, "A")
        XCTAssertEqual(snap.upNext.map(\.title), ["B", "C"])
        XCTAssertNil(snap.nowPlaying?.streamUrl)

        // View + Hear: the current track's PUBLIC rip URL rides the snapshot — but only
        // when the manifest actually has a durable rip for it.
        store.hearEnabled = true
        snap = store.stateSnapshot()
        XCTAssertTrue(snap.hear)
        XCTAssertNil(snap.nowPlaying?.streamUrl, "no manifest rip yet ⇒ view-only track")
        stack.rips.setManifest(["a": .init(key: "rips/a.mp3", source: "digital")])
        snap = store.stateSnapshot()
        XCTAssertEqual(snap.nowPlaying?.streamUrl, "\(Config.ripsBase.absoluteString)/rips/a.mp3")
        stack.sequencer.stop()
    }

    func testSnapshotCoversStandaloneSinglePlays() async {
        let app = await makeApp()
        let stack = makeStack()
        let store = makeStore(app, stack)
        // A single-row play outside the sequencer still shows on the guests' page.
        stack.rips.setNowPlaying(.init(songId: "sng_1", title: "Neon", artist: "Aria",
                                       url: URL(string: "https://rips.test/rips/sng_1.mp3")!,
                                       live: false, startMs: nil, seekMs: nil, waveform: nil))
        let snap = store.stateSnapshot()
        XCTAssertEqual(snap.nowPlaying?.title, "Neon")
        XCTAssertTrue(snap.upNext.isEmpty)
    }

    func testStatePayloadEncodesTheWireKeys() throws {
        let payload = JukeboxStatePayload(
            hear: true,
            nowPlaying: .init(title: "T", artist: "A", lengthMs: 1000, positionMs: 500,
                              streamUrl: "https://x/y.mp3"),
            upNext: [.init(title: "U", artist: "B")])
        let obj = try JSONSerialization.jsonObject(with: JSONEncoder().encode(payload)) as? [String: Any]
        XCTAssertEqual(obj?["hear"] as? Bool, true)
        let np = obj?["nowPlaying"] as? [String: Any]
        XCTAssertEqual(np?["streamUrl"] as? String, "https://x/y.mp3")
        XCTAssertEqual(np?["positionMs"] as? Int, 500)
        XCTAssertEqual((obj?["upNext"] as? [[String: Any]])?.count, 1)
    }

    // MARK: Host decisions → the live queue

    private func pendingItem(_ id: String, match: JukeboxMatch?) -> JukeboxStore.InboxItem {
        .init(request: JukeboxRequest(id: id, seq: 1, title: "t", artist: "a",
                                      createdAt: 0, status: "pending"),
              match: match)
    }

    func testAcceptPlacesIntoTheRunningQueue() async {
        let app = await makeApp()
        let stack = makeStack()
        let store = makeStore(app, stack)
        stack.sequencer.play([item("a"), item("b")], sourceSetlistId: nil)

        store.accept(pendingItem("r1", match: .catalog(app.songsById["sng_1"]!)), placement: .next)
        XCTAssertEqual(stack.sequencer.queue.map(\.id), ["a", "sng_1", "b"])

        store.accept(pendingItem("r2", match: .catalog(app.songsById["sng_2"]!)), placement: .end)
        XCTAssertEqual(stack.sequencer.queue.map(\.id), ["a", "sng_1", "b", "sng_2"])

        // An Apple-Music-only match queues under its namespaced id (streams via MusicKit).
        store.accept(pendingItem("r3", match: .appleMusic(storeID: "777", title: "X", artist: "Y")),
                     placement: .random)
        XCTAssertTrue(stack.sequencer.queue.contains { $0.id == "am:777" })
        XCTAssertEqual(stack.sequencer.queue[stack.sequencer.index].id, "a", "current never disturbed")
        stack.sequencer.stop()
    }

    func testAcceptWithNothingRunningStartsTheRadio() async {
        let app = await makeApp()
        let stack = makeStack()
        let store = makeStore(app, stack)
        XCTAssertFalse(stack.sequencer.isRunning)
        store.accept(pendingItem("r1", match: .catalog(app.songsById["sng_6"]!)), placement: .next)
        XCTAssertTrue(stack.sequencer.isRunning)
        XCTAssertEqual(stack.sequencer.queue.map(\.id), ["sng_6"])
        stack.sequencer.stop()
    }

    // MARK: Broadcast (Mix tie-in)

    /// The auto queue's jukebox seams: `autoUpcoming` is the not-yet-reached tail, and
    /// `autoQueueInsert` lands at/after `autoNextToLoad` — the preloaded on-deck track is
    /// never displaced (in-mix actions take precedence). Engine-level, no audio needed:
    /// the queue shape is bookkeeping (unresolvable loadables just leave decks empty).
    func testMixAutoQueueInsertRespectsCommittedDecks() throws {
        let stack = makeStack()
        let mix = stack.mix
        func load(_ id: String) -> MixLoadable {
            MixLoadable(songId: id, title: id.uppercased(), artist: "A",
                        bpm: nil, camelot: nil, key: nil, albumId: nil, lengthMs: 180_000)
        }
        func item(_ id: String) -> MixEngine.AutoMixItem {
            .init(loadable: load(id), durationMs: 180_000)
        }
        // Not mixing ⇒ no-op.
        mix.autoQueueInsert(item("x"), placement: .end)
        XCTAssertTrue(mix.autoUpcoming.isEmpty)

        mix.startAutoMix([item("a"), item("b"), item("c")], shuffled: false, lead: 15, fade: 3)
        guard mix.autoMixing else { throw XCTSkip("no audio device on this test host") }
        XCTAssertEqual(mix.autoUpcoming.map(\.songId), ["b", "c"])
        // "Play next" lands AFTER the preloaded on-deck track ("b" is committed to deck B).
        mix.autoQueueInsert(item("x"), placement: .next)
        XCTAssertEqual(mix.autoUpcoming.map(\.songId), ["b", "x", "c"])
        mix.autoQueueInsert(item("y"), placement: .end)
        XCTAssertEqual(mix.autoUpcoming.map(\.songId), ["b", "x", "c", "y"])
        mix.autoQueueInsert(item("z"), placement: .random, slot: { $0.lowerBound })
        XCTAssertEqual(mix.autoUpcoming.map(\.songId), ["b", "z", "x", "c", "y"])
        mix.stopAutoMix()
    }

    /// A BROADCAST accept of an UNBURNED track parks a pending insert (a deck can only
    /// load burned files) — the auto queue is untouched until the burn lands, and the
    /// sequencer is never started underneath a running mix.
    func testBroadcastAcceptOfUnburnedTrackParksAPendingInsert() async throws {
        let app = await makeApp()
        let stack = makeStack()
        let store = makeStore(app, stack)
        stack.mix.startAutoMix([.init(loadable: MixLoadable(songId: "q", title: "Q", artist: "A",
                                                            bpm: nil, camelot: nil, key: nil,
                                                            albumId: nil, lengthMs: 180_000),
                                      durationMs: 180_000)],
                               shuffled: false, lead: 15, fade: 3)
        guard stack.mix.autoMixing else { throw XCTSkip("no audio device on this test host") }
        store.accept(pendingItem("r1", match: .catalog(app.songsById["sng_1"]!)), placement: .next)
        XCTAssertEqual(store.pendingMixInserts.map(\.songId), ["sng_1"])
        XCTAssertTrue(stack.mix.autoUpcoming.isEmpty, "unburned ⇒ nothing lands in the queue yet")
        XCTAssertFalse(stack.sequencer.isRunning, "the mix owns the audio — no competing radio")
        stack.mix.stopAutoMix()
    }

    func testUnmatchedOrUndecidedRequestsCannotBeAccepted() async {
        let app = await makeApp()
        let stack = makeStack()
        let store = makeStore(app, stack)
        stack.sequencer.play([item("a")], sourceSetlistId: nil)
        store.accept(pendingItem("r1", match: JukeboxMatch.none), placement: .next)   // no match
        store.accept(pendingItem("r2", match: nil), placement: .next)                 // still matching
        store.accept(pendingItem("r3", match: .catalog(app.songsById["sng_1"]!)), placement: .denied)
        XCTAssertEqual(stack.sequencer.queue.map(\.id), ["a"], "none of those may touch the queue")
        stack.sequencer.stop()
    }

    // MARK: - Joined list + deep-link open signal

    /// A tapped share-link / "Open in PocketDJ" banner must BOTH add the jukebox to the joined list
    /// AND park its id in `pendingOpenId` — RootView consumes that to switch to the Jukebox tab and
    /// push the live join panel. Without the signal, deep-links opened the app but stranded the user
    /// on whatever tab they were on (the reported regression).
    func testAddJoinedInsertsEntryAndParksOpenSignal() async {
        let app = await makeApp()
        let store = makeStore(app, makeStack())
        XCTAssertNil(store.pendingOpenId)
        // Ids are base32 [a-z2-7], 8 chars (the server's shape) — a "1"/"0" would fail to parse.
        let link = JukeboxLink(url: URL(string: "pocketdj://jukebox/erjjo4jn")!)!
        store.addJoined(link)
        XCTAssertEqual(store.joinedSessions.first?.id, "erjjo4jn", "entry inserted at the top")
        XCTAssertEqual(store.pendingOpenId, "erjjo4jn", "deep-link open signal parked for RootView")
        // A second link parks the newer id (RootView takes the latest tap to the front).
        store.addJoined(JukeboxLink(url: URL(string: "pocketdj://jukebox/qrstuv67")!)!)
        XCTAssertEqual(store.pendingOpenId, "qrstuv67")
        XCTAssertEqual(store.joinedSessions.first?.id, "qrstuv67")
    }
}

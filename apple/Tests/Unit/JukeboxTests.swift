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

    /// `burned:` seeds REAL on-disk burns for those ids (`MixBurnFixture`) — startAutoMix
    /// ejects + re-loads both decks from its queue now, so a broadcast test's auto items must
    /// resolve for the mix to start. Empty (the default) keeps the old empty ledger.
    private func makeStack(burned: [String] = []) -> Stack {
        let rips = RipsStore(ripsBase: URL(string: "https://rips.test")!,
                             session: URLSession(configuration: .ephemeral))
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("pdj-jukebox-\(UUID().uuidString).json")
        addTeardownBlock { try? FileManager.default.removeItem(at: url) }
        let burns = burned.isEmpty ? BurnStore(rips: rips, fileURL: url)
                                   : try! MixBurnFixture.burnStore(ids: burned, rips: rips)
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
        let stack = makeStack(burned: ["a", "b", "c"])
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
        let stack = makeStack(burned: ["q"])
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

    // MARK: - Adoption (a device other than the one that STARTED a session becomes its
    // active publisher — the TV "pick a listed session → host it here" fix, 2026-09-02)

    /// Wires `store.settings` (an absolute broker base, so `JukeboxClient`'s `request(_:)`
    /// builds real URLs the stub can intercept by path) and `store.urlSession` onto a fresh
    /// `JukeboxAdoptStub`-backed `URLSession` — the DiscoverStoreTests/MwFURLProtocol shape,
    /// no real network.
    private func wireAdoptTransport(_ store: JukeboxStore) {
        let settings = SettingsStore(defaults: UserDefaults(suiteName: "test.jukeboxadopt.\(UUID().uuidString)")!)
        settings.jukeboxServerURL = "https://broker.test"
        settings.jukeboxToken = "tok"
        store.settings = settings
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [JukeboxAdoptStub.self]
        store.urlSession = URLSession(configuration: config)
    }

    private func sessionInfoJSON(id: String, hostKey: String, name: String = "Living Room") -> Data {
        Data("""
        {"jukeboxId":"\(id)","hostKey":"\(hostKey)","name":"\(name)",
         "url":"https://jukebox.pocket-dj.com/\(id)/","timeless":false,"expiresAt":1234}
        """.utf8)
    }

    /// With nothing active, `adopt` fetches the FULL session (the real hostKey — the whole
    /// point) via the host-authed GET /sessions/:id lookup, adopts it, and starts the loop:
    /// its very first tick publishes THIS device's state using that hostKey. That publish —
    /// not just `session` being non-nil — is the proof adoption actually works, since a
    /// stale/placeholder hostKey would set `session` too but never successfully post.
    func testAdoptWithNoActiveSessionFetchesHostKeyAndStartsPublishing() async throws {
        JukeboxAdoptStub.reset()
        let app = await makeApp()
        let store = makeStore(app, makeStack())
        wireAdoptTransport(store)
        JukeboxAdoptStub.bodyByPath["/sessions/erjjo4jn"] = sessionInfoJSON(id: "erjjo4jn", hostKey: "realhostkey123")

        await store.adopt(jukeboxId: "erjjo4jn")

        XCTAssertEqual(store.session?.jukeboxId, "erjjo4jn")
        XCTAssertEqual(store.session?.hostKey, "realhostkey123",
                       "adoption must carry the SESSION'S real hostKey, not a placeholder")
        XCTAssertNil(store.lastError)
        XCTAssertFalse(store.hearEnabled, "adopting resets the same state start() resets")
        XCTAssertTrue(store.inbox.isEmpty)

        // Let startLoop's background Task actually run its first tick.
        try await Task.sleep(for: .milliseconds(250))
        XCTAssertGreaterThan(JukeboxAdoptStub.count(path: "/jukebox/erjjo4jn/state"), 0,
                             "startLoop must have fired — this device now publishes to the adopted session")
        XCTAssertEqual(JukeboxAdoptStub.last(path: "/jukebox/erjjo4jn/state")?
                        .value(forHTTPHeaderField: "Authorization"), "Bearer realhostkey123",
                       "the publish must ride the ADOPTED session's real hostKey")
    }

    /// Re-adopting the session THIS device already hosts is a harmless no-op success: no
    /// second GET /sessions/:id round trip, `session` is left exactly as it was.
    func testAdoptingTheSessionAlreadyHostingIsANoOp() async throws {
        JukeboxAdoptStub.reset()
        let app = await makeApp()
        let store = makeStore(app, makeStack())
        wireAdoptTransport(store)
        JukeboxAdoptStub.bodyByPath["/sessions/erjjo4jn"] = sessionInfoJSON(id: "erjjo4jn", hostKey: "realhostkey123")

        await store.adopt(jukeboxId: "erjjo4jn")
        XCTAssertEqual(JukeboxAdoptStub.count(path: "/sessions/erjjo4jn"), 1)
        let sessionBefore = store.session

        await store.adopt(jukeboxId: "erjjo4jn")

        XCTAssertEqual(JukeboxAdoptStub.count(path: "/sessions/erjjo4jn"), 1,
                       "adopting the session already being hosted must not re-fetch it")
        XCTAssertEqual(store.session, sessionBefore)
    }

    /// The same guard shape as `start()`: with a DIFFERENT session already active, `adopt`
    /// refuses outright (no network call at all) rather than clobbering it. Switching is the
    /// CALLER's job (end the old one first) — see TVJukeboxView.select.
    func testAdoptRefusesToClobberADifferentActiveSession() async throws {
        JukeboxAdoptStub.reset()
        let app = await makeApp()
        let store = makeStore(app, makeStack())
        wireAdoptTransport(store)
        JukeboxAdoptStub.bodyByPath["/jukebox"] = sessionInfoJSON(id: "aaaa2222", hostKey: "ownkey", name: "Mine")
        await store.start(name: "Mine")
        XCTAssertEqual(store.session?.jukeboxId, "aaaa2222")

        JukeboxAdoptStub.bodyByPath["/sessions/bbbb3333"] = sessionInfoJSON(id: "bbbb3333", hostKey: "otherkey", name: "Someone Else's")
        await store.adopt(jukeboxId: "bbbb3333")

        XCTAssertEqual(store.session?.jukeboxId, "aaaa2222",
                       "adopt must not clobber an already-active DIFFERENT session")
        XCTAssertEqual(JukeboxAdoptStub.count(path: "/sessions/bbbb3333"), 0,
                       "the guard must refuse before any network call")
    }

    /// Two overlapping lifecycle calls for the SAME id: the first's fetch is gated open, so
    /// while it sits mid-flight (`starting == true`, `session` still nil) a second `adopt`
    /// call for that id must be refused by the guard — NOT quietly routed through the
    /// "already hosting" no-op, since there is no session to already be hosting yet.
    func testAdoptGuardedWhileAnotherCallIsStarting() async throws {
        JukeboxAdoptStub.reset()
        let app = await makeApp()
        let store = makeStore(app, makeStack())
        wireAdoptTransport(store)
        JukeboxAdoptStub.gatedPaths = ["/sessions/erjjo4jn"]
        JukeboxAdoptStub.bodyByPath["/sessions/erjjo4jn"] = sessionInfoJSON(id: "erjjo4jn", hostKey: "realhostkey123")

        let first = Task { await store.adopt(jukeboxId: "erjjo4jn") }
        // Wait for the first call's synchronous prefix (`starting = true`) to land before its
        // gated network fetch resolves. Bounded so a broken guard fails loudly, not by hanging.
        var spins = 0
        while !store.starting, spins < 500_000 { await Task.yield(); spins += 1 }
        guard store.starting else { return XCTFail("first adopt never reached `starting`") }
        XCTAssertNil(store.session, "still mid-flight — no session yet")

        await store.adopt(jukeboxId: "erjjo4jn")
        XCTAssertNil(store.session, "the guarded concurrent call must not have raced ahead")

        JukeboxAdoptStub.releaseGate()
        await first.value
        XCTAssertEqual(store.session?.jukeboxId, "erjjo4jn", "the first call completes normally once released")
        XCTAssertEqual(JukeboxAdoptStub.count(path: "/sessions/erjjo4jn"), 1,
                       "the guarded second call made no network request of its own")
    }
}

/// Scriptable, request-recording URLProtocol standing in for the broker's host-authed
/// GET /sessions/:id (adoption) + the loop's POST …/state and GET …/requests — the
/// DiscoverStoreTests/MwFURLProtocol shape, sized for the JukeboxStore.adopt() tests.
/// `gatedPaths` lets a test hold a response open (a semaphore, released on another thread —
/// `startLoading()` runs off the URLSession's private queue, never MainActor) so it can
/// observe a lifecycle call mid-flight without a flaky Task.yield race.
private final class JukeboxAdoptStub: URLProtocol {
    nonisolated(unsafe) static var bodyByPath: [String: Data] = [:]
    nonisolated(unsafe) static var statusCodeByPath: [String: Int] = [:]
    nonisolated(unsafe) static var gatedPaths: Set<String> = []

    private static let lock = NSLock()
    nonisolated(unsafe) private static var requests: [URLRequest] = []
    nonisolated(unsafe) private static var gate = DispatchSemaphore(value: 0)

    static func reset() {
        lock.lock(); defer { lock.unlock() }
        bodyByPath = [:]; statusCodeByPath = [:]; gatedPaths = []; requests = []
        gate = DispatchSemaphore(value: 0)
    }
    static func releaseGate() { gate.signal() }
    static func count(path: String) -> Int {
        lock.lock(); defer { lock.unlock() }
        return requests.filter { $0.url?.path == path }.count
    }
    static func last(path: String) -> URLRequest? {
        lock.lock(); defer { lock.unlock() }
        return requests.last { $0.url?.path == path }
    }

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func stopLoading() {}
    override func startLoading() {
        let path = request.url?.path ?? ""
        Self.lock.lock()
        Self.requests.append(request)
        let blocks = Self.gatedPaths.contains(path)
        let status = Self.statusCodeByPath[path] ?? 200
        // Default covers BOTH the state-post Ack (`ok`) and the requests-poll page
        // (`requests`/`seq`) so the loop's other calls don't error while a test only cares
        // about the adoption lookup.
        let payload = Self.bodyByPath[path] ?? Data("{\"ok\":true,\"requests\":[],\"seq\":0}".utf8)
        Self.lock.unlock()
        if blocks { Self.gate.wait() }
        let response = HTTPURLResponse(url: request.url!, statusCode: status,
                                       httpVersion: "HTTP/1.1", headerFields: nil)!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: payload)
        client?.urlProtocolDidFinishLoading(self)
    }
}

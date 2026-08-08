import XCTest
@testable import PocketDJ

/// Music with Friends store — create/join persistence, the 410 fold + once-only score
/// record, the matcher-backed leader approve, collection download (songId →
/// appleMusicId → provisional), and token re-registration. Transport is a scriptable
/// URLProtocol (the DiscoverStoreTests pattern — no real network).
@MainActor
final class MusicWithFriendsStoreTests: XCTestCase {

    override func setUp() {
        super.setUp()
        MwFURLProtocol.reset()
    }

    private func tempURL(_ tag: String) -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("pdj-mwfstore-\(tag)-\(UUID().uuidString).json")
        addTeardownBlock { try? FileManager.default.removeItem(at: url) }
        return url
    }

    private func makeStore() -> (store: MusicWithFriendsStore, defaults: UserDefaults) {
        let defaults = UserDefaults(suiteName: "test.mwf.\(UUID().uuidString)")!
        let store = MusicWithFriendsStore(defaults: defaults)
        let settings = SettingsStore(defaults: UserDefaults(suiteName: "test.mwfset.\(UUID().uuidString)")!)
        settings.jukeboxServerURL = "https://broker.test"
        settings.jukeboxToken = "tok"
        store.settings = settings
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [MwFURLProtocol.self]
        store.urlSession = URLSession(configuration: config)
        store.deviceClientId = { "client-test" }
        store.joinSecret = { "secret-test" }
        store.makePickModel = { nil }   // tests never touch FoundationModels
        store.scoreboard = GameScoreboardStore(fileURL: tempURL("scores"))
        return (store, defaults)
    }

    /// The app-scoped playback stack the leader's queue-accepted nicety writes into.
    private func makeSequencer() -> SetlistPlayer {
        let rips = RipsStore(ripsBase: URL(string: "https://rips.test")!,
                             session: URLSession(configuration: .ephemeral))
        let burns = BurnStore(rips: rips, fileURL: tempURL("burns"))
        let player = PlayerEngine()
        let coordinator = PlaybackCoordinator(
            ripProvider: RipServerPlaybackProvider(rips: rips, player: player),
            appleMusic: AppleMusicPlaybackProvider(provider: AppleMusicProvider()))
        return SetlistPlayer(player: player, rips: rips, burns: burns, coordinator: coordinator)
    }

    private func seedEntry(_ store: MusicWithFriendsStore, defaults: UserDefaults,
                           id: String = "abcd2345", leader: Bool = true) -> MwFSessionEntry {
        let entry = MwFSessionEntry(id: id, memberId: "mb_me", memberKey: "mk_me",
                                    leaderKey: leader ? "lk_me" : nil, name: "Session",
                                    theme: "90s bangers", url: "https://jukebox.pocket-dj.com/mwf/\(id)/",
                                    apiBase: "https://broker.test", expiresAt: nil,
                                    pocketId: nil, joinedAt: 1000)
        defaults.set(try! JSONEncoder().encode([entry]), forKey: "pdj.mwf.sessions.v1")
        store.loadPersisted()
        return entry
    }

    // MARK: Create / join

    func testCreatePersistsLeaderEntry() async throws {
        let (store, defaults) = makeStore()
        MwFURLProtocol.bodyByPath["/mwf"] = Data("""
        { "sessionId": "abcd2345", "leaderKey": "lk1", "memberId": "mb_1", "memberKey": "mk1",
          "name": "Ada's MwF", "theme": "90s", "url": "https://jukebox.pocket-dj.com/mwf/abcd2345/",
          "expiresAt": 999999, "settings": { "turnSeconds": 120 } }
        """.utf8)
        let err = await store.create(name: "Ada's MwF", theme: "90s", displayName: "Ada",
                                     settings: MwFSettings(turnSeconds: 120, acceptOutsideTurn: false,
                                                           turnEndsOnFirstSuggestion: true))
        XCTAssertNil(err, "create RETURNS its error (the sheet owns the message, not a shared field)")
        XCTAssertTrue(store.lastErrors.isEmpty)
        XCTAssertEqual(store.sessions.count, 1)
        let entry = store.sessions[0]
        XCTAssertTrue(entry.isLeader)
        XCTAssertEqual(entry.id, "abcd2345")
        XCTAssertEqual(entry.memberKey, "mk1")
        XCTAssertEqual(entry.theme, "90s")
        XCTAssertEqual(store.pendingOpenId, "abcd2345", "create opens the session screen")
        // The create hit the configured broker with the token + clientId.
        let req = MwFURLProtocol.last(path: "/mwf")
        XCTAssertEqual(req?.value(forHTTPHeaderField: "Authorization"), "Bearer tok")
        XCTAssertEqual(MwFURLProtocol.lastBodyJSON(path: "/mwf")?["clientId"] as? String, "client-test")
        XCTAssertEqual(MwFURLProtocol.lastBodyJSON(path: "/mwf")?["joinSecret"] as? String, "secret-test",
                       "the leader registers a re-join secret too")
        // Persisted: a fresh store on the same defaults reloads the entry.
        let store2 = MusicWithFriendsStore(defaults: defaults)
        store2.loadPersisted()
        XCTAssertEqual(store2.sessions.first?.id, "abcd2345")
    }

    func testJoinAddsEntryAndPendingOpen() async throws {
        let (store, _) = makeStore()
        // The public state.json (CloudFront) supplies apiBase + theme…
        MwFURLProtocol.bodyByPath["/mwf/abcd2345/state.json"] = Data("""
        { "sessionId": "abcd2345", "name": "Ada's MwF", "theme": "90s",
          "apiBase": "https://broker.test" }
        """.utf8)
        // …and the join goes to that apiBase.
        MwFURLProtocol.bodyByPath["/mwf/abcd2345/join"] = Data("""
        { "memberId": "mb_2", "memberKey": "mk2", "name": "Beth", "theme": "90s",
          "sessionName": "Ada's MwF", "expiresAt": 999999 }
        """.utf8)
        let link = MwFLink(url: URL(string: "https://jukebox.pocket-dj.com/mwf/abcd2345/")!)!
        let err = await store.join(link: link, name: "Beth")
        XCTAssertNil(err)
        XCTAssertTrue(store.lastErrors.isEmpty)
        XCTAssertEqual(store.sessions.count, 1)
        XCTAssertFalse(store.sessions[0].isLeader)
        XCTAssertEqual(store.sessions[0].apiBase, "https://broker.test")
        XCTAssertEqual(store.sessions[0].name, "Ada's MwF")
        XCTAssertEqual(store.pendingOpenId, "abcd2345")
        let body = MwFURLProtocol.lastBodyJSON(path: "/mwf/abcd2345/join")
        XCTAssertEqual(body?["name"] as? String, "Beth")
        // The re-join credential is the per-install SECRET, never the broadcast device id
        // (the broker refuses a bare clientId as proof of identity).
        XCTAssertEqual(body?["joinSecret"] as? String, "secret-test")
        XCTAssertNotEqual(body?["joinSecret"] as? String, body?["clientId"] as? String)
        XCTAssertNil(MwFURLProtocol.last(path: "/mwf/abcd2345/join")?
            .value(forHTTPHeaderField: "Authorization"),
                     "a first join presents no bearer — nothing to prove yet")
    }

    /// Broker-side member loss (a session.json restored from a backup): every verb 401s,
    /// and `join()` early-returns for known sessions — so the STORE must recover from the
    /// poll itself: re-join presenting the stored memberKey, adopt the reply's binding,
    /// and retry the state fetch. This drives the store (not the bare client) so the
    /// recovery path can never silently go unreachable again.
    func testPoll401RecoversMembershipThroughTheStore() async throws {
        let (store, defaults) = makeStore()
        _ = seedEntry(store, defaults: defaults, id: "abcd2345", leader: false)
        MwFURLProtocol.statusCodeByPath["/mwf/abcd2345/state"] = 401
        // The broker minted a FRESH member for us (the old one is gone from session.json).
        MwFURLProtocol.bodyByPath["/mwf/abcd2345/join"] = Data("""
        { "memberId": "mb_new", "memberKey": "mk_new" }
        """.utf8)
        _ = await store.refresh("abcd2345")
        // The recovery re-join PRESENTED the stored memberKey as the bearer…
        XCTAssertEqual(MwFURLProtocol.last(path: "/mwf/abcd2345/join")?
            .value(forHTTPHeaderField: "Authorization"), "Bearer mk_me")
        XCTAssertEqual(MwFURLProtocol.lastBodyJSON(path: "/mwf/abcd2345/join")?["joinSecret"] as? String,
                       "secret-test", "…alongside the per-install re-join secret")
        // …and the entry re-bound to the broker's reply.
        XCTAssertEqual(store.sessions[0].memberKey, "mk_new")
        XCTAssertEqual(store.sessions[0].memberId, "mb_new")
        // The state retry still 401s in this script — the poll surface reports, the
        // session is NOT folded as ended, and the entry keeps the recovered binding.
        XCTAssertNotEqual(store.lastState["abcd2345"]?.ended, true)
    }

    /// When even the re-join fails (the whole session vanished), the poll surfaces the
    /// problem on ITS channel and the cached state stands — no crash, no silent 401 loop.
    func testPoll401WithFailedRecoveryReportsOnPollError() async throws {
        let (store, defaults) = makeStore()
        _ = seedEntry(store, defaults: defaults, id: "abcd2345", leader: false)
        MwFURLProtocol.statusCodeByPath["/mwf/abcd2345/state"] = 401
        MwFURLProtocol.statusCodeByPath["/mwf/abcd2345/join"] = 401
        _ = await store.refresh("abcd2345")
        XCTAssertNotNil(store.pollErrors["abcd2345"])
        XCTAssertTrue(store.lastErrors.isEmpty)
        XCTAssertEqual(store.sessions[0].memberKey, "mk_me", "no fake re-bind on failure")
        XCTAssertGreaterThanOrEqual(MwFURLProtocol.count(path: "/mwf/abcd2345/join"), 2,
                                    "memberKey attempt, then the joinSecret fallback")
    }

    /// A raw 404 from POST /mwf (the live broker predates v3) turns into an actionable
    /// "update the broker" message via the /health capability probe — not a bare HTTP 404.
    func testCreate404ProbesHealthAndExplainsTheOldBroker() async throws {
        let (store, _) = makeStore()
        MwFURLProtocol.statusCodeByPath["/mwf"] = 404
        MwFURLProtocol.bodyByPath["/health"] = Data("""
        { "ok": true, "service": "jukebox", "version": 2 }
        """.utf8)
        let err = await store.create(name: "n", theme: "t", displayName: "Ada",
                                     settings: MwFSettings(turnSeconds: 120, acceptOutsideTurn: false,
                                                           turnEndsOnFirstSuggestion: true))
        XCTAssertNotNil(err)
        XCTAssertTrue(err?.contains("older version") == true,
                      "the v2 broker case names the fix, got: \(err ?? "nil")")
        XCTAssertEqual(MwFURLProtocol.count(path: "/health"), 1)
    }

    func testHandleOpenedLinkKnownOpensUnknownDrivesJoinSheet() {
        let (store, defaults) = makeStore()
        _ = seedEntry(store, defaults: defaults)
        store.handleOpenedLink(MwFLink(url: URL(string: "pocketdj://mwf/abcd2345")!)!)
        XCTAssertEqual(store.pendingOpenId, "abcd2345")
        XCTAssertNil(store.pendingJoin)
        store.pendingOpenId = nil
        store.handleOpenedLink(MwFLink(url: URL(string: "pocketdj://mwf/zzzz7777")!)!)
        XCTAssertEqual(store.pendingJoin?.sessionId, "zzzz7777", "unknown session → the Join sheet")
        XCTAssertEqual(store.pendingOpenId, "zzzz7777",
                       "…AND the navigation signal, or the sheet is unreachable from another tab")
    }

    /// The 4 s poll must not write the field the create/join sheets read (multi-window:
    /// one window's poll would erase or forge the other's message).
    func testPollErrorNeverTouchesTheVerbErrorSurface() async throws {
        let (store, defaults) = makeStore()
        _ = seedEntry(store, defaults: defaults)
        MwFURLProtocol.statusCodeByPath["/mwf/abcd2345/state"] = 500
        _ = await store.refresh("abcd2345")
        XCTAssertNotNil(store.pollErrors["abcd2345"], "the poll reports on its own channel")
        XCTAssertTrue(store.lastErrors.isEmpty, "…and never on the sheets' or the session banner's")
        // A create failing while that poll error stands returns ITS message.
        MwFURLProtocol.statusCodeByPath["/mwf"] = 500
        let err = await store.create(name: "n", theme: "t", displayName: "Ada",
                                     settings: MwFSettings(turnSeconds: 120, acceptOutsideTurn: false,
                                                           turnEndsOnFirstSuggestion: true))
        XCTAssertNotNil(err)
        XCTAssertTrue(store.lastErrors.isEmpty)
        // …and a later SUCCESSFUL poll can't retroactively "clear" it.
        MwFURLProtocol.statusCodeByPath["/mwf/abcd2345/state"] = 200
        MwFURLProtocol.bodyByPath["/mwf/abcd2345/state"] = Data("{\"sessionId\":\"abcd2345\"}".utf8)
        _ = await store.refresh("abcd2345")
        XCTAssertNil(store.pollErrors["abcd2345"])
        XCTAssertNotNil(err, "the sheet's message is local to the sheet")
    }

    /// The poll error is RENDERED on the session screen, so it carries the same
    /// cross-session hazard the verb banner does: one session's dead broker must not paint
    /// an "unreachable" banner inside another session's screen (two macOS windows).
    func testPollErrorIsKeyedPerSession() async throws {
        let (store, defaults) = makeStore()
        let a = MwFSessionEntry(id: "abcd2345", memberId: "mb_a", memberKey: "mk_a", leaderKey: nil,
                                name: nil, theme: nil, url: nil, apiBase: "https://broker.test",
                                expiresAt: nil, pocketId: nil, joinedAt: 1)
        let b = MwFSessionEntry(id: "efgh6789", memberId: "mb_b", memberKey: "mk_b", leaderKey: nil,
                                name: nil, theme: nil, url: nil, apiBase: "https://broker.test",
                                expiresAt: nil, pocketId: nil, joinedAt: 2)
        defaults.set(try! JSONEncoder().encode([a, b]), forKey: "pdj.mwf.sessions.v1")
        store.loadPersisted()
        MwFURLProtocol.statusCodeByPath["/mwf/abcd2345/state"] = 500
        MwFURLProtocol.bodyByPath["/mwf/efgh6789/state"] = Data("{\"sessionId\":\"efgh6789\"}".utf8)

        _ = await store.refresh("abcd2345")
        _ = await store.refresh("efgh6789")

        XCTAssertNotNil(store.pollErrors["abcd2345"])
        XCTAssertNil(store.pollErrors["efgh6789"], "the healthy session's screen stays clean")
        // …and the healthy session's success cannot clear the broken one's banner.
        _ = await store.refresh("efgh6789")
        XCTAssertNotNil(store.pollErrors["abcd2345"])
        // Leaving forgets the entry AND its banner.
        store.leave("abcd2345")
        XCTAssertNil(store.pollErrors["abcd2345"])
    }

    // MARK: Refresh / final score

    func testRefresh410FoldsAndRecordsScoreOnce() async throws {
        let (store, defaults) = makeStore()
        _ = seedEntry(store, defaults: defaults)
        // First refresh caches a live state carrying my score.
        MwFURLProtocol.bodyByPath["/mwf/abcd2345/state"] = Data("""
        { "sessionId": "abcd2345", "ended": false, "theme": "90s bangers",
          "members": [ { "memberId": "mb_me", "name": "Me", "score": 4 } ],
          "you": { "memberId": "mb_me" } }
        """.utf8)
        let live = await store.refresh("abcd2345")
        XCTAssertEqual(live?.ended, false)
        XCTAssertEqual(store.scoreboard!.recentRuns(.musicWithFriends, limit: 5).count, 0,
                       "a live session records nothing")
        // The broker expires the session → 410 → local fold + ONE scoreboard record
        // from the last-known cached state.
        MwFURLProtocol.statusCodeByPath["/mwf/abcd2345/state"] = 410
        let folded = await store.refresh("abcd2345")
        XCTAssertEqual(folded?.ended, true)
        let runs = store.scoreboard!.recentRuns(.musicWithFriends, limit: 5)
        XCTAssertEqual(runs.count, 1)
        XCTAssertEqual(runs[0].score, 4, "score comes from the cached member row")
        XCTAssertEqual(runs[0].detail?["sessionId"], "abcd2345")
        _ = await store.refresh("abcd2345")
        XCTAssertEqual(store.scoreboard!.recentRuns(.musicWithFriends, limit: 5).count, 1,
                       "the pdj.mwf.scored guard records ONCE")
    }

    // MARK: Leader approve

    func testApproveRunsMatcherAndPostsMatch() async throws {
        let (store, defaults) = makeStore()
        _ = seedEntry(store, defaults: defaults)
        let app = AppModel(loader: TestData.StubLoader())
        await app.loadIfNeeded()
        store.appModel = app
        MwFURLProtocol.bodyByPath["/mwf/abcd2345/suggestions/sg_1/decision"] = Data("{\"ok\":true}".utf8)
        MwFURLProtocol.bodyByPath["/mwf/abcd2345/state"] = Data("{\"sessionId\":\"abcd2345\"}".utf8)
        // "Neon" by Aria is an exact fixture-catalog hit → the decision carries sng_1.
        let suggestion = MwFSuggestion(id: "sg_1", seq: 1, memberId: "mb_2",
                                       title: "Neon", artist: "Aria", createdAt: 1,
                                       status: "pending", decidedAt: nil, plusOnes: [], match: nil)
        await store.approve("abcd2345", suggestion: suggestion)
        XCTAssertNil(store.lastErrors["abcd2345"])
        let body = MwFURLProtocol.lastBodyJSON(path: "/mwf/abcd2345/suggestions/sg_1/decision")
        XCTAssertEqual(body?["action"] as? String, "accepted")
        let match = body?["match"] as? [String: Any]
        XCTAssertEqual(match?["songId"] as? String, "sng_1")
        XCTAssertEqual(match?["title"] as? String, "Neon")
        // The leaderKey rides as the bearer.
        let req = MwFURLProtocol.last(path: "/mwf/abcd2345/suggestions/sg_1/decision")
        XCTAssertEqual(req?.value(forHTTPHeaderField: "Authorization"), "Bearer lk_me")
    }

    func testPlusOneSingleFlight() async throws {
        let (store, defaults) = makeStore()
        _ = seedEntry(store, defaults: defaults, leader: false)
        MwFURLProtocol.bodyByPath["/mwf/abcd2345/suggestions/sg_9/plusone"] = Data("{\"ok\":true,\"plusOnes\":1}".utf8)
        MwFURLProtocol.bodyByPath["/mwf/abcd2345/state"] = Data("{\"sessionId\":\"abcd2345\"}".utf8)
        await store.plusOne("abcd2345", suggestionId: "sg_9")
        XCTAssertEqual(MwFURLProtocol.count(path: "/mwf/abcd2345/suggestions/sg_9/plusone"), 1)
        XCTAssertEqual(MwFURLProtocol.last(path: "/mwf/abcd2345/suggestions/sg_9/plusone")?
            .value(forHTTPHeaderField: "Authorization"), "Bearer mk_me")
        // A server 409 (already +1'd) surfaces as THIS session's error, not a crash —
        // and never as some OTHER session's banner (per-session keying).
        MwFURLProtocol.statusCodeByPath["/mwf/abcd2345/suggestions/sg_9/plusone"] = 409
        await store.plusOne("abcd2345", suggestionId: "sg_9")
        XCTAssertNotNil(store.lastErrors["abcd2345"])
        XCTAssertNil(store.lastErrors["efgh6789"], "session B never paints session A's failure")
    }

    /// The leader's "queue accepted songs" nicety rides the app-scoped sequencer — but a
    /// Collectors Puzzle round maps ITS queue index onto that sequencer's, so an append
    /// mid-round would desync the decision log's positions.
    /// Assertions run synchronously after each call (the NowPlayingQueueTests discipline —
    /// the sequencer's playCurrent Tasks haven't run).
    func testAcceptedSongNeverAppendsIntoALivePuzzleRound() {
        let (store, defaults) = makeStore()
        _ = seedEntry(store, defaults: defaults)
        let sequencer = makeSequencer()
        store.sequencer = sequencer
        let match = MwFMatch(songId: "sng_1", appleMusicId: nil, title: "Neon",
                             artist: "Aria", lengthMs: 222000)

        // A live puzzle round owns the sequencer → the accept must NOT append.
        sequencer.play([SetlistPlayer.Item(id: "sng_2", title: "Pulse", artist: "Aria")],
                       sourceSetlistId: "\(CollectorsPuzzleEngine.runTagPrefix)\(UUID().uuidString)")
        store.queueMatchIfPlayable(match)
        XCTAssertEqual(sequencer.queue.count, 1, "a puzzle round's queue is left exactly as it was")

        // An ordinary set still takes the append (the nicety is unchanged elsewhere).
        sequencer.play([SetlistPlayer.Item(id: "sng_2", title: "Pulse", artist: "Aria")],
                       sourceSetlistId: "set_x")
        store.queueMatchIfPlayable(match)
        XCTAssertEqual(sequencer.queue.count, 2)
        XCTAssertEqual(sequencer.queue.last?.id, "sng_1")
    }

    // MARK: Collection download

    func testDownloadCollectionResolvesBySongIdThenAppleMusicId() async throws {
        let (store, defaults) = makeStore()
        _ = seedEntry(store, defaults: defaults)
        let app = AppModel(loader: TestData.StubLoader())
        await app.loadIfNeeded()
        store.appModel = app
        let collections = CollectionsStore(fileURL: tempURL("coll"))
        collections.app = app
        store.collectionsStore = collections
        var st = MwFState()
        st.sessionId = "abcd2345"
        st.name = "Ada's MwF"
        st.theme = "90s bangers"
        st.collection = [
            MwFCollectionEntry(songId: "sng_1", appleMusicId: nil, title: "Neon", artist: "Aria",
                               lengthMs: 222000, suggestedBy: "mb_2", acceptedAt: 1),
            MwFCollectionEntry(songId: nil, appleMusicId: "999", title: "Unknown Cut", artist: "Nobody",
                               lengthMs: 100000, suggestedBy: "mb_3", acceptedAt: 2),
        ]
        let pocketId = await store.downloadCollection("abcd2345", state: st)
        XCTAssertNotNil(pocketId)
        let pocket = collections.pocket(pocketId!)
        XCTAssertEqual(pocket?.name, "MwF — Ada's MwF")
        XCTAssertEqual(pocket?.description, "90s bangers")
        XCTAssertEqual(pocket?.songIds.first, "sng_1", "a catalog songId resolves directly")
        XCTAssertEqual(pocket?.songIds.count, 2)
        XCTAssertTrue(pocket!.songIds[1].hasPrefix("mwf_"),
                      "an unresolvable entry materializes as a provisional id")
        XCTAssertEqual(store.sessions[0].pocketId, pocketId, "pocket id persists for idempotence")
    }

    func testDownloadCollectionIdempotentPocket() async throws {
        let (store, defaults) = makeStore()
        _ = seedEntry(store, defaults: defaults)
        let app = AppModel(loader: TestData.StubLoader())
        await app.loadIfNeeded()
        store.appModel = app
        let collections = CollectionsStore(fileURL: tempURL("coll"))
        collections.app = app
        store.collectionsStore = collections
        var st = MwFState()
        st.sessionId = "abcd2345"
        st.name = "S"
        st.collection = [MwFCollectionEntry(songId: "sng_1", appleMusicId: nil, title: "Neon",
                                            artist: "Aria", lengthMs: nil, suggestedBy: nil, acceptedAt: 1)]
        let first = await store.downloadCollection("abcd2345", state: st)
        // A later download (one more accepted song) reuses the SAME pocket, adds only the new member.
        st.collection?.append(MwFCollectionEntry(songId: "sng_2", appleMusicId: nil, title: "Pulse",
                                                 artist: "Aria", lengthMs: nil, suggestedBy: nil, acceptedAt: 2))
        let second = await store.downloadCollection("abcd2345", state: st)
        XCTAssertEqual(first, second, "idempotent pocket reuse")
        XCTAssertEqual(collections.pockets.count, 1)
        XCTAssertEqual(collections.pocket(first!)?.songIds, ["sng_1", "sng_2"], "no duplicates")
    }

    // MARK: Account deletion

    /// Account deletion must leave NO MwF trace: entries (bearer memberKeys), the scored
    /// set, the queue-accepted preference, cached states, pending link signals — and the
    /// UserDefaults copies of all of it (a fresh store on the same defaults sees nothing).
    func testEraseAllForgetsEveryLocalTrace() async throws {
        let (store, defaults) = makeStore()
        _ = seedEntry(store, defaults: defaults)
        defaults.set(["abcd2345"], forKey: "pdj.mwf.scored.v1")
        store.loadPersisted()
        store.queueAccepted = true
        store.pendingOpenId = "abcd2345"
        // Cache a state + a poll error so the wipe covers the render surfaces too.
        MwFURLProtocol.bodyByPath["/mwf/abcd2345/state"] = Data("{\"sessionId\":\"abcd2345\"}".utf8)
        _ = await store.refresh("abcd2345")
        XCTAssertFalse(store.sessions.isEmpty)

        store.eraseAll()

        XCTAssertTrue(store.sessions.isEmpty)
        XCTAssertTrue(store.lastState.isEmpty)
        XCTAssertNil(store.pendingOpenId)
        XCTAssertNil(store.pendingJoin)
        XCTAssertFalse(store.queueAccepted)
        XCTAssertNil(defaults.data(forKey: "pdj.mwf.sessions.v1"))
        XCTAssertNil(defaults.stringArray(forKey: "pdj.mwf.scored.v1"))
        XCTAssertNil(defaults.object(forKey: "pdj.mwf.queueAccepted.v1"))
        // A fresh store over the same defaults starts clean.
        let store2 = MusicWithFriendsStore(defaults: defaults)
        store2.loadPersisted()
        XCTAssertTrue(store2.sessions.isEmpty)
    }

    /// The APNs device token pushed to the broker is personal data on a server the user may
    /// not own. Deletion must WITHDRAW it from every session while the memberKeys that
    /// authorize the call still exist — `eraseAll()` destroys them immediately after.
    func testUnregisterPushWithdrawsTheTokenFromEverySession() async throws {
        let (store, defaults) = makeStore()
        let a = MwFSessionEntry(id: "abcd2345", memberId: "mb_a", memberKey: "mk_a", leaderKey: nil,
                                name: nil, theme: nil, url: nil, apiBase: "https://broker.test",
                                expiresAt: nil, pocketId: nil, joinedAt: 1)
        let b = MwFSessionEntry(id: "efgh6789", memberId: "mb_b", memberKey: "mk_b", leaderKey: "lk_b",
                                name: nil, theme: nil, url: nil, apiBase: "https://broker.test",
                                expiresAt: nil, pocketId: nil, joinedAt: 2)
        defaults.set(try! JSONEncoder().encode([a, b]), forKey: "pdj.mwf.sessions.v1")
        store.loadPersisted()

        await store.unregisterPushEverywhere()

        for (id, key) in [("abcd2345", "mk_a"), ("efgh6789", "mk_b")] {
            let req = MwFURLProtocol.last(path: "/mwf/\(id)/register-device")
            XCTAssertEqual(req?.httpMethod, "DELETE", "the withdraw verb, not another register")
            XCTAssertEqual(req?.value(forHTTPHeaderField: "Authorization"), "Bearer \(key)",
                           "each session's OWN memberKey authorizes its retraction")
        }
        // An unreachable broker must not trap the deletion — the local wipe still runs.
        MwFURLProtocol.statusCodeByPath["/mwf/abcd2345/register-device"] = 500
        await store.unregisterPushEverywhere()
        store.eraseAll()
        XCTAssertTrue(store.sessions.isEmpty)
    }

    /// The per-install re-join secret is identity: after a reset the next mint must be a
    /// DIFFERENT value, or a re-join would sha256-match the deleted account's member.
    func testJoinSecretResetMintsAFreshSecret() {
        let before = MwFJoinSecret.current
        XCTAssertEqual(before, MwFJoinSecret.current, "stable until reset")
        MwFJoinSecret.reset()
        let after = MwFJoinSecret.current
        XCTAssertNotEqual(before, after)
        XCTAssertEqual(after.count, 32)
    }

    // MARK: Push token

    func testUpdateDeviceTokenReRegistersAllSessions() async throws {
        let (store, defaults) = makeStore()
        let a = MwFSessionEntry(id: "abcd2345", memberId: "mb_a", memberKey: "mk_a", leaderKey: nil,
                                name: nil, theme: nil, url: nil, apiBase: "https://broker.test",
                                expiresAt: nil, pocketId: nil, joinedAt: 1)
        let b = MwFSessionEntry(id: "efgh6789", memberId: "mb_b", memberKey: "mk_b", leaderKey: "lk_b",
                                name: nil, theme: nil, url: nil, apiBase: "https://broker.test",
                                expiresAt: nil, pocketId: nil, joinedAt: 2)
        defaults.set(try JSONEncoder().encode([a, b]), forKey: "pdj.mwf.sessions.v1")
        store.loadPersisted()
        store.push = PushRegistrationService.shared
        store.updateDeviceToken("ab".repeating(32))
        try await Task.sleep(for: .milliseconds(300))   // fire-and-forget tasks land
        XCTAssertEqual(MwFURLProtocol.count(path: "/mwf/abcd2345/register-device"), 1)
        XCTAssertEqual(MwFURLProtocol.count(path: "/mwf/efgh6789/register-device"), 1)
        let body = MwFURLProtocol.lastBodyJSON(path: "/mwf/abcd2345/register-device")
        XCTAssertEqual(body?["token"] as? String, "ab".repeating(32))
    }
}

private extension String {
    func repeating(_ n: Int) -> String { String(repeating: self, count: n) }
}

/// Scriptable, request-recording URLProtocol standing in for the broker —
/// per-path bodies + status overrides, full request capture (the DiscoverURLProtocol shape).
private final class MwFURLProtocol: URLProtocol {
    nonisolated(unsafe) static var bodyByPath: [String: Data] = [:]
    nonisolated(unsafe) static var statusCodeByPath: [String: Int] = [:]

    private static let lock = NSLock()
    nonisolated(unsafe) private static var requests: [(request: URLRequest, body: Data?)] = []

    static func reset() {
        lock.lock(); defer { lock.unlock() }
        bodyByPath = [:]; statusCodeByPath = [:]; requests = []
    }

    static func count(path: String) -> Int {
        lock.lock(); defer { lock.unlock() }
        return requests.filter { $0.request.url?.path == path }.count
    }

    static func last(path: String) -> URLRequest? {
        lock.lock(); defer { lock.unlock() }
        return requests.last { $0.request.url?.path == path }?.request
    }

    static func lastBodyJSON(path: String) -> [String: Any]? {
        lock.lock()
        let data = requests.last { $0.request.url?.path == path }?.body
        lock.unlock()
        guard let data else { return nil }
        return (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
    }

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func stopLoading() {}

    override func startLoading() {
        let path = request.url?.path ?? ""
        let body: Data?
        if let stream = request.httpBodyStream {
            body = Self.read(stream)
        } else {
            body = request.httpBody
        }
        Self.lock.lock()
        Self.requests.append((request, body))
        let status = Self.statusCodeByPath[path] ?? 200
        let payload = Self.bodyByPath[path] ?? Data("{}".utf8)
        Self.lock.unlock()

        let response = HTTPURLResponse(url: request.url!, statusCode: status,
                                       httpVersion: "HTTP/1.1", headerFields: nil)!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: payload)
        client?.urlProtocolDidFinishLoading(self)
    }

    private static func read(_ stream: InputStream) -> Data {
        stream.open(); defer { stream.close() }
        var data = Data(); let bufSize = 4096
        let buffer = UnsafeMutablePointer<UInt8>.allocate(capacity: bufSize)
        defer { buffer.deallocate() }
        while stream.hasBytesAvailable {
            let read = stream.read(buffer, maxLength: bufSize)
            if read <= 0 { break }
            data.append(buffer, count: read)
        }
        return data
    }
}

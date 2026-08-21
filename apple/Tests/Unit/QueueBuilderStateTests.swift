import XCTest
@testable import PocketDJ

/// Queue builder (Now Playing ＋) — the controller behind the builder sheet.
/// Device search rides the BrowseState `refreshExternal` lane (the History
/// precedent, never the shared browse memo); cloud rides the Discover machinery.
///
/// SEMANTICS: EVERY add lands in the DRAFT — running or not. Play hands the draft
/// to the playNow funnel (REPLACING playback) and is gated on the draft alone;
/// `flushToQueue` is the second exit that appends the draft to a running set's
/// live queue. The shipped build instead routed adds straight to the live queue
/// whenever `sequencer.isRunning` — which includes a PAUSED set and a cold-launch
/// session restore — so the draft stayed empty, the sheet showed no trace of the
/// add, and Play (gated on a non-empty draft AND `!isRunning`) could never appear.
/// Cloud adds must still record catalog citizenship BEFORE drafting (playNow
/// drops ids absent from `songsById`).
@MainActor
final class QueueBuilderStateTests: XCTestCase {

    // MARK: Fixtures

    private func makeDefaults() -> UserDefaults {
        UserDefaults(suiteName: "test.queuebuilder.\(UUID().uuidString)")!
    }

    private func makeBuilder(_ defaults: UserDefaults? = nil) -> QueueBuilderState {
        QueueBuilderState(defaults: defaults ?? makeDefaults())
    }

    private func loadedApp() async -> AppModel {
        let app = AppModel(loader: TestData.StubLoader())
        await app.loadIfNeeded()
        return app
    }

    private func makeRips() -> RipsStore {
        RipsStore(ripsBase: URL(string: "https://rips.test")!,
                  session: URLSession(configuration: .ephemeral))
    }

    /// Minimal live-playback stack (the JukeboxTests idiom) — real SetlistPlayer,
    /// no network resolution needed for queue-shape assertions.
    private func makeSequencer() -> SetlistPlayer {
        let rips = makeRips()
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("pdj-qbuilder-\(UUID().uuidString).json")
        addTeardownBlock { try? FileManager.default.removeItem(at: url) }
        let burns = BurnStore(rips: rips, fileURL: url)
        let player = PlayerEngine()
        let coordinator = PlaybackCoordinator(
            ripProvider: RipServerPlaybackProvider(rips: rips, player: player),
            appleMusic: AppleMusicPlaybackProvider(provider: AppleMusicProvider()))
        return SetlistPlayer(player: player, rips: rips, burns: burns, coordinator: coordinator)
    }

    private func item(_ id: String) -> SetlistPlayer.Item {
        SetlistPlayer.Item(id: id, title: id, artist: "A")
    }

    private func hit(_ storeId: String, title: String = "T", artist: String = "A",
                     durationMs: Int? = 200_000) -> RipsStore.DiscoverHit {
        RipsStore.DiscoverHit(appleMusicId: storeId, title: title, artist: artist,
                              durationMs: durationMs, songId: "amrec_\(storeId)")
    }

    // MARK: Device filtering (the refreshExternal lane)

    func testDeviceSearchFiltersAndSortsThroughBrowsePipeline() async {
        let app = await loadedApp()
        let b = makeBuilder()
        b.bindExternalBase(app)
        b.songQuery = "neon"
        await b.refreshDevice(app)
        XCTAssertEqual(b.deviceResults.map(\.idString), ["sng_1"])

        // Clause + sort run through the SAME FilterEngine/SortEngine as the Browser.
        b.songQuery = ""
        var bpm = Clause(field: "bpm", op: .between); bpm.min = 100; bpm.max = 130
        b.browse.clauses = [bpm]
        b.browse.sortKeys = [SortKey(field: "bpm", dir: .asc)]
        await b.refreshDevice(app)
        XCTAssertEqual(b.deviceResults.map(\.idString), ["sng_4", "sng_6", "sng_2", "sng_1"])
    }

    func testArtistRefineIsReadTimeOverDisplayItems() async {
        let app = await loadedApp()
        let b = makeBuilder()
        b.bindExternalBase(app)
        await b.refreshDevice(app)
        XCTAssertEqual(b.browse.displayItems.count, 7)   // no query: whole catalog
        b.artistQuery = "aria"
        XCTAssertEqual(b.deviceResults.map(\.idString), ["sng_1", "sng_2", "sng_3"])
        // The refine layers on top WITHOUT touching the published rows.
        XCTAssertEqual(b.browse.displayItems.count, 7)
    }

    func testRefineByArtistFoldingAndEdgeCases() throws {
        let items = try TestData.songItems()
        // Case-insensitive…
        XCTAssertEqual(QueueBuilderState.refineByArtist(items, artist: "COBALT").count, 2)
        // …diacritic-insensitive both directions…
        XCTAssertEqual(QueueBuilderState.refineByArtist(items, artist: "ária").count, 3)
        // …empty/whitespace = identity…
        XCTAssertEqual(QueueBuilderState.refineByArtist(items, artist: "  ").count, items.count)
        // …and a no-match term yields empty, not everything.
        XCTAssertTrue(QueueBuilderState.refineByArtist(items, artist: "zzz").isEmpty)
    }

    func testDeviceSignatureMovesWithEveryRecomputeInput() async {
        let app = await loadedApp()
        let b = makeBuilder()
        let s0 = b.deviceSignature(app)
        b.songQuery = "x"
        let s1 = b.deviceSignature(app)
        XCTAssertNotEqual(s0, s1)                       // query is in the signature
        b.artistQuery = "y"
        let s2 = b.deviceSignature(app)
        XCTAssertNotEqual(s1, s2)                       // artist refine re-fires the task
        b.browse.sortKeys = [SortKey(field: "bpm", dir: .desc)]
        XCTAssertNotEqual(s2, b.deviceSignature(app))   // sort too
    }

    // MARK: Mode switch

    func testModePersistsAndRoundTrips() {
        let defaults = makeDefaults()
        let b = makeBuilder(defaults)
        XCTAssertEqual(b.mode, .device)                 // fresh default
        b.mode = .cloud
        XCTAssertEqual(makeBuilder(defaults).mode, .cloud)   // restored
        b.mode = .device
        XCTAssertEqual(makeBuilder(defaults).mode, .device)
    }

    func testSwitchingToDeviceCancelsInFlightDiscover() async throws {
        let b = makeBuilder()
        b.mode = .cloud
        b.songQuery = "daft"
        b.refreshCloud(rips: makeRips())                // 400 ms debounce in flight
        b.mode = .device                                // cancels before it fires
        try await Task.sleep(for: .milliseconds(600))
        XCTAssertEqual(b.discover.state, .idle)         // the late publish never landed
        XCTAssertTrue(b.discover.hits.isEmpty)
    }

    func testModeSwitchLeavesDeviceBrowseStateIntact() {
        let b = makeBuilder()
        b.songQuery = "neon"
        var c = Clause(field: "bpm", op: .between); c.min = 90; c.max = 130
        b.browse.clauses = [c]
        b.mode = .cloud
        b.mode = .device
        XCTAssertEqual(b.browse.query, "neon")
        XCTAssertEqual(b.browse.clauses.count, 1)
        XCTAssertEqual(b.browse.kind, .song)            // pinned throughout
    }

    // MARK: Add while a set runs — THE user-reported bug

    /// The report was "it won't let me add anything to the queue". It did add — into
    /// the LIVE queue, behind a sheet that showed nothing and offered no Play. The
    /// contract now: an add while running is VISIBLE (it is in the draft) and
    /// PLAYABLE (`canPlay`), and it does NOT mutate the running set behind the
    /// user's back. PRE-FIX this fails on every assertion: the draft stayed empty,
    /// `seq.queue` grew silently, and Play was gated off by `isRunning`.
    func testAddWhileRunningIsVisibleInTheDraftAndPlayable() {
        let seq = makeSequencer()
        let b = makeBuilder()
        seq.play([item("a"), item("b"), item("c"), item("d")], sourceSetlistId: nil)
        XCTAssertTrue(seq.isRunning)
        XCTAssertFalse(b.canPlay, "nothing drafted yet")

        b.add([item("e")], at: .bottom)
        XCTAssertEqual(b.draft.map(\.id), ["e"], "the add must be VISIBLE in the draft")
        XCTAssertTrue(b.canPlay, "…and playable the moment it lands")
        XCTAssertEqual(seq.queue.map(\.id), ["a", "b", "c", "d"],
                       "a plain ＋ must not silently mutate the running set")

        // Positions apply to the DRAFT in both regimes now (the menu labels say so).
        b.add([item("f")], at: .top)
        XCTAssertEqual(b.draft.map(\.id), ["f", "e"])
        var seenRange: ClosedRange<Int>?
        b.add([item("g")], at: .random, slot: { r in seenRange = r; return 1 })
        XCTAssertEqual(seenRange, 0...2, "the Surprise slot spans the draft, inclusive ends")
        XCTAssertEqual(b.draft.map(\.id), ["f", "g", "e"])
        seq.stop()
    }

    /// Play's gate, stated once: the DRAFT alone. Never `sequencer.isRunning` —
    /// that half of the shipped condition made Play unreachable for a paused set
    /// and for every cold launch that restored a session (`restore(from:)` sets
    /// `isRunning = true` with no audio started).
    func testCanPlayIsGatedOnTheDraftAloneEvenWhileASetRuns() {
        let seq = makeSequencer()
        let b = makeBuilder()
        XCTAssertFalse(b.canPlay)                       // idle + empty
        b.add([item("x")], at: .bottom)
        XCTAssertTrue(b.canPlay)                        // idle + drafted

        seq.play([item("a")], sourceSetlistId: nil)
        XCTAssertTrue(seq.isRunning)
        XCTAssertTrue(b.canPlay, "a running set must NOT hide Play")

        b.removeDraft(uids: Set(b.draft.map(\.uid)))
        XCTAssertFalse(b.canPlay, "…but an empty draft still has nothing to play")
        seq.stop()
    }

    // MARK: The second exit — flushToQueue (draft → the running set's live queue)

    func testFlushToQueueAppendsTheDraftAndLeavesAReceipt() {
        let seq = makeSequencer()
        let b = makeBuilder()
        seq.play([item("a"), item("b"), item("c"), item("d")], sourceSetlistId: nil)
        b.add([item("e"), item("f")], at: .bottom)

        XCTAssertEqual(b.flushToQueue(at: .bottom, sequencer: seq), 2)
        XCTAssertEqual(seq.queue.map(\.id), ["a", "b", "c", "d", "e", "f"])
        XCTAssertTrue(b.draft.isEmpty, "the draft is consumed by the flush")
        XCTAssertEqual(b.notice?.kind, .confirmation)
        XCTAssertEqual(b.notice?.text, "Added 2 songs to Up next.")

        // Insert-next and the Surprise slot ride the same live-edit primitives.
        b.add([item("g")], at: .bottom)
        XCTAssertEqual(b.flushToQueue(at: .top, sequencer: seq), 1)
        XCTAssertEqual(seq.queue.map(\.id), ["a", "g", "b", "c", "d", "e", "f"])
        XCTAssertEqual(b.notice?.text, "Added \u{201C}g\u{201D} to Up next.")

        b.add([item("h")], at: .bottom)
        var seenRange: ClosedRange<Int>?
        XCTAssertEqual(b.flushToQueue(at: .random, sequencer: seq,
                                      slot: { r in seenRange = r; return r.lowerBound }), 1)
        XCTAssertEqual(seenRange, 1...7, "the LIVE tail — right-after-current ... end")
        seq.stop()
    }

    /// The race between the render that offered "Up next" and the tap: the set can
    /// end in between. Returning 0 in silence is the exact failure this whole change
    /// exists to kill, so it must SAY so — and keep the draft, which Play can start.
    func testFlushAfterTheSetEndedSaysSoAndKeepsTheDraft() {
        let seq = makeSequencer()
        let b = makeBuilder()
        b.add([item("x"), item("y")], at: .bottom)
        XCTAssertFalse(seq.isRunning)

        XCTAssertEqual(b.flushToQueue(at: .bottom, sequencer: seq), 0)
        XCTAssertEqual(b.notice?.kind, .problem, "a no-op must never read as a confirmation")
        XCTAssertEqual(b.draft.map(\.id), ["x", "y"], "the draft survives — Play still works")
        XCTAssertTrue(b.canPlay)
    }

    func testFlushOfAnEmptyDraftIsAQuietNoOp() {
        let seq = makeSequencer()
        let b = makeBuilder()
        seq.play([item("a")], sourceSetlistId: nil)
        XCTAssertEqual(b.flushToQueue(at: .bottom, sequencer: seq), 0)
        XCTAssertNil(b.notice, "nothing was asked for, so nothing is reported")
        seq.stop()
    }

    // MARK: Add position — draft regime (idle) + Play hand-off

    func testDraftAccumulatesWithPositionSemantics() {
        let seq = makeSequencer()                       // idle set, for the untouched-queue check
        let b = makeBuilder()

        b.add([item("x")], at: .bottom)
        b.add([item("y")], at: .bottom)
        XCTAssertEqual(b.draft.map(\.id), ["x", "y"])

        b.add([item("z")], at: .top)
        XCTAssertEqual(b.draft.map(\.id), ["z", "x", "y"])

        var seenRange: ClosedRange<Int>?
        b.add([item("w")], at: .random, slot: { r in seenRange = r; return 2 })
        XCTAssertEqual(seenRange, 0...3)                // anywhere in the draft, inclusive ends
        XCTAssertEqual(b.draft.map(\.id), ["z", "x", "w", "y"])
        XCTAssertTrue(seq.queue.isEmpty)                // idle queue untouched
    }

    func testConsumeDraftForPlayReturnsIdsInOrderAndResets() {
        let b = makeBuilder()
        b.songQuery = "q"; b.artistQuery = "a"
        b.add([item("x"), item("y")], at: .bottom)
        b.add([item("z")], at: .top)

        let ids = b.consumeDraftForPlay()
        XCTAssertEqual(ids, ["z", "x", "y"])            // the playNow funnel's input, in draft order
        XCTAssertTrue(b.draft.isEmpty)
        XCTAssertEqual(b.songQuery, "")
        XCTAssertEqual(b.artistQuery, "")
        XCTAssertEqual(b.browse.query, "")              // the forward stayed in sync
    }

    func testDraftRemoveAndMove() {
        let b = makeBuilder()
        b.add([item("x"), item("y"), item("z")], at: .bottom)
        b.moveDraft(fromOffsets: IndexSet(integer: 2), toOffset: 0)
        XCTAssertEqual(b.draft.map(\.id), ["z", "x", "y"])
        let yUid = b.draft[2].uid
        b.removeDraft(uids: [yUid])
        XCTAssertEqual(b.draft.map(\.id), ["z", "x"])
        b.removeDraft(uids: [UUID()])                   // unknown uid = no-op
        XCTAssertEqual(b.draft.map(\.id), ["z", "x"])
    }

    // MARK: Cloud add (record-before-queue ordering, both regimes)

    /// Seam stub: records call order and lets a test observe builder state AT the
    /// moment `recordProvisional` fires (the ordering contract under test).
    @MainActor
    private final class StubCloudAdder: QueueBuilderCloudAdding {
        var events: [String] = []
        var onRecord: (() -> Void)?
        func recordProvisional(_ hit: RipsStore.DiscoverHit) {
            events.append("record:\(hit.songId)"); onRecord?()
        }
        func performAdd(_ hit: RipsStore.DiscoverHit) async {
            events.append("perform:\(hit.songId)")
        }
    }

    func testCloudAddRecordsProvisionalBeforeDraftInsertThenPerforms() async {
        let b = makeBuilder()
        let adder = StubCloudAdder()
        b.cloudAdder = adder
        adder.onRecord = { XCTAssertTrue(b.draft.isEmpty, "citizenship must land BEFORE the insert") }

        let task = b.addCloudHit(hit("123"), at: .bottom)
        // The synchronous half: recorded, then drafted — perform not yet run.
        XCTAssertEqual(adder.events, ["record:amrec_123"])
        XCTAssertEqual(b.draft.map(\.id), ["amrec_123"])
        // The minted item carries the hit's display + length metadata.
        XCTAssertEqual(b.draft[0].title, "T")
        XCTAssertEqual(b.draft[0].artist, "A")
        XCTAssertEqual(b.draft[0].lengthMs, 200_000)

        await task?.value
        XCTAssertEqual(adder.events, ["record:amrec_123", "perform:amrec_123"])
    }

    /// A cloud ＋ while a set runs obeys the SAME contract as a device ＋: it lands
    /// in the draft where the user can see it, and leaves the running set alone.
    /// Pre-fix it went straight into the live queue behind the sheet — and a cloud
    /// add is the one most likely to fail asynchronously, so the invisible landing
    /// spot was worst here.
    func testCloudAddWhileRunningLandsInTheVisibleDraft() async {
        let seq = makeSequencer()
        let b = makeBuilder()
        let adder = StubCloudAdder()
        b.cloudAdder = adder
        seq.play([item("a"), item("b")], sourceSetlistId: nil)

        // NOTE: every live-queue assertion stays in this synchronous stretch — the
        // real SetlistPlayer resolves (and tears down unresolvable ids) across awaits.
        let task = b.addCloudHit(hit("9"), at: .top)
        XCTAssertEqual(b.draft.map(\.id), ["amrec_9"], "visible, not swallowed by the live queue")
        XCTAssertTrue(b.canPlay)
        XCTAssertEqual(seq.queue.map(\.id), ["a", "b"], "the running set is untouched")

        // …and the second exit still puts it in the live queue, on purpose this time.
        XCTAssertEqual(b.flushToQueue(at: .top, sequencer: seq), 1)
        XCTAssertEqual(seq.queue.map(\.id), ["a", "amrec_9", "b"])
        seq.stop()

        await task?.value
        XCTAssertEqual(adder.events, ["record:amrec_9", "perform:amrec_9"])
    }

    func testCloudAddWithoutAdderStillQueues() {
        let b = makeBuilder()                           // no cloudAdder wired
        let task = b.addCloudHit(hit("7"), at: .bottom)
        XCTAssertNil(task)
        XCTAssertEqual(b.draft.map(\.id), ["amrec_7"])
    }

    // MARK: Production adapter (the DiscoverRow.addToCatalog move)

    func testAdapterRecordProvisionalMakesCatalogCitizen() async {
        let app = await loadedApp()
        let rips = makeRips()
        let addsURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("pdj-qbuilder-adds-\(UUID().uuidString).json")
        addTeardownBlock { try? FileManager.default.removeItem(at: addsURL) }
        let adds = DiscoverAddsStore(fileURL: addsURL)
        adds.onAdded = { [weak app] song in app?.injectDiscoverAdd(song) }
        rips.discoverAdds = adds
        let adapter = DiscoverQueueBuilderCloudAdder(app: app, rips: rips, library: nil)

        XCTAssertNil(app.songsById["amrec_123"])
        adapter.recordProvisional(hit("123", title: "New Song", artist: "Someone"))
        // The playNow gate: the id resolves in songsById the moment record returns.
        XCTAssertEqual(app.songsById["amrec_123"]?.name, "New Song")
        XCTAssertEqual(adds.entries.count, 1)

        adapter.recordProvisional(hit("123"))           // idempotent
        XCTAssertEqual(adds.entries.count, 1)

        // A song already in the catalog (any source) records nothing.
        adapter.recordProvisional(RipsStore.DiscoverHit(appleMusicId: "x", title: "Neon",
                                                        artist: "Aria", songId: "sng_1"))
        XCTAssertEqual(adds.entries.count, 1)
    }

    // MARK: Supersede blind spot (H1) — an owned recording must queue its OWN row

    private func indexSong(_ id: String, am: String?, name: String) -> IndexSong {
        var obj: [String: Any] = ["id": id, "name": name, "artist": "Roy Woods"]
        if let am { obj["appleMusicId"] = am }
        return try! JSONDecoder().decode(IndexSong.self,
                                         from: try! JSONSerialization.data(withJSONObject: obj))
    }

    /// A cloud hit for a recording the catalog ALREADY holds (an indexed row claims
    /// the same `appleMusicId`): `recordProvisional`'s supersede yields to the twin,
    /// so `amrec_X` never becomes a citizen — the queued item must carry the twin's
    /// id, or playNow silently drops the song from the set.
    func testCloudAddOfOwnedRecordingQueuesTheIndexedTwinNotTheDeadId() async {
        let app = AppModel()
        app.injectImported(songs: [indexSong("sng_real", am: "999", name: "How You Say My Name")],
                           albums: [])
        XCTAssertEqual(app.songId(forAppleMusicId: "999"), "sng_real")

        let rips = makeRips()
        let addsURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("pdj-qbuilder-twin-\(UUID().uuidString).json")
        addTeardownBlock { try? FileManager.default.removeItem(at: addsURL) }
        let adds = DiscoverAddsStore(fileURL: addsURL)
        adds.onAdded = { [weak app] song in app?.injectDiscoverAdd(song) }
        rips.discoverAdds = adds
        let adapter = DiscoverQueueBuilderCloudAdder(app: app, rips: rips, library: nil)

        // The adapter's re-resolution, in isolation: dead provisional id → the twin.
        XCTAssertNil(app.songsById["amrec_999"])
        XCTAssertEqual(adapter.resolvedSongId(hit("999")), "sng_real")

        // End-to-end through addCloudHit: the DRAFT holds the live twin id.
        let b = makeBuilder()
        b.cloudAdder = adapter
        _ = b.addCloudHit(hit("999", title: "How You Say My Name"), at: .bottom)
        XCTAssertNil(app.songsById["amrec_999"], "the provisional twin still yields")
        XCTAssertEqual(b.draft.map(\.id), ["sng_real"],
                       "the queued item must carry the id playNow can resolve")

        // A genuinely-new hit is untouched by the re-resolution.
        XCTAssertEqual(adapter.resolvedSongId(hit("1000")), "amrec_1000")
        // …and once a provisional IS a citizen, its own id stays authoritative.
        adapter.recordProvisional(hit("1000", title: "Something New"))
        XCTAssertNotNil(app.songsById["amrec_1000"])
        XCTAssertEqual(adapter.resolvedSongId(hit("1000")), "amrec_1000")
    }

    // MARK: Play failure (H2) — the draft must survive a refused Play

    func testPlayDraftConsumesOnlyOnSuccess() async {
        let b = makeBuilder()
        b.songQuery = "q"; b.artistQuery = "a"
        b.add([item("x"), item("y")], at: .bottom)

        struct Refused: Error {}
        var seen: [String]?
        // Throwing funnel (onboarding veto / every id dropped): NOTHING is consumed.
        let failed = await b.playDraft { ids in seen = ids; throw Refused() }
        XCTAssertFalse(failed)
        XCTAssertEqual(seen, ["x", "y"])
        XCTAssertEqual(b.draft.map(\.id), ["x", "y"], "a failed Play must not lose the draft")
        XCTAssertEqual(b.songQuery, "q")
        XCTAssertEqual(b.artistQuery, "a")

        // Successful funnel: draft + queries reset, caller told to dismiss.
        let played = await b.playDraft { ids in XCTAssertEqual(ids, ["x", "y"]) }
        XCTAssertTrue(played)
        XCTAssertTrue(b.draft.isEmpty)
        XCTAssertEqual(b.songQuery, "")
        XCTAssertEqual(b.artistQuery, "")
    }

    func testPlayDraftEmptyDraftNeverFiresTheFunnel() async {
        let b = makeBuilder()
        let played = await b.playDraft { _ in XCTFail("empty draft must not reach playNow") }
        XCTAssertFalse(played)
    }

    // ========================================================================
    // MARK: Search reliability — the ordering race, the sticky empty, the submit
    // ========================================================================

    /// THE RACE. The shipped view bound `externalBase` in a plain `.task` declared
    /// alongside the `.task(id:)` recompute — two siblings with no ordering
    /// guarantee. `refreshDevice` now binds ITSELF, so the order is a call sequence
    /// rather than a scheduling coin-flip. Note the deliberate absence of a
    /// `bindExternalBase` call here: PRE-FIX this yields 0 rows.
    func testRefreshDeviceBindsItsOwnBaseSoTheRecomputeCannotLoseTheRace() async {
        let app = await loadedApp()
        let b = makeBuilder()
        b.songQuery = "neon"
        await b.refreshDevice(app)                      // no explicit bind, on purpose
        XCTAssertEqual(b.deviceResults.map(\.idString), ["sng_1"])
        XCTAssertEqual(b.deviceState, .loaded)
    }

    /// THE STICKY EMPTY, at the BrowseState seam. When a recompute did land before
    /// any base was bound, the shipped `refreshExternal` resolved the base to `[]`
    /// AND memoized it under `baseKey` (which only moves with the catalog revision)
    /// AND stamped `displayKey = signature` — so the "already current" guard turned
    /// that empty answer into a permanent one for the rest of the session. It must
    /// now publish nothing and stamp nothing, leaving the next run free to do the
    /// real work. PRE-FIX the second refresh early-returns and this stays empty.
    func testUnboundBaseNeitherPoisonsTheCacheNorStampsTheDisplayKey() async {
        let app = await loadedApp()
        let b = makeBuilder()
        let signature = b.deviceSignature(app)
        let baseKey = b.deviceBaseKey(app)

        // The race, exactly: recompute with nothing bound yet.
        await b.browse.refreshExternal(signature: signature, baseKey: baseKey)
        XCTAssertTrue(b.browse.displayItems.isEmpty, "nothing to publish yet")

        // The binding lands late…
        b.bindExternalBase(app)
        // …and the SAME signature + SAME baseKey must still produce a real answer.
        await b.browse.refreshExternal(signature: signature, baseKey: baseKey)
        XCTAssertEqual(b.browse.displayItems.count, 7,
                       "an empty first pass must never become sticky")
    }

    /// The same thing end-to-end through the controller, and then a REPEAT of the
    /// identical query — the "I typed it again and still nothing" path.
    func testRepeatedIdenticalQueryStillPublishesAfterAnEmptyFirstPass() async {
        let app = await loadedApp()
        let b = makeBuilder()
        b.songQuery = "neon"
        // Recompute BEFORE any bind (the losing order), straight at the browse lane.
        await b.browse.refreshExternal(signature: b.deviceSignature(app),
                                       baseKey: b.deviceBaseKey(app))
        XCTAssertTrue(b.deviceResults.isEmpty)

        // Now the normal path runs for the very same signature.
        await b.refreshDevice(app)
        XCTAssertEqual(b.deviceResults.map(\.idString), ["sng_1"])

        // And typing the same term again + submitting still searches.
        await b.refreshDevice(app, force: true)
        XCTAssertEqual(b.deviceResults.map(\.idString), ["sng_1"])
    }

    /// EXPLICIT SUBMIT, at the seam. `refreshExternal` checks `displayKey` FIRST and
    /// early-returns on an unchanged signature — so a naive Search button would be
    /// inert: re-submitting the same query would do literally nothing, even with a
    /// different base underneath. `invalidateDisplayKey` is what makes it real.
    func testInvalidateDisplayKeyIsWhatMakesAnExplicitSubmitDoAnything() async throws {
        let all = try TestData.songItems()
        let b = makeBuilder()
        var rows = Array(all.prefix(2))
        b.browse.externalBase = { (rows, []) }

        await b.browse.refreshExternal(signature: "S", baseKey: "K1")
        XCTAssertEqual(b.browse.displayItems.count, 2)

        // The base moved (new baseKey) but the signature did NOT.
        rows = Array(all.prefix(5))
        await b.browse.refreshExternal(signature: "S", baseKey: "K2")
        XCTAssertEqual(b.browse.displayItems.count, 2,
                       "the 'already current' memo — this is why a plain re-run is inert")

        b.browse.invalidateDisplayKey()
        await b.browse.refreshExternal(signature: "S", baseKey: "K2")
        XCTAssertEqual(b.browse.displayItems.count, 5, "an EXPLICIT submit gets past the memo")
    }

    /// …and the controller's `force` flag wired to it, against the exact real-world
    /// shape: a lost race already published an EMPTY set under the signature the
    /// user's query maps to. Un-forced, the memo keeps that blank forever; the ⌕
    /// button / return key must still produce a real search.
    func testForcedRefreshDeviceGetsPastAPoisonedPublish() async {
        let app = await loadedApp()
        let b = makeBuilder()
        b.songQuery = "neon"

        b.browse.externalBase = { ([], []) }
        await b.browse.refreshExternal(signature: b.deviceSignature(app), baseKey: "poison")
        XCTAssertTrue(b.deviceResults.isEmpty)

        await b.refreshDevice(app)
        XCTAssertTrue(b.deviceResults.isEmpty, "unchanged signature ⇒ the memo short-circuits")

        await b.refreshDevice(app, force: true)
        XCTAssertEqual(b.deviceResults.map(\.idString), ["sng_1"],
                       "an explicit submit must always yield a real search")
    }

    /// In-flight ≠ empty. The shipped header read `On-device (0)` for "still
    /// computing", "genuinely no matches", and "the base never bound" alike.
    func testDeviceStateSeparatesSearchingFromLoaded() async {
        let app = await loadedApp()
        let b = makeBuilder()
        XCTAssertEqual(b.deviceState, .idle, "nothing has run yet — not a zero-result answer")

        b.songQuery = "neon"
        let running = Task { await b.refreshDevice(app) }
        await Task.yield()
        XCTAssertEqual(b.deviceState, .searching, "the 180 ms debounce must SAY it is searching")
        await running.value
        XCTAssertEqual(b.deviceState, .loaded)

        // A real zero-result answer is `.loaded` with no rows — distinguishable.
        b.songQuery = "zzzznope"
        await b.refreshDevice(app)
        XCTAssertEqual(b.deviceState, .loaded)
        XCTAssertTrue(b.deviceResults.isEmpty)
    }

    /// The cloud lane must announce itself SYNCHRONOUSLY, before the 400 ms
    /// coalescing sleep. Pre-fix `state` was only set inside the task after the
    /// sleep, so the first 400 ms of every cloud search rendered the idle hint —
    /// i.e. looked like the keystroke did nothing at all.
    func testCloudSearchGoesLoadingBeforeTheDebounceSleep() {
        let b = makeBuilder()
        b.mode = .cloud
        b.songQuery = "daft"
        XCTAssertEqual(b.discover.state, .idle)
        b.refreshCloud(rips: makeRips())
        XCTAssertEqual(b.discover.state, .loading,
                       "in-flight is visible from the first keystroke, not 400 ms later")
    }

    /// A blank pair of omni bars is not a search — device mode lists the whole
    /// catalog (the discoverable default) and cloud shows its hint rather than a
    /// bare "No matches."
    func testHasSearchTermDistinguishesBlankFromTyped() {
        let b = makeBuilder()
        XCTAssertFalse(b.hasSearchTerm)
        b.songQuery = "   "
        XCTAssertFalse(b.hasSearchTerm, "whitespace is not a query")
        b.songQuery = "neon"
        XCTAssertTrue(b.hasSearchTerm)
        b.songQuery = ""; b.artistQuery = "aria"
        XCTAssertTrue(b.hasSearchTerm, "an artist-only refine is still a search")
    }

    // MARK: Notices — a refusal must never render as a confirmation

    func testRefusedPlayLeavesAProblemNoticeCarryingTheReason() async {
        let b = makeBuilder()
        b.add([item("x")], at: .bottom)

        let played = await b.playDraft { _ in throw PocketDJIntentError.emptyCollection("Queue") }
        XCTAssertFalse(played)
        XCTAssertEqual(b.notice?.kind, .problem,
                       "a refusal drawn with a green checkmark is worse than no notice")
        XCTAssertEqual(b.notice?.text, String(localized: PocketDJIntentError
                                                  .emptyCollection("Queue").localizedStringResource))
        XCTAssertEqual(b.draft.map(\.id), ["x"], "and the draft survives (H2)")

        // A successful Play clears the stale refusal.
        let ok = await b.playDraft { _ in }
        XCTAssertTrue(ok)
        XCTAssertNil(b.notice)
    }

    func testANewAddClearsAStaleNotice() {
        let seq = makeSequencer()
        let b = makeBuilder()
        b.add([item("x")], at: .bottom)
        _ = b.flushToQueue(at: .bottom, sequencer: seq)   // idle ⇒ problem notice
        XCTAssertEqual(b.notice?.kind, .problem)
        b.add([item("y")], at: .bottom)
        XCTAssertNil(b.notice, "a receipt must never outlive the thing it described")
    }
}

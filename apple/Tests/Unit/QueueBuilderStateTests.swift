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
        b.browse.sortKeys = [SortKey(field: "bpm", dir: .desc)]
        XCTAssertNotEqual(s1, b.deviceSignature(app))   // sort too
    }

    /// …and the ONE input that must NOT be in it. `artistQuery` is a read-time predicate
    /// over the already-computed rows (`deviceResults`); nothing downstream of the
    /// off-main filter/sort reads it. In the signature it bought nothing and charged an
    /// Artist keystroke the 180 ms text debounce plus a full catalog filter+sort before
    /// the refine ran anyway — which is what "typing does nothing" feels like. Out of it,
    /// the refine lands on the next body pass.
    func testArtistQueryIsNotInTheRecomputeSignature() async {
        let app = await loadedApp()
        let b = makeBuilder()
        b.songQuery = "x"
        let before = b.deviceSignature(app)
        b.artistQuery = "cobalt"
        XCTAssertEqual(before, b.deviceSignature(app),
                       "a read-time refine must not re-fire the debounce + filter/sort")

        // …and it still narrows what the list shows, immediately, off the SAME rows.
        // CONCRETE ids, deliberately: `deviceResults` IS
        // `refineByArtist(browse.displayItems, artist: artistQuery)`, so asserting it
        // against that same expression asserts nothing — a `refineByArtist` whose field
        // lookup matched NOTHING kept that version of this test green.
        b.songQuery = ""
        await b.refreshDevice(app)
        let all = b.browse.displayItems.map(\.idString)
        XCTAssertEqual(all, ["sng_1", "sng_2", "sng_3", "sng_4", "sng_5", "sng_6", "sng_7"])
        XCTAssertEqual(b.deviceResults.map(\.idString), ["sng_6", "sng_7"],
                       "the refine narrows to Cobalt's songs, off the already-published rows")
        b.artistQuery = ""
        XCTAssertEqual(b.deviceResults.map(\.idString), all,
                       "clearing the refine restores every row")
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

    /// THE STICKY EMPTY, one level under the one `force` fixed — reached THROUGH the
    /// explicit submit. `refreshDevice` evaluates `deviceSignature(app)` BEFORE
    /// `refreshExternal`'s 180 ms text debounce, while the rows are filtered from
    /// `query` read AFTER it. The submit task is unstructured (nothing cancels it, by
    /// design: an unchanged id must still re-fire), so a user who keeps typing inside
    /// that window used to get the NEW query's rows published under the OLD query's
    /// signature — after which the "already current" guard early-returned for that
    /// signature forever and the submitted query could never be searched again.
    /// PRE-FIX the final assertion sees an empty list.
    func testASubmitOvertakenByMoreTypingNeverStampsTheOldQuerysSignature() async {
        let app = await loadedApp()
        let b = makeBuilder()
        b.bindExternalBase(app)
        b.songQuery = "neon"

        // The explicit submit, exactly as the sheet fires it…
        let submit = Task { await b.refreshDevice(app, force: true) }
        // …and one more keystroke inside its debounce window (20 ms ≪ 180 ms).
        try? await Task.sleep(for: .milliseconds(20))
        b.songQuery = "neonzzz"
        await submit.value

        // Back to the query the user actually submitted: it must still SEARCH.
        b.songQuery = "neon"
        await b.refreshDevice(app)
        XCTAssertEqual(b.deviceResults.map(\.idString), ["sng_1"],
                       "a superseded submit must not poison the signature it was fired for")
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

    func testANewAddReplacesAStaleNoticeWithItsOwnReceipt() {
        let seq = makeSequencer()
        let b = makeBuilder()
        b.add([item("x")], at: .bottom)
        _ = b.flushToQueue(at: .bottom, sequencer: seq)   // idle ⇒ problem notice
        XCTAssertEqual(b.notice?.kind, .problem)
        b.add([item("y")], at: .bottom)
        XCTAssertEqual(b.notice?.kind, .confirmation,
                       "a receipt must never outlive the thing it described")
        XCTAssertTrue(b.notice?.text.contains("y") == true, "and the new one names the add")
    }

    /// Every ＋ SAYS SO. `add` used to CLEAR the notice line, so adds 2..N moved exactly
    /// one dim digit in the bottom bar while the only other receipt — the draft row —
    /// sat above the results where a scrolled list hides it. PRE-FIX every assertion
    /// here fails on `notice == nil`.
    func testEveryAddLeavesAVisibleReceiptNamingWhatLanded() {
        let b = makeBuilder()
        b.add([item("Neon")], at: .bottom)
        XCTAssertEqual(b.notice?.kind, .confirmation)
        XCTAssertTrue(b.notice?.text.contains("Neon") == true, "one add names the song")

        // The slot is part of the receipt whenever it isn't the default end-of-draft:
        // the row it lands on may be nowhere near the user's eyes.
        b.add([item("Cobalt")], at: .top)
        XCTAssertTrue(b.notice?.text.contains("TOP") == true, "…and says where it went")

        b.add([item("a"), item("b"), item("c")], at: .bottom)
        XCTAssertTrue(b.notice?.text.contains("3 songs") == true, "a batch counts")

        // A remove is not an add — its receipt would be a lie about the draft's shape.
        b.removeDraft(uids: Set(b.draft.prefix(1).map(\.uid)))
        XCTAssertNil(b.notice)
    }

    /// The ROW's own receipt. Without it a user unsure their tap registered taps again
    /// and silently gets two copies (`add` appends unconditionally, by design).
    func testDraftedIdsMarkTheResultRowsAlreadyAdded() {
        let b = makeBuilder()
        XCTAssertTrue(b.draftedIds.isEmpty)
        b.add([item("sng_1")], at: .bottom)
        XCTAssertTrue(b.draftedIds.contains("sng_1"))
        XCTAssertFalse(b.draftedIds.contains("sng_2"))
        b.removeDraft(uids: Set(b.draft.map(\.uid)))
        XCTAssertTrue(b.draftedIds.isEmpty, "…and it un-marks when the row leaves the draft")
    }

    // MARK: The LIVE queue — "I can see what I am building" (requirement A)

    /// The sheet covers the Now Playing panel on iPhone, so while it is open the running
    /// set was invisible: the user built a queue with no view of what it was being built
    /// against. PRE-FIX there is no `liveQueue` at all.
    func testLiveQueueProjectsWhatIsPlayingAndWhatIsQueuedBehindIt() {
        let seq = makeSequencer()
        let b = makeBuilder()
        XCTAssertTrue(b.liveQueue(seq).isEmpty, "nothing running ⇒ nothing to show")

        seq.play([item("a"), item("b"), item("c"), item("d")], sourceSetlistId: nil)
        let live = b.liveQueue(seq)
        XCTAssertEqual(live.nowPlaying?.id, "a")
        XCTAssertEqual(live.upNext.map(\.id), ["b", "c", "d"])
        XCTAssertEqual(live.upNextTotal, 3)
        XCTAssertFalse(live.isHeld)
        XCTAssertFalse(live.isEmpty)

        // WINDOWED: `SetlistPlayer.upcoming` is a slice precisely so nobody materializes
        // a 26k tail per body pass. The total is reported separately so the sheet can
        // say "+ N more" instead of lying about the set's length.
        let windowed = b.liveQueue(seq, limit: 2)
        XCTAssertEqual(windowed.upNext.map(\.id), ["b", "c"])
        XCTAssertEqual(windowed.upNextTotal, 3)
        seq.stop()
    }

    /// A RESTORED set is `isRunning` with NO audio. Calling that "Now playing" is the
    /// same class of lie the shipped Up-next receipt told, so the projection carries the
    /// distinction and the sheet's header reads "Paused set".
    func testLiveQueueMarksARestoredSetHeldRatherThanPlaying() {
        let seq = makeSequencer()
        let b = makeBuilder()
        seq.restore(from: PlaybackSessionStore.Snapshot(
            sessionId: "pses_t",
            source: .init(kind: "playlist", id: "pls_1", name: "Roadtrip"),
            queue: [.init(songId: "s_a", title: "A", artist: "X", lengthMs: nil, repeatCount: nil),
                    .init(songId: "s_b", title: "B", artist: "X", lengthMs: nil, repeatCount: nil)],
            index: 0, positionMs: 0, isPlaying: true, updatedAt: 0))
        XCTAssertTrue(seq.isRunning)
        let live = b.liveQueue(seq)
        XCTAssertTrue(live.isHeld, "running by every flag, silent in fact")
        XCTAssertEqual(live.nowPlaying?.id, "s_a")
        XCTAssertEqual(live.upNext.map(\.id), ["s_b"])
        seq.stop()
    }

    /// The flush was a ONE-WAY DOOR: the draft emptied, Play vanished with it, and the
    /// songs went somewhere the sheet could not render — one line of text was the whole
    /// receipt. They must remain VISIBLE, in the live queue, right where they landed.
    func testFlushedSongsStayVisibleInTheLiveQueue() {
        let seq = makeSequencer()
        let b = makeBuilder()
        seq.play([item("a"), item("b")], sourceSetlistId: nil)
        b.add([item("e"), item("f")], at: .bottom)
        XCTAssertEqual(b.liveQueue(seq).upNext.map(\.id), ["b"], "not there yet")

        XCTAssertEqual(b.flushToQueue(at: .bottom, sequencer: seq), 2)
        XCTAssertTrue(b.draft.isEmpty)
        XCTAssertEqual(b.liveQueue(seq).upNext.map(\.id), ["b", "e", "f"],
                       "the draft emptied INTO something the sheet can show")
        XCTAssertEqual(b.notice?.kind, .confirmation)
        seq.stop()
    }

    // MARK: Cloud — the FOURTH state (no backend at all)

    /// With no import server AND no Apple Music authorization, Discover settles `.loaded`
    /// with zero hits and NO error, so every query rendered "Nothing in the Apple Music
    /// catalog matched that" — a claim about the CATALOG standing in for the truth about
    /// this device. Knowable before any search runs.
    func testCloudUnavailableIsItsOwnStateNotAnEmptyResult() {
        XCTAssertNil(QueueBuilderState.cloudUnavailableMessage(hasServer: true,
                                                               canSearchCatalog: false))
        XCTAssertNil(QueueBuilderState.cloudUnavailableMessage(hasServer: false,
                                                               canSearchCatalog: true))
        XCTAssertNil(QueueBuilderState.cloudUnavailableMessage(hasServer: true,
                                                               canSearchCatalog: true))
        let message = QueueBuilderState.cloudUnavailableMessage(hasServer: false,
                                                                canSearchCatalog: false)
        XCTAssertNotNil(message, "neither lane can answer — SAY so")
        XCTAssertTrue(message?.contains("Settings") == true, "…and point somewhere actionable")
    }

    // MARK: Sticky-empty, one level below the unbound case (the BASE memo)

    /// `baseKey` moves only with the catalog revision, so memoizing an EMPTY base blanks
    /// the surface for that WHOLE revision — every later signature reuses the cached
    /// nothing. PRE-FIX the second call reuses `[]` under "K" and this asserts 0 == 5.
    func testAnEmptyBaseIsNeverMemoizedUnderItsBaseKey() async throws {
        let all = try TestData.songItems()
        let b = makeBuilder()
        var rows: [BrowseItem] = []
        b.browse.externalBase = { (rows, []) }

        await b.browse.refreshExternal(signature: "S1", baseKey: "K")
        XCTAssertTrue(b.browse.displayItems.isEmpty)

        // The base fills in — WITHOUT the catalog revision (and so `baseKey`) moving.
        rows = Array(all.prefix(5))
        await b.browse.refreshExternal(signature: "S2", baseKey: "K")
        XCTAssertEqual(b.browse.displayItems.count, 5,
                       "an empty base must never be remembered")
    }

    /// …and the explicit submit must escape it even when the empty base WAS cached under
    /// the real key. This is TRACE A's poisoned-base probe against the REAL `qb-<rev>`
    /// key (the existing forced-refresh test uses a different key, so it never touched
    /// the base memo). PRE-FIX: `invalidateDisplayKey` cleared only the DISPLAY memo, so
    /// the forced run re-filtered the cached nothing and the user stayed blank forever.
    func testExplicitSubmitEscapesABasePoisonedUnderTheRealBaseKey() async {
        let app = await loadedApp()
        let b = makeBuilder()
        b.songQuery = "neon"

        // The lost race, exactly as it lands in production: a bound-but-empty base
        // published under the signature AND the real baseKey.
        b.browse.externalBase = { ([], []) }
        await b.browse.refreshExternal(signature: b.deviceSignature(app),
                                       baseKey: b.deviceBaseKey(app))
        XCTAssertTrue(b.deviceResults.isEmpty)

        await b.refreshDevice(app, force: true)
        XCTAssertEqual(b.deviceResults.map(\.idString), ["sng_1"],
                       "the ⌕ button / return key is the one gesture that must ALWAYS work")
    }

    /// The silent no-op where an assertion belongs: mismatched parallel arrays used to
    /// DROP the text query and return the whole base — indistinguishable, to a user,
    /// from "typing has no effect". PRE-FIX this returns all 7 rows.
    func testFilterSortHonoursTheQueryEvenWithMismatchedSearchKeys() throws {
        let items = try TestData.songItems()
        let out = BrowseState.filterSort(base: items, searchKeys: [], query: "neon",
                                         clauses: [], sortKeys: [])
        XCTAssertEqual(out.map(\.idString), ["sng_1"],
                       "a broken haystack must never silently widen the search")
    }
}

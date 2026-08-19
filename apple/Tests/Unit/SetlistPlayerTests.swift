import XCTest
@testable import PocketDJ

/// Feature 3 — Setlist PLAY ALL. `SetlistPlayer` sequences a setlist's tracks in order,
/// choosing the SOURCE per track: a BURNT local file (`BurnStore.localURL`) is played
/// directly through the shared `PlayerEngine`; otherwise the track STREAMS via the
/// `PlaybackCoordinator` (cached rip → S3 mp3 here). It AUTO-ADVANCES on the engine's
/// `onTrackEnded` hook and SKIPS an unplayable track (coordinator error) immediately.
///
/// These tests use the real (final) `PlayerEngine` / `PlaybackCoordinator` /
/// `RipServerPlaybackProvider` wired to a `RipsStore` whose manifest + `URLProtocol` stub
/// make the rip path resolve deterministically offline, plus a real `BurnStore` that has
/// actually burned a file (so `localURL` returns it). `sourceOfSong` is left at its nil
/// default, so the coordinator only ever uses the rip-server provider — no Apple Music
/// authorization is involved. The engine's natural end is simulated by invoking its public
/// `onTrackEnded` hook (the same callback `.AVPlayerItemDidPlayToEndTime` fires).
@MainActor
final class SetlistPlayerTests: XCTestCase {
    private let ripsBase = URL(string: "https://rips.test")!

    // MARK: Fixtures

    private func makeRips(serverURL: String = "") -> RipsStore {
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [SetlistStubURLProtocol.self]
        let rips = RipsStore(ripsBase: ripsBase, session: URLSession(configuration: config))
        let settings = SettingsStore(defaults: UserDefaults(suiteName: "test.\(UUID().uuidString)")!)
        settings.ripServerURL = serverURL
        settings.ripToken = ""
        rips.settings = settings
        return rips
    }

    private func makeBurns(_ rips: RipsStore) -> BurnStore {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("pdj-setlistburn-\(UUID().uuidString).json")
        addTeardownBlock { try? FileManager.default.removeItem(at: url) }
        return BurnStore(rips: rips, fileURL: url)
    }

    private func makeCoordinator(rips: RipsStore, player: PlayerEngine) -> PlaybackCoordinator {
        let am = AppleMusicPlaybackProvider(provider: AppleMusicProvider())
        return PlaybackCoordinator(
            ripProvider: RipServerPlaybackProvider(rips: rips, player: player),
            appleMusic: am)
        // sourceOfSong defaults to { _ in nil } → Apple Music is never first → rip-only.
    }

    private func cleanBurnedFiles(_ names: [String]) {
        guard let dir = try? RipsStore.burnsDirectory() else { return }
        for n in names { try? FileManager.default.removeItem(at: dir.appendingPathComponent(n)) }
    }

    /// Actually burn `songId` so `BurnStore.localURL(forSong:)` returns a real on-disk file.
    private func burn(_ rips: RipsStore, _ burns: BurnStore, songId: String) async {
        rips.setManifest([songId: .init(key: "rips/\(songId).mp3", source: "digital")])
        SetlistStubURLProtocol.body = Data("BURNT-MP3".utf8)
        _ = await burns.burn([(id: songId, title: songId, artist: "A")])
        XCTAssertNotNil(burns.localURL(forSong: songId), "precondition: \(songId) is burned")
    }

    /// Poll the main actor until `predicate` holds or a short timeout elapses — used to await
    /// `SetlistPlayer`'s fire-and-forget `Task { await playCurrent() }` (no awaitable handle).
    private func waitUntil(_ message: String, _ predicate: () -> Bool) async {
        for _ in 0..<200 {
            if predicate() { return }
            try? await Task.sleep(nanoseconds: 5_000_000)   // 5 ms
        }
        XCTFail("timed out waiting: \(message)")
    }

    // MARK: Empty list is a no-op

    func testPlayEmptyIsNoOp() {
        let rips = makeRips(); let burns = makeBurns(rips)
        let player = PlayerEngine()
        let coord = makeCoordinator(rips: rips, player: player)
        let seq = SetlistPlayer(player: player, rips: rips, burns: burns, coordinator: coord)
        seq.play([])
        XCTAssertFalse(seq.isRunning)
        XCTAssertTrue(seq.queue.isEmpty)
    }

    // MARK: Source tracking — a fresh play REPLACES the running set

    /// `play(_:sourceSetlistId:)` tags the run, and playing a DIFFERENT collection REPLACES
    /// the first (queue + index + source swap). Nothing else stops a set — that contract is
    /// what lets one set keep playing (the player is app-scoped) while you build others,
    /// until you explicitly play another collection.
    func testNewPlayReplacesRunningSetAndTracksSource() {
        let rips = makeRips(); let burns = makeBurns(rips)
        let player = PlayerEngine()
        let coord = makeCoordinator(rips: rips, player: player)
        let seq = SetlistPlayer(player: player, rips: rips, burns: burns, coordinator: coord)

        seq.play([.init(id: "sng_a1", title: "A1", artist: "A"),
                  .init(id: "sng_a2", title: "A2", artist: "A")], sourceSetlistId: "set_A")
        XCTAssertTrue(seq.isRunning)
        XCTAssertEqual(seq.sourceSetlistId, "set_A")
        XCTAssertEqual(seq.queue.map(\.id), ["sng_a1", "sng_a2"])

        // Playing another collection swaps the queue + source (the first set is replaced).
        seq.play([.init(id: "sng_b1", title: "B1", artist: "B")], sourceSetlistId: "set_B")
        XCTAssertTrue(seq.isRunning)
        XCTAssertEqual(seq.sourceSetlistId, "set_B")
        XCTAssertEqual(seq.queue.map(\.id), ["sng_b1"])
        XCTAssertEqual(seq.index, 0)
        seq.stop()
    }

    /// Play-History attribution seam: `inRunningQueue` recognizes ANY member of the running set
    /// (so a member-row jump isn't mislabeled a Browser single), and `capturedHistoryContext` is
    /// snapshotted at play() time from the wired provider (so a later playNow can't retag this run).
    func testInRunningQueueAndCapturedHistoryContext() {
        let rips = makeRips(); let burns = makeBurns(rips)
        let player = PlayerEngine()
        let coord = makeCoordinator(rips: rips, player: player)
        let seq = SetlistPlayer(player: player, rips: rips, burns: burns, coordinator: coord)
        seq.historyContextProvider = { id in id == "set_A" ? (.playlist, "Roadtrip") : (.setlist, nil) }

        seq.play([.init(id: "t1", title: "T1", artist: "A"),
                  .init(id: "t5", title: "T5", artist: "A")], sourceSetlistId: "set_A")
        // Every member — not just the current track — attributes to the set.
        XCTAssertTrue(seq.inRunningQueue("t1"))
        XCTAssertTrue(seq.inRunningQueue("t5"))
        XCTAssertFalse(seq.inRunningQueue("not_in_set"))
        // Origin captured from the provider at play() time.
        XCTAssertEqual(seq.capturedHistoryContext?.source, .playlist)
        XCTAssertEqual(seq.capturedHistoryContext?.name, "Roadtrip")

        seq.stop()
        XCTAssertFalse(seq.inRunningQueue("t1"))         // nothing is "in the running queue" when idle
        XCTAssertNil(seq.capturedHistoryContext)
    }

    /// A GAME's run tag names no collection, so the collections lookup alone answers
    /// (.setlist, nil) and History labelled every Gem Collector play "Set list". With the real
    /// composition-root provider installed, the run captures (.game, "Gem Collector") instead.
    func testPuzzleRunCapturesTheGameHistoryContext() async {
        let rips = makeRips(); let burns = makeBurns(rips)
        let player = PlayerEngine()
        let coord = makeCoordinator(rips: rips, player: player)
        let seq = SetlistPlayer(player: player, rips: rips, burns: burns, coordinator: coord)
        let app = AppModel(loader: TestData.StubLoader())
        await app.loadIfNeeded()
        let colURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("pdj-seqgame-\(UUID().uuidString).json")
        addTeardownBlock { try? FileManager.default.removeItem(at: colURL) }
        let collections = CollectionsStore(fileURL: colURL)
        collections.app = app
        // The EXACT provider PocketDJApp installs — not a stand-in, so this can't drift from it.
        seq.historyContextProvider = { [weak collections] in
            PocketDJApp.historyContext(forSourceSetlistId: $0, collections: collections)
        }

        seq.play([.init(id: "t1", title: "T1", artist: "A")],
                 sourceSetlistId: "\(CollectorsPuzzleEngine.runTagPrefix)\(UUID().uuidString)")
        XCTAssertEqual(seq.capturedHistoryContext?.source, .game)
        XCTAssertEqual(seq.capturedHistoryContext?.name, GameKind.collectorsPuzzle.label)
        seq.stop()

        // An ordinary run through the SAME provider is untouched by the game branch.
        guard let sl = collections.realize(songIds: ["sng_1"], name: "Friday Night") else {
            return XCTFail("realize failed")
        }
        seq.play([.init(id: "sng_1", title: "One", artist: "A")], sourceSetlistId: sl.id)
        XCTAssertEqual(seq.capturedHistoryContext?.source, .setlist)
        XCTAssertEqual(seq.capturedHistoryContext?.name, "Friday Night")
        seq.stop()
    }

    /// Stop clears the source id, so no detail screen mistakes itself for the one playing.
    func testStopClearsSourceSetlistId() {
        let rips = makeRips(); let burns = makeBurns(rips)
        let player = PlayerEngine()
        let coord = makeCoordinator(rips: rips, player: player)
        let seq = SetlistPlayer(player: player, rips: rips, burns: burns, coordinator: coord)
        seq.play([.init(id: "sng_1", title: "1", artist: "A")], sourceSetlistId: "set_1")
        XCTAssertEqual(seq.sourceSetlistId, "set_1")
        seq.stop()
        XCTAssertNil(seq.sourceSetlistId)
        XCTAssertFalse(seq.isRunning)
    }

    // MARK: Burnt local file WINS over streaming

    /// A track with a burnt local file plays that file directly through the `PlayerEngine`
    /// (nowPlaying.url == the burnt file, NOT live) and never engages the coordinator
    /// (activeBackend stays nil — the streaming path was not taken).
    func testPicksBurntLocalFileOverStreaming() async {
        cleanBurnedFiles(["sng_b.mp3", "sng_b.txt"])
        // Server configured so streaming WOULD work — proving the burnt file is preferred.
        let rips = makeRips(serverURL: "https://imac.test")
        let burns = makeBurns(rips)
        let player = PlayerEngine()
        let coord = makeCoordinator(rips: rips, player: player)
        await burn(rips, burns, songId: "sng_b")
        let local = burns.localURL(forSong: "sng_b")

        let seq = SetlistPlayer(player: player, rips: rips, burns: burns, coordinator: coord)
        seq.play([.init(id: "sng_b", title: "Burned", artist: "A")])

        await waitUntil("burnt file becomes now-playing") { rips.nowPlaying?.songId == "sng_b" }
        XCTAssertTrue(seq.isRunning)
        XCTAssertEqual(rips.nowPlaying?.url, local, "the BURNT local file is played, not a stream")
        XCTAssertEqual(rips.nowPlaying?.live, false)
        XCTAssertNil(coord.activeBackend, "the coordinator/stream path was NOT engaged")
        seq.stop()
        cleanBurnedFiles(["sng_b.mp3", "sng_b.txt"])
    }

    // MARK: Streams via the coordinator when there's no burnt file

    /// A track with NO burnt file but a cached rip streams via the coordinator: the rip
    /// provider wins (activeBackend == .ripServer), no error is surfaced, and now-playing is
    /// the cached S3 mp3 (not live).
    func testStreamsViaCoordinatorWhenNoBurntFile() async {
        let rips = makeRips(serverURL: "https://imac.test")
        let burns = makeBurns(rips)
        let player = PlayerEngine()
        let coord = makeCoordinator(rips: rips, player: player)
        // Cached (in the manifest) but NOT burned → the coordinator resolves the S3 mp3.
        rips.setManifest(["sng_s": .init(key: "rips/sng_s.mp3", source: "digital")])
        XCTAssertNil(burns.localURL(forSong: "sng_s"), "precondition: not burned")

        let seq = SetlistPlayer(player: player, rips: rips, burns: burns, coordinator: coord)
        seq.play([.init(id: "sng_s", title: "Streamed", artist: "A")])

        await waitUntil("coordinator backend becomes active") { coord.activeBackend == .ripServer }
        XCTAssertNil(coord.lastErrorMessage, "a resolvable stream surfaces no error")
        XCTAssertEqual(rips.nowPlaying?.songId, "sng_s")
        XCTAssertEqual(rips.nowPlaying?.url.absoluteString, "https://rips.test/rips/sng_s.mp3")
        XCTAssertEqual(rips.nowPlaying?.live, false)
        seq.stop()
    }

    // MARK: AUTO-ADVANCE on the engine's natural end

    /// When the current (burnt) track ends, the engine's `onTrackEnded` hook fires and the
    /// sequencer advances to the next queued track.
    func testAutoAdvancesOnTrackEnded() async {
        cleanBurnedFiles(["sng_1.mp3", "sng_1.txt", "sng_2.mp3", "sng_2.txt"])
        let rips = makeRips(serverURL: "https://imac.test")
        let burns = makeBurns(rips)
        let player = PlayerEngine()
        let coord = makeCoordinator(rips: rips, player: player)
        await burn(rips, burns, songId: "sng_1")
        await burn(rips, burns, songId: "sng_2")

        let seq = SetlistPlayer(player: player, rips: rips, burns: burns, coordinator: coord)
        seq.play([
            .init(id: "sng_1", title: "One", artist: "A"),
            .init(id: "sng_2", title: "Two", artist: "A"),
        ])

        await waitUntil("track 0 playing") { rips.nowPlaying?.songId == "sng_1" }
        XCTAssertEqual(seq.index, 0)

        // Simulate the finite item playing to its natural end (the same callback
        // .AVPlayerItemDidPlayToEndTime invokes). The sequencer must advance to track 1.
        player.onTrackEnded?()
        await waitUntil("auto-advanced to track 1") { rips.nowPlaying?.songId == "sng_2" }
        XCTAssertEqual(seq.index, 1)
        XCTAssertTrue(seq.isRunning)

        // Ending the LAST track stops the sequence cleanly.
        player.onTrackEnded?()
        await waitUntil("sequence stops at the end") { !seq.isRunning }
        XCTAssertNil(rips.nowPlaying, "now-playing cleared when the set finishes")
        cleanBurnedFiles(["sng_1.mp3", "sng_1.txt", "sng_2.mp3", "sng_2.txt"])
    }

    // MARK: cleanOnly substitution — a variant play advances at its natural end

    /// REGRESSION (critical, cleanOnly stall): a substituted row's stream/rip resolves under
    /// the VARIANT id ("sng_…_clean" — the rip pipeline keys variant audio by it) while the
    /// queue row keeps the BASE id. The end-of-track ownership guard must recognize that
    /// play as its own (`Item.matches`) — comparing the base id alone made the guard fail,
    /// so every substituted track silently STOPPED the set at its natural end. Also proves
    /// the stats hook fires the BASE id (no ghost "sng_…_clean" history/stats rows) and
    /// that the sequencer's own variant play is not adopted as a foreign jump.
    func testVariantTrackAutoAdvancesOnNaturalEndAndReportsBaseIdToStats() async {
        cleanBurnedFiles(["sng_2.mp3", "sng_2.txt"])
        let rips = makeRips(serverURL: "https://imac.test")
        let burns = makeBurns(rips)
        let player = PlayerEngine()
        let coord = makeCoordinator(rips: rips, player: player)
        await burn(rips, burns, songId: "sng_2")
        // The clean variant's rip is cached (manifest keyed by the VARIANT id) but NOT
        // burned → the coordinator streams it via the rip provider under the variant id.
        // AFTER burn(): setManifest REPLACES the manifest wholesale (test seam), and
        // burn() uses it for its own song.
        rips.setManifest([
            "sng_1a7f6bc854af_clean": .init(key: "rips/sng_1a7f6bc854af_clean.mp3", source: "digital"),
            "sng_2": .init(key: "rips/sng_2.mp3", source: "digital"),
        ])
        var statsIds: [String] = []
        rips.onPlay = { statsIds.append($0) }

        let seq = SetlistPlayer(player: player, rips: rips, burns: burns, coordinator: coord)
        seq.play([
            .init(id: "sng_1a7f6bc854af", title: "Substituted", artist: "A", variant: .clean),
            .init(id: "sng_2", title: "Two", artist: "A"),
        ])

        await waitUntil("variant streams under its variant id") {
            rips.nowPlaying?.songId == "sng_1a7f6bc854af_clean"
        }
        XCTAssertEqual(seq.index, 0, "the sequencer's own variant play is not a foreign jump")
        XCTAssertTrue(seq.isRunning)
        XCTAssertEqual(statsIds, ["sng_1a7f6bc854af"],
                       "the stats hook reports the BASE id — never the variant ghost id")

        // Natural end of the substituted track: the ownership guard matches the row via its
        // resolving identity and ADVANCES — pre-fix it returned early and the set stalled.
        player.onTrackEnded?()
        await waitUntil("advanced past the substituted track") { rips.nowPlaying?.songId == "sng_2" }
        XCTAssertEqual(seq.index, 1)
        XCTAssertTrue(seq.isRunning)
        XCTAssertEqual(statsIds, ["sng_1a7f6bc854af", "sng_2"])
        seq.stop()
        cleanBurnedFiles(["sng_2.mp3", "sng_2.txt"])
    }

    // MARK: Repeat count — a track loops N times before advancing

    /// A track with `repeatCount` loops IN PLACE on each natural end until its plays are used up,
    /// then advances. The index logic is synchronous in `handleEnded`/`advanceToNext`, so the
    /// per-end index is asserted deterministically (no timing).
    func testRepeatCountLoopsTrackBeforeAdvancing() async {
        cleanBurnedFiles(["rp_1.mp3", "rp_1.txt", "rp_2.mp3", "rp_2.txt"])
        let rips = makeRips(serverURL: "https://imac.test")
        let burns = makeBurns(rips)
        let player = PlayerEngine()
        let coord = makeCoordinator(rips: rips, player: player)
        await burn(rips, burns, songId: "rp_1")
        await burn(rips, burns, songId: "rp_2")

        let seq = SetlistPlayer(player: player, rips: rips, burns: burns, coordinator: coord)
        seq.play([
            .init(id: "rp_1", title: "One", artist: "A", repeatCount: 3),   // plays 3×
            .init(id: "rp_2", title: "Two", artist: "A"),
        ])
        await waitUntil("track 0 playing") { rips.nowPlaying?.songId == "rp_1" }
        XCTAssertEqual(seq.index, 0)

        player.onTrackEnded?(); XCTAssertEqual(seq.index, 0, "1st repeat — stays on the track")
        player.onTrackEnded?(); XCTAssertEqual(seq.index, 0, "2nd repeat — stays on the track")
        player.onTrackEnded?()                                             // 3rd play done → advance
        await waitUntil("advanced after all 3 plays") { seq.index == 1 && rips.nowPlaying?.songId == "rp_2" }
        cleanBurnedFiles(["rp_1.mp3", "rp_1.txt", "rp_2.mp3", "rp_2.txt"])
    }

    /// An explicit SKIP ignores the repeat count — a repeating track moves on immediately rather
    /// than looping (only a NATURAL end repeats).
    func testSkipNextIgnoresRepeatCount() async {
        cleanBurnedFiles(["rp_1.mp3", "rp_1.txt", "rp_2.mp3", "rp_2.txt"])
        let rips = makeRips(serverURL: "https://imac.test")
        let burns = makeBurns(rips)
        let player = PlayerEngine()
        let coord = makeCoordinator(rips: rips, player: player)
        await burn(rips, burns, songId: "rp_1")
        await burn(rips, burns, songId: "rp_2")

        let seq = SetlistPlayer(player: player, rips: rips, burns: burns, coordinator: coord)
        seq.play([
            .init(id: "rp_1", title: "One", artist: "A", repeatCount: 5),
            .init(id: "rp_2", title: "Two", artist: "A"),
        ])
        await waitUntil("track 0 playing") { rips.nowPlaying?.songId == "rp_1" }
        seq.skipNext()
        XCTAssertEqual(seq.index, 1, "skip advances immediately, never repeats")
        cleanBurnedFiles(["rp_1.mp3", "rp_1.txt", "rp_2.mp3", "rp_2.txt"])
    }

    // MARK: SKIP an unplayable track

    /// An unplayable track (no burnt file, not cached, no rip server → the coordinator
    /// surfaces an error and no end event will ever fire) is SKIPPED immediately, so the
    /// next (playable, burnt) track plays without manual intervention.
    func testSkipsUnplayableTrackAndPlaysNext() async {
        cleanBurnedFiles(["sng_ok.mp3", "sng_ok.txt"])
        // No rip server → an un-burned, un-cached track can't be streamed (rips.play throws).
        let rips = makeRips(serverURL: "")
        let burns = makeBurns(rips)
        let player = PlayerEngine()
        let coord = makeCoordinator(rips: rips, player: player)
        // Burn ONLY the second track; the first is unplayable.
        await burn(rips, burns, songId: "sng_ok")
        // burn() set the manifest to just sng_ok; sng_dead is neither burned nor cached.
        XCTAssertNil(burns.localURL(forSong: "sng_dead"))
        XCTAssertNil(rips.cachedURL("sng_dead"))

        let seq = SetlistPlayer(player: player, rips: rips, burns: burns, coordinator: coord)
        seq.play([
            .init(id: "sng_dead", title: "Dead", artist: "A"),
            .init(id: "sng_ok", title: "OK", artist: "A"),
        ])

        // The dead track is skipped; the burnt track becomes now-playing at index 1.
        await waitUntil("skipped to the playable burnt track") { rips.nowPlaying?.songId == "sng_ok" }
        XCTAssertEqual(seq.index, 1, "advanced past the unplayable track")
        XCTAssertEqual(rips.nowPlaying?.url, burns.localURL(forSong: "sng_ok"))
        XCTAssertTrue(seq.isRunning)
        seq.stop()
        cleanBurnedFiles(["sng_ok.mp3", "sng_ok.txt"])
    }

    // MARK: lock-screen NEXT / PREVIOUS drive the set (Feature: background audio)

    /// `play()` assigns the engine's `onNext`/`onPrevious` hooks (which the lock-screen /
    /// Control Center commands call) and `stop()` releases them. `skipNext` advances the set;
    /// `skipPrevious` steps back (never below index 0).
    func testNextPreviousHooksDriveTheSet() async {
        cleanBurnedFiles(["sng_1.mp3", "sng_1.txt", "sng_2.mp3", "sng_2.txt"])
        let rips = makeRips(serverURL: "https://imac.test")
        let burns = makeBurns(rips)
        let player = PlayerEngine()
        let coord = makeCoordinator(rips: rips, player: player)
        await burn(rips, burns, songId: "sng_1")
        await burn(rips, burns, songId: "sng_2")

        // Before a set runs, the engine has no next/previous consumer.
        XCTAssertNil(player.onNext)
        XCTAssertNil(player.onPrevious)

        let seq = SetlistPlayer(player: player, rips: rips, burns: burns, coordinator: coord)
        seq.play([
            .init(id: "sng_1", title: "One", artist: "A"),
            .init(id: "sng_2", title: "Two", artist: "A"),
        ])
        await waitUntil("track 0 playing") { rips.nowPlaying?.songId == "sng_1" }
        XCTAssertNotNil(player.onNext, "play() wires the lock-screen NEXT hook")
        XCTAssertNotNil(player.onPrevious, "play() wires the lock-screen PREVIOUS hook")

        // Simulate the lock-screen NEXT command target firing the engine hook.
        player.onNext?()
        await waitUntil("NEXT advanced to track 1") { rips.nowPlaying?.songId == "sng_2" }
        XCTAssertEqual(seq.index, 1)

        // Simulate lock-screen PREVIOUS → step back to track 0.
        player.onPrevious?()
        await waitUntil("PREVIOUS stepped back to track 0") { rips.nowPlaying?.songId == "sng_1" }
        XCTAssertEqual(seq.index, 0)

        // PREVIOUS at the top is clamped (stays at index 0).
        player.onPrevious?()
        XCTAssertEqual(seq.index, 0)

        seq.stop()
        XCTAssertNil(player.onNext, "stop() releases the NEXT hook")
        XCTAssertNil(player.onPrevious, "stop() releases the PREVIOUS hook")
        cleanBurnedFiles(["sng_1.mp3", "sng_1.txt", "sng_2.mp3", "sng_2.txt"])
    }

    // MARK: JUMP to an upcoming row (CarPlay Up-Next "Play now")

    /// `jumpToUpcoming(uid:)` shifts playback straight onto the tapped row: the index moves to
    /// that exact position, the row starts playing through the same play-current path a skip
    /// uses, jumped-over rows land in the played region (`queue[0..<index]`), and the queue's
    /// order is untouched (a jump repositions the needle, it never reorders).
    func testJumpToUpcomingMovesToExactRowAndPlaysIt() async {
        cleanBurnedFiles(["sng_1.mp3", "sng_1.txt", "sng_3.mp3", "sng_3.txt"])
        let rips = makeRips(serverURL: "https://imac.test")
        let burns = makeBurns(rips)
        let player = PlayerEngine()
        let coord = makeCoordinator(rips: rips, player: player)
        await burn(rips, burns, songId: "sng_1")
        await burn(rips, burns, songId: "sng_3")

        let seq = SetlistPlayer(player: player, rips: rips, burns: burns, coordinator: coord)
        seq.play([
            .init(id: "sng_1", title: "One", artist: "A"),
            .init(id: "sng_2", title: "Two", artist: "A"),
            .init(id: "sng_3", title: "Three", artist: "A"),
            .init(id: "sng_4", title: "Four", artist: "A"),
        ])
        await waitUntil("track 0 playing") { rips.nowPlaying?.songId == "sng_1" }

        seq.jumpToUpcoming(uid: seq.queue[2].uid)                 // tap "Three" in Up Next
        XCTAssertEqual(seq.index, 2, "index moves straight onto the tapped row")
        await waitUntil("jumped row becomes now-playing") { rips.nowPlaying?.songId == "sng_3" }
        XCTAssertTrue(seq.isRunning)
        XCTAssertEqual(rips.nowPlaying?.url, burns.localURL(forSong: "sng_3"),
                       "the jump routes through the same burned-file play path a skip uses")
        XCTAssertEqual(seq.queue.map(\.id), ["sng_1", "sng_2", "sng_3", "sng_4"],
                       "a jump repositions the needle — it never reorders the queue")
        XCTAssertEqual(seq.queue[0..<seq.index].map(\.id), ["sng_1", "sng_2"],
                       "jumped-over rows land in the played region")
        XCTAssertEqual(seq.upcoming.map(\.id), ["sng_4"])
        seq.stop()
        cleanBurnedFiles(["sng_1.mp3", "sng_1.txt", "sng_3.mp3", "sng_3.txt"])
    }

    /// The jump targets the EXACT tapped row by uid, never a songId nearest-occurrence: with the
    /// CURRENT track's songId repeated later in the queue, tapping the later duplicate must land
    /// on IT (a songId-based resolution would stay put on the nearer occurrence at index 0) —
    /// and the adopt observer must not yank the index back afterwards.
    func testJumpToUpcomingTargetsExactUidWithDuplicateSongIds() async {
        cleanBurnedFiles(["sng_dup.mp3", "sng_dup.txt", "sng_x.mp3", "sng_x.txt"])
        let rips = makeRips(serverURL: "https://imac.test")
        let burns = makeBurns(rips)
        let player = PlayerEngine()
        let coord = makeCoordinator(rips: rips, player: player)
        await burn(rips, burns, songId: "sng_dup")
        await burn(rips, burns, songId: "sng_x")

        let seq = SetlistPlayer(player: player, rips: rips, burns: burns, coordinator: coord)
        seq.play([
            .init(id: "sng_dup", title: "Dup (first)", artist: "A"),
            .init(id: "sng_x", title: "Filler", artist: "A"),
            .init(id: "sng_dup", title: "Dup (second)", artist: "A"),
        ])
        await waitUntil("track 0 playing") { rips.nowPlaying?.songId == "sng_dup" }

        seq.jumpToUpcoming(uid: seq.queue[2].uid)                 // tap the SECOND "sng_dup"
        XCTAssertEqual(seq.index, 2, "lands on the exact tapped row, not the nearest songId match")
        // Let the async play + the now-playing adopt observer settle — the index must HOLD.
        try? await Task.sleep(nanoseconds: 100_000_000)
        XCTAssertEqual(seq.index, 2, "the adopt observer must not reposition a uid-exact jump")
        XCTAssertTrue(seq.isRunning)
        XCTAssertTrue(seq.upcoming.isEmpty, "everything before the tapped row is now played")
        seq.stop()
        cleanBurnedFiles(["sng_dup.mp3", "sng_dup.txt", "sng_x.mp3", "sng_x.txt"])
    }

    /// A vanished uid (the queue was edited/advanced under the tap) — and the current row's own
    /// uid, which is not "upcoming" — are safe no-ops: no index move, no restart, still running.
    func testJumpToUpcomingUnknownOrCurrentUidIsNoOp() {
        let rips = makeRips(); let burns = makeBurns(rips)
        let player = PlayerEngine()
        let coord = makeCoordinator(rips: rips, player: player)
        let seq = SetlistPlayer(player: player, rips: rips, burns: burns, coordinator: coord)
        seq.play([.init(id: "sng_1", title: "One", artist: "A"),
                  .init(id: "sng_2", title: "Two", artist: "A")])

        seq.jumpToUpcoming(uid: UUID())                           // vanished row
        XCTAssertEqual(seq.index, 0)
        XCTAssertTrue(seq.isRunning)

        seq.jumpToUpcoming(uid: seq.queue[0].uid)                 // the CURRENT row isn't upcoming
        XCTAssertEqual(seq.index, 0)
        XCTAssertEqual(seq.queue.map(\.id), ["sng_1", "sng_2"])
        seq.stop()
    }

    /// A jump arms the LANDED row's repeat count (like any fresh track start): a repeatCount-3
    /// row jumped onto loops in place on its natural ends before advancing.
    func testJumpToUpcomingArmsRepeatCount() async {
        cleanBurnedFiles(["rp_1.mp3", "rp_1.txt", "rp_2.mp3", "rp_2.txt", "rp_3.mp3", "rp_3.txt"])
        let rips = makeRips(serverURL: "https://imac.test")
        let burns = makeBurns(rips)
        let player = PlayerEngine()
        let coord = makeCoordinator(rips: rips, player: player)
        await burn(rips, burns, songId: "rp_1")
        await burn(rips, burns, songId: "rp_2")
        await burn(rips, burns, songId: "rp_3")

        let seq = SetlistPlayer(player: player, rips: rips, burns: burns, coordinator: coord)
        seq.play([
            .init(id: "rp_1", title: "One", artist: "A"),
            .init(id: "rp_2", title: "Two", artist: "A", repeatCount: 3),
            .init(id: "rp_3", title: "Three", artist: "A"),
        ])
        await waitUntil("track 0 playing") { rips.nowPlaying?.songId == "rp_1" }

        seq.jumpToUpcoming(uid: seq.queue[1].uid)
        await waitUntil("jumped onto the repeating row") { rips.nowPlaying?.songId == "rp_2" }
        player.onTrackEnded?(); XCTAssertEqual(seq.index, 1, "1st repeat — stays on the row")
        player.onTrackEnded?(); XCTAssertEqual(seq.index, 1, "2nd repeat — stays on the row")
        player.onTrackEnded?()                                    // 3rd play done → advance
        await waitUntil("advanced after all 3 plays") { seq.index == 2 && rips.nowPlaying?.songId == "rp_3" }
        seq.stop()
        cleanBurnedFiles(["rp_1.mp3", "rp_1.txt", "rp_2.mp3", "rp_2.txt", "rp_3.mp3", "rp_3.txt"])
    }

    // MARK: Item 7 — DEVICE mode skips streamable-only tracks + advances

    /// In DEVICE mode a track with NO burned file is SKIPPED (even though it WOULD stream in
    /// cloud mode), and the next BURNED track plays. The coordinator/stream path is never
    /// engaged for the skipped track.
    func testDeviceModeSkipsUnburnedTrackAndPlaysNextBurned() async {
        cleanBurnedFiles(["sng_ok.mp3", "sng_ok.txt"])
        // A working rip server: in CLOUD mode the first track WOULD stream — device mode must
        // still skip it because it has no burned file.
        let rips = makeRips(serverURL: "https://imac.test")
        let burns = makeBurns(rips)
        let player = PlayerEngine()
        let coord = makeCoordinator(rips: rips, player: player)
        await burn(rips, burns, songId: "sng_ok")            // only the 2nd track is burned
        rips.setManifest([                                    // both cached (streamable)
            "sng_stream": .init(key: "rips/sng_stream.mp3", source: "digital"),
            "sng_ok": .init(key: "rips/sng_ok.mp3", source: "digital"),
        ])
        XCTAssertNil(burns.localURL(forSong: "sng_stream"), "precondition: 1st track not burned")

        let seq = SetlistPlayer(player: player, rips: rips, burns: burns, coordinator: coord)
        seq.playbackMode = { .device }
        seq.play([
            .init(id: "sng_stream", title: "Streamable", artist: "A"),
            .init(id: "sng_ok", title: "Burned", artist: "A"),
        ])

        await waitUntil("skipped the un-burned track to the burned one") { rips.nowPlaying?.songId == "sng_ok" }
        XCTAssertEqual(seq.index, 1, "device mode skipped the streamable-but-unburned track")
        XCTAssertEqual(rips.nowPlaying?.url, burns.localURL(forSong: "sng_ok"), "played from the burned file")
        XCTAssertNil(coord.activeBackend, "device mode never engaged the stream/coordinator")
        XCTAssertFalse(seq.deviceQueueUnplayable, "at least one track was playable → no banner")
        seq.stop()
        cleanBurnedFiles(["sng_ok.mp3", "sng_ok.txt"])
    }

    /// CRITIC-D — a DEVICE-mode set whose WHOLE queue has no burned files plays nothing,
    /// stops, and raises the one-shot `deviceQueueUnplayable` banner signal.
    func testDeviceModeWholeQueueUnplayableRaisesBanner() async {
        let rips = makeRips(serverURL: "https://imac.test")
        let burns = makeBurns(rips)
        let player = PlayerEngine()
        let coord = makeCoordinator(rips: rips, player: player)
        // Both cached (would stream in cloud mode) but NEITHER is burned.
        rips.setManifest([
            "sng_a": .init(key: "rips/sng_a.mp3", source: "digital"),
            "sng_b": .init(key: "rips/sng_b.mp3", source: "digital"),
        ])

        let seq = SetlistPlayer(player: player, rips: rips, burns: burns, coordinator: coord)
        seq.playbackMode = { .device }
        seq.play([
            .init(id: "sng_a", title: "A", artist: "A"),
            .init(id: "sng_b", title: "B", artist: "A"),
        ])

        await waitUntil("device set with no burned files stops") { !seq.isRunning }
        XCTAssertNil(rips.nowPlaying, "nothing ever played on-device")
        XCTAssertNil(coord.activeBackend, "the stream path was never engaged")
        XCTAssertTrue(seq.deviceQueueUnplayable, "the whole-queue-unplayable banner is raised")

        // Acknowledging clears it; a fresh play resets it.
        seq.clearDeviceUnplayable()
        XCTAssertFalse(seq.deviceQueueUnplayable)
    }

    /// **THE BANNER MUST BE ABLE TO REACH A SCREEN**, which for four months it could not.
    ///
    /// Every consumer binds on `deviceQueueUnplayable && sourceSetlistId == <this screen's id>`.
    /// But the flag is raised at the END of `advanceToNext`, and the line immediately before it is
    /// `stop()` — which sets `sourceSetlistId = nil`. So the comparison was nil-vs-id for EVERY
    /// run, on every screen: the alert that exists specifically to stop device mode dead-ending in
    /// silence could never once have fired. (The review that found this thought it was New-only,
    /// because New starts with no id at all. It is universal.)
    ///
    /// So the raising run's identity is captured BEFORE the teardown and published beside the flag.
    /// That is the pair a surface binds on.
    func testTheUnplayableBannerCarriesTheIdOfTheRunThatRaisedIt() async {
        let rips = makeRips(serverURL: "https://imac.test")
        let burns = makeBurns(rips)
        let player = PlayerEngine()
        let coord = makeCoordinator(rips: rips, player: player)
        rips.setManifest(["sng_c": .init(key: "rips/sng_c.mp3", source: "digital")])

        let seq = SetlistPlayer(player: player, rips: rips, burns: burns, coordinator: coord)
        seq.playbackMode = { .device }
        seq.play([.init(id: "sng_c", title: "C", artist: "A")], sourceSetlistId: "set_probe")

        await waitUntil("device set with no burned files stops") { !seq.isRunning }
        XCTAssertTrue(seq.deviceQueueUnplayable, "precondition: the banner signal is up")
        XCTAssertNil(seq.sourceSetlistId,
                     "stop() has already torn the run down — this is WHY the id must be carried separately")
        XCTAssertEqual(seq.deviceUnplayableSourceId, "set_probe",
                       "the screen that started the run has to be able to recognise its own banner")

        seq.clearDeviceUnplayable()
        XCTAssertNil(seq.deviceUnplayableSourceId, "acknowledging clears both halves")
    }

    /// A New-tile run carries no collection, and that is exactly the case the banner has to survive:
    /// these are records the owner does not own, so device mode is the likeliest mode to play
    /// nothing at all.
    func testANewTileRunIsRecognisableByItsOwnBanner() async {
        let rips = makeRips(serverURL: "https://imac.test")
        let burns = makeBurns(rips)
        let player = PlayerEngine()
        let coord = makeCoordinator(rips: rips, player: player)

        let seq = SetlistPlayer(player: player, rips: rips, burns: burns, coordinator: coord)
        seq.playbackMode = { .device }
        seq.play(ReleaseStreaming.items([ReleaseStreamTrack(storeID: "9000000001", title: "New",
                                                            artist: "A", lengthMs: nil)]),
                 sourceSetlistId: ReleaseStreaming.runTag)

        await waitUntil("an unowned release has no burned file, so device mode stops") { !seq.isRunning }
        XCTAssertTrue(seq.deviceQueueUnplayable)
        XCTAssertEqual(seq.deviceUnplayableSourceId, ReleaseStreaming.runTag,
                       "the New screen (and the For You grid) bind on exactly this")
    }

    // MARK: PERSISTENT play state — adopt a manual mid-set jump and keep auto-advancing

    /// While a set runs, manually starting a DIFFERENT in-set track (a row ▶, which just sets
    /// `RipsStore.nowPlaying` via the shared burned path) REPOSITIONS the sequencer onto that
    /// track, so when it ends the set advances to the NEXT track instead of stopping. Proves
    /// the "persistent play state" tweak: starting another song mid-set no longer dead-ends.
    func testAdoptsManualJumpAndKeepsAutoAdvancing() async {
        cleanBurnedFiles(["sng_a.mp3","sng_a.txt","sng_b.mp3","sng_b.txt","sng_c.mp3","sng_c.txt"])
        let rips = makeRips(serverURL: "https://imac.test")
        let burns = makeBurns(rips)
        let player = PlayerEngine()
        let coord = makeCoordinator(rips: rips, player: player)
        await burn(rips, burns, songId: "sng_a")
        await burn(rips, burns, songId: "sng_b")
        await burn(rips, burns, songId: "sng_c")

        let seq = SetlistPlayer(player: player, rips: rips, burns: burns, coordinator: coord)
        seq.play([
            .init(id: "sng_a", title: "A", artist: "A"),
            .init(id: "sng_b", title: "B", artist: "A"),
            .init(id: "sng_c", title: "C", artist: "A"),
        ])
        await waitUntil("track 0 (A) playing") { rips.nowPlaying?.songId == "sng_a" }
        XCTAssertEqual(seq.index, 0)

        // Simulate a manual row ▶ on the MIDDLE track (B): the shared single-row burned path
        // just sets nowPlaying to B's burned file — exactly what RowTransport.doPlay does.
        playLocalFile(burns.localURL(forSong: "sng_b")!, songId: "sng_b", title: "B", artist: "A",
                      startMs: nil, rips: rips, player: player)

        // The sequencer observes the nowPlaying jump and repositions onto B (index 1).
        await waitUntil("sequencer adopted the manual jump to B") { seq.index == 1 }
        XCTAssertTrue(seq.isRunning)

        // B ending now advances to C — the set did NOT stop at the manually-started track.
        player.onTrackEnded?()
        await waitUntil("advanced past the adopted track to C") { rips.nowPlaying?.songId == "sng_c" }
        XCTAssertEqual(seq.index, 2)
        XCTAssertTrue(seq.isRunning)

        seq.stop()
        cleanBurnedFiles(["sng_a.mp3","sng_a.txt","sng_b.mp3","sng_b.txt","sng_c.mp3","sng_c.txt"])
    }

    /// The SAME adoption for an APPLE MUSIC row ▶: a manual play of an in-set track that
    /// streams via MusicKit stamps `coordinator.appleMusic.nowPlaying` (never
    /// `rips.nowPlaying`), and the sequencer must reposition onto it all the same. This was
    /// the trace-confirmed desync: the deck + widget stayed on the previous song, the deck's
    /// toggle hit the idle engine ("engine.toggle REFUSED"), and the set would have silently
    /// stopped at the track's end (the AM end guard compares against `queue[index]`).
    func testAdoptsAppleMusicRowPlayAndKeepsAutoAdvancing() async {
        cleanBurnedFiles(["sng_a.mp3","sng_a.txt","sng_c.mp3","sng_c.txt"])
        let rips = makeRips(serverURL: "https://imac.test")
        let burns = makeBurns(rips)
        let player = PlayerEngine()
        let coord = makeCoordinator(rips: rips, player: player)
        await burn(rips, burns, songId: "sng_a")
        await burn(rips, burns, songId: "sng_c")

        let seq = SetlistPlayer(player: player, rips: rips, burns: burns, coordinator: coord)
        seq.play([
            .init(id: "sng_a", title: "A", artist: "A"),
            .init(id: "sng_b", title: "B", artist: "A"),
            .init(id: "sng_c", title: "C", artist: "A"),
        ])
        await waitUntil("track 0 (A) playing") { rips.nowPlaying?.songId == "sng_a" }
        XCTAssertEqual(seq.index, 0)

        // Simulate a manual row ▶ on B that WINS via Apple Music — the provider stamps its
        // now-playing, then the coordinator records the backend, the same order
        // `PlaybackCoordinator.play` produces (nowPlaying inside tryPlay, backend after).
        coord.appleMusic.setNowPlayingForTests(.init(songId: "sng_b", title: "B", artist: "A"))
        coord.setActiveBackendForTests(.appleMusic)

        // The sequencer observes the coordinator jump and repositions onto B (index 1).
        await waitUntil("sequencer adopted the Apple Music jump to B") { seq.index == 1 }
        XCTAssertTrue(seq.isRunning)

        // B's stream ending advances to C (burned → local) — the set did NOT stop.
        coord.appleMusic.onTrackEnded?(.natural)
        await waitUntil("advanced past the adopted AM track to C") { rips.nowPlaying?.songId == "sng_c" }
        XCTAssertEqual(seq.index, 2)
        XCTAssertTrue(seq.isRunning)
        XCTAssertNil(coord.activeBackend, "advancing to a burned local track silenced the AM backend")

        seq.stop()
        cleanBurnedFiles(["sng_a.mp3","sng_a.txt","sng_c.mp3","sng_c.txt"])
    }

    // MARK: Repeat-one vs. the system remote ⏭ during an Apple Music stream

    /// REGRESSION (CarPlay repeat-one deadlock): iOS delivers the lock-screen/CarPlay ⏭ to
    /// MusicKit itself; the end monitor detects the skip-park and reports the end with reason
    /// `.systemSkip`. With repeat-one ON, that reason must advance the set exactly like the
    /// in-app ⏭ — the pre-fix code treated every AM end as natural, so repeat-one replayed
    /// the same song on every car ⏭ and the set could never advance from the wheel. A
    /// `.natural` end under repeat-one still replays. Queue edits (remove/reorder of the
    /// upcoming rows) beforehand must not change either behavior.
    func testRepeatOneAdvancesOnSystemSkipButReplaysOnNaturalEnd() async {
        cleanBurnedFiles(["sng_b.mp3","sng_b.txt","sng_c.mp3","sng_c.txt"])
        let rips = makeRips(serverURL: "https://imac.test")
        let burns = makeBurns(rips)
        let player = PlayerEngine()
        let coord = makeCoordinator(rips: rips, player: player)
        await burn(rips, burns, songId: "sng_b")
        await burn(rips, burns, songId: "sng_c")

        let seq = SetlistPlayer(player: player, rips: rips, burns: burns, coordinator: coord)
        seq.play([
            .init(id: "sng_a", title: "A", artist: "A"),   // the AM-streamed row (not burned)
            .init(id: "sng_b", title: "B", artist: "A"),
            .init(id: "sng_c", title: "C", artist: "A"),
            .init(id: "sng_d", title: "D", artist: "A"),
        ])
        seq.setRepeatMode(.one)
        // Put the deck in the "streaming A via Apple Music" state (the unit-test seam — the
        // real provider chain can't run MusicKit headless).
        coord.appleMusic.setNowPlayingForTests(.init(songId: "sng_a", title: "A", artist: "A"))
        coord.setActiveBackendForTests(.appleMusic)
        await waitUntil("deck settled on A") { seq.index == 0 }

        // The user re-arranges what plays next from the phone — remove one upcoming row,
        // reorder the rest — the reported repro's preconditions.
        let upcoming = seq.upcoming
        if let d = upcoming.first(where: { $0.title == "D" }) { seq.removeUpcoming(uids: [d.uid]) }
        seq.moveUpcoming(fromOffsets: IndexSet(integer: 1), toOffset: 0)

        // CarPlay ⏭ (system skip): repeat-one must NOT swallow it — the set advances.
        coord.appleMusic.onTrackEnded?(.systemSkip)
        await waitUntil("system skip advanced the set") { seq.index == 1 }
        XCTAssertTrue(seq.isRunning)

        seq.stop()
        cleanBurnedFiles(["sng_b.mp3","sng_b.txt","sng_c.mp3","sng_c.txt"])
    }

    /// The natural-end half: repeat-one replays the SAME AM row (index stays put), proving
    /// the discriminator didn't break repeat-one itself. The row is BURNED so the
    /// fire-and-forget replay actually resolves in this harness (an unresolvable replay
    /// would advance as a dead source and fail the assertion for the wrong reason).
    func testRepeatOneStillReplaysOnNaturalAppleMusicEnd() async {
        cleanBurnedFiles(["sng_a.mp3","sng_a.txt"])
        let rips = makeRips(serverURL: "https://imac.test")
        let burns = makeBurns(rips)
        let player = PlayerEngine()
        let coord = makeCoordinator(rips: rips, player: player)
        await burn(rips, burns, songId: "sng_a")

        let seq = SetlistPlayer(player: player, rips: rips, burns: burns, coordinator: coord)
        seq.play([
            .init(id: "sng_a", title: "A", artist: "A"),
            .init(id: "sng_b", title: "B", artist: "A"),
        ])
        seq.setRepeatMode(.one)
        coord.appleMusic.setNowPlayingForTests(.init(songId: "sng_a", title: "A", artist: "A"))
        coord.setActiveBackendForTests(.appleMusic)
        await waitUntil("deck settled on A") { seq.index == 0 }

        coord.appleMusic.onTrackEnded?(.natural)
        // Give the fire-and-forget replay a beat, then assert the deck did NOT advance.
        try? await Task.sleep(nanoseconds: 100_000_000)
        XCTAssertEqual(seq.index, 0, "natural end under repeat-one replays the same row")
        XCTAssertTrue(seq.isRunning)
        seq.stop()
        cleanBurnedFiles(["sng_a.mp3","sng_a.txt"])
    }

    /// A manual play of a song that is NOT in the running set must NOT reposition the
    /// sequencer (its index/queue stay put) — only in-set jumps are adopted.
    func testManualPlayOfOutOfSetSongDoesNotReposition() async {
        cleanBurnedFiles(["sng_a.mp3","sng_a.txt","sng_b.mp3","sng_b.txt","sng_x.mp3","sng_x.txt"])
        let rips = makeRips(serverURL: "https://imac.test")
        let burns = makeBurns(rips)
        let player = PlayerEngine()
        let coord = makeCoordinator(rips: rips, player: player)
        await burn(rips, burns, songId: "sng_a")
        await burn(rips, burns, songId: "sng_b")
        await burn(rips, burns, songId: "sng_x")   // NOT in the set

        let seq = SetlistPlayer(player: player, rips: rips, burns: burns, coordinator: coord)
        seq.play([
            .init(id: "sng_a", title: "A", artist: "A"),
            .init(id: "sng_b", title: "B", artist: "A"),
        ])
        await waitUntil("track 0 (A) playing") { rips.nowPlaying?.songId == "sng_a" }

        // Manually play an OUT-OF-SET song.
        playLocalFile(burns.localURL(forSong: "sng_x")!, songId: "sng_x", title: "X", artist: "A",
                      startMs: nil, rips: rips, player: player)
        // Give the observation a turn to (not) fire.
        try? await Task.sleep(nanoseconds: 60_000_000)
        XCTAssertEqual(seq.index, 0, "an out-of-set manual play does not move the sequencer")
        XCTAssertEqual(seq.queue.count, 2)
        XCTAssertTrue(seq.isRunning)

        seq.stop()
        cleanBurnedFiles(["sng_a.mp3","sng_a.txt","sng_b.mp3","sng_b.txt","sng_x.mp3","sng_x.txt"])
    }

    // MARK: Requirement 1 over the CLOUD STREAM path — shared-album rip advances at track length

    /// A cloud rip of an ANALOG album is ONE shared mp3 + per-song startMs, so its natural end
    /// only fires at the WHOLE-file end. A streamed (not-yet-burned) Play-All must still advance
    /// at each track's OWN length: we arm the boundary off `nowPlaying.startMs` and prove a
    /// boundary tick at startMs+lengthMs advances the streamed set.
    func testCloudStreamAnalogArmsLengthBoundaryAndAdvances() async {
        let rips = makeRips(serverURL: "https://imac.test")
        let burns = makeBurns(rips)
        let player = PlayerEngine()
        let coord = makeCoordinator(rips: rips, player: player)
        // Two analog songs SHARING one album mp3 (cached, NOT burned), each with its own startMs.
        rips.setManifest([
            "an_1": .init(key: "rips/sideA.mp3", source: "analog", startMs: 0),
            "an_2": .init(key: "rips/sideA.mp3", source: "analog", startMs: 180_000),
        ])
        XCTAssertNil(burns.localURL(forSong: "an_1"), "precondition: not burned → streams")

        let seq = SetlistPlayer(player: player, rips: rips, burns: burns, coordinator: coord)
        seq.play([
            .init(id: "an_1", title: "A1", artist: "A", lengthMs: 180_000),  // 0:00–3:00 of the file
            .init(id: "an_2", title: "A2", artist: "A", lengthMs: 120_000),
        ])
        await waitUntil("streamed track 0 playing") { rips.nowPlaying?.songId == "an_1" }
        XCTAssertEqual(coord.activeBackend, .ripServer, "streamed via the rip server (shared file)")
        XCTAssertEqual(seq.index, 0)

        // The whole-file natural end is at the END of sideA.mp3 — far past track 0's 3:00. The
        // armed length boundary (startMs 0 + 180s) must advance at 3:00 instead.
        player.checkEndBoundary(atSeconds: 180.0)
        await waitUntil("advanced at the track's own length, not the album end") { rips.nowPlaying?.songId == "an_2" }
        XCTAssertEqual(seq.index, 1)
        XCTAssertTrue(seq.isRunning)

        seq.stop()
    }

    // MARK: Duplicate-song disambiguation — adopt the NEAREST-FORWARD occurrence

    /// A setlist that repeats a song: a manual jump to a later occurrence repositions to the
    /// nearest-FORWARD occurrence (not always the first), so the set advances correctly from it.
    func testDuplicateSongJumpPrefersNearestForwardOccurrence() async {
        cleanBurnedFiles(["d_a.mp3","d_a.txt","d_b.mp3","d_b.txt"])
        let rips = makeRips(serverURL: "https://imac.test")
        let burns = makeBurns(rips)
        let player = PlayerEngine()
        let coord = makeCoordinator(rips: rips, player: player)
        await burn(rips, burns, songId: "d_a")
        await burn(rips, burns, songId: "d_b")

        // Queue [A, B, A] — A repeats. Start at index 0 (first A).
        let seq = SetlistPlayer(player: player, rips: rips, burns: burns, coordinator: coord)
        seq.play([
            .init(id: "d_a", title: "A", artist: "A"),
            .init(id: "d_b", title: "B", artist: "A"),
            .init(id: "d_a", title: "A", artist: "A"),
        ])
        await waitUntil("first A playing") { rips.nowPlaying?.songId == "d_a" && seq.index == 0 }

        // Manually play B (index 1) → adopt to 1.
        playLocalFile(burns.localURL(forSong: "d_b")!, songId: "d_b", title: "B", artist: "A",
                      startMs: nil, rips: rips, player: player)
        await waitUntil("adopted B at index 1") { seq.index == 1 }

        // Now manually play A again — from index 1 the nearest A is index 2 (forward on the tie),
        // NOT index 0. The set repositions FORWARD to the last A, not back to the first.
        playLocalFile(burns.localURL(forSong: "d_a")!, songId: "d_a", title: "A", artist: "A",
                      startMs: nil, rips: rips, player: player)
        await waitUntil("adopted the FORWARD A occurrence (index 2)") { seq.index == 2 }
        XCTAssertEqual(seq.index, 2, "nearest-forward occurrence chosen over the earlier duplicate")

        // Ending the last A stops the set cleanly (it was the final track).
        player.onTrackEnded?()
        await waitUntil("set ends after the final track") { !seq.isRunning }
        cleanBurnedFiles(["d_a.mp3","d_a.txt","d_b.mp3","d_b.txt"])
    }

    // MARK: stop() tears down and resets

    func testStopResetsSequenceAndNowPlaying() async {
        cleanBurnedFiles(["sng_z.mp3", "sng_z.txt"])
        let rips = makeRips(serverURL: "https://imac.test")
        let burns = makeBurns(rips)
        let player = PlayerEngine()
        let coord = makeCoordinator(rips: rips, player: player)
        await burn(rips, burns, songId: "sng_z")

        let seq = SetlistPlayer(player: player, rips: rips, burns: burns, coordinator: coord)
        seq.play([.init(id: "sng_z", title: "Z", artist: "A")])
        await waitUntil("playing") { rips.nowPlaying?.songId == "sng_z" }

        seq.stop()
        XCTAssertFalse(seq.isRunning)
        XCTAssertTrue(seq.queue.isEmpty)
        XCTAssertEqual(seq.index, 0)
        XCTAssertNil(rips.nowPlaying, "now-playing cleared on stop")
        cleanBurnedFiles(["sng_z.mp3", "sng_z.txt"])
    }

    // MARK: Repeat mode (whole-session) — wrap-ALL + repeat-ONE

    /// Repeat-ALL wraps at the end of the queue instead of stopping: the last track's natural end
    /// loops back to the top (index 0) and keeps running. Flipping back to OFF restores the
    /// stop-at-end behaviour.
    func testRepeatAllWrapsAtEndOfQueue() async {
        cleanBurnedFiles(["ra_1.mp3","ra_1.txt","ra_2.mp3","ra_2.txt"])
        let rips = makeRips(serverURL: "https://imac.test")
        let burns = makeBurns(rips)
        let player = PlayerEngine()
        let coord = makeCoordinator(rips: rips, player: player)
        await burn(rips, burns, songId: "ra_1")
        await burn(rips, burns, songId: "ra_2")

        let seq = SetlistPlayer(player: player, rips: rips, burns: burns, coordinator: coord)
        seq.play([.init(id: "ra_1", title: "One", artist: "A"),
                  .init(id: "ra_2", title: "Two", artist: "A")])
        await waitUntil("track 0 playing") { rips.nowPlaying?.songId == "ra_1" }
        seq.setRepeatMode(.all)
        XCTAssertEqual(seq.repeatMode, .all)

        player.onTrackEnded?()   // end track 0 → advance to 1
        await waitUntil("advanced to track 1") { rips.nowPlaying?.songId == "ra_2" && seq.index == 1 }

        player.onTrackEnded?()   // end LAST track → repeat-all WRAPS to 0 (does NOT stop)
        await waitUntil("wrapped to the top") { rips.nowPlaying?.songId == "ra_1" && seq.index == 0 }
        XCTAssertTrue(seq.isRunning, "repeat-all keeps the set running past the end")

        // OFF again → the next end walks to the last track, then stops at the boundary.
        seq.setRepeatMode(.off)
        player.onTrackEnded?()
        await waitUntil("advanced to last track") { rips.nowPlaying?.songId == "ra_2" && seq.index == 1 }
        player.onTrackEnded?()
        await waitUntil("stops at end with repeat off") { !seq.isRunning }
        cleanBurnedFiles(["ra_1.mp3","ra_1.txt","ra_2.mp3","ra_2.txt"])
    }

    /// Repeat-ONE replays the CURRENT track on its natural end (index holds, set keeps running);
    /// an explicit ⏭ still advances — only a NATURAL end repeats.
    func testRepeatOneReplaysCurrentAndSkipStillAdvances() async {
        cleanBurnedFiles(["ro_1.mp3","ro_1.txt","ro_2.mp3","ro_2.txt"])
        let rips = makeRips(serverURL: "https://imac.test")
        let burns = makeBurns(rips)
        let player = PlayerEngine()
        let coord = makeCoordinator(rips: rips, player: player)
        await burn(rips, burns, songId: "ro_1")
        await burn(rips, burns, songId: "ro_2")

        let seq = SetlistPlayer(player: player, rips: rips, burns: burns, coordinator: coord)
        seq.play([.init(id: "ro_1", title: "One", artist: "A"),
                  .init(id: "ro_2", title: "Two", artist: "A")])
        await waitUntil("track 0 playing") { rips.nowPlaying?.songId == "ro_1" }
        seq.setRepeatMode(.one)

        player.onTrackEnded?()   // natural end → replay the SAME track (no advance)
        try? await Task.sleep(nanoseconds: 80_000_000)
        XCTAssertEqual(seq.index, 0, "repeat-one replays the current track (no advance)")
        XCTAssertTrue(seq.isRunning)
        await waitUntil("track 0 replaying") { rips.nowPlaying?.songId == "ro_1" }

        seq.skipNext()           // explicit skip overrides repeat-one
        XCTAssertEqual(seq.index, 1, "explicit skip advances even under repeat-one")
        seq.stop()
        cleanBurnedFiles(["ro_1.mp3","ro_1.txt","ro_2.mp3","ro_2.txt"])
    }

    /// Repeat mode round-trips through the durable session snapshot (restore reads it back), and
    /// the shuffle toggle rides it too. Optional/defaulted so pre-existing snapshots still decode.
    func testRestoreReadsRepeatAndShuffleState() {
        let rips = makeRips(); let burns = makeBurns(rips)
        let player = PlayerEngine()
        let coord = makeCoordinator(rips: rips, player: player)
        let seq = SetlistPlayer(player: player, rips: rips, burns: burns, coordinator: coord)
        let snap = PlaybackSessionStore.Snapshot(
            sessionId: "pses_x",
            source: .init(kind: PlayHistoryStore.PlaySource.setlist.rawValue, id: "set_1", name: "S"),
            queue: [.init(songId: "sng_1", title: "One", artist: "A"),
                    .init(songId: "sng_2", title: "Two", artist: "A")],
            index: 0, positionMs: 0, isPlaying: false,
            repeatMode: "all", shuffleEnabled: true, updatedAt: 0)
        seq.restore(from: snap)
        XCTAssertEqual(seq.repeatMode, .all, "restore reads the persisted repeat mode")
        XCTAssertTrue(seq.shuffleEnabled, "restore reads the persisted shuffle state")
        XCTAssertTrue(seq.isRunning)
        XCTAssertTrue(seq.isHeldForResume, "a restored deck is held, not auto-playing")
        XCTAssertEqual(seq.sourceSetlistId, "set_1", "an ordinary source id restores as-is")
        seq.stop()
    }

    /// A snapshot written mid-Collectors-Puzzle carries the round's `puzzle_<id>` run tag —
    /// but the round engine does not survive a relaunch, so restoring the tag would leave a
    /// GHOST round owning the sequencer forever (the MwF queue-accepted append, among other
    /// surfaces, silently refuses while that prefix stands). The queue restores; the tag dies.
    func testRestoreDropsAPuzzleRunTag() {
        let rips = makeRips(); let burns = makeBurns(rips)
        let player = PlayerEngine()
        let coord = makeCoordinator(rips: rips, player: player)
        let seq = SetlistPlayer(player: player, rips: rips, burns: burns, coordinator: coord)
        let snap = PlaybackSessionStore.Snapshot(
            sessionId: "pses_puz",
            source: .init(kind: PlayHistoryStore.PlaySource.setlist.rawValue,
                          id: "\(CollectorsPuzzleEngine.runTagPrefix)\(UUID().uuidString)", name: "Round"),
            queue: [.init(songId: "sng_1", title: "One", artist: "A"),
                    .init(songId: "sng_2", title: "Two", artist: "A")],
            index: 0, positionMs: 0, isPlaying: false, updatedAt: 0)
        seq.restore(from: snap)
        XCTAssertTrue(seq.isRunning)
        XCTAssertEqual(seq.queue.count, 2, "the queue itself restores fine")
        XCTAssertNil(seq.sourceSetlistId, "the dead round's tag must not outlive the relaunch")
        seq.stop()
    }

    // MARK: Shuffle — live upcoming-tail reorder + restore

    /// Toggling shuffle permutes ONLY the upcoming tail; toggling it back off restores the tail's
    /// original order. The current track (queue[index]) is never touched.
    func testShuffleReordersUpcomingTailThenRestores() async {
        cleanBurnedFiles(["sh_0.mp3","sh_0.txt"])
        let rips = makeRips(serverURL: "https://imac.test")
        let burns = makeBurns(rips)
        let player = PlayerEngine()
        let coord = makeCoordinator(rips: rips, player: player)
        await burn(rips, burns, songId: "sh_0")   // only the current track needs to be playable

        let seq = SetlistPlayer(player: player, rips: rips, burns: burns, coordinator: coord)
        let ids = ["sh_0","sh_1","sh_2","sh_3","sh_4","sh_5","sh_6","sh_7"]
        seq.play(ids.map { .init(id: $0, title: $0, artist: "A") })
        await waitUntil("current track playing") { rips.nowPlaying?.songId == "sh_0" && seq.index == 0 }

        let originalUpcoming = seq.upcoming.map(\.id)
        XCTAssertEqual(originalUpcoming, Array(ids[1...]))

        seq.toggleShuffle()
        XCTAssertTrue(seq.shuffleEnabled)
        XCTAssertEqual(seq.queue[0].id, "sh_0", "the current track is never shuffled")
        XCTAssertEqual(Set(seq.upcoming.map(\.id)), Set(ids[1...]), "shuffle preserves tail membership")

        seq.toggleShuffle()
        XCTAssertFalse(seq.shuffleEnabled)
        XCTAssertEqual(seq.upcoming.map(\.id), originalUpcoming, "shuffle-off restores the original tail order")
        seq.stop()
        cleanBurnedFiles(["sh_0.mp3","sh_0.txt"])
    }
}

/// The position-based END BOUNDARY (tweak 1): a track inside a shared album-rip mp3 must
/// advance at its OWN length, not the whole file's end. The fire lives in the AVPlayer
/// periodic observer (not exercisable headlessly), so it is extracted into the callable
/// `checkEndBoundary(atSeconds:)` — these tests drive it directly to prove arming, the
/// one-shot latch shared with the natural end, the live-stream skip, and the resets.
@MainActor
final class PlayerEngineBoundaryTests: XCTestCase {
    private let url = FileManager.default.temporaryDirectory.appendingPathComponent("pdj-boundary.mp3")

    /// Counts `onTrackEnded` fires for a freshly-loaded engine with a boundary armed via `load`.
    private func makeEngine(boundaryMs: Int?, live: Bool = false) -> (PlayerEngine, () -> Int) {
        let engine = PlayerEngine()
        var fires = 0
        engine.onTrackEnded = { fires += 1 }
        engine.load(url: url, live: live, startMs: nil, endBoundaryMs: boundaryMs)
        return (engine, { fires })
    }

    /// Below the boundary → no fire; at/after it → fires EXACTLY once; further ticks are latched.
    func testBoundaryFiresOnceWhenPositionPassesIt() {
        let (engine, fires) = makeEngine(boundaryMs: 5_000)   // 5.0 s
        engine.checkEndBoundary(atSeconds: 4.9)
        XCTAssertEqual(fires(), 0, "before the boundary: no advance")
        engine.checkEndBoundary(atSeconds: 5.0)
        XCTAssertEqual(fires(), 1, "at the boundary: advance once")
        engine.checkEndBoundary(atSeconds: 7.0)
        XCTAssertEqual(fires(), 1, "after the boundary: latched, no second advance")
    }

    /// A live stream is NEVER armed — even when `load`/`setEndBoundary` is handed a boundary.
    func testBoundaryNeverFiresForLiveStream() {
        let (engine, fires) = makeEngine(boundaryMs: 1_000, live: true)
        engine.checkEndBoundary(atSeconds: 9_999)
        XCTAssertEqual(fires(), 0, "live load ignored the boundary")
        engine.setEndBoundary(ms: 1_000)   // arming while live is also a no-op
        engine.checkEndBoundary(atSeconds: 9_999)
        XCTAssertEqual(fires(), 0, "setEndBoundary is a no-op for a live stream")
    }

    /// `setEndBoundary` arms WITHOUT a reload (the adoption path); nil disarms it.
    func testSetEndBoundaryArmsAndDisarmsWithoutReload() {
        let engine = PlayerEngine()
        var fires = 0
        engine.onTrackEnded = { fires += 1 }
        engine.load(url: url, live: false, startMs: nil)   // no boundary at load

        engine.checkEndBoundary(atSeconds: 100)
        XCTAssertEqual(fires, 0, "no boundary armed → never fires")

        engine.setEndBoundary(ms: 3_000)
        engine.checkEndBoundary(atSeconds: 3.0)
        XCTAssertEqual(fires, 1, "armed via setEndBoundary → fires")

        // Disarm, then a fresh load resets the latch so a NEW boundary can fire again.
        engine.setEndBoundary(ms: nil)
        engine.load(url: url, live: false, startMs: nil, endBoundaryMs: 2_000)
        engine.checkEndBoundary(atSeconds: 2.0)
        XCTAssertEqual(fires, 2, "load reset the one-shot latch → the new boundary fires")
    }

    /// `stop()` disarms the boundary so a stale tick can't advance a torn-down set.
    func testStopResetsBoundary() {
        let (engine, fires) = makeEngine(boundaryMs: 1_000)
        engine.stop()
        engine.checkEndBoundary(atSeconds: 9_999)
        XCTAssertEqual(fires(), 0, "stop() disarmed the boundary")
    }
}

/// EXTERNAL now-playing (Apple Music streaming). During a streamed setlist track MusicKit's
/// `ApplicationMusicPlayer` produces the audio but writes nothing to the lock-screen / CarPlay
/// card and swallows the system next button. `PlayerEngine.beginExternalNowPlaying` makes the
/// engine OWN the card + remote transport on MusicKit's behalf: it publishes state, routes
/// play/pause to the stream's closures, and its ⏭/⏮ still drive the set. These tests drive that
/// surface directly (the real MusicKit path needs authorization + a live catalog, so it can't
/// run headlessly).
@MainActor
final class PlayerEngineExternalNowPlayingTests: XCTestCase {
    private let localURL = FileManager.default.temporaryDirectory.appendingPathComponent("pdj-ext.mp3")

    /// Handles to observe how the remote transport routes while external.
    private struct ExternalProbe {
        var plays = 0
        var pauses = 0
        var streamPlaying = true
        var position = 12.0
    }

    private func beginExternal(_ engine: PlayerEngine, probe: @escaping () -> ExternalProbe,
                               mutate: @escaping ((inout ExternalProbe) -> Void) -> Void,
                               durationSeconds: Double = 200) {
        engine.beginExternalNowPlaying(
            title: "Streamed", artist: "AM", songId: "am:123", durationSeconds: durationSeconds,
            position: { probe().position },
            isPlaying: { probe().streamPlaying },
            play: { mutate { $0.plays += 1; $0.streamPlaying = true } },
            pause: { mutate { $0.pauses += 1; $0.streamPlaying = false } })
    }

    /// beginExternalNowPlaying publishes playing state + the stream's duration, and marks the
    /// engine playing (so the card shows ▶ and the scrubber has a range).
    func testBeginExternalPublishesPlayingStateAndDuration() {
        let engine = PlayerEngine()
        var box = ExternalProbe()
        beginExternal(engine, probe: { box }, mutate: { $0(&box) }, durationSeconds: 200)
        XCTAssertTrue(engine.isPlaying, "external track shows as playing")
        XCTAssertEqual(engine.duration, 200, accuracy: 0.001, "the stream's duration drives the card range")
    }

    /// While external, the remote play/pause commands drive the STREAM's closures (not the idle
    /// AVPlayer), and `toggle()` respects the stream's real play state.
    func testExternalTransportRoutesToStreamClosures() {
        let engine = PlayerEngine()
        var box = ExternalProbe()
        beginExternal(engine, probe: { box }, mutate: { $0(&box) })

        engine.pause()
        XCTAssertEqual(box.pauses, 1, "remote pause paused the STREAM")
        XCTAssertFalse(engine.isPlaying)

        engine.play()
        XCTAssertEqual(box.plays, 1, "remote play resumed the STREAM")
        XCTAssertTrue(engine.isPlaying)

        // toggle() reads the stream's real state: now playing → toggle pauses it.
        engine.toggle()
        XCTAssertEqual(box.pauses, 2, "toggle paused the playing stream")
    }

    /// Loading a REAL local item ends external impersonation: transport goes back to the AVPlayer,
    /// so the stream's pause closure is no longer called.
    func testLoadingLocalItemEndsExternalMode() {
        let engine = PlayerEngine()
        var box = ExternalProbe()
        beginExternal(engine, probe: { box }, mutate: { $0(&box) })

        engine.load(url: localURL, live: false, startMs: nil)   // a real (local) track supersedes
        engine.pause()
        XCTAssertEqual(box.pauses, 0, "after loading a local track, pause no longer routes to the stream")
    }

    /// stop() ends external impersonation too (nothing routes to the stream afterward).
    func testStopEndsExternalMode() {
        let engine = PlayerEngine()
        var box = ExternalProbe()
        beginExternal(engine, probe: { box }, mutate: { $0(&box) })

        engine.stop()
        engine.pause()
        XCTAssertEqual(box.pauses, 0, "after stop, pause no longer routes to the stream")
    }

    /// An IDLE engine (no item loaded, not external) must REFUSE transport: a blind play()
    /// used to re-claim the Now Playing card with the previous track's stale title (the macOS
    /// "ghost second card" bug) and flip `isPlaying` with no audio behind it (the widget
    /// play-state mismatch). The tap probe still counts (`toggleCount`).
    func testIdleEngineTransportIsNoOp() {
        let engine = PlayerEngine()
        engine.play()
        XCTAssertFalse(engine.isPlaying, "idle play() is refused")
        engine.toggle()
        XCTAssertFalse(engine.isPlaying, "idle toggle() is refused")
        XCTAssertEqual(engine.toggleCount, 1, "the tap is still counted (test probe)")
        engine.pause()
        XCTAssertFalse(engine.isPlaying)
    }

    /// idleForExternalPlayback (the macOS Apple Music branch) leaves the engine inert: not
    /// playing, and transport still refused afterward (no item was re-loaded).
    func testIdleForExternalPlaybackLeavesEngineInert() {
        let engine = PlayerEngine()
        engine.load(url: localURL, live: false, startMs: nil, title: "Prev", artist: "A")
        engine.idleForExternalPlayback()
        XCTAssertFalse(engine.isPlaying)
        engine.play()
        XCTAssertFalse(engine.isPlaying, "post-idle play() is refused (no item)")
    }
}

/// Minimal `URLProtocol` serving HTTP 200 + a fixed body (the durable mp3 bytes for the
/// burn download, and any rip-server fetch in these tests resolves to a cached S3 mp3 that
/// is never actually loaded by AVPlayer in a headless unit run).
private final class SetlistStubURLProtocol: URLProtocol {
    static var body = Data("MP3-DATA".utf8)

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func stopLoading() {}

    override func startLoading() {
        let response = HTTPURLResponse(url: request.url!, statusCode: 200,
                                       httpVersion: "HTTP/1.1", headerFields: nil)!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Self.body)
        client?.urlProtocolDidFinishLoading(self)
    }
}

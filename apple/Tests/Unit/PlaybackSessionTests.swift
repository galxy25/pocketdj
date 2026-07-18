import XCTest
@testable import PocketDJ

/// Durable Playback Sessions — the store. A single overwrite-in-place snapshot
/// (`pocketdj-playback-session.json`) written in real time as playback happens: structural
/// saves immediate, position refreshes throttled while playing and immediate on a
/// pause/resume transition, lenient load (any decode failure → nil), clear-on-stop.
@MainActor
final class PlaybackSessionStoreTests: XCTestCase {

    private func makeStore() -> (PlaybackSessionStore, URL) {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("pdj-psession-\(UUID().uuidString).json")
        addTeardownBlock { try? FileManager.default.removeItem(at: url) }
        return (PlaybackSessionStore(fileURL: url), url)
    }

    private func snapshot(index: Int = 1, positionMs: Int = 42_000,
                          isPlaying: Bool = true) -> PlaybackSessionStore.Snapshot {
        PlaybackSessionStore.Snapshot(
            sessionId: "pses_test",
            source: .init(kind: "playlist", id: "pls_1", name: "Roadtrip"),
            queue: [
                .init(songId: "sng_a", title: "Alpha", artist: "Aria", lengthMs: 200_000, repeatCount: nil),
                .init(songId: "sng_b", title: "Beta", artist: "Bea", lengthMs: nil, repeatCount: 3),
                // DUPLICATE songId — a set can repeat a song; both rows must survive.
                .init(songId: "sng_a", title: "Alpha", artist: "Aria", lengthMs: 200_000, repeatCount: nil),
            ],
            index: index, positionMs: positionMs, isPlaying: isPlaying,
            updatedAt: 0)
    }

    /// Poll until `predicate` holds (the store's writes land via an off-main actor Task).
    private func waitUntil(_ message: String, _ predicate: () -> Bool) async {
        for _ in 0..<400 {
            if predicate() { return }
            try? await Task.sleep(nanoseconds: 5_000_000)
        }
        XCTFail("timed out waiting: \(message)")
    }

    // MARK: Round trip

    func testSaveThenLoadRoundTripsEverything() async {
        let (store, _) = makeStore()
        store.save(snapshot(), now: 1_000)
        await waitUntil("snapshot lands on disk") { store.load() != nil }
        let loaded = store.load()!
        XCTAssertEqual(loaded.sessionId, "pses_test")
        XCTAssertEqual(loaded.source.kind, "playlist")
        XCTAssertEqual(loaded.source.id, "pls_1")
        XCTAssertEqual(loaded.source.name, "Roadtrip")
        XCTAssertEqual(loaded.queue.map(\.songId), ["sng_a", "sng_b", "sng_a"],
                       "duplicate songIds + order preserved exactly")
        XCTAssertEqual(loaded.queue.map(\.title), ["Alpha", "Beta", "Alpha"])
        XCTAssertEqual(loaded.queue.map(\.repeatCount), [nil, 3, nil])
        XCTAssertEqual(loaded.queue.map(\.lengthMs), [200_000, nil, 200_000])
        XCTAssertEqual(loaded.index, 1)
        XCTAssertEqual(loaded.positionMs, 42_000)
        XCTAssertTrue(loaded.isPlaying)
    }

    // MARK: Lenient load

    func testLoadIsLenientOnMissingGarbageSchemaAndEmptyQueue() async {
        let (store, url) = makeStore()
        XCTAssertNil(store.load(), "missing file → nil")

        try? Data("NOT JSON {{{".utf8).write(to: url)
        XCTAssertNil(store.load(), "garbage bytes → nil, never throws")

        // A DIFFERENT (future/old) schema version must not restore.
        var wrongVersion = snapshot()
        wrongVersion.schemaVersion = playbackSessionSchemaVersion + 1
        try? JSONEncoder().encode(wrongVersion).write(to: url)
        XCTAssertNil(store.load(), "schema mismatch → nil (no migration)")

        var empty = snapshot()
        empty.queue = []
        try? JSONEncoder().encode(empty).write(to: url)
        XCTAssertNil(store.load(), "empty queue → nothing to restore")
    }

    // MARK: Position throttle

    func testPositionWritesThrottledWhilePlayingAndImmediateOnTransition() async {
        let (store, _) = makeStore()
        store.save(snapshot(positionMs: 0, isPlaying: true), now: 1_000)
        await waitUntil("initial save lands") { store.load()?.positionMs == 0 }

        // 1 s later, still playing → INSIDE the 5 s throttle window: no disk write.
        store.updatePosition(ms: 1_000, isPlaying: true, now: 1_001)
        try? await Task.sleep(nanoseconds: 100_000_000)
        XCTAssertEqual(store.load()?.positionMs, 0, "throttled — the 1 s tick did not hit disk")

        // 6 s after the last write → past the interval: the refresh lands.
        store.updatePosition(ms: 6_000, isPlaying: true, now: 1_006)
        await waitUntil("throttled refresh lands after the interval") { store.load()?.positionMs == 6_000 }

        // PAUSE transition (playing → paused) writes immediately, throttle ignored.
        store.updatePosition(ms: 6_500, isPlaying: false, now: 1_006.5)
        await waitUntil("pause transition lands immediately") {
            store.load()?.positionMs == 6_500 && store.load()?.isPlaying == false
        }

        // RESUME transition writes immediately too.
        store.updatePosition(ms: 6_500, isPlaying: true, now: 1_007)
        await waitUntil("resume transition lands immediately") { store.load()?.isPlaying == true }
    }

    func testUpdatePositionWithoutActiveSessionIsNoOp() async {
        let (store, url) = makeStore()
        store.updatePosition(ms: 9_999, isPlaying: true, now: 1_000)
        try? await Task.sleep(nanoseconds: 100_000_000)
        XCTAssertFalse(FileManager.default.fileExists(atPath: url.path),
                       "no session established → nothing written")
    }

    // MARK: Clear + flush

    func testClearDeletesTheFile() async {
        let (store, url) = makeStore()
        store.save(snapshot(), now: 1_000)
        await waitUntil("saved") { store.load() != nil }
        store.clear()
        await waitUntil("file removed") { !FileManager.default.fileExists(atPath: url.path) }
        XCTAssertNil(store.load())
    }

    func testFlushLandsLatestInMemoryStateSynchronously() {
        let (store, _) = makeStore()
        store.save(snapshot(positionMs: 0, isPlaying: true), now: 1_000)
        // A throttled tick updates memory but not disk; flush must land it SYNCHRONOUSLY
        // (the scene → background suspension race — no polling allowed here).
        store.updatePosition(ms: 3_333, isPlaying: true, now: 1_002)
        store.flush(now: 1_002)
        XCTAssertEqual(store.load()?.positionMs, 3_333, "flush wrote the freshest position inline")
    }
}

/// Durable Playback Sessions — the `SetlistPlayer` integration. Every structural change
/// (play, every index move, every live-queue edit) snapshots into the wired store;
/// stop/natural-end clear it; `restore(from:)` rebuilds the deck HELD (active, rendered,
/// but silent — no audio, no hooks armed) and `resumeFromHold()` starts real playback at
/// the saved position. Uses the same offline rips/burns/coordinator rig as
/// `SetlistPlayerTests`.
@MainActor
final class SetlistPlayerSessionTests: XCTestCase {
    private let ripsBase = URL(string: "https://rips.test")!

    // MARK: Rig (mirrors SetlistPlayerTests)

    private func makeRips(serverURL: String = "https://imac.test") -> RipsStore {
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [SessionStubURLProtocol.self]
        let rips = RipsStore(ripsBase: ripsBase, session: URLSession(configuration: config))
        let settings = SettingsStore(defaults: UserDefaults(suiteName: "test.\(UUID().uuidString)")!)
        settings.ripServerURL = serverURL
        settings.ripToken = ""
        rips.settings = settings
        return rips
    }

    private func makeBurns(_ rips: RipsStore) -> BurnStore {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("pdj-psessionburn-\(UUID().uuidString).json")
        addTeardownBlock { try? FileManager.default.removeItem(at: url) }
        return BurnStore(rips: rips, fileURL: url)
    }

    private func makeStore() -> PlaybackSessionStore {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("pdj-psession-seq-\(UUID().uuidString).json")
        addTeardownBlock { try? FileManager.default.removeItem(at: url) }
        return PlaybackSessionStore(fileURL: url)
    }

    private func makeSequencer(rips: RipsStore, burns: BurnStore, player: PlayerEngine,
                               store: PlaybackSessionStore) -> (SetlistPlayer, PlaybackCoordinator) {
        let coord = PlaybackCoordinator(
            ripProvider: RipServerPlaybackProvider(rips: rips, player: player),
            appleMusic: AppleMusicPlaybackProvider(provider: AppleMusicProvider()))
        let seq = SetlistPlayer(player: player, rips: rips, burns: burns, coordinator: coord)
        seq.sessionStore = store
        return (seq, coord)
    }

    private func cleanBurnedFiles(_ names: [String]) {
        guard let dir = try? RipsStore.burnsDirectory() else { return }
        for n in names { try? FileManager.default.removeItem(at: dir.appendingPathComponent(n)) }
    }

    private func burn(_ rips: RipsStore, _ burns: BurnStore, songId: String) async {
        rips.setManifest([songId: .init(key: "rips/\(songId).mp3", source: "digital")])
        SessionStubURLProtocol.body = Data("BURNT-MP3".utf8)
        _ = await burns.burn([(id: songId, title: songId, artist: "A")])
        XCTAssertNotNil(burns.localURL(forSong: songId), "precondition: \(songId) is burned")
    }

    private func waitUntil(_ message: String, _ predicate: () -> Bool) async {
        for _ in 0..<400 {
            if predicate() { return }
            try? await Task.sleep(nanoseconds: 5_000_000)
        }
        XCTFail("timed out waiting: \(message)")
    }

    /// Await the on-disk snapshot matching `predicate` (writes land via an off-main actor).
    private func waitSnapshot(_ store: PlaybackSessionStore, _ message: String,
                              _ predicate: (PlaybackSessionStore.Snapshot) -> Bool) async {
        await waitUntil(message) { store.load().map(predicate) ?? false }
    }

    // MARK: play() writes a full snapshot

    func testPlayWritesFullSnapshotWithSourceAndRows() async {
        cleanBurnedFiles(["ps_1.mp3", "ps_1.txt"])
        let rips = makeRips(); let burns = makeBurns(rips)
        let player = PlayerEngine(); let store = makeStore()
        let (seq, _) = makeSequencer(rips: rips, burns: burns, player: player, store: store)
        await burn(rips, burns, songId: "ps_1")
        seq.historyContextProvider = { _ in (.pocket, "Warmup") }

        seq.play([.init(id: "ps_1", title: "One", artist: "A", lengthMs: 111_000),
                  .init(id: "ps_2", title: "Two", artist: "B", repeatCount: 2)],
                 sourceSetlistId: "set_A")
        await waitSnapshot(store, "play() snapshot") { $0.index == 0 && $0.queue.count == 2 }
        let snap = store.load()!
        XCTAssertTrue(snap.sessionId.hasPrefix("pses_"), "fresh session identity per play()")
        XCTAssertEqual(snap.source.kind, "pocket")
        XCTAssertEqual(snap.source.id, "set_A")
        XCTAssertEqual(snap.source.name, "Warmup")
        XCTAssertEqual(snap.queue.map(\.songId), ["ps_1", "ps_2"])
        XCTAssertEqual(snap.queue[0].title, "One")
        XCTAssertEqual(snap.queue[0].artist, "A")
        XCTAssertEqual(snap.queue[0].lengthMs, 111_000)
        XCTAssertEqual(snap.queue[1].repeatCount, 2, "self-contained rows — no catalog needed to restore")
        XCTAssertEqual(snap.positionMs, 0)

        seq.stop()
        cleanBurnedFiles(["ps_1.mp3", "ps_1.txt"])
    }

    // MARK: every index-move trigger persists

    func testIndexMovesPersist_SkipAutoAdvanceJumpAndPrevious() async {
        cleanBurnedFiles(["ps_a.mp3","ps_a.txt","ps_b.mp3","ps_b.txt","ps_c.mp3","ps_c.txt"])
        let rips = makeRips(); let burns = makeBurns(rips)
        let player = PlayerEngine(); let store = makeStore()
        let (seq, _) = makeSequencer(rips: rips, burns: burns, player: player, store: store)
        await burn(rips, burns, songId: "ps_a")
        await burn(rips, burns, songId: "ps_b")
        await burn(rips, burns, songId: "ps_c")

        seq.play([.init(id: "ps_a", title: "A", artist: "X"),
                  .init(id: "ps_b", title: "B", artist: "X"),
                  .init(id: "ps_c", title: "C", artist: "X")])
        await waitUntil("track 0 playing") { rips.nowPlaying?.songId == "ps_a" }

        // Manual skip (lock-screen ⏭ rides the same method).
        seq.skipNext()
        await waitSnapshot(store, "skipNext persisted") { $0.index == 1 && $0.positionMs == 0 }

        // AUTO-advance (natural end).
        await waitUntil("track 1 playing") { rips.nowPlaying?.songId == "ps_b" }
        player.onTrackEnded?()
        await waitSnapshot(store, "auto-advance persisted") { $0.index == 2 }

        // skipPrevious.
        seq.skipPrevious()
        await waitSnapshot(store, "skipPrevious persisted") { $0.index == 1 }

        // jumpToUpcoming (CarPlay "Play now").
        await waitUntil("back on track 1") { rips.nowPlaying?.songId == "ps_b" }
        seq.jumpToUpcoming(uid: seq.queue[2].uid)
        await waitSnapshot(store, "jumpToUpcoming persisted") { $0.index == 2 }

        seq.stop()
        cleanBurnedFiles(["ps_a.mp3","ps_a.txt","ps_b.mp3","ps_b.txt","ps_c.mp3","ps_c.txt"])
    }

    // MARK: every live-queue edit persists (jukebox guest requests survive)

    func testAllSevenLiveQueueEditsPersist() async {
        cleanBurnedFiles(["ps_e1.mp3", "ps_e1.txt"])
        let rips = makeRips(); let burns = makeBurns(rips)
        let player = PlayerEngine(); let store = makeStore()
        let (seq, _) = makeSequencer(rips: rips, burns: burns, player: player, store: store)
        await burn(rips, burns, songId: "ps_e1")

        seq.play([.init(id: "ps_e1", title: "Cur", artist: "X"),
                  .init(id: "up_1", title: "U1", artist: "X"),
                  .init(id: "up_2", title: "U2", artist: "X")])
        await waitUntil("running") { rips.nowPlaying?.songId == "ps_e1" }

        // appendToQueue (the panel's ＋ / a jukebox append).
        seq.appendToQueue([.init(id: "add_1", title: "Added", artist: "G")])
        await waitSnapshot(store, "append persisted") { $0.queue.map(\.songId).contains("add_1") }

        // insertNextInQueue ("Add next").
        seq.insertNextInQueue([.init(id: "next_1", title: "Next", artist: "G")])
        await waitSnapshot(store, "insertNext persisted") { $0.queue.map(\.songId)[1] == "next_1" }

        // insertRandomInQueue (Jukebox Hero's Surprise Slot; slot pinned for determinism).
        seq.insertRandomInQueue([.init(id: "rand_1", title: "Rand", artist: "G")], slot: { $0.lowerBound })
        await waitSnapshot(store, "insertRandom persisted") { $0.queue.map(\.songId)[1] == "rand_1" }

        // moveUpcomingNext ("Play next").
        let addUid = seq.queue.first { $0.id == "add_1" }!.uid
        seq.moveUpcomingNext(uid: addUid)
        await waitSnapshot(store, "moveUpcomingNext persisted") { $0.queue.map(\.songId)[1] == "add_1" }

        // moveUpcomingToEnd ("Move to end").
        seq.moveUpcomingToEnd(uid: addUid)
        await waitSnapshot(store, "moveUpcomingToEnd persisted") { $0.queue.map(\.songId).last == "add_1" }

        // moveUpcoming (drag reorder): move the first upcoming row to the end of the tail.
        seq.moveUpcoming(fromOffsets: IndexSet(integer: 0), toOffset: seq.upcoming.count)
        let orderAfterMove = seq.queue.map(\.id)
        await waitSnapshot(store, "moveUpcoming persisted") { $0.queue.map(\.songId) == orderAfterMove }

        // removeUpcoming (✕ — and jukebox request removal).
        seq.removeUpcoming(uids: [addUid])
        await waitSnapshot(store, "removeUpcoming persisted") { !$0.queue.map(\.songId).contains("add_1") }

        seq.stop()
        cleanBurnedFiles(["ps_e1.mp3", "ps_e1.txt"])
    }

    // MARK: cleared on stop + natural end-of-set

    func testStopAndNaturalEndClearTheSession() async {
        cleanBurnedFiles(["ps_z.mp3", "ps_z.txt"])
        let rips = makeRips(); let burns = makeBurns(rips)
        let player = PlayerEngine(); let store = makeStore()
        let (seq, _) = makeSequencer(rips: rips, burns: burns, player: player, store: store)
        await burn(rips, burns, songId: "ps_z")

        // Explicit stop.
        seq.play([.init(id: "ps_z", title: "Z", artist: "X")])
        await waitSnapshot(store, "play persisted") { $0.queue.count == 1 }
        seq.stop()
        await waitUntil("stop cleared the session") { store.load() == nil }

        // Natural end-of-set (last track's natural end → advanceToNext → stop → clear).
        seq.play([.init(id: "ps_z", title: "Z", artist: "X")])
        await waitUntil("playing again") { rips.nowPlaying?.songId == "ps_z" }
        await waitSnapshot(store, "second run persisted") { $0.queue.count == 1 }
        player.onTrackEnded?()
        await waitUntil("set ended") { !seq.isRunning }
        await waitUntil("end-of-set cleared the session") { store.load() == nil }
        cleanBurnedFiles(["ps_z.mp3", "ps_z.txt"])
    }

    // MARK: adoption of a manual member play persists

    func testManualJumpAdoptionPersistsNewIndex() async {
        cleanBurnedFiles(["ps_m1.mp3","ps_m1.txt","ps_m2.mp3","ps_m2.txt"])
        let rips = makeRips(); let burns = makeBurns(rips)
        let player = PlayerEngine(); let store = makeStore()
        let (seq, _) = makeSequencer(rips: rips, burns: burns, player: player, store: store)
        await burn(rips, burns, songId: "ps_m1")
        await burn(rips, burns, songId: "ps_m2")

        seq.play([.init(id: "ps_m1", title: "M1", artist: "X"),
                  .init(id: "ps_m2", title: "M2", artist: "X")])
        await waitUntil("track 0 playing") { rips.nowPlaying?.songId == "ps_m1" }

        // A manual row ▶ on the second member (the RowTransport path).
        playLocalFile(burns.localURL(forSong: "ps_m2")!, songId: "ps_m2", title: "M2", artist: "X",
                      startMs: nil, rips: rips, player: player)
        await waitUntil("adopted") { seq.index == 1 }
        await waitSnapshot(store, "adoption persisted") { $0.index == 1 }

        seq.stop()
        cleanBurnedFiles(["ps_m1.mp3","ps_m1.txt","ps_m2.mp3","ps_m2.txt"])
    }

    // MARK: restore fidelity

    func testRestoreRebuildsDeckHeldWithoutAudio() {
        let rips = makeRips(); let burns = makeBurns(rips)
        let player = PlayerEngine(); let store = makeStore()
        let (seq, coord) = makeSequencer(rips: rips, burns: burns, player: player, store: store)

        // Shuffle-ordered queue with a DUPLICATE songId and a repeat count, killed at index 2.
        let snap = PlaybackSessionStore.Snapshot(
            sessionId: "pses_restored",
            source: .init(kind: "playlist", id: "pls_9", name: "Roadtrip"),
            queue: [
                .init(songId: "s_c", title: "C", artist: "X", lengthMs: 100_000, repeatCount: nil),
                .init(songId: "s_a", title: "A", artist: "X", lengthMs: nil, repeatCount: nil),
                .init(songId: "s_b", title: "B", artist: "X", lengthMs: 90_000, repeatCount: 3),
                .init(songId: "s_a", title: "A", artist: "X", lengthMs: nil, repeatCount: nil),
            ],
            index: 2, positionMs: 42_000, isPlaying: true, updatedAt: 0)

        seq.restore(from: snap)

        XCTAssertTrue(seq.isRunning, "deck is ACTIVE — the home panel renders")
        XCTAssertTrue(seq.isHeldForResume, "…but HELD: nothing is sounding")
        XCTAssertEqual(seq.queue.map(\.id), ["s_c", "s_a", "s_b", "s_a"],
                       "shuffle order + duplicate songIds preserved")
        XCTAssertEqual(seq.index, 2)
        XCTAssertEqual(seq.queue[0..<seq.index].map(\.id), ["s_c", "s_a"],
                       "played region = exactly the pre-kill played region (this run, not History)")
        XCTAssertEqual(seq.upcoming.map(\.id), ["s_a"])
        XCTAssertEqual(seq.currentSongId, "s_b")
        XCTAssertEqual(seq.queue[seq.index].repeatCount, 3, "repeat counts survive")
        XCTAssertEqual(seq.sourceSetlistId, "pls_9")
        XCTAssertEqual(seq.capturedHistoryContext?.source, .playlist,
                       "history origin reconstructed from the stored kind")
        XCTAssertEqual(seq.capturedHistoryContext?.name, "Roadtrip")
        // NO audio started, no engine hooks armed, no card claimed via play state.
        XCTAssertFalse(player.isPlaying)
        XCTAssertNil(rips.nowPlaying, "restore never touches now-playing")
        XCTAssertNil(coord.activeBackend)
        XCTAssertNil(player.onTrackEnded, "hooks stay un-armed until real playback starts")
        XCTAssertNil(player.onNext)

        seq.stop()
    }

    func testRestoreClampsOutOfRangeIndex() {
        let rips = makeRips(); let burns = makeBurns(rips)
        let player = PlayerEngine(); let store = makeStore()
        let (seq, _) = makeSequencer(rips: rips, burns: burns, player: player, store: store)
        var snap = PlaybackSessionStore.Snapshot(
            sessionId: "pses_x", source: .init(kind: "setlist", id: nil, name: nil),
            queue: [.init(songId: "s_1", title: "1", artist: "X", lengthMs: nil, repeatCount: nil)],
            index: 99, positionMs: 0, isPlaying: false, updatedAt: 0)
        seq.restore(from: snap)
        XCTAssertEqual(seq.index, 0, "corrupt index clamps into the queue")
        seq.stop()

        snap.index = -3
        seq.restore(from: snap)
        XCTAssertEqual(seq.index, 0)
        seq.stop()
    }

    // MARK: restore is skipped when playback is already live

    func testRestoreSkippedWhenAlreadyRunningOrBackendActive() async {
        cleanBurnedFiles(["ps_r1.mp3", "ps_r1.txt"])
        let rips = makeRips(); let burns = makeBurns(rips)
        let player = PlayerEngine(); let store = makeStore()
        let (seq, coord) = makeSequencer(rips: rips, burns: burns, player: player, store: store)
        await burn(rips, burns, songId: "ps_r1")

        // Mid-run: restore(from:) is a no-op.
        seq.play([.init(id: "ps_r1", title: "R1", artist: "X")])
        await waitUntil("running") { rips.nowPlaying?.songId == "ps_r1" }
        let liveSession = store.load()?.sessionId
        seq.restore(from: PlaybackSessionStore.Snapshot(
            sessionId: "pses_stale", source: .init(kind: "setlist", id: nil, name: nil),
            queue: [.init(songId: "other", title: "O", artist: "X", lengthMs: nil, repeatCount: nil)],
            index: 0, positionMs: 0, isPlaying: false, updatedAt: 0))
        XCTAssertEqual(seq.queue.map(\.id), ["ps_r1"], "a running set is never clobbered by a restore")
        XCTAssertFalse(seq.isHeldForResume)
        XCTAssertEqual(store.load()?.sessionId, liveSession)
        seq.stop()

        // A backend already owning audio (an intent/widget launch beat the launch task):
        // restorePersistedSessionIfIdle refuses even with a valid snapshot on disk.
        store.save(PlaybackSessionStore.Snapshot(
            sessionId: "pses_disk", source: .init(kind: "setlist", id: nil, name: nil),
            queue: [.init(songId: "s_1", title: "1", artist: "X", lengthMs: nil, repeatCount: nil)],
            index: 0, positionMs: 0, isPlaying: true, updatedAt: 0))
        await waitUntil("disk snapshot present") { store.load()?.sessionId == "pses_disk" }
        coord.setActiveBackendForTests(.appleMusic)
        seq.restorePersistedSessionIfIdle()
        XCTAssertFalse(seq.isRunning, "active backend → no restore")
        coord.setActiveBackendForTests(nil)

        // Idle + snapshot present → restores (the normal launch path).
        seq.restorePersistedSessionIfIdle()
        XCTAssertTrue(seq.isRunning)
        XCTAssertTrue(seq.isHeldForResume)
        XCTAssertEqual(seq.currentSongId, "s_1")
        seq.stop()
        cleanBurnedFiles(["ps_r1.mp3", "ps_r1.txt"])
    }

    // MARK: first ▶ resumes at the saved position

    func testResumeFromHoldStartsCurrentTrackAtSavedPosition() async {
        cleanBurnedFiles(["ps_res.mp3", "ps_res.txt"])
        let rips = makeRips(); let burns = makeBurns(rips)
        let player = PlayerEngine(); let store = makeStore()
        let (seq, _) = makeSequencer(rips: rips, burns: burns, player: player, store: store)
        await burn(rips, burns, songId: "ps_res")

        seq.restore(from: PlaybackSessionStore.Snapshot(
            sessionId: "pses_res", source: .init(kind: "setlist", id: "set_r", name: "Set R"),
            queue: [.init(songId: "ps_res", title: "Res", artist: "X", lengthMs: 200_000, repeatCount: nil)],
            index: 0, positionMs: 42_000, isPlaying: true, updatedAt: 0))
        XCTAssertNil(rips.nowPlaying, "held — nothing started yet")

        seq.resumeFromHold()
        await waitUntil("resume started the burned file") { rips.nowPlaying?.songId == "ps_res" }
        XCTAssertEqual(rips.nowPlaying?.seekMs, 42_000,
                       "playback resumes AT the saved position (the cue-seek seam)")
        XCTAssertFalse(seq.isHeldForResume)
        XCTAssertNotNil(player.onTrackEnded, "hooks armed — auto-advance works from here on")
        XCTAssertNotNil(player.onNext)

        seq.stop()
        cleanBurnedFiles(["ps_res.mp3", "ps_res.txt"])
    }

    /// A skip on a HELD deck goes live like any normal run (hooks armed) and drops the
    /// pending resume offset — the NEXT track starts from its top, not 42 s in.
    func testSkipOnHeldDeckGoesLiveFromTrackTop() async {
        cleanBurnedFiles(["ps_h2.mp3", "ps_h2.txt"])
        let rips = makeRips(); let burns = makeBurns(rips)
        let player = PlayerEngine(); let store = makeStore()
        let (seq, _) = makeSequencer(rips: rips, burns: burns, player: player, store: store)
        await burn(rips, burns, songId: "ps_h2")

        seq.restore(from: PlaybackSessionStore.Snapshot(
            sessionId: "pses_h", source: .init(kind: "setlist", id: nil, name: nil),
            queue: [.init(songId: "ps_h1", title: "H1", artist: "X", lengthMs: nil, repeatCount: nil),
                    .init(songId: "ps_h2", title: "H2", artist: "X", lengthMs: nil, repeatCount: nil)],
            index: 0, positionMs: 42_000, isPlaying: true, updatedAt: 0))

        seq.skipNext()
        await waitUntil("skip started the next track") { rips.nowPlaying?.songId == "ps_h2" }
        XCTAssertNil(rips.nowPlaying?.seekMs, "pending resume offset dropped on skip — plays from the top")
        XCTAssertFalse(seq.isHeldForResume)
        XCTAssertNotNil(player.onTrackEnded)

        seq.stop()
        cleanBurnedFiles(["ps_h2.mp3", "ps_h2.txt"])
    }
}

/// Minimal `URLProtocol` serving HTTP 200 + a fixed body (mirrors `SetlistStubURLProtocol` —
/// stubs are private per file).
private final class SessionStubURLProtocol: URLProtocol {
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

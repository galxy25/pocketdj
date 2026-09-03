import XCTest
import AVFoundation
@testable import PocketDJ

/// Durable Mix deck sessions — the store. A single overwrite-in-place snapshot
/// (`pocketdj-mix-decks.json`) written in real time as the mix happens: structural saves
/// immediate, slider-y control saves DEBOUNCED (~trailing edge — the drag's final value always
/// lands, 60 Hz never hits disk), playhead refreshes throttled while running and immediate on a
/// run/pause transition, lenient load (any decode failure → nil), clear-on-eject.
@MainActor
final class MixDeckSessionStoreTests: XCTestCase {

    private func makeStore() -> (MixDeckSessionStore, URL) {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("pdj-mixsession-\(UUID().uuidString).json")
        addTeardownBlock { try? FileManager.default.removeItem(at: url) }
        return (MixDeckSessionStore(fileURL: url), url)
    }

    private func track(_ id: String, title: String = "T", bpm: Double? = 120) -> MixDeckSessionStore.TrackRef {
        .init(songId: id, title: title, artist: "Aria", bpm: bpm, camelot: "8A", key: "Am",
              albumId: "alb_1", lengthMs: 200_000)
    }

    private func deck(_ id: String, positionMs: Int = 42_000) -> MixDeckSessionStore.DeckSnapshot {
        .init(track: track(id), positionMs: positionMs, volume: 1.4, rate: 1.25, pitch: -3,
              compressor: false, reverb: true, flanger: false, filter: true,
              compStrength: 0.5, reverbStrength: 0.8, flangerStrength: 0.5, filterStrength: 0.33,
              stemMode: true, stemMuted: ["vocals"], stemVol: ["drums": 0.6],
              loopOn: true, loopUnits: 8)
    }

    private func snapshot() -> MixDeckSessionStore.Snapshot {
        .init(deckA: deck("sng_a"), deckB: deck("sng_b", positionMs: 7_000),
              crossfader: 0.3, leadDeck: "A",
              auto: .init(queue: [.init(track: track("sng_a"), durationMs: 200_000, sourceLabel: "Crate A"),
                                  .init(track: track("sng_b"), durationMs: 180_000, sourceLabel: "Crate B"),
                                  .init(track: track("sng_c", title: "C"), durationMs: 190_000)],
                          livePos: 1, nextToLoad: 2, liveDeck: "B", sourceLabel: "Warmup",
                          leadSeconds: 12, fadeSeconds: 4, fxGlide: true, mixGlide: false,
                          repeatMode: "one"),
              wasRunning: true, updatedAt: 0)
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
        // Deck A — every plain-value control.
        let a = loaded.deckA!
        XCTAssertEqual(a.track.songId, "sng_a")
        XCTAssertEqual(a.track.title, "T")
        XCTAssertEqual(a.track.artist, "Aria")
        XCTAssertEqual(a.track.bpm, 120)
        XCTAssertEqual(a.track.camelot, "8A")
        XCTAssertEqual(a.track.lengthMs, 200_000)
        XCTAssertEqual(a.positionMs, 42_000)
        XCTAssertEqual(a.volume, 1.4, "the >unity boost survives")
        XCTAssertEqual(a.rate, 1.25)
        XCTAssertEqual(a.pitch, -3)
        XCTAssertTrue(a.reverb); XCTAssertTrue(a.filter)
        XCTAssertFalse(a.compressor); XCTAssertFalse(a.flanger)
        XCTAssertEqual(a.reverbStrength, 0.8)
        XCTAssertEqual(a.filterStrength, 0.33)
        XCTAssertTrue(a.stemMode)
        XCTAssertEqual(a.stemMuted, ["vocals"])
        XCTAssertEqual(a.stemVol, ["drums": 0.6], "per-stem gains survive")
        XCTAssertEqual(a.loopOn, true, "loop engagement survives a relaunch")
        XCTAssertEqual(a.loopUnits, 8, "loop length survives a relaunch")
        XCTAssertEqual(loaded.deckB?.positionMs, 7_000)
        // Globals.
        XCTAssertEqual(loaded.crossfader, 0.3)
        XCTAssertEqual(loaded.leadDeck, "A")
        XCTAssertTrue(loaded.wasRunning)
        // Auto-DJ — order + cursor + label + glide flags.
        let auto = loaded.auto!
        XCTAssertEqual(auto.queue.map(\.track.songId), ["sng_a", "sng_b", "sng_c"],
                       "queue order preserved exactly")
        XCTAssertEqual(auto.queue.map(\.durationMs), [200_000, 180_000, 190_000])
        XCTAssertEqual(auto.queue.map(\.sourceLabel), ["Crate A", "Crate B", nil],
                       "per-row crate provenance round-trips (nil for legacy rows)")
        XCTAssertEqual(auto.repeatMode, "one", "the repeat mode round-trips")
        XCTAssertEqual(auto.livePos, 1)
        XCTAssertEqual(auto.nextToLoad, 2)
        XCTAssertEqual(auto.liveDeck, "B")
        XCTAssertEqual(auto.sourceLabel, "Warmup")
        XCTAssertEqual(auto.leadSeconds, 12)
        XCTAssertEqual(auto.fadeSeconds, 4)
        XCTAssertTrue(auto.fxGlide); XCTAssertFalse(auto.mixGlide)
    }

    // MARK: Lenient load

    func testLoadIsLenientOnMissingGarbageSchemaAndEmpty() async {
        let (store, url) = makeStore()
        XCTAssertNil(store.load(), "missing file → nil")

        try? Data("NOT JSON {{{".utf8).write(to: url)
        XCTAssertNil(store.load(), "garbage bytes → nil, never throws")

        var wrongVersion = snapshot()
        wrongVersion.schemaVersion = mixDeckSessionSchemaVersion + 1
        try? JSONEncoder().encode(wrongVersion).write(to: url)
        XCTAssertNil(store.load(), "schema mismatch → nil (no migration)")

        // Nothing to restore (no decks, no auto queue) → nil.
        let empty = MixDeckSessionStore.Snapshot(deckA: nil, deckB: nil, crossfader: 0.5,
                                                 leadDeck: nil, auto: nil, wasRunning: false,
                                                 updatedAt: 0)
        try? JSONEncoder().encode(empty).write(to: url)
        XCTAssertNil(store.load(), "empty snapshot → nothing to restore")
    }

    // MARK: Debounce (control changes)

    func testDebouncedSaveCoalescesAndLandsTheFinalValue() async {
        let (store, url) = makeStore()
        store.controlDebounceInterval = 0.08
        // A "drag": many rapid updates. None hits disk immediately; ONE write lands the LAST value.
        var snap = snapshot()
        for v in [0.1, 0.2, 0.3, 0.9] {
            snap.crossfader = v
            store.saveDebounced(snap, now: 1_000)
        }
        XCTAssertFalse(FileManager.default.fileExists(atPath: url.path),
                       "debounced — no write during the burst")
        await waitUntil("trailing-edge write lands the final value") { store.load()?.crossfader == 0.9 }
    }

    func testImmediateSaveSupersedesPendingDebounce() async {
        let (store, _) = makeStore()
        store.controlDebounceInterval = 0.08
        var snap = snapshot()
        snap.crossfader = 0.1
        store.saveDebounced(snap, now: 1_000)
        snap.crossfader = 0.7
        store.save(snap, now: 1_000)     // structural save: immediate + cancels the debounce
        await waitUntil("immediate save landed") { store.load()?.crossfader == 0.7 }
        try? await Task.sleep(nanoseconds: 150_000_000)   // past the debounce interval
        XCTAssertEqual(store.load()?.crossfader, 0.7, "no stale debounced write resurfaced")
    }

    // MARK: Position throttle

    func testPositionWritesThrottledWhileRunningAndImmediateOnTransition() async {
        let (store, _) = makeStore()
        store.save(snapshot(), now: 1_000)
        await waitUntil("initial save lands") { store.load() != nil }

        // 1 s later, still running → INSIDE the 5 s throttle window: no disk write.
        store.updatePosition(aMs: 43_000, bMs: 8_000, isRunning: true, now: 1_001)
        try? await Task.sleep(nanoseconds: 100_000_000)
        XCTAssertEqual(store.load()?.deckA?.positionMs, 42_000, "throttled — the 1 s tick did not hit disk")

        // 6 s after the last write → past the interval: the refresh lands, BOTH decks.
        store.updatePosition(aMs: 48_000, bMs: 13_000, isRunning: true, now: 1_006)
        await waitUntil("throttled refresh lands after the interval") {
            store.load()?.deckA?.positionMs == 48_000 && store.load()?.deckB?.positionMs == 13_000
        }

        // PAUSE transition (running → stopped) writes immediately, throttle ignored.
        store.updatePosition(aMs: 48_500, bMs: 13_500, isRunning: false, now: 1_006.5)
        await waitUntil("pause transition lands immediately") {
            store.load()?.deckA?.positionMs == 48_500 && store.load()?.wasRunning == false
        }

        // RESUME transition writes immediately too.
        store.updatePosition(aMs: 48_500, bMs: 13_500, isRunning: true, now: 1_007)
        await waitUntil("resume transition lands immediately") { store.load()?.wasRunning == true }
    }

    func testUpdatePositionWithoutActiveSessionIsNoOp() async {
        let (store, url) = makeStore()
        store.updatePosition(aMs: 9_999, bMs: nil, isRunning: true, now: 1_000)
        try? await Task.sleep(nanoseconds: 100_000_000)
        XCTAssertFalse(FileManager.default.fileExists(atPath: url.path),
                       "no session established → nothing written")
    }

    // MARK: Clear + flush

    func testClearDeletesTheFileAndBeatsAPendingDebounce() async {
        let (store, url) = makeStore()
        store.save(snapshot(), now: 1_000)
        await waitUntil("saved") { store.load() != nil }
        // Arm a debounced write, then clear: the delete must WIN (no resurrection).
        store.controlDebounceInterval = 0.05
        store.saveDebounced(snapshot(), now: 1_001)
        store.clear()
        await waitUntil("file removed") { !FileManager.default.fileExists(atPath: url.path) }
        try? await Task.sleep(nanoseconds: 150_000_000)   // past the debounce interval
        XCTAssertNil(store.load(), "a cleared session never rehydrates from a stale write")
    }

    func testFlushLandsLatestInMemoryStateSynchronously() {
        let (store, _) = makeStore()
        store.save(snapshot(), now: 1_000)
        // A throttled tick updates memory but not disk; flush must land it SYNCHRONOUSLY
        // (the scene → background suspension race — no polling allowed here).
        store.updatePosition(aMs: 55_555, bMs: nil, isRunning: true, now: 1_002)
        store.flush(now: 1_002)
        XCTAssertEqual(store.load()?.deckA?.positionMs, 55_555, "flush wrote the freshest position inline")
    }
}

/// Durable Mix deck sessions — the `MixEngine` integration. Every structural change (deck
/// load/eject, auto-mix start/stop/insert/pause/resume, lead change, effect toggle) persists
/// immediately; slider-y controls debounce; both decks eject → clear. Restore materializes
/// HELD: decks re-loaded + cued, controls re-applied, Auto-DJ suspended, NOTHING playing.
/// Deck loads resolve through the studio seam (`studioResolve`) so the rig needs no BurnStore
/// ledger — mirroring how performance items load; the missing-file test uses a non-studio id
/// that the (empty) BurnStore can't resolve.
@MainActor
final class MixEngineSessionTests: XCTestCase {

    private func makeStore() -> MixDeckSessionStore {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("pdj-mixsession-eng-\(UUID().uuidString).json")
        addTeardownBlock { try? FileManager.default.removeItem(at: url) }
        let store = MixDeckSessionStore(fileURL: url)
        store.controlDebounceInterval = 0.05
        return store
    }

    private func makeEngine(store: MixDeckSessionStore) -> MixEngine {
        let rips = RipsStore(ripsBase: URL(string: "https://rips.test")!, session: .shared)
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("pdj-mixsession-burns-\(UUID().uuidString).json")
        addTeardownBlock { try? FileManager.default.removeItem(at: url) }
        let e = MixEngine(burns: BurnStore(rips: rips, fileURL: url))
        e.sessionStore = store
        return e
    }

    /// Route studio-prefixed ids ("smp_…") to generated WAVs, so restore/load runs the REAL
    /// `load(songId:)` path end-to-end without a BurnStore ledger.
    private func wireStudioResolve(_ e: MixEngine, files: [String: URL]) {
        e.studioResolve = { id in
            guard let url = files[id] else { return nil }
            return (url: url, release: nil, title: id, lengthMs: 2_000)
        }
    }

    private func meta(_ id: String, bpm: Double? = 120) -> MixEngine.LoadedTrack {
        MixEngine.LoadedTrack(songId: id, title: "Song \(id)", artist: "Artist",
                              bpm: bpm, camelot: "8A", key: "Am", albumId: nil)
    }

    private func makeSineWAV(seconds: Double, sr: Double = 44_100) throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("mixsession-\(UUID().uuidString).wav")
        addTeardownBlock { try? FileManager.default.removeItem(at: url) }
        let fmt = AVAudioFormat(standardFormatWithSampleRate: sr, channels: 2)!
        let file = try AVAudioFile(forWriting: url, settings: fmt.settings)
        let frames = AVAudioFrameCount(seconds * sr)
        let buf = AVAudioPCMBuffer(pcmFormat: fmt, frameCapacity: frames)!
        buf.frameLength = frames
        for ch in 0..<2 {
            let p = buf.floatChannelData![ch]
            for i in 0..<Int(frames) { p[i] = sinf(Float(i) * 2 * .pi * 440 / Float(sr)) * 0.5 }
        }
        try file.write(from: buf)
        return url
    }

    private func waitUntil(_ message: String, _ predicate: () -> Bool) async {
        for _ in 0..<400 {
            if predicate() { return }
            try? await Task.sleep(nanoseconds: 5_000_000)
        }
        XCTFail("timed out waiting: \(message)")
    }

    private func waitSnapshot(_ store: MixDeckSessionStore, _ message: String,
                              _ predicate: (MixDeckSessionStore.Snapshot) -> Bool) async {
        await waitUntil(message) { store.load().map(predicate) ?? false }
    }

    // MARK: Deck load / eject triggers

    func testDeckLoadPersistsAndEjectingBothClears() async throws {
        let store = makeStore()
        let e = makeEngine(store: store)
        e.ensureEngine()
        try XCTSkipUnless(e.isReady, "no audio device on this test host")

        let a = try makeSineWAV(seconds: 2)
        e.loadFile(a, release: nil, startMs: nil, meta: meta("t1"), on: .a)
        await waitSnapshot(store, "deck load persisted") { $0.deckA?.track.songId == "t1" }
        let snap = store.load()!
        XCTAssertEqual(snap.deckA?.track.title, "Song t1", "self-contained track metadata")
        XCTAssertEqual(snap.deckA?.track.bpm, 120)
        XCTAssertNil(snap.deckB)
        XCTAssertNil(snap.auto)
        XCTAssertFalse(snap.wasRunning, "loaded, not playing")

        let b = try makeSineWAV(seconds: 2)
        e.loadFile(b, release: nil, startMs: nil, meta: meta("t2"), on: .b)
        await waitSnapshot(store, "second deck persisted") { $0.deckB?.track.songId == "t2" }

        // Eject one deck → the other still persists; eject BOTH → the session clears.
        e.clearDeck(.a)
        await waitSnapshot(store, "one eject keeps the mix") { $0.deckA == nil && $0.deckB != nil }
        e.clearDeck(.b)
        await waitUntil("both decks ejected → session cleared") { store.load() == nil }
    }

    // MARK: Control-change triggers (debounced sliders, immediate discrete taps)

    func testSliderControlsPersistDebouncedWithFinalValue() async throws {
        let store = makeStore()
        let e = makeEngine(store: store)
        e.ensureEngine()
        try XCTSkipUnless(e.isReady, "no audio device on this test host")
        e.loadFile(try makeSineWAV(seconds: 2), release: nil, startMs: nil, meta: meta("t1"), on: .a)
        await waitSnapshot(store, "load persisted") { $0.deckA != nil }

        // A volume "drag": several rapid values — only the final one needs to land (one write).
        for v in [0.9, 0.7, 0.5, 0.4] { e.setVolume(v, on: .a) }
        e.setCrossfader(0.25)
        e.setRate(1.5, on: .a)
        e.setPitch(-2, on: .a)
        e.setEffectStrength(.reverb, 0.66, on: .a)
        e.setStemVolume("drums", 0.4, on: .a)
        await waitSnapshot(store, "debounced control burst landed its final values") {
            $0.deckA?.volume == 0.4 && $0.crossfader == 0.25 && $0.deckA?.rate == 1.5
                && $0.deckA?.pitch == -2 && $0.deckA?.reverbStrength == 0.66
                && $0.deckA?.stemVol["drums"] == 0.4
        }
    }

    func testEffectToggleAndLeadPersistImmediately() async throws {
        let store = makeStore()
        let e = makeEngine(store: store)
        e.ensureEngine()
        try XCTSkipUnless(e.isReady, "no audio device on this test host")
        e.loadFile(try makeSineWAV(seconds: 2), release: nil, startMs: nil, meta: meta("t1"), on: .a)
        await waitSnapshot(store, "load persisted") { $0.deckA != nil }

        e.setEffect(.filter, enabled: true, on: .a)
        await waitSnapshot(store, "effect toggle persisted") { $0.deckA?.filter == true }
        e.setLead(.a)
        await waitSnapshot(store, "lead persisted") { $0.leadDeck == "A" }
        e.setLead(.a)   // toggle off
        await waitSnapshot(store, "lead cleared persisted") { $0.leadDeck == nil }
    }

    // MARK: Auto-mix triggers

    func testAutoMixLifecyclePersistsQueueInsertPauseAndStop() async throws {
        let store = makeStore()
        let e = makeEngine(store: store)
        e.ensureEngine()
        try XCTSkipUnless(e.isReady, "no audio device on this test host")
        let files = ["smp_a1": try makeSineWAV(seconds: 3), "smp_a2": try makeSineWAV(seconds: 3),
                     "smp_a3": try makeSineWAV(seconds: 3), "smp_g1": try makeSineWAV(seconds: 3)]
        wireStudioResolve(e, files: files)
        // durationMs deliberately LONG (30 s) relative to the lead so the auto machine arms no
        // transition during the test — the asserts below need a stable cursor.
        func item(_ id: String) -> MixEngine.AutoMixItem {
            .init(loadable: MixLoadable(songId: id, title: "T \(id)", artist: "A", bpm: 120,
                                        camelot: "8A", key: nil, albumId: nil, lengthMs: 30_000),
                  durationMs: 30_000)
        }

        e.startAutoMix([item("smp_a1"), item("smp_a2"), item("smp_a3")],
                       shuffled: false, lead: 5, fade: 2, label: "Warmup")
        await waitSnapshot(store, "auto-mix start persisted the queue") {
            $0.auto?.queue.map(\.track.songId) == ["smp_a1", "smp_a2", "smp_a3"]
        }
        var snap = store.load()!
        XCTAssertEqual(snap.auto?.sourceLabel, "Warmup")
        XCTAssertEqual(snap.auto?.liveDeck, "A")
        XCTAssertEqual(snap.auto?.livePos, 0)
        XCTAssertEqual(snap.auto?.nextToLoad, 2, "both decks preloaded")
        XCTAssertEqual(snap.auto?.leadSeconds, 5)
        XCTAssertEqual(snap.auto?.fadeSeconds, 2)
        XCTAssertEqual(snap.auto?.queue.map(\.durationMs), [30_000, 30_000, 30_000])
        XCTAssertEqual(snap.deckA?.track.songId, "smp_a1", "live deck's track persisted too")
        XCTAssertEqual(snap.deckB?.track.songId, "smp_a2", "preloaded on-deck track persisted")
        XCTAssertTrue(snap.wasRunning)

        // A jukebox guest insert survives (autoQueueInsert → immediate persist).
        e.autoQueueInsert(item("smp_g1"), placement: .next)
        await waitSnapshot(store, "jukebox insert persisted") {
            $0.auto?.queue.map(\.track.songId) == ["smp_a1", "smp_a2", "smp_g1", "smp_a3"]
        }

        // Pause / resume persist.
        e.pauseAuto()
        await waitUntil("pauseAuto persisted (a write happened)") { store.load() != nil }
        XCTAssertTrue(e.autoPaused)
        e.resumeAuto()
        await waitUntil("resumeAuto persisted") { store.load() != nil }
        XCTAssertFalse(e.autoPaused)

        // Stop: the auto machine leaves the snapshot; the (still-loaded) decks remain.
        e.stopAutoMix()
        await waitSnapshot(store, "stop removed the auto queue, kept the decks (now paused)") {
            $0.auto == nil && $0.deckA != nil && $0.wasRunning == false
        }
        snap = store.load()!
        XCTAssertNotNil(snap.deckB)
    }

    // MARK: Restore fidelity

    private func fidelitySnapshot() -> MixDeckSessionStore.Snapshot {
        func t(_ id: String) -> MixDeckSessionStore.TrackRef {
            .init(songId: id, title: "Title \(id)", artist: "Artist", bpm: 128, camelot: "9A",
                  key: "Em", albumId: nil, lengthMs: 2_000)
        }
        let a = MixDeckSessionStore.DeckSnapshot(
            track: t("smp_r1"), positionMs: 500, volume: 0.7, rate: 1.25, pitch: 3,
            compressor: false, reverb: true, flanger: false, filter: false,
            compStrength: 0.5, reverbStrength: 0.8, flangerStrength: 0.5, filterStrength: 0.5,
            stemMode: false, stemMuted: [], stemVol: [:])
        let b = MixDeckSessionStore.DeckSnapshot(
            track: t("smp_r2"), positionMs: 0, volume: 1.6, rate: 1.0, pitch: 0,
            compressor: true, reverb: false, flanger: false, filter: false,
            compStrength: 0.9, reverbStrength: 0.5, flangerStrength: 0.5, filterStrength: 0.5,
            stemMode: false, stemMuted: [], stemVol: [:])
        return .init(deckA: a, deckB: b, crossfader: 0.3, leadDeck: "A",
                     auto: .init(queue: [.init(track: t("smp_r1"), durationMs: 2_000),
                                         .init(track: t("smp_r2"), durationMs: 2_000),
                                         .init(track: t("smp_r3"), durationMs: 2_000)],
                                 livePos: 0, nextToLoad: 2, liveDeck: "A", sourceLabel: "Warmup",
                                 leadSeconds: 12, fadeSeconds: 4, fxGlide: true, mixGlide: false),
                     wasRunning: true, updatedAt: 0)
    }

    func testRestoreMaterializesHeldWithFullFidelity() async throws {
        let store = makeStore()
        let e = makeEngine(store: store)
        e.ensureEngine()
        try XCTSkipUnless(e.isReady, "no audio device on this test host")
        wireStudioResolve(e, files: ["smp_r1": try makeSineWAV(seconds: 2),
                                     "smp_r2": try makeSineWAV(seconds: 2),
                                     "smp_r3": try makeSineWAV(seconds: 2)])
        store.save(fidelitySnapshot())
        await waitUntil("snapshot on disk") { store.load() != nil }

        e.restorePersistedMixIfIdle()          // launch task: parks, no audio
        XCTAssertNil(e.loaded(.a), "parked — nothing materialized at launch")
        e.materializePendingRestoreIfNeeded()  // Mix tab appears

        // Decks re-loaded + cued.
        XCTAssertEqual(e.loaded(.a)?.songId, "smp_r1")
        XCTAssertEqual(e.loaded(.a)?.title, "Title smp_r1", "snapshot metadata is the display truth")
        XCTAssertEqual(e.loaded(.b)?.songId, "smp_r2")
        XCTAssertEqual(e.position(.a), 0.5, accuracy: 0.01, "playhead cued at the saved position")
        XCTAssertEqual(e.position(.b), 0.0, accuracy: 0.01)
        // Controls re-applied.
        XCTAssertEqual(e.volume(.a), 0.7)
        XCTAssertEqual(e.volume(.b), 1.6, "the >unity boost restores")
        XCTAssertEqual(e.rate(.a), 1.25)
        XCTAssertEqual(e.pitch(.a), 3)
        XCTAssertTrue(e.isEnabled(.reverb, on: .a))
        XCTAssertEqual(e.strength(.reverb, on: .a), 0.8)
        XCTAssertTrue(e.isEnabled(.compressor, on: .b))
        XCTAssertEqual(e.strength(.compressor, on: .b), 0.9)
        XCTAssertEqual(e.crossfader, 0.3, accuracy: 1e-9)
        XCTAssertTrue(e.isLead(.a))
        // Auto-DJ restored SUSPENDED with its queue intact.
        XCTAssertTrue(e.autoMixing)
        XCTAssertTrue(e.autoPaused, "restored Auto-DJ is suspended — it must not self-resume")
        XCTAssertEqual(e.autoUpcoming.map(\.songId), ["smp_r2", "smp_r3"], "queue tail preserved")
        XCTAssertEqual(e.autoSourceLabel, "Warmup")
        // HELD: nothing plays, nothing runs.
        XCTAssertFalse(e.isRunning, "restore never starts audio")
        XCTAssertFalse(e.isPlaying(.a))
        XCTAssertFalse(e.isPlaying(.b))
        XCTAssertFalse(e.playerNodeIsPlayingForTesting(.a), "no AVAudioPlayerNode was started")
        XCTAssertFalse(e.playerNodeIsPlayingForTesting(.b))

        e.stopAutoMix()
    }

    func testRestoreIsSkippedWhenTheEngineIsAlreadyInUse() async throws {
        let store = makeStore()
        let e = makeEngine(store: store)
        e.ensureEngine()
        try XCTSkipUnless(e.isReady, "no audio device on this test host")

        // A deck is already loaded (e.g. an intent-started mix beat the launch task).
        e.loadFile(try makeSineWAV(seconds: 2), release: nil, startMs: nil, meta: meta("live"), on: .a)
        await waitSnapshot(store, "live load persisted") { $0.deckA?.track.songId == "live" }

        // A (stale) snapshot exists on disk, as if from a previous run.
        wireStudioResolve(e, files: ["smp_r1": try makeSineWAV(seconds: 2)])
        store.save(fidelitySnapshot())
        await waitSnapshot(store, "stale snapshot on disk") { $0.auto != nil }
        e.restorePersistedMixIfIdle()
        e.materializePendingRestoreIfNeeded()
        XCTAssertEqual(e.loaded(.a)?.songId, "live", "an in-use engine is never clobbered")
        XCTAssertNil(e.loaded(.b))
        XCTAssertFalse(e.autoMixing)
    }

    func testMissingFilesRestorePartiallyPerDeck() async throws {
        let store = makeStore()
        let e = makeEngine(store: store)
        e.ensureEngine()
        try XCTSkipUnless(e.isReady, "no audio device on this test host")
        // Deck A resolves; deck B's track is a NON-studio id the empty BurnStore can't find
        // (its burn was deleted since the snapshot).
        wireStudioResolve(e, files: ["smp_r1": try makeSineWAV(seconds: 2)])
        var snap = fidelitySnapshot()
        snap.deckB?.track.songId = "sng_gone"
        snap.auto = nil
        store.save(snap)
        await waitUntil("snapshot on disk") { store.load() != nil }

        e.restorePersistedMixIfIdle()
        e.materializePendingRestoreIfNeeded()

        XCTAssertEqual(e.loaded(.a)?.songId, "smp_r1", "the loadable deck restores")
        XCTAssertNil(e.loaded(.b), "the vanished file's deck is simply empty — no crash, no error")
        XCTAssertFalse(e.isRunning)
        // The post-materialize re-sync drops the unloadable deck from the file too.
        await waitSnapshot(store, "re-synced snapshot dropped the dead deck") {
            $0.deckA != nil && $0.deckB == nil
        }
    }

    /// A restored suspended Auto-DJ resumes through the EXISTING resume path: `resumeAuto`
    /// re-arms the machine against live playback and starts the live deck at its cued position.
    func testRestoredAutoResumesViaExistingResumePath() async throws {
        let store = makeStore()
        let e = makeEngine(store: store)
        e.ensureEngine()
        try XCTSkipUnless(e.isReady, "no audio device on this test host")
        wireStudioResolve(e, files: ["smp_r1": try makeSineWAV(seconds: 2),
                                     "smp_r2": try makeSineWAV(seconds: 2),
                                     "smp_r3": try makeSineWAV(seconds: 2)])
        store.save(fidelitySnapshot())
        await waitUntil("snapshot on disk") { store.load() != nil }
        e.restorePersistedMixIfIdle()
        e.materializePendingRestoreIfNeeded()
        XCTAssertTrue(e.autoPaused)

        e.resumeAuto()
        XCTAssertFalse(e.autoPaused)
        XCTAssertTrue(e.isRunning, "resume starts the live deck")
        XCTAssertTrue(e.isPlaying(.a))
        XCTAssertGreaterThanOrEqual(e.position(.a), 0.49, "resumed FROM the cued position, not 0:00")

        e.stopAutoMix()
    }

    // MARK: tvOS silent resume (field session tvos-95F9E8D4/2026-09-03)

    /// The field fingerprint: cold launch → restore parked → materialize (decks CUED, nothing
    /// playing) → the OS drops the never-rendered schedules (tvOS: the first `engine.start()`
    /// renegotiates the output format and flushes them) → the user's Resume (the remote seam).
    /// Pre-fix the deck went "playing" into an empty queue — 1 Hz card writes, 10 s of silence,
    /// healed only by a skip's fresh load. The resume must re-ARM a real schedule from the cued
    /// position before play.
    func testMaterializedRestoreResumesWithARealScheduleAfterTheOSDroppedTheCues() async throws {
        let store = makeStore()
        let e = makeEngine(store: store)
        e.ensureEngine()
        try XCTSkipUnless(e.isReady, "no audio device on this test host")
        wireStudioResolve(e, files: ["smp_r1": try makeSineWAV(seconds: 2),
                                     "smp_r2": try makeSineWAV(seconds: 2),
                                     "smp_r3": try makeSineWAV(seconds: 2)])
        store.save(fidelitySnapshot())
        await waitUntil("snapshot on disk") { store.load() != nil }
        e.restorePersistedMixIfIdle()
        e.materializePendingRestoreIfNeeded()

        e.flushNodeSchedulesForTesting()    // the OS flushed the cued segments behind our back
        e.remotePlay()                      // TV Resume: "[action] mix resume (remote seam)"
        if e.autoMixing, e.autoPaused { e.resumeAuto() }   // TVRootView's Resume button tail

        XCTAssertTrue(e.isPlaying(.a), "resume starts the restored now-playing deck")
        XCTAssertTrue(e.playerNodeIsPlayingForTesting(.a))
        XCTAssertTrue(e.fileScheduledForTesting(.a),
                      "the resume re-armed a REAL schedule — not a bare play() into a flushed queue")
        XCTAssertGreaterThanOrEqual(e.deckRescheduleCountForTesting, 1, "the re-arm path actually ran")
        XCTAssertGreaterThanOrEqual(e.position(.a), 0.49, "re-armed FROM the cued position, not 0:00")
        e.stopAutoMix()
    }

    /// The guard on the fix: a NORMAL pause→resume keeps its live schedule and the ensure path
    /// must leave it alone — re-scheduling there would restart-glitch every ordinary resume.
    func testNormalPauseResumeDoesNotReschedule() async throws {
        let store = makeStore()
        let e = makeEngine(store: store)
        e.ensureEngine()
        try XCTSkipUnless(e.isReady, "no audio device on this test host")
        e.loadFile(try makeSineWAV(seconds: 2), release: nil, startMs: nil, meta: meta("sng_n"), on: .a)
        e.play(.a)
        e.pause(.a)
        e.play(.a)
        XCTAssertEqual(e.deckRescheduleCountForTesting, 0,
                       "segments stay alive across pause() — resume must not stop()+reschedule")
        XCTAssertTrue(e.playerNodeIsPlayingForTesting(.a))
        e.pause(.a)
    }

    /// An `.AVAudioEngineConfigurationChange` uninit can drop node schedules with it: the
    /// recovery lane must re-arm from the tracked position rather than bare-replaying (pause/
    /// play re-prime, heal re-kick) into empty queues.
    func testConfigChangeRecoveryReArmsDroppedSchedules() async throws {
        let store = makeStore()
        let e = makeEngine(store: store)
        e.ensureEngine()
        try XCTSkipUnless(e.isReady, "no audio device on this test host")
        e.loadFile(try makeSineWAV(seconds: 2), release: nil, startMs: nil, meta: meta("sng_c"), on: .a)
        e.play(.a)
        XCTAssertTrue(e.playerNodeIsPlayingForTesting(.a))

        e.flushNodeSchedulesForTesting()    // the uninit flushed the queues…
        e.simulateConfigChangeForTesting()  // …and the observer fires

        XCTAssertTrue(e.isPlaying(.a), "the playing intent survives")
        XCTAssertTrue(e.playerNodeIsPlayingForTesting(.a), "recovery restarted the node")
        XCTAssertTrue(e.fileScheduledForTesting(.a), "…on a re-armed schedule, not an empty queue")
        e.pause(.a)
    }

    // MARK: Relaunch must not consume an upcoming slot (field: TV build 1788406415)

    /// The field loop: an auto-mix transition BEGINS (fade starts -> the incoming track is marked
    /// played in the session log, which survives relaunches) and the app is KILLED mid-fade (the
    /// durable snapshot still shows the outgoing deck live and the incoming track merely CUED).
    /// On relaunch + Resume, the played-log re-derivation skipped the cued track and loaded one
    /// slot further -- every relaunch consumed one upcoming song ("it skips to the next song when
    /// you relaunch the app"). The restored cursor must win: deck B's songId stays UNCHANGED
    /// across restore -> resume -> restore.
    func testRelaunchResumeDoesNotConsumeAnUpcomingSlot() async throws {
        let store = makeStore()
        let sessURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("pdj-mix-sessions-\(UUID().uuidString).json")
        addTeardownBlock { try? FileManager.default.removeItem(at: sessURL) }
        let files = ["smp_q1": try makeSineWAV(seconds: 2), "smp_q2": try makeSineWAV(seconds: 2),
                     "smp_q3": try makeSineWAV(seconds: 2), "smp_q4": try makeSineWAV(seconds: 2)]
        func item(_ id: String) -> MixEngine.AutoMixItem {
            .init(loadable: MixLoadable(songId: id, title: id, artist: "Artist", bpm: 120,
                                        camelot: "8A", key: "Am", albumId: nil, lengthMs: 2_000),
                  durationMs: 2_000)
        }

        // Session 0: a real mix; a skip's fade BEGINS (incoming q2 marked played), then kill.
        let sess1 = MixSessionStore(fileURL: sessURL)
        let e1 = makeEngine(store: store)
        e1.recorder = sess1
        e1.ensureEngine()
        try XCTSkipUnless(e1.isReady, "no audio device on this test host")
        wireStudioResolve(e1, files: files)
        e1.startAutoMix([item("smp_q1"), item("smp_q2"), item("smp_q3"), item("smp_q4")],
                        shuffled: false, lead: 15, fade: 3)
        XCTAssertEqual(e1.loaded(.a)?.songId, "smp_q1")
        XCTAssertEqual(e1.loaded(.b)?.songId, "smp_q2", "on-deck next preloaded")
        e1.skipToNext(fadeSeconds: 30)          // fade STARTS: play(B) -> q2 enters the played log
        XCTAssertTrue(sess1.hasPlayed("smp_q2"), "fade start marks the incoming track played")
        await waitSnapshot(store, "mid-fade state on disk") {
            $0.deckA?.track.songId == "smp_q1" && $0.deckB?.track.songId == "smp_q2" && $0.auto != nil
        }
        await waitUntil("play log on disk") { MixSessionStore(fileURL: sessURL).hasPlayed("smp_q2") }
        e1.sessionStore = nil; e1.recorder = nil   // "kill": nothing below may write through e1
        e1.teardown()

        // Session 1: relaunch -> restore -> the TV Resume (remote seam + resumeAuto tail).
        let sess2 = MixSessionStore(fileURL: sessURL)   // reloads the still-current session's log
        XCTAssertTrue(sess2.hasPlayed("smp_q2"), "the played log SURVIVES the relaunch")
        let e2 = makeEngine(store: store)
        e2.recorder = sess2
        wireStudioResolve(e2, files: files)
        e2.restorePersistedMixIfIdle()
        e2.materializePendingRestoreIfNeeded()
        XCTAssertEqual(e2.loaded(.a)?.songId, "smp_q1", "outgoing deck restores live")
        XCTAssertEqual(e2.loaded(.b)?.songId, "smp_q2", "the cued on-deck next restores")
        XCTAssertTrue(e2.autoPaused)
        e2.remotePlay()
        if e2.autoMixing, e2.autoPaused { e2.resumeAuto() }
        XCTAssertEqual(e2.loaded(.b)?.songId, "smp_q2",
                       "resume must keep the restored cue, not skip it as played (killed fade)")
        XCTAssertEqual(e2.autoUpcoming.first?.songId, "smp_q2", "the cursor did not consume the slot")
        XCTAssertTrue(e2.autoPlayed.isEmpty, "nothing was falsely retired behind the cursor")
        await waitSnapshot(store, "resumed state persisted") { $0.deckB?.track.songId == "smp_q2" }
        e2.sessionStore = nil; e2.recorder = nil
        e2.teardown()

        // Session 2: relaunch again -- deck B UNCHANGED across the double restore.
        let sess3 = MixSessionStore(fileURL: sessURL)
        let e3 = makeEngine(store: store)
        e3.recorder = sess3
        wireStudioResolve(e3, files: files)
        e3.restorePersistedMixIfIdle()
        e3.materializePendingRestoreIfNeeded()
        XCTAssertEqual(e3.loaded(.a)?.songId, "smp_q1", "A held")
        XCTAssertEqual(e3.loaded(.b)?.songId, "smp_q2",
                       "deck B's songId is UNCHANGED across restore -> resume -> restore")
        XCTAssertEqual(e3.autoUpcoming.map(\.songId), ["smp_q2", "smp_q3", "smp_q4"],
                       "no queue slot fell out across the relaunch cycle")
        e3.stopAutoMix()
    }

    // MARK: Auto-mix repeat modes (task #52)

    /// Repeat-one: the tick's advance replays the ON-AIR track — the standby deck re-queues the
    /// current item and the cursor NEVER moves (no upcoming slot consumed, nothing falsely
    /// retired into autoPlayed, the played-log untouched beyond its idempotent dedup). Turning
    /// repeat off resumes the ordinary advance from the frozen cursor.
    func testRepeatOneReplaysWithoutCursorDrift() async throws {
        let store = makeStore()
        let e = makeEngine(store: store)
        e.ensureEngine()
        try XCTSkipUnless(e.isReady, "no audio device on this test host")
        let files = ["smp_p1": try makeSineWAV(seconds: 2), "smp_p2": try makeSineWAV(seconds: 2),
                     "smp_p3": try makeSineWAV(seconds: 2)]
        wireStudioResolve(e, files: files)
        func item(_ id: String) -> MixEngine.AutoMixItem {
            .init(loadable: MixLoadable(songId: id, title: id, artist: "Artist", bpm: 120,
                                        camelot: "8A", key: "Am", albumId: nil, lengthMs: 2_000),
                  durationMs: 2_000)
        }
        e.startAutoMix([item("smp_p1"), item("smp_p2"), item("smp_p3")],
                       shuffled: false, lead: 15, fade: 3)
        e.setAutoRepeat(.one)

        for cycle in 1...2 {                    // two replays — drift would compound
            e.backdateAutoDeckEndForTesting(secondsLeft: 1)
            e.autoFireForTesting()              // advance window → repeat-one transition begins
            e.finishAutoCrossfadeForTesting()
            XCTAssertEqual(e.onAirTrack?.songId, "smp_p1", "cycle \(cycle): the SAME track replays")
            XCTAssertEqual(e.autoUpcoming.map(\.songId), ["smp_p2", "smp_p3"],
                           "cycle \(cycle): the upcoming tail is untouched — zero cursor drift")
            XCTAssertTrue(e.autoPlayed.isEmpty, "cycle \(cycle): nothing falsely retired")
            XCTAssertTrue(e.autoMixing)
        }

        e.setAutoRepeat(.off)                   // back to normal: the next advance moves on
        e.backdateAutoDeckEndForTesting(secondsLeft: 1)
        e.autoFireForTesting()
        e.finishAutoCrossfadeForTesting()
        XCTAssertEqual(e.onAirTrack?.songId, "smp_p2", "repeat off → ordinary advance resumes")
        XCTAssertEqual(e.autoUpcoming.map(\.songId), ["smp_p3"])
        XCTAssertEqual(e.autoPlayed.map(\.songId), ["smp_p1"])
        e.stopAutoMix()
    }

    /// Repeat-all: a drained queue wraps back to its head instead of ending exhausted — both on
    /// the tick's natural end-of-runway and on an explicit last-track skip — so
    /// `autoEndedExhausted` never arms and the downloader's exhaustion re-arm has nothing to
    /// fight. Turning repeat off afterwards restores the ordinary exhaustion end.
    func testRepeatAllRestartsADrainedQueue() async throws {
        let store = makeStore()
        let e = makeEngine(store: store)
        e.ensureEngine()
        try XCTSkipUnless(e.isReady, "no audio device on this test host")
        let files = ["smp_w1": try makeSineWAV(seconds: 2), "smp_w2": try makeSineWAV(seconds: 2)]
        wireStudioResolve(e, files: files)
        func item(_ id: String) -> MixEngine.AutoMixItem {
            .init(loadable: MixLoadable(songId: id, title: id, artist: "Artist", bpm: 120,
                                        camelot: "8A", key: "Am", albumId: nil, lengthMs: 2_000),
                  durationMs: 2_000)
        }
        e.startAutoMix([item("smp_w1"), item("smp_w2")], shuffled: false, lead: 15, fade: 3)
        e.setAutoRepeat(.all)
        e.skipToNext(fadeSeconds: 0.5)          // onto the LAST track
        e.finishAutoCrossfadeForTesting()
        XCTAssertEqual(e.onAirTrack?.songId, "smp_w2")
        XCTAssertTrue(e.autoUpcoming.isEmpty, "queue drained")

        // Natural end-of-runway on the last track → WRAP, not exhaustion.
        e.backdateAutoDeckEndForTesting(secondsLeft: 1)
        e.autoFireForTesting()
        e.finishAutoCrossfadeForTesting()
        XCTAssertTrue(e.autoMixing, "the mix keeps running")
        XCTAssertFalse(e.autoEndedExhausted, "repeat-all never arms the exhaustion pickup")
        XCTAssertEqual(e.onAirTrack?.songId, "smp_w1", "wrapped to the queue head")
        XCTAssertEqual(e.autoUpcoming.map(\.songId), ["smp_w2"], "the lap restarts in order")
        XCTAssertTrue(e.autoPlayed.isEmpty, "cursor reset — nothing stuck behind it")

        // Explicit skip on the last track wraps too (skip means next; next of last = head).
        e.skipToNext(fadeSeconds: 0.5)          // onto w2 (ordinary advance)
        e.finishAutoCrossfadeForTesting()
        e.skipToNext(fadeSeconds: 0.5)          // last track → wrap
        e.finishAutoCrossfadeForTesting()
        XCTAssertTrue(e.autoMixing)
        XCTAssertEqual(e.onAirTrack?.songId, "smp_w1", "last-track skip wraps under repeat-all")

        // Repeat off → the ordinary exhaustion end (and the downloader pickup) is back.
        e.setAutoRepeat(.off)
        e.skipToNext(fadeSeconds: 0.5)
        e.finishAutoCrossfadeForTesting()
        e.backdateAutoDeckEndForTesting(secondsLeft: -1)   // expired, nothing next
        e.autoFireForTesting()
        XCTAssertFalse(e.autoMixing, "repeat off → the drained queue ends the mix")
        XCTAssertTrue(e.autoEndedExhausted, "…arming the downloader's exhaustion re-arm")
    }

    /// The repeat mode and the queue rows' crate provenance both ride the durable session:
    /// kill → restore materializes the same mode and the same per-row labels (interleave
    /// pattern intact), with legacy-optional decoding pinned by the store round-trip test.
    func testRepeatModeAndSourceLabelsSurviveRestore() async throws {
        let store = makeStore()
        let e = makeEngine(store: store)
        e.ensureEngine()
        try XCTSkipUnless(e.isReady, "no audio device on this test host")
        let files = ["smp_s1": try makeSineWAV(seconds: 2), "smp_s2": try makeSineWAV(seconds: 2),
                     "smp_s3": try makeSineWAV(seconds: 2), "smp_s4": try makeSineWAV(seconds: 2)]
        wireStudioResolve(e, files: files)
        func item(_ id: String, crate: String) -> MixEngine.AutoMixItem {
            .init(loadable: MixLoadable(songId: id, title: id, artist: "Artist", bpm: 120,
                                        camelot: "8A", key: "Am", albumId: nil, lengthMs: 2_000),
                  durationMs: 2_000, sourceLabel: crate)
        }
        // The two-crate interleave: A0,B0,A1,B1 with per-row provenance.
        e.startAutoMix([item("smp_s1", crate: "Warmup"), item("smp_s2", crate: "Bangers"),
                        item("smp_s3", crate: "Warmup"), item("smp_s4", crate: "Bangers")],
                       shuffled: false, lead: 15, fade: 3, label: "Warmup + Bangers")
        e.setAutoRepeat(.all)
        XCTAssertEqual(e.autoUpcomingDetailed.map { $0.sourceLabel }, ["Bangers", "Warmup", "Bangers"])
        await waitSnapshot(store, "labeled queue + mode persisted") {
            $0.auto?.repeatMode == "all" && $0.auto?.queue.first?.sourceLabel == "Warmup"
        }
        e.sessionStore = nil; e.recorder = nil
        e.teardown()

        let e2 = makeEngine(store: store)
        wireStudioResolve(e2, files: files)
        e2.restorePersistedMixIfIdle()
        e2.materializePendingRestoreIfNeeded()
        XCTAssertTrue(e2.autoMixing)
        XCTAssertEqual(e2.autoRepeat, .all, "the repeat mode survives the restore")
        XCTAssertEqual(e2.autoUpcomingDetailed.map { $0.sourceLabel }, ["Bangers", "Warmup", "Bangers"],
                       "per-row crate provenance survives the restore, interleave intact")
        XCTAssertEqual(e2.autoUpcomingDetailed.map { $0.loadable.songId }, ["smp_s2", "smp_s3", "smp_s4"])
        e2.stopAutoMix()
    }

    /// A session written BEFORE the loop feature (no `loopOn`/`loopUnits` keys) must still decode.
    /// The loader demands an exact `schemaVersion` match, so the loop fields had to be OPTIONAL
    /// rather than version-bumped — otherwise every saved deck session would have been discarded.
    func testPreLoopSessionJSONStillDecodes() throws {
        let legacy = """
        {"track":{"songId":"sng_old","title":"T","artist":"Aria","bpm":120,"camelot":"8A",
         "key":"Am","albumId":"alb_1","lengthMs":200000},
         "positionMs":42000,"volume":1.0,"rate":1.0,"pitch":0.0,
         "compressor":false,"reverb":false,"flanger":false,"filter":false,
         "compStrength":0.5,"reverbStrength":0.5,"flangerStrength":0.5,"filterStrength":0.5,
         "stemMode":false,"stemMuted":[],"stemVol":{}}
        """
        let ds = try JSONDecoder().decode(MixDeckSessionStore.DeckSnapshot.self, from: Data(legacy.utf8))
        XCTAssertEqual(ds.track.songId, "sng_old")
        XCTAssertEqual(ds.positionMs, 42_000)
        XCTAssertNil(ds.loopOn, "absent ⇒ no loop, not a decode failure")
        XCTAssertNil(ds.loopUnits)
    }
}

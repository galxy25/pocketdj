import XCTest
import AVFoundation
import MediaPlayer
@testable import PocketDJ

/// The MIX lane of the playback-bulletproofing plan (docs/design/playback-bulletproof-plan.md):
///  • P0-2 a restored-but-never-played mix is not a remote-command target,
///  • P0-3 materialize is inert (no session activation / engine start / write; setlist-live skip;
///    an end-of-file deck re-cues to 0:00),
///  • P0-4 interruption handling is owner-scoped and only latches an AUDIBLE mix,
///  • P0-5 a suspended Auto-DJ never restarts the engine; EOF decks never "play",
///  • P0-6 the Mix card needs real ownership,
///  • P1-9 snapshot hygiene, §3 SILENT-PLAYING detector.
/// Field fingerprint: deck A "Hold On Me" persisted at 358/358, Auto-DJ suspended, re-parked every
/// launch; every CarPlay connect / AM start / route change woke it.
@MainActor
final class MixPlaybackBulletproofTests: XCTestCase {

    override func setUp() {
        super.setUp()
        NowPlayingArbiter.shared.resetForTesting()
        NowPlayingCardPublisher.shared.resetForTesting()
    }

    override func tearDown() {
        NowPlayingCardPublisher.shared.sink = nil
        NowPlayingArbiter.shared.resetForTesting()
        super.tearDown()
    }

    // MARK: Rig

    private func makeStore() -> MixDeckSessionStore {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("pdj-mixbp-\(UUID().uuidString).json")
        addTeardownBlock { try? FileManager.default.removeItem(at: url) }
        let store = MixDeckSessionStore(fileURL: url)
        store.controlDebounceInterval = 0.05
        return store
    }

    private func makeEngine(store: MixDeckSessionStore? = nil) -> MixEngine {
        let rips = RipsStore(ripsBase: URL(string: "https://rips.test")!, session: .shared)
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("pdj-mixbp-burns-\(UUID().uuidString).json")
        addTeardownBlock { try? FileManager.default.removeItem(at: url) }
        let e = MixEngine(burns: BurnStore(rips: rips, fileURL: url))
        e.sessionStore = store
        addTeardownBlock { @MainActor in e.stopAutoMix(); e.pause(.a); e.pause(.b) }
        return e
    }

    /// Proves the host has an audio device WITHOUT touching the engine under test.
    private func requireAudioDevice() throws {
        let probe = makeEngine()
        probe.ensureEngine()
        try XCTSkipUnless(probe.isReady, "no audio device on this test host")
    }

    private func makeWAV(seconds: Double, silent: Bool = false, sr: Double = 44_100) throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("mixbp-\(UUID().uuidString).wav")
        addTeardownBlock { try? FileManager.default.removeItem(at: url) }
        let fmt = AVAudioFormat(standardFormatWithSampleRate: sr, channels: 2)!
        let file = try AVAudioFile(forWriting: url, settings: fmt.settings)
        let frames = AVAudioFrameCount(seconds * sr)
        let buf = AVAudioPCMBuffer(pcmFormat: fmt, frameCapacity: frames)!
        buf.frameLength = frames
        for ch in 0..<2 {
            let p = buf.floatChannelData![ch]
            for i in 0..<Int(frames) { p[i] = silent ? 0 : sinf(Float(i) * 2 * .pi * 440 / Float(sr)) * 0.5 }
        }
        try file.write(from: buf)
        return url
    }

    private func wire(_ e: MixEngine, _ ids: [String], seconds: Double = 2, silent: Bool = false) throws {
        var files: [String: URL] = [:]
        for id in ids { files[id] = try makeWAV(seconds: seconds, silent: silent) }
        e.studioResolve = { id in
            guard let url = files[id] else { return nil }
            return (url: url, release: nil, title: id, lengthMs: Int(seconds * 1000))
        }
    }

    private func meta(_ id: String) -> MixEngine.LoadedTrack {
        MixEngine.LoadedTrack(songId: id, title: "Song \(id)", artist: "Artist",
                              bpm: 120, camelot: "8A", key: "Am", albumId: nil)
    }

    private func track(_ id: String, lengthMs: Int = 2_000) -> MixDeckSessionStore.TrackRef {
        .init(songId: id, title: "Title \(id)", artist: "Artist", bpm: 128, camelot: "9A",
              key: "Em", albumId: nil, lengthMs: lengthMs)
    }

    private func deck(_ id: String, positionMs: Int, lengthMs: Int = 2_000) -> MixDeckSessionStore.DeckSnapshot {
        .init(track: track(id, lengthMs: lengthMs), positionMs: positionMs, volume: 1, rate: 1, pitch: 0,
              compressor: false, reverb: false, flanger: false, filter: false,
              compStrength: 0.5, reverbStrength: 0.5, flangerStrength: 0.5, filterStrength: 0.5,
              stemMode: false, stemMuted: [], stemVol: [:])
    }

    private func autoSnap(_ ids: [String], nextToLoad: Int, liveDeck: String = "A") -> MixDeckSessionStore.AutoSnapshot {
        .init(queue: ids.map { .init(track: track($0), durationMs: 2_000) },
              livePos: 0, nextToLoad: nextToLoad, liveDeck: liveDeck, sourceLabel: "Crate",
              leadSeconds: 12, fadeSeconds: 4, fxGlide: false, mixGlide: false)
    }

    private func waitUntil(_ message: String, _ predicate: () -> Bool) async {
        for _ in 0..<400 {
            if predicate() { return }
            try? await Task.sleep(nanoseconds: 5_000_000)
        }
        XCTFail("timed out waiting: \(message)")
    }

    /// Save + land a snapshot on disk, park it on `e` (launch task), and materialize it (Mix surface).
    private func restore(_ e: MixEngine, _ store: MixDeckSessionStore,
                         _ snap: MixDeckSessionStore.Snapshot, materialize: Bool = true) async {
        store.save(snap)
        await waitUntil("snapshot on disk") { store.load() != nil }
        e.restorePersistedMixIfIdle()
        if materialize { e.materializePendingRestoreIfNeeded() }
    }

    // MARK: P0-2 — a restored, never-played mix is not a remote target

    func testRestoredNeverPlayedMixRefusesRemotePlayUntilPlayedInApp() async throws {
        try requireAudioDevice()
        let store = makeStore()
        let e = makeEngine(store: store)
        try wire(e, ["smp_a"])
        var cards: [NowPlayingCardPublisher.Publication] = []
        NowPlayingCardPublisher.shared.sink = { cards.append($0) }
        await restore(e, store, .init(deckA: deck("smp_a", positionMs: 500), deckB: nil, crossfader: 0,
                                      leadDeck: "A", auto: nil, wasRunning: true, updatedAt: 0))
        XCTAssertEqual(e.loaded(.a)?.songId, "smp_a")
        XCTAssertFalse(e.hasSoundedThisProcess)

        // The head unit's play-on-connect fans out to the Mix target.
        XCTAssertEqual(e.handleRemoteCommand(.play), .commandFailed)
        XCTAssertEqual(e.handleRemoteCommand(.toggle), .commandFailed)
        XCTAssertFalse(e.isRunning, "a parked restore never wakes from a remote command")
        XCTAssertNil(NowPlayingArbiter.shared.owner, "…and never claims the card")
        XCTAssertTrue(cards.filter { $0.writer == "mix" }.isEmpty, "no Mix card publication")

        // An explicit in-app play makes the Mix a legitimate remote target.
        e.play(.a)
        XCTAssertTrue(e.hasSoundedThisProcess)
        e.pause(.a)
        XCTAssertEqual(e.handleRemoteCommand(.play), .success)
        XCTAssertTrue(e.isRunning, "the target works once the user played the mix")
    }

    /// `remotePlay()` itself stays ungated — TV Resume / CarPlay's Mix row / Siri call it directly.
    func testDirectRemotePlayStillResumesARestoredMix() async throws {
        try requireAudioDevice()
        let store = makeStore()
        let e = makeEngine(store: store)
        try wire(e, ["smp_a"])
        await restore(e, store, .init(deckA: deck("smp_a", positionMs: 500), deckB: nil, crossfader: 0,
                                      leadDeck: "A", auto: nil, wasRunning: true, updatedAt: 0))
        e.remotePlay()
        XCTAssertTrue(e.isPlaying(.a))
        XCTAssertGreaterThanOrEqual(e.position(.a), 0.49)
    }

    // MARK: P0-3 — materialize is inert

    func testMaterializeActivatesNoSessionStartsNoEngineAndWritesNothing() async throws {
        try requireAudioDevice()
        // Two store instances on ONE file — the previous run's writer and this launch's reader —
        // exactly like a relaunch (a launch store holds no in-memory session until a real write).
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("pdj-mixbp-\(UUID().uuidString).json")
        addTeardownBlock { try? FileManager.default.removeItem(at: url) }
        let previousRun = MixDeckSessionStore(fileURL: url)
        let store = MixDeckSessionStore(fileURL: url)
        let e = makeEngine(store: store)          // never touched before the restore
        try wire(e, ["smp_a", "smp_b", "smp_c"])
        previousRun.save(.init(deckA: deck("smp_a", positionMs: 500), deckB: deck("smp_b", positionMs: 0),
                         crossfader: 0.2, leadDeck: "A", auto: autoSnap(["smp_a", "smp_b", "smp_c"], nextToLoad: 2),
                         wasRunning: true, updatedAt: 0))
        await waitUntil("snapshot on disk") { store.load() != nil }
        let stampBefore = try XCTUnwrap(store.load()?.updatedAt)

        e.restorePersistedMixIfIdle()
        e.materializePendingRestoreIfNeeded()

        XCTAssertEqual(e.loaded(.a)?.songId, "smp_a", "decks materialized")
        XCTAssertTrue(e.isReady, "graph built")
        XCTAssertFalse(e.engineIsRunningForTesting, "INERT: no engine.start() for a parked restore")
        XCTAssertEqual(e.audioSessionActivationsForTesting, 0, "INERT: no AVAudioSession activation")
        XCTAssertEqual(e.engineStartAttemptsForTesting, 0)
        try await Task.sleep(nanoseconds: 300_000_000)   // give a (wrong) async write time to land
        XCTAssertEqual(store.load()?.updatedAt, stampBefore, "a restore is not a write")

        e.play(.a)                                         // the first REAL transport activates
        XCTAssertEqual(e.audioSessionActivationsForTesting, 1)
        XCTAssertTrue(e.engineIsRunningForTesting)
        XCTAssertTrue(e.playerNodeIsPlayingForTesting(.a))
        XCTAssertTrue(e.fileScheduledForTesting(.a), "cued-on-a-stopped-engine schedule re-armed before play")
    }

    func testLaunchTaskSkipsMaterializeWhileASetlistIsLive() async throws {
        try requireAudioDevice()
        let store = makeStore()
        let e = makeEngine(store: store)
        try wire(e, ["smp_a"])
        var live = true
        e.setlistIsLive = { live }
        e.materializePendingRestoreIfNeeded()   // the Mix surface asked first (macOS landing tab)
        await restore(e, store, .init(deckA: deck("smp_a", positionMs: 500), deckB: nil, crossfader: 0,
                                      leadDeck: "A", auto: nil, wasRunning: true, updatedAt: 0),
                      materialize: false)
        XCTAssertNil(e.loaded(.a), "a live set list keeps the mix parked")
        XCTAssertTrue(e.hasParkedRestore)
        XCTAssertEqual(e.parkedRestoreSummary?.title, "Title smp_a", "the parked summary still renders")

        live = false
        e.materializePendingRestoreIfNeeded()   // the next Mix-surface request finishes the job
        XCTAssertEqual(e.loaded(.a)?.songId, "smp_a")
        XCTAssertFalse(e.hasParkedRestore)
    }

    // MARK: P0-3.5 + P0-5 — an end-of-file deck never "plays"

    func testEndOfFileDeckIsRecuedAndRemotePlayAdvancesTheSuspendedMix() async throws {
        try requireAudioDevice()
        let store = makeStore()
        let e = makeEngine(store: store)
        try wire(e, ["smp_a", "smp_b", "smp_c"])
        await restore(e, store, .init(deckA: deck("smp_a", positionMs: 2_000), deckB: deck("smp_b", positionMs: 0),
                                      crossfader: 0, leadDeck: "A",
                                      auto: autoSnap(["smp_a", "smp_b", "smp_c"], nextToLoad: 2),
                                      wasRunning: true, updatedAt: 0))
        XCTAssertEqual(e.loaded(.a)?.songId, "smp_a")
        XCTAssertEqual(e.position(.a), 0, accuracy: 0.01, "an end-of-file deck re-cues to 0:00")
        XCTAssertTrue(e.deckExhaustedFromRestoreForTesting(.a))
        XCTAssertTrue(e.autoPaused)

        e.remotePlay()   // lock screen / car ▶ over the suspended restore

        XCTAssertFalse(e.isPlaying(.a), "the finished deck is not resumed (no silent 358/358 owner)")
        XCTAssertTrue(e.isPlaying(.b), "the machine advanced to the cued next track")
        XCTAssertFalse(e.autoPaused, "the restored Auto-DJ actually resumed")
        XCTAssertTrue(NowPlayingArbiter.shared.owner === e)
    }

    func testTickRetiresADeckReachingItsEndUnderAPausedAuto() async throws {
        try requireAudioDevice()
        let store = makeStore()
        let e = makeEngine(store: store)
        try wire(e, ["smp_a", "smp_b", "smp_c"])
        await restore(e, store, .init(deckA: deck("smp_a", positionMs: 500), deckB: deck("smp_b", positionMs: 0),
                                      crossfader: 0, leadDeck: "A",
                                      auto: autoSnap(["smp_a", "smp_b", "smp_c"], nextToLoad: 2),
                                      wasRunning: true, updatedAt: 0))
        e.play(.a)                         // hand-started under the suspended machine
        XCTAssertTrue(e.autoMixing && e.autoPaused)
        e.seek(.a, toSeconds: e.duration(.a))
        e.tickFireForTesting()
        XCTAssertFalse(e.isPlaying(.a), "a deck at its end under a PAUSED machine retires")
        XCTAssertTrue(e.autoMixing, "…without ending the parked Auto-DJ")
    }

    func testSuspendedRestoreNeverRestartsTheEngineFromTicksRecoveryOrRouteChanges() async throws {
        try requireAudioDevice()
        let store = makeStore()
        let e = makeEngine(store: store)
        try wire(e, ["smp_a", "smp_b", "smp_c"])
        await restore(e, store, .init(deckA: deck("smp_a", positionMs: 500), deckB: deck("smp_b", positionMs: 0),
                                      crossfader: 0, leadDeck: "A",
                                      auto: autoSnap(["smp_a", "smp_b", "smp_c"], nextToLoad: 2),
                                      wasRunning: true, updatedAt: 0))
        XCTAssertTrue(e.autoMixing && e.autoPaused)
        XCTAssertFalse(e.mixWantsAudio)
        for _ in 0..<20 { e.tickFireForTesting() }
        e.simulateEngineRecoveryForTesting()
        #if os(iOS)
        e.handleRouteChange([AVAudioSessionRouteChangeReasonKey: AVAudioSession.RouteChangeReason.newDeviceAvailable.rawValue])
        #endif
        XCTAssertEqual(e.engineStartAttemptsForTesting, 0, "a suspended mix wants no audio — never restart")
        XCTAssertEqual(e.audioSessionActivationsForTesting, 0, "…and never re-grab the session")
        XCTAssertFalse(e.engineIsRunningForTesting)
    }

    // MARK: P0-4 — interruptions are owner-scoped

    #if os(iOS)
    func testInterruptionEndedDoesNotResumeTheMixOnceAnotherEngineOwnsTheCard() async throws {
        try requireAudioDevice()
        let e = makeEngine()
        e.ensureEngine()
        e.loadFile(try makeWAV(seconds: 6), release: nil, startMs: nil, meta: meta("x"), on: .a)
        e.play(.a)
        XCTAssertTrue(NowPlayingArbiter.shared.owner === e)

        e.handleInterruption(.began, info: [:])           // the set list's AM start interrupts us
        XCTAssertFalse(e.isPlaying(.a))
        let setlist = NSObject()
        NowPlayingArbiter.shared.claim(setlist)            // PlayerEngine claims the card
        e.handleInterruption(.ended, info: [AVAudioSessionInterruptionOptionKey:
                                            AVAudioSession.InterruptionOptions.shouldResume.rawValue])
        XCTAssertFalse(e.isRunning, "a displaced mix never resumes over the set list")
        XCTAssertTrue(NowPlayingArbiter.shared.owner === setlist, "ownership unchanged")
    }

    func testInterruptionEndedStillResumesAnOwningMix() async throws {
        try requireAudioDevice()
        let e = makeEngine()
        e.ensureEngine()
        e.loadFile(try makeWAV(seconds: 6), release: nil, startMs: nil, meta: meta("x"), on: .a)
        e.play(.a)
        e.handleInterruption(.began, info: [:])           // phone call over the mix the user owns
        XCTAssertFalse(e.isPlaying(.a))
        e.handleInterruption(.ended, info: [AVAudioSessionInterruptionOptionKey:
                                            AVAudioSession.InterruptionOptions.shouldResume.rawValue])
        XCTAssertTrue(e.isPlaying(.a), "the owner still auto-resumes after a call")
    }

    func testInterruptionBeganDoesNotLatchASilentEndOfFileDeck() async throws {
        try requireAudioDevice()
        let e = makeEngine()
        e.ensureEngine()
        e.loadFile(try makeWAV(seconds: 2), release: nil, startMs: nil, meta: meta("x"), on: .a)
        e.play(.a)
        e.seek(.a, toSeconds: e.duration(.a))              // "playing" with nothing left to render
        XCTAssertTrue(e.isPlaying(.a))
        e.handleInterruption(.began, info: [:])
        e.handleInterruption(.ended, info: [AVAudioSessionInterruptionOptionKey:
                                            AVAudioSession.InterruptionOptions.shouldResume.rawValue])
        XCTAssertFalse(e.isPlaying(.a), "an inaudible deck never latches → .ended has nothing to resume")
    }
    #endif

    func testDisplacementPausesASilentGraphAndDropsResumeLatches() async throws {
        try requireAudioDevice()
        let e = makeEngine()
        e.ensureEngine()
        e.loadFile(try makeWAV(seconds: 6), release: nil, startMs: nil, meta: meta("x"), on: .a)
        e.play(.a)
        e.remotePause()                                     // lock-screen ⏸ → pause memory {A}
        XCTAssertTrue(e.engineIsRunningForTesting)
        let setlist = NSObject()
        NowPlayingArbiter.shared.claim(setlist)
        XCTAssertFalse(e.engineIsRunningForTesting, "a silent graph stops holding the session")
        // The pause memory is gone: a later direct remotePlay falls back to the now-playing deck
        // (still resumable) rather than replaying a stale memory — and the gesture still works.
        e.remotePlay()
        XCTAssertTrue(e.isPlaying(.a))
        XCTAssertTrue(e.engineIsRunningForTesting, "the next real play restarts the engine")
    }

    // MARK: P0-6 — the Mix card needs real ownership

    func testMixCardIsNotWrittenWhileNobodyOwnsTheCard() async throws {
        try requireAudioDevice()
        let e = makeEngine()
        e.ensureEngine()
        e.loadFile(try makeWAV(seconds: 6), release: nil, startMs: nil, meta: meta("x"), on: .a)
        var cards: [NowPlayingCardPublisher.Publication] = []
        NowPlayingCardPublisher.shared.sink = { cards.append($0) }
        e.play(.a)
        XCTAssertTrue(cards.contains { $0.writer == "mix" }, "a cold in-app play still claims + publishes")
        e.pause(.a)
        NowPlayingArbiter.shared.resign(e)                 // the gap between two set-list tracks
        cards.removeAll()
        e.setRate(1.1, on: .a)
        e.seek(.a, toSeconds: 1)
        XCTAssertTrue(cards.filter { $0.writer == "mix" }.isEmpty, "no 'Hold On Me' flash into the gap")
    }

    // MARK: §3 — SILENT-PLAYING detector

    func testSilentPlayingDetectorRetiresAPlayingDeckThatRendersNoSignal() async throws {
        try requireAudioDevice()
        let e = makeEngine()
        e.ensureEngine()
        e.loadFile(try makeWAV(seconds: 30, silent: true), release: nil, startMs: nil, meta: meta("s"), on: .a)
        e.play(.a)
        XCTAssertTrue(e.isPlaying(.a))
        let t0 = Date()
        e.silentPlayingCheck(now: t0.addingTimeInterval(5))
        e.silentPlayingCheck(now: t0.addingTimeInterval(6))
        XCTAssertTrue(e.isPlaying(.a), "two strikes are not enough")
        e.silentPlayingCheck(now: t0.addingTimeInterval(7))
        XCTAssertFalse(e.isPlaying(.a), "three consecutive silent checks retire the deck")
    }

    func testSilentPlayingDetectorIgnoresAnIntentionallyMutedDeck() async throws {
        try requireAudioDevice()
        let e = makeEngine()
        e.ensureEngine()
        e.loadFile(try makeWAV(seconds: 30, silent: true), release: nil, startMs: nil, meta: meta("s"), on: .a)
        e.setVolume(0, on: .a)
        e.play(.a)
        let t0 = Date()
        for i in 0..<6 { e.silentPlayingCheck(now: t0.addingTimeInterval(5 + Double(i))) }
        XCTAssertTrue(e.isPlaying(.a), "volume 0 is the user's choice, not a silent failure")
    }

    // MARK: P1-9 — snapshot hygiene

    func testSilentRunPlayheadIsNeverPersisted() async throws {
        try requireAudioDevice()
        let store = makeStore()
        let e = makeEngine(store: store)
        e.ensureEngine()
        e.loadFile(try makeWAV(seconds: 30, silent: true), release: nil, startMs: nil, meta: meta("s"), on: .a)
        await waitUntil("load persisted") { store.load()?.deckA?.track.songId == "s" }
        e.play(.a)
        await waitUntil("run transition persisted") { store.load()?.wasRunning == true }
        let persisted = store.load()?.deckA?.positionMs ?? -1
        e.backdateRunningSinceForTesting(seconds: 10)       // a long run with zero signal
        try await Task.sleep(nanoseconds: 400_000_000)
        e.tickFireForTesting()
        e.pause(.a)                                         // the pause transition would write the playhead
        try await Task.sleep(nanoseconds: 300_000_000)
        XCTAssertGreaterThan(e.position(.a), 0.2, "the playhead did advance in memory")
        XCTAssertEqual(store.load()?.deckA?.positionMs, persisted,
                       "a playhead advanced over silence is never persisted")
    }
}

/// `MixDeckSessionStore.load()` drops a FINISHED mix (P1-9).
@MainActor
final class MixDeckSessionExhaustionTests: XCTestCase {
    private func makeStore() -> MixDeckSessionStore {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("pdj-mixex-\(UUID().uuidString).json")
        addTeardownBlock { try? FileManager.default.removeItem(at: url) }
        return MixDeckSessionStore(fileURL: url)
    }

    private func deck(_ id: String, positionMs: Int, lengthMs: Int = 358_000) -> MixDeckSessionStore.DeckSnapshot {
        .init(track: .init(songId: id, title: id, artist: "A", bpm: nil, camelot: nil, key: nil,
                           albumId: nil, lengthMs: lengthMs),
              positionMs: positionMs, volume: 1, rate: 1, pitch: 0,
              compressor: false, reverb: false, flanger: false, filter: false,
              compStrength: 0.5, reverbStrength: 0.5, flangerStrength: 0.5, filterStrength: 0.5,
              stemMode: false, stemMuted: [], stemVol: [:])
    }

    private func auto(_ n: Int, nextToLoad: Int, repeatMode: String? = nil) -> MixDeckSessionStore.AutoSnapshot {
        .init(queue: (0..<n).map { .init(track: .init(songId: "q\($0)", title: "q", artist: "a", bpm: nil, camelot: nil,
                                                      key: nil, albumId: nil, lengthMs: 1_000), durationMs: 1_000) },
              livePos: max(0, n - 1), nextToLoad: nextToLoad, liveDeck: "A", sourceLabel: nil,
              leadSeconds: 12, fadeSeconds: 4, fxGlide: false, mixGlide: false, repeatMode: repeatMode)
    }

    private func roundTrip(_ snap: MixDeckSessionStore.Snapshot) async -> MixDeckSessionStore.Snapshot? {
        let store = makeStore()
        store.save(snap)
        store.flush()
        return store.load()
    }

    func testDeckAtEndWithEmptyAutoQueueIsDropped() async {
        let loaded = await roundTrip(.init(deckA: deck("hold_on_me", positionMs: 358_000), deckB: nil,
                                           crossfader: 0, leadDeck: "A", auto: auto(0, nextToLoad: 0),
                                           wasRunning: false, updatedAt: 0))
        XCTAssertNil(loaded, "a finished deck with nothing to follow is not a session")
    }

    func testDeckAtEndWithDrainedQueueIsDropped() async {
        let loaded = await roundTrip(.init(deckA: deck("hold_on_me", positionMs: 357_800), deckB: nil,
                                           crossfader: 0, leadDeck: "A", auto: auto(3, nextToLoad: 3),
                                           wasRunning: false, updatedAt: 0))
        XCTAssertNil(loaded)
    }

    func testDeckAtEndThatCanStillAdvanceIsKept() async {
        let advancing = await roundTrip(.init(deckA: deck("a", positionMs: 358_000), deckB: nil,
                                              crossfader: 0, leadDeck: "A", auto: auto(172, nextToLoad: 2),
                                              wasRunning: false, updatedAt: 0))
        XCTAssertNotNil(advancing, "the Auto-DJ cursor can still move on")
        let standby = await roundTrip(.init(deckA: deck("a", positionMs: 358_000), deckB: deck("b", positionMs: 0),
                                            crossfader: 0, leadDeck: "A", auto: nil,
                                            wasRunning: false, updatedAt: 0))
        XCTAssertNotNil(standby, "the other deck still has audio")
        let repeating = await roundTrip(.init(deckA: deck("a", positionMs: 358_000), deckB: nil,
                                              crossfader: 0, leadDeck: "A", auto: auto(3, nextToLoad: 3, repeatMode: "all"),
                                              wasRunning: false, updatedAt: 0))
        XCTAssertNotNil(repeating, "repeat-all wraps")
        let mid = await roundTrip(.init(deckA: deck("a", positionMs: 120_000), deckB: nil,
                                        crossfader: 0, leadDeck: "A", auto: nil,
                                        wasRunning: false, updatedAt: 0))
        XCTAssertNotNil(mid, "a mid-track deck is a session")
    }
}

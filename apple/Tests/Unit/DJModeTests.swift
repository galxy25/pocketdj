import AVFoundation
import XCTest
@testable import PocketDJ

/// NOW PLAYING DJ MODE — the integration (docs/design/np-dj-mode.md §8).
///
///  • PURE: the status chip words, the membership inversion, the snapshot field.
///  • `NowPlayingDSP` TAIL DECK over real sine WAVs (skipped without an audio device): the
///    handover keeps the playhead, the fade reaches 0 / 1, the tail is released, pause / skip /
///    seek mid-transition, the listener touch, and the decline paths.
///  • `SetlistPlayer` DJ over burned WAVs: DJ ⇒ Mix Mode, Mix off ⇒ DJ off, the advance at the
///    FADE START, snapshot round-trip (held), the Mix tab suspends it, the selector respects
///    fixed rows + the buffered next, a non-local next is a normal advance, and leveling lands.
///
/// Every wait polls the ASSERTED condition (no fixed sleeps).
@MainActor
final class DJModeTests: XCTestCase {
    private var saved: (tick: Double, lead: Double, ramp: Double, debounce: Double, retry: Double)!

    override func setUp() {
        super.setUp()
        saved = (NowPlayingDSP.djTickSeconds, NowPlayingDSP.djHandoverLead, NowPlayingDSP.levelRampSeconds,
                 SetlistPlayer.djReplanDebounceSeconds, NowPlayingDSP.djRetrySeconds)
        NowPlayingDSP.levelRampSeconds = 0.2
        SetlistPlayer.djReplanDebounceSeconds = 0.05
        NowPlayingDSP.djRetrySeconds = 0.2
    }

    override func tearDown() {
        NowPlayingDSP.djTickSeconds = saved.tick
        NowPlayingDSP.djHandoverLead = saved.lead
        NowPlayingDSP.levelRampSeconds = saved.ramp
        SetlistPlayer.djReplanDebounceSeconds = saved.debounce
        NowPlayingDSP.djRetrySeconds = saved.retry
        super.tearDown()
    }

    private func waitUntil(_ message: String, timeout: TimeInterval = 8, _ predicate: () -> Bool) async {
        await StemAudioProbe.wait(timeout: timeout, until: predicate)
        XCTAssertTrue(predicate(), "timed out waiting: \(message)")
    }

    // MARK: - Pure

    func testIndicatorWords() {
        XCTAssertNil(DJMode.Indicator.off.chipText)
        XCTAssertEqual(DJMode.Indicator.nextReady.chipText, "DJ — next mixes in")
        XCTAssertEqual(DJMode.Indicator.bufferingNext(0.42).chipText, "DJ — buffering next 42%")
        XCTAssertEqual(DJMode.Indicator.bufferingNext(nil).chipText, "DJ — buffering next")
        XCTAssertEqual(DJMode.Indicator.mixing.chipText, "DJ — mixing")
        XCTAssertNotNil(DJMode.Indicator.suspended.chipText)
        XCTAssertTrue(DJMode.Indicator.bufferingNext(nil).isBuffering)
        XCTAssertFalse(DJMode.Indicator.nextReady.isBuffering)
        // The Mix Mode chip carries the DJ words after its own (and VoiceOver reads all three).
        let chip = MixModeChipLabel.Content(indicator: .engaged, note: "Clean edition", dj: "DJ — mixing")
        XCTAssertEqual(chip?.spoken, "Mixing · DJ — mixing · Clean edition")
        XCTAssertEqual(MixModeChipLabel.Content(indicator: .engaged, note: nil)?.spoken, "Mixing",
                       "no DJ words: the Mix Mode chip is exactly what it was")
    }

    func testMembershipInvertsTheFlattenedCollections() {
        let m = DJMode.membership([
            .init(id: "p1", kind: "pocket", name: "P", songIds: ["a", "b"]),
            .init(id: "l1", kind: "playlist", name: "L", songIds: ["b", "c"]),
        ])
        XCTAssertEqual(m["a"], ["p1"])
        XCTAssertEqual(m["b"], ["p1", "l1"])
        XCTAssertEqual(m["c"], ["l1"])
        XCTAssertNil(m["z"])
    }

    func testSnapshotCarriesDJModeAndOldSnapshotsDecode() throws {
        var st = DJModeState(enabled: true)
        st.planner = DJSetPlanner.State(seed: 42)
        let snap = PlaybackSessionStore.Snapshot(
            sessionId: "pses_dj", source: .init(kind: "playlist", id: "p", name: "P"),
            queue: [.init(songId: "s1", title: "S1", artist: "A", lengthMs: nil, repeatCount: nil)],
            index: 0, positionMs: 0, isPlaying: false, npMixMode: NPMixModeState(enabled: true),
            djMode: st, updatedAt: 0)
        let data = try JSONEncoder().encode(snap)
        XCTAssertEqual(try JSONDecoder().decode(PlaybackSessionStore.Snapshot.self, from: data).djMode, st)
        var obj = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        obj["djMode"] = nil
        let old = try JSONDecoder().decode(PlaybackSessionStore.Snapshot.self, from: JSONSerialization.data(withJSONObject: obj))
        XCTAssertNil(old.djMode, "a pre-DJ snapshot restores with DJ Mode off")
        XCTAssertEqual(try JSONDecoder().decode(DJModeState.self, from: Data(#"{"enabled":true}"#.utf8)),
                       DJModeState(enabled: true), "no planner yet decodes")
    }

    // MARK: - NowPlayingDSP tail deck (real graph)

    private func makeBurns() -> BurnStore {
        let rips = RipsStore(ripsBase: URL(string: "https://rips.test")!, session: URLSession(configuration: .ephemeral))
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("pdj-dj-burn-\(UUID().uuidString).json")
        addTeardownBlock { try? FileManager.default.removeItem(at: url) }
        return BurnStore(rips: rips, fileURL: url)
    }

    private func wav(_ seconds: Double, hz: Double = 440) throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("pdj-dj-\(UUID().uuidString).wav")
        addTeardownBlock { try? FileManager.default.removeItem(at: url) }
        let sr = 44_100.0
        let fmt = AVAudioFormat(standardFormatWithSampleRate: sr, channels: 2)!
        let file = try AVAudioFile(forWriting: url, settings: fmt.settings)
        let frames = AVAudioFrameCount(seconds * sr)
        let buf = AVAudioPCMBuffer(pcmFormat: fmt, frameCapacity: frames)!
        buf.frameLength = frames
        for c in 0..<2 {
            for i in 0..<Int(frames) { buf.floatChannelData![c][i] = Float(sin(2 * .pi * hz * Double(i) / sr)) * 0.2 }
        }
        try file.write(from: buf)
        return url
    }

    /// A DSP playing A (`seconds` long) near its end, with B on disk to mix into.
    private func playingDSP(aSeconds: Double = 8, at: Double = 4) throws -> (NowPlayingDSP, URL, URL) {
        let a = try wav(aSeconds), b = try wav(8, hz: 660)
        let d = NowPlayingDSP(burns: makeBurns())
        addTeardownBlock { @MainActor in d.disengage() }
        d.engage(url: a, startMs: nil, lengthMs: nil, atSeconds: at, songId: "A", play: true)
        try XCTSkipUnless(d.isReady, "no audio device on this test host")
        return (d, a, b)
    }

    private func spec(_ b: URL, preRoll: Double = 0.4, fade: Double = 0.6, postRoll: Double = 0.4,
                      outRate: Double = 1.05, inRate: Double = 0.95, texture: Bool = true,
                      release: (() -> Void)? = nil) -> NowPlayingDSP.DJTransition {
        let plan = AutoTransition.Plan(isGlide: true, preRollSeconds: preRoll, fadeSeconds: fade,
                                       postRollSeconds: postRoll, fadeRestore: nil)
        return NowPlayingDSP.DJTransition(
            plan: plan, outRate: outRate, outPitch: 0.5, inRate: inRate, inPitch: -0.5,
            texture: texture ? (.filter, 0.6) : nil,
            outgoingBeat: .init(bpm: 120), incoming: .init(songId: "B", url: b, startMs: nil, lengthMs: nil,
                                                           release: release, beat: .init(bpm: 120), levelDb: -3))
    }

    private func rendering(_ d: NowPlayingDSP) async {
        await waitUntil("A rendering") { d.isPlaying && d.mainNodePlayingForTesting() && d.currentTime > 4.05 }
    }

    /// THE HANDOVER keeps the playhead: the outgoing moves onto the tail at the frame the main
    /// voice was at, so the song clock never jumps (± a tick) and the main voice stops.
    func testHandoverMovesTheOutgoingOntoTheTailAtItsPlayhead() async throws {
        let (d, _, b) = try playingDSP()
        await rendering(d)
        let nodes = d.attachedNodeCountForTesting
        let before = d.currentTime
        let t0 = Date()
        XCTAssertNil(d.beginDJTransition(spec(b, preRoll: 1.5)))
        XCTAssertEqual(d.djPhase, .preRoll)
        XCTAssertTrue(d.tailDeckActiveForTesting)
        XCTAssertEqual(d.attachedNodeCountForTesting, nodes + 7, "the tail deck's 7 nodes join the engine")
        await waitUntil("handover landed: the main voice stopped, the tail carries the song") {
            !d.mainNodePlayingForTesting() && d.tailPlayingForTesting && d.tailPlayheadForTesting() != nil
        }
        let elapsed = Date().timeIntervalSince(t0)
        let tailPos = try XCTUnwrap(d.tailPlayheadForTesting())
        // The ramp bends the tempo a little (≤ +5 %): the song advanced ~elapsed at ~1×.
        XCTAssertEqual(tailPos, before + elapsed, accuracy: 0.2, "the tail plays on from the outgoing's playhead")
        XCTAssertEqual(d.currentTime, tailPos, accuracy: 0.1, "the deck's clock rides the tail")
        XCTAssertEqual(d.loadedSongId, "A", "still the outgoing song during the pre-roll")
        XCTAssertEqual(d.tailGainForTesting ?? 0, 1, accuracy: 0.01, "the handover lands the tail at full gain")
    }

    /// FADE: the advance fires once at the fade start, the incoming comes up from 0 on the main
    /// chain at its glide target while the tail goes 1 → 0; at the fade's end the tail is RELEASED
    /// (nodes detached), the main gain is 1, and the post-roll eases the overlays back to identity.
    func testFadeReachesZeroAndOneAndTheTailIsReleased() async throws {
        let (d, _, b) = try playingDSP()
        await rendering(d)
        let nodes = d.attachedNodeCountForTesting
        var advanced: [String] = []
        var engaged: [String] = []
        var ended: [String] = []
        var released = 0
        d.onDJFadeStart = { advanced.append($0); return true }
        d.onDJIncomingEngaged = { id, _, _ in engaged.append(id) }
        d.onDJTransitionEnded = { _, how in ended.append(how) }
        XCTAssertNil(d.beginDJTransition(spec(b, release: { released += 1 })))
        await waitUntil("fade") { d.djPhase == .fade }
        XCTAssertEqual(advanced, ["B"], "the host advances at the FADE START")
        XCTAssertEqual(engaged, ["B"])
        XCTAssertEqual(d.loadedSongId, "B", "the incoming is the current song from the fade start")
        XCTAssertLessThan(d.mainFadeGainForTesting, 0.6, "the incoming starts silent")
        XCTAssertEqual(d.timePitchRate, 0.95, accuracy: 1e-3, "the incoming is pinned at its glide target")
        XCTAssertEqual(d.tailRateForTesting ?? 0, 1.05, accuracy: 1e-3, "the outgoing is pinned at its target")
        XCTAssertFalse(d.filterBandBypassed, "the texture sweeps the incoming's filter")
        XCTAssertEqual(d.levelTargetDb, -3, accuracy: 1e-3, "the incoming's leveling gain")
        await waitUntil("the incoming's gain lands in a few ms (never a step)") { abs(d.levelTrimGainDb + 3) < 1e-3 }
        await waitUntil("fade landed: the tail released") { d.djPhase != .fade }
        XCTAssertFalse(d.tailDeckActiveForTesting)
        XCTAssertEqual(d.attachedNodeCountForTesting, nodes, "every tail node detached")
        XCTAssertEqual(d.mainFadeGainForTesting, 1)
        await waitUntil("post-roll done") { d.djPhase == .idle }
        XCTAssertEqual(ended, ["complete"])
        XCTAssertEqual(d.timePitchRate, 1, accuracy: 1e-3, "back to the listener's tempo")
        XCTAssertEqual(d.timePitchPitchCents, 0, accuracy: 1e-3)
        XCTAssertTrue(d.filterBandBypassed, "the texture swept back out")
        XCTAssertTrue(d.isPlaying)
        XCTAssertTrue(d.mainNodePlayingForTesting())
        XCTAssertEqual(released, 0, "the incoming's scope is the main chain's now (released at its disengage)")
        d.disengage()
        XCTAssertEqual(released, 1)
    }

    /// PAUSE mid-transition pauses BOTH decks; ▶ resumes both and the transition completes.
    func testPauseMidTransitionPausesBothDecksAndResumes() async throws {
        let (d, _, b) = try playingDSP()
        await rendering(d)
        d.onDJFadeStart = { _ in true }
        XCTAssertNil(d.beginDJTransition(spec(b, fade: 1.5)))
        await waitUntil("fade, both decks sounding") {
            d.djPhase == .fade && d.tailPlayingForTesting && d.mainNodePlayingForTesting()
        }
        d.pause()
        XCTAssertFalse(d.isPlaying)
        XCTAssertFalse(d.tailPlayingForTesting, "the tail paused")
        XCTAssertFalse(d.mainNodePlayingForTesting(), "the incoming paused")
        XCTAssertEqual(d.djPhase, .fade, "the transition waits")
        d.resume()
        XCTAssertTrue(d.isPlaying)
        XCTAssertTrue(d.tailPlayingForTesting)
        XCTAssertTrue(d.mainNodePlayingForTesting())
        await waitUntil("transition completes after the resume") { d.djPhase == .idle }
        XCTAssertFalse(d.tailDeckActiveForTesting)
        XCTAssertEqual(d.loadedSongId, "B")
    }

    /// SKIP / STOP (`disengage`) mid-transition cuts the tail: nodes gone, nothing sounding.
    func testDisengageMidTransitionCutsTheTail() async throws {
        let (d, _, b) = try playingDSP()
        await rendering(d)
        let nodes = d.attachedNodeCountForTesting
        d.onDJFadeStart = { _ in true }
        XCTAssertNil(d.beginDJTransition(spec(b, fade: 2)))
        await waitUntil("fade") { d.djPhase == .fade }
        d.disengage()
        XCTAssertEqual(d.djPhase, .idle)
        XCTAssertFalse(d.tailDeckActiveForTesting)
        XCTAssertEqual(d.attachedNodeCountForTesting, nodes)
        XCTAssertFalse(d.isEngaged)
        XCTAssertEqual(d.levelTrimGainDb, 0, "leveling resets with the engagement")
    }

    /// SEEK in the pre-roll cuts the tail and puts the OUTGOING back on the main chain at the
    /// target; a seek after the fade started cuts the tail and the incoming carries on.
    func testSeekMidTransitionCutsTheTail() async throws {
        let (d, _, b) = try playingDSP()
        await rendering(d)
        var released = 0
        XCTAssertNil(d.beginDJTransition(spec(b, preRoll: 3, release: { released += 1 })))
        await waitUntil("handover landed") { !d.mainNodePlayingForTesting() && d.tailPlayingForTesting }
        d.seek(toSongSeconds: 2)
        XCTAssertEqual(d.djPhase, .idle)
        XCTAssertFalse(d.tailDeckActiveForTesting)
        XCTAssertEqual(d.loadedSongId, "A", "still the outgoing — no advance")
        XCTAssertEqual(released, 1, "the incoming's scope goes back")
        await waitUntil("the outgoing plays on the main chain from the target") {
            d.mainNodePlayingForTesting() && d.currentTime > 2.0 && d.currentTime < 3.5
        }
        XCTAssertEqual(d.timePitchRate, 1, accuracy: 1e-3, "no glide left behind")

        // …and after the fade started: the tail goes, the incoming stays.
        d.seek(toSongSeconds: 5)
        await waitUntil("near the end again") { d.currentTime > 5.05 }
        d.onDJFadeStart = { _ in true }
        XCTAssertNil(d.beginDJTransition(spec(b, preRoll: 0.2, fade: 2)))
        await waitUntil("fade") { d.djPhase == .fade }
        d.seek(toSongSeconds: 1)
        XCTAssertEqual(d.djPhase, .idle)
        XCTAssertFalse(d.tailDeckActiveForTesting)
        XCTAssertEqual(d.loadedSongId, "B")
        XCTAssertEqual(d.mainFadeGainForTesting, 1, "the incoming at full gain at once")
        await waitUntil("the incoming plays from the target") { d.mainNodePlayingForTesting() && d.currentTime >= 1 }
    }

    /// A listener touch on tempo mid-fade ends the glide at once (the listener wins); the
    /// crossfade carries on and completes without a post-roll.
    func testListenerTouchEndsTheGlide() async throws {
        let (d, _, b) = try playingDSP()
        await rendering(d)
        d.onDJFadeStart = { _ in true }
        XCTAssertNil(d.beginDJTransition(spec(b, fade: 1.5)))
        await waitUntil("fade") { d.djPhase == .fade }
        XCTAssertEqual(d.timePitchRate, 0.95, accuracy: 1e-3)
        d.setRate(1.1)
        XCTAssertEqual(d.timePitchRate, 1.1, accuracy: 1e-3, "the listener's tempo, no glide on top")
        XCTAssertEqual(d.djPhase, .fade, "the crossfade itself carries on")
        await waitUntil("done") { d.djPhase == .idle }
        XCTAssertEqual(d.timePitchRate, 1.1, accuracy: 1e-3)
        XCTAssertTrue(d.filterBandBypassed, "no texture left on")
    }

    /// The host REFUSING the advance at the fade start (the queue moved) puts the outgoing back.
    func testHostRefusalAtTheFadeStartKeepsTheOutgoing() async throws {
        let (d, _, b) = try playingDSP()
        await rendering(d)
        d.setRate(1.02)
        d.onDJFadeStart = { _ in false }
        XCTAssertNil(d.beginDJTransition(spec(b, preRoll: 0.2)))
        await waitUntil("cut back") { d.djPhase == .idle }
        XCTAssertEqual(d.loadedSongId, "A")
        XCTAssertEqual(d.rate, 1.02, accuracy: 1e-9, "the outgoing keeps the listener's controls")
        // The HAND-BACK: the main chain picks the song up at the tail's playhead (a 60 ms cross,
        // no gap), then the tail goes and the glide eases back to the listener's tempo.
        await waitUntil("A plays on the main chain, the tail released") {
            d.mainNodePlayingForTesting() && d.isPlaying && !d.tailDeckActiveForTesting && !d.djReturningForTesting
        }
        let t = d.currentTime
        XCTAssertGreaterThan(t, 4.2, "the song carried on from where the tail had it (never restarted)")
        await waitUntil("the glide eased back") { abs(d.timePitchRate - 1.02) < 1e-3 }
        XCTAssertEqual(d.djRateOverlayForTesting, 1, accuracy: 1e-9)
        XCTAssertTrue(d.filterBandBypassed, "the texture eased out too")
        XCTAssertEqual(d.retiringTailCountForTesting, 0)
    }

    /// DECLINES touch nothing (and hand the incoming's scope back): paused, in flight, an
    /// unreadable incoming, too close to the end, muted stems.
    func testDeclinePaths() async throws {
        let (d, _, b) = try playingDSP()
        await rendering(d)
        var released = 0
        d.pause()
        XCTAssertEqual(d.beginDJTransition(spec(b, release: { released += 1 })), "not playing")
        d.resume()
        await waitUntil("playing") { d.mainNodePlayingForTesting() }
        let bogus = FileManager.default.temporaryDirectory.appendingPathComponent("pdj-dj-missing-\(UUID().uuidString).wav")
        XCTAssertEqual(d.beginDJTransition(spec(bogus, release: { released += 1 })), "incoming unreadable")
        d.onDJFadeStart = { _ in true }
        XCTAssertNil(d.beginDJTransition(spec(b, preRoll: 2)))
        XCTAssertEqual(d.beginDJTransition(spec(b, release: { released += 1 })), "transition in flight")
        XCTAssertEqual(released, 3)
        XCTAssertEqual(d.djPhase, .preRoll, "the first transition is untouched")
        d.disengage()

        // Too close to the end (or already over) — declined either way.
        let (e, _, b2) = try playingDSP(aSeconds: 8, at: 7.6)
        await waitUntil("rendering near the end") { e.mainNodePlayingForTesting() && e.currentTime > 7.62 || !e.isPlaying }
        XCTAssertNotNil(e.beginDJTransition(spec(b2)))
        XCTAssertFalse(e.tailDeckActiveForTesting)
    }

    func testMutedStemsDecline() async throws {
        let song = "pdj_djstems"
        var stems: [String: URL] = [:]
        for n in MixEngine.stemNames { stems[n] = try wav(8) }
        let a = try wav(8), b = try wav(8)
        let d = NowPlayingDSP(burns: makeBurns())
        d.profileStemResolve = { $0 == song ? stems : nil }
        addTeardownBlock { @MainActor in d.disengage() }
        d.engage(url: a, startMs: nil, lengthMs: nil, atSeconds: 4, songId: song, play: true)
        try XCTSkipUnless(d.isReady, "no audio device on this test host")
        XCTAssertTrue(d.setStemMode(true))
        await waitUntil("stems on air") { d.stemsOnAir && d.stemHandover == nil }
        d.toggleStemMute("vocals")
        XCTAssertEqual(d.beginDJTransition(spec(b)), "stems-muted")
        d.toggleStemMute("vocals")
        await waitUntil("stems rendering") { d.stemNodesPlayingForTesting() }
        XCTAssertNil(d.beginDJTransition(spec(b, preRoll: 1)), "full-mix stems (nothing muted) mix fine")
        await waitUntil("the tail carries the full mix") { d.tailPlayingForTesting && !d.stemNodesPlayingForTesting() }
    }

    // MARK: - SetlistPlayer DJ (real sequencer + DSP over burned WAVs)

    private struct Rig {
        let rips: RipsStore; let burns: BurnStore; let player: PlayerEngine
        let seq: SetlistPlayer; let dsp: NowPlayingDSP
    }

    private func rig(_ ids: [String], seconds: Double = 8) throws -> Rig {
        let rips = RipsStore(ripsBase: URL(string: "https://rips.test")!, session: URLSession(configuration: .ephemeral))
        rips.setManifest(Dictionary(uniqueKeysWithValues: ids.map { ($0, RipsStore.ManifestEntry(key: "rips/\($0).mp3", source: "digital")) }))
        let burns = try MixBurnFixture.burnStore(ids: ids, rips: rips, lengths: Dictionary(uniqueKeysWithValues: ids.map { ($0, seconds) }))
        let player = PlayerEngine()
        let coord = PlaybackCoordinator(ripProvider: RipServerPlaybackProvider(rips: rips, player: player),
                                        appleMusic: AppleMusicPlaybackProvider(provider: AppleMusicProvider()))
        let seq = SetlistPlayer(player: player, rips: rips, burns: burns, coordinator: coord)
        let dsp = NowPlayingDSP(burns: burns)
        seq.dsp = dsp
        seq.djTimings = { DJMode.Timings(lead: 3, fade: 0.6, glide: 0.3) }
        let cacheURL = FileManager.default.temporaryDirectory.appendingPathComponent("pdj-dj-loud-\(UUID().uuidString).json")
        addTeardownBlock { try? FileManager.default.removeItem(at: cacheURL) }
        seq.loudnessCache = LoudnessCache(fileURL: cacheURL)
        addTeardownBlock { @MainActor in seq.stop(); dsp.disengage() }
        return Rig(rips: rips, burns: burns, player: player, seq: seq, dsp: dsp)
    }

    private func item(_ id: String) -> SetlistPlayer.Item { .init(id: id, title: id, artist: "A") }

    private func startDJ(_ r: Rig, _ ids: [String]) async throws {
        r.seq.play(ids.map(item))
        await waitUntil("\(ids[0]) playing") { r.rips.nowPlaying?.songId == ids[0] }
        r.seq.setDJMode(true)
        try XCTSkipUnless(r.dsp.isReady, "no audio device on this test host")
        await waitUntil("engaged + armed") { r.seq.mixEngaged && r.dsp.djArmed }
        if !r.dsp.isPlaying { r.dsp.resume() }
    }

    /// DJ ⇒ Mix Mode; Mix Mode off ⇒ DJ off; no session ⇒ no-op; stop / a new play clear it.
    func testDJImpliesMixModeAndMixOffTurnsItOff() async throws {
        let r = try rig(["a", "b"])
        r.seq.setDJMode(true)
        XCTAssertFalse(r.seq.djMode.enabled, "no session ⇒ no-op")
        r.seq.play([item("a"), item("b")])
        await waitUntil("a playing") { r.rips.nowPlaying?.songId == "a" }
        r.seq.setDJMode(true)
        XCTAssertTrue(r.seq.djMode.enabled)
        XCTAssertTrue(r.seq.mixMode.enabled, "DJ Mode turns Mix Mode on")
        XCTAssertNotNil(r.seq.djMode.planner, "the selector is seeded")
        r.seq.setMixMode(false)
        XCTAssertFalse(r.seq.djMode.enabled, "Mix Mode off turns DJ off")
        XCTAssertFalse(r.dsp.djArmed)
        r.seq.setDJMode(true)
        r.seq.play([item("b")])
        XCTAssertFalse(r.seq.djMode.enabled, "a new session starts with DJ Mode off")
        r.seq.play([item("a"), item("b")])
        r.seq.setDJMode(true)
        r.seq.stop()
        XCTAssertFalse(r.seq.djMode.enabled)
        XCTAssertEqual(r.seq.djIndicator, .off)
    }

    /// THE HEADLINE: a local row is engaged + armed at its start; in the lead window the DJ
    /// transition begins and the SEQUENCER ADVANCES AT THE FADE START — the index, `nowPlaying`
    /// and the DSP are on the incoming while the outgoing still fades on the tail.
    func testAdvanceHappensAtTheFadeStart() async throws {
        let r = try rig(["d1", "d2", "d3"])
        try await startDJ(r, ["d1", "d2", "d3"])
        XCTAssertEqual(r.seq.djIndicator, .nextReady)
        r.dsp.seek(toSongSeconds: 4.8)                      // 3.2 s left → the 3 s lead window next
        await waitUntil("the transition began") { r.dsp.djTransitioning }
        XCTAssertEqual(r.seq.djIndicator, .mixing)
        await waitUntil("advanced at the fade start") { r.seq.index == 1 }
        XCTAssertTrue(r.dsp.tailDeckActiveForTesting, "the outgoing still sounds on the tail when the index moves")
        XCTAssertEqual(r.dsp.djPhase, .fade)
        XCTAssertEqual(r.rips.nowPlaying?.songId, "d2")
        XCTAssertEqual(r.dsp.loadedSongId, "d2")
        XCTAssertTrue(r.seq.mixEngaged)
        XCTAssertEqual(r.seq.djTransitionCount, 1)
        await waitUntil("transition done") { !r.dsp.djTransitioning }
        XCTAssertTrue(r.dsp.isPlaying)
        XCTAssertTrue(r.dsp.djArmed, "re-armed for d2 → d3")
        XCTAssertEqual(r.seq.index, 1, "exactly one advance")
        XCTAssertLessThan(r.dsp.currentTime, 3, "d2 from (near) its top")
    }

    /// The next row is NOT local: the transition declines and the song ends with the normal
    /// advance (no DJ transition counted).
    func testNonLocalNextIsANormalAdvance() async throws {
        let r = try rig(["n1", "n2"])
        r.rips.setManifest([:])
        try await startDJ(r, ["n1", "zz"])
        XCTAssertNotEqual(r.seq.djIndicator, .nextReady)
        r.dsp.seek(toSongSeconds: 6.5)
        await waitUntil("n1 ended") { r.seq.index != 0 || !r.seq.isRunning }
        XCTAssertEqual(r.seq.djTransitionCount, 0)
        XCTAssertFalse(r.dsp.tailDeckActiveForTesting)
    }

    /// Transitions OFF in Settings: every advance is a normal one.
    func testTransitionsOffIsANormalAdvance() async throws {
        let r = try rig(["t1", "t2"])
        var cfg = DJModeSettings.allOn
        cfg.transitions = false
        r.seq.djModeSettings = { cfg }
        try await startDJ(r, ["t1", "t2"])
        r.dsp.seek(toSongSeconds: 6.5)
        await waitUntil("t1 ended") { r.seq.index == 1 }
        XCTAssertEqual(r.seq.djTransitionCount, 0)
    }

    /// The snapshot carries DJ Mode (+ the selector state) and a restore is HELD: Mix Mode on with
    /// it, nothing armed until ▶.
    func testSnapshotRoundTripRestoresHeld() async throws {
        let r = try rig(["s1", "s2"])
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("pdj-dj-session-\(UUID().uuidString).json")
        addTeardownBlock { try? FileManager.default.removeItem(at: url) }
        let store = PlaybackSessionStore(fileURL: url)
        r.seq.sessionStore = store
        r.seq.play([item("s1"), item("s2")])
        await waitUntil("s1 playing") { r.rips.nowPlaying?.songId == "s1" }
        r.seq.setDJMode(true)
        r.seq.flushSessionSnapshotNow(); store.flush()
        let snap = try XCTUnwrap(store.load())
        XCTAssertEqual(snap.djMode?.enabled, true)
        XCTAssertNotNil(snap.djMode?.planner)

        let r2 = try rig(["s1", "s2"])
        var noMix = snap
        noMix.npMixMode = nil
        r2.seq.restore(from: noMix)
        XCTAssertTrue(r2.seq.isHeldForResume)
        XCTAssertTrue(r2.seq.djMode.enabled)
        XCTAssertEqual(r2.seq.djMode.planner, snap.djMode?.planner)
        XCTAssertTrue(r2.seq.mixMode.enabled, "DJ implies Mix Mode on restore too")
        XCTAssertFalse(r2.dsp.djArmed, "held: nothing armed before ▶")
        XCTAssertFalse(r2.seq.mixEngaged)
    }

    /// A live Mix-tab session SUSPENDS DJ Mode: the engagement (and its arm) goes; the chip says so.
    func testMixTabSuspendsDJMode() async throws {
        let r = try rig(["m1", "m2"])
        let live = DJMixLiveFlag()
        r.seq.mixSessionActive = { live.on }
        try await startDJ(r, ["m1", "m2"])
        live.on = true
        await waitUntil("suspended") { r.seq.djIndicator == .suspended && !r.seq.mixEngaged }
        XCTAssertFalse(r.dsp.djArmed, "the engagement's arm went with it")
        XCTAssertTrue(r.seq.djMode.enabled, "DJ Mode itself stays ON")
        XCTAssertFalse(r.seq.djActive)
        live.on = false
        await waitUntil("resumes") { r.seq.djIndicator != .suspended }
    }

    /// The selector re-orders the upcoming rows into the tempo band, but a buffered (local) NEXT
    /// row and a listener-placed row hold their places; a pinned run row too.
    func testReplanRespectsFixedRowsAndTheBufferedNext() async throws {
        let r = try rig(["c", "n"])
        let bpm: [String: Double] = ["c": 100, "n": 100, "u1": 141, "u2": 101, "u3": 142, "u4": 102,
                                     "u5": 143, "u6": 103, "x": 150]
        r.seq.djSongFacts = { id in bpm[id].map { DJMode.SongFacts(bpm: $0) } }
        let ids = ["c", "n", "u1", "u2", "u3", "u4", "u5", "u6"]
        r.seq.play(ids.map(item))
        await waitUntil("c playing") { r.rips.nowPlaying?.songId == "c" }
        let u3 = try XCTUnwrap(r.seq.queue.first { $0.id == "u3" }?.uid)
        r.seq.insertInQueue([item("x")], before: u3)          // listener-placed at index 4
        let xIndex = try XCTUnwrap(r.seq.queue.firstIndex { $0.id == "x" })
        r.seq.setDJMode(true)
        XCTAssertEqual(r.seq.queue[1].id, "n", "the buffered next holds")
        XCTAssertEqual(r.seq.queue[xIndex].id, "x", "the listener's row holds its slot")
        XCTAssertGreaterThanOrEqual(r.seq.djReplanCount, 1)
        // The free rows were re-ordered toward the current 100-BPM band.
        XCTAssertEqual(r.seq.queue[2].id, "u2", "the closest in-band song comes next")
        XCTAssertEqual(Set(r.seq.queue.map(\.id)), Set(ids + ["x"]), "a re-order, nothing lost")
        // A queue edit re-plans (debounced) without moving the fixed rows.
        let tailUid = try XCTUnwrap(r.seq.queue.last?.uid)
        r.seq.moveUpcomingNext(uid: tailUid)                  // listener-placed: holds at index 1
        XCTAssertTrue(r.seq.djReplanPending, "an edit schedules a (debounced) re-plan")
        await waitUntil("re-planned after the edit") { !r.seq.djReplanPending }
        XCTAssertEqual(r.seq.queue[1].uid, tailUid, "the moved row holds")
        XCTAssertEqual(r.seq.queue[xIndex + 1].id, "x", "the inserted row holds its (shifted) slot")
        XCTAssertFalse(r.seq.djReplanPending, "our own re-order never schedules another re-plan")
    }

    /// VOLUME LEVELING: the current local file is measured once; its gain lands on the DSP trim
    /// (ramped, never a step).
    func testLevelingMeasuresAndAppliesTheGain() async throws {
        let r = try rig(["l1", "l2"])
        try await startDJ(r, ["l1", "l2"])
        let cache = try XCTUnwrap(r.seq.loudnessCache)
        let url = try XCTUnwrap(r.rips.nowPlaying?.url)
        let key = try XCTUnwrap(LoudnessCache.key(songId: "l1", url: url))
        await waitUntil("analysis landed", timeout: 15) { cache.contains(key) }
        let gain = try XCTUnwrap(cache.gainDb(for: key), "a steady sine is measurable")
        XCTAssertNotEqual(gain, 0, accuracy: 0.05, "the fixture isn't already at −14 LUFS")
        await waitUntil("the gain heads onto the trim") { abs(r.dsp.levelTargetDb - gain) < 0.01 }
        await waitUntil("ramp landed") { !r.dsp.levelRampInFlight }
        XCTAssertEqual(Double(r.dsp.levelTrimGainDb), r.dsp.levelTargetDb, accuracy: 0.01)
        // Leveling OFF ⇒ 0 dB on the next start.
        var cfg = DJModeSettings.allOn
        cfg.volumeLeveling = false
        r.seq.djModeSettings = { cfg }
        r.seq.skipNext()
        await waitUntil("l2 engaged") { r.dsp.loadedSongId == "l2" && r.seq.mixEngaged }
        XCTAssertEqual(r.dsp.levelTrimGainDb, 0)
    }
}

/// A mutable flag the `mixSessionActive` seam reads (observable, like `MixEngine.isRunning`).
@MainActor
@Observable
private final class DJMixLiveFlag { var on = false }

// MARK: - Review fixes (np-dj-mode §9: Remote suspension, album runs, natural ends, the
// selector's guards, the hand-back, the analyser)

extension DJModeTests {

    // MARK: DSP

    /// A PAUSE inside the 60 ms handover of a no-pre-roll transition lands the handover but never
    /// starts the fade (that would advance the set inside a pause and, with the stale handover
    /// task, stop the incoming): the fade — and the advance — wait for ▶, then run normally.
    func testPauseInsideTheHandoverDefersTheFade() async throws {
        let (d, _, b) = try playingDSP()
        await rendering(d)
        var advanced: [String] = []
        d.onDJFadeStart = { advanced.append($0); return true }
        XCTAssertNil(d.beginDJTransition(spec(b, preRoll: 0, fade: 0.6, postRoll: 0)))
        d.pause()
        XCTAssertFalse(d.isPlaying)
        XCTAssertEqual(d.djPhase, .preRoll, "the fade waits for ▶")
        XCTAssertTrue(advanced.isEmpty, "no advance inside a pause")
        XCTAssertFalse(d.mainNodePlayingForTesting(), "the handover landed: the main voice stopped")
        XCTAssertFalse(d.tailPlayingForTesting, "the tail paused")
        d.resume()
        await waitUntil("the fade starts once the clock runs") { advanced == ["B"] && d.djPhase != .preRoll }
        XCTAssertEqual(d.loadedSongId, "B")
        await waitUntil("the transition completes with the incoming SOUNDING") {
            d.djPhase == .idle && d.mainNodePlayingForTesting() && d.isPlaying
        }
        XCTAssertFalse(d.tailDeckActiveForTesting)
        XCTAssertEqual(d.mainFadeGainForTesting, 1)
    }

    /// The tail ran out in the pre-roll and the host then refused the advance: that is the
    /// song's END (reported — the host advances), never a session parked silent at the end.
    func testTailThatRanOutReportsTheEnd() async throws {
        let (d, _, b) = try playingDSP(aSeconds: 8, at: 6.6)
        await waitUntil("A rendering near its end") { d.isPlaying && d.mainNodePlayingForTesting() && d.currentTime > 6.62 }
        var ended = 0
        d.onReachedEnd = { ended += 1 }
        d.onDJFadeStart = { _ in false }
        XCTAssertNil(d.beginDJTransition(spec(b, preRoll: 6, outRate: 1, inRate: 1, texture: false)))
        // (The tail's completion is "data consumed", so the refusal can land a little before the
        // last frame: then the hand-back carries the remainder and ITS end is reported.)
        await waitUntil("the end is reported, the tail gone", timeout: 6) { ended >= 1 && !d.tailDeckActiveForTesting }
        XCTAssertEqual(ended, 1, "exactly one end")
        XCTAssertEqual(d.djPhase, .idle)
        XCTAssertFalse(d.isPlaying, "stopped AT the end — the host advances (never parked silent)")
    }

    /// A stem action in the pre-roll hands the outgoing back (no gap) — after the advance the
    /// stems are the INCOMING's: a mute there doesn't cut the fade.
    func testStemMuteAfterTheAdvanceDoesNotCutTheFade() async throws {
        let (d, _, b) = try playingDSP()
        await rendering(d)
        d.onDJFadeStart = { _ in true }
        XCTAssertNil(d.beginDJTransition(spec(b, preRoll: 0.2, fade: 1.5)))
        await waitUntil("fade") { d.djPhase == .fade }
        d.toggleStemMute("vocals")
        XCTAssertEqual(d.djPhase, .fade, "the crossfade carries on")
        XCTAssertTrue(d.tailDeckActiveForTesting, "the outgoing still fades on the tail")
        await waitUntil("done") { d.djPhase == .idle }
    }

    /// An engine configuration change while PAUSED mid-transition cuts it: ▶ then restarts the
    /// current song on the main chain from its playhead (never `play()` on flushed decks).
    func testEngineStopWhilePausedMidTransitionCuts() async throws {
        let (d, _, b) = try playingDSP()
        await rendering(d)
        XCTAssertNil(d.beginDJTransition(spec(b, preRoll: 3)))
        await waitUntil("handover landed") { !d.mainNodePlayingForTesting() && d.tailPlayingForTesting }
        d.pause()
        let at = d.currentTime
        d.simulateEngineStopForTesting()
        XCTAssertEqual(d.djPhase, .idle)
        XCTAssertFalse(d.tailDeckActiveForTesting)
        d.resume()
        await waitUntil("A plays on the main chain from its playhead") {
            d.mainNodePlayingForTesting() && d.isPlaying && d.currentTime > at
        }
        XCTAssertEqual(d.loadedSongId, "A")
        XCTAssertLessThan(d.currentTime, at + 1.5, "resumed where it paused")
    }

    // MARK: Leveling / analysis

    /// One analysis per key: a second caller AWAITS the first (it never gets an instant "nothing
    /// yet" to spin on); a failure is remembered (no retry loop); a segment of a shared file is
    /// measured on its own.
    func testLoudnessAnalysisIsSingleFlightRemembersFailuresAndMeasuresSegments() async throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("pdj-dj-loud-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: dir) }
        let cache = LoudnessCache(fileURL: dir.appendingPathComponent("loudness.json"))
        // A "side": 3 s loud, 3 s 12 dB quieter.
        let side = dir.appendingPathComponent("side.wav")
        let sr = 44_100.0
        let fmt = AVAudioFormat(standardFormatWithSampleRate: sr, channels: 2)!
        do {
            let f = try AVAudioFile(forWriting: side, settings: fmt.settings)
            let n = Int(sr * 6)
            let buf = AVAudioPCMBuffer(pcmFormat: fmt, frameCapacity: AVAudioFrameCount(n))!
            buf.frameLength = AVAudioFrameCount(n)
            for c in 0..<2 {
                for i in 0..<n {
                    let amp: Float = i < n / 2 ? 0.5 : 0.5 * Float(pow(10, -12.0 / 20))
                    buf.floatChannelData![c][i] = amp * Float(sin(2 * .pi * 997 * Double(i) / sr))
                }
            }
            try f.write(from: buf)
        }
        let k1 = try XCTUnwrap(LoudnessCache.key(songId: "s1", url: side, startMs: 0, lengthMs: 3000))
        let k2 = try XCTUnwrap(LoudnessCache.key(songId: "s2", url: side, startMs: 3000, lengthMs: 3000))
        XCTAssertNotEqual(k1, k2, "each song on the side keys its own slice")
        async let a = cache.analyze(k1, url: side)
        async let b = cache.analyze(k1, url: side)
        let (ra, rb) = await (a, b)
        let outcomes = [ra, rb]
        XCTAssertEqual(outcomes.filter { if case .measured = $0 { return true } else { return false } }.count, 1,
                       "exactly one caller ran the analysis")
        XCTAssertEqual(outcomes.filter { if case .cached = $0 { return true } else { return false } }.count, 1,
                       "the other awaited it")
        _ = await cache.analyze(k2, url: side)
        let loud = try XCTUnwrap(cache.lufs(for: k1)), quiet = try XCTUnwrap(cache.lufs(for: k2))
        XCTAssertEqual(loud - quiet, 12, accuracy: 0.3, "the segments measure their own loudness, not the side's")

        let junk = dir.appendingPathComponent("junk.wav")
        try Data(repeating: 7, count: 4096).write(to: junk)
        let kj = try XCTUnwrap(LoudnessCache.key(songId: "j", url: junk))
        let first = await cache.analyze(kj, url: junk)
        XCTAssertEqual(first, .failed)
        XCTAssertTrue(cache.hasFailed(kj))
        XCTAssertTrue(cache.isSettledOrRunning(kj), "a failed key is never kicked again this launch")
        let again = await cache.analyze(kj, url: junk)
        XCTAssertEqual(again, .failed)
    }

    /// The mono-sum fast path reads identical channels exactly as the full BS.1770 sum.
    func testMonoSumMatchesTheFullSumOnCorrelatedChannels() throws {
        let url = try wav(3)
        let mono = try XCTUnwrap(LoudnessAnalyzer.analyzeSync(url: url, monoSum: true))
        let full = try XCTUnwrap(LoudnessAnalyzer.analyzeSync(url: url, monoSum: false))
        XCTAssertEqual(mono, full, accuracy: 0.05)
    }

    // MARK: Sequencer

    /// REMOTE: an attached SharePlay / Backseat session SUSPENDS DJ Mode — the chip says so, the
    /// arm goes, nothing re-plans, and the song's end is a NORMAL advance tagged as a natural
    /// end (the DSP end path used to tag it `.autoSkip`). The session ending resumes it.
    func testRemoteSessionSuspendsDJModeAndResumesAfter() async throws {
        let r = try rig(["r1", "r2", "r3"])
        let remote = DJMixLiveFlag()
        r.seq.remoteSessionActive = { remote.on }
        try await startDJ(r, ["r1", "r2", "r3"])
        XCTAssertTrue(r.dsp.djArmed)
        remote.on = true
        await waitUntil("suspended for the session") { r.seq.djIndicator == .suspendedRemote && !r.dsp.djArmed }
        XCTAssertEqual(r.seq.djIndicator.chipText, "DJ — paused · SharePlay session")
        XCTAssertFalse(r.seq.djActive)
        XCTAssertTrue(r.seq.djMode.enabled, "DJ Mode itself stays ON")
        r.seq.appendToQueue([item("r1")])
        XCTAssertFalse(r.seq.djReplanPending, "no re-ordering while a session is attached")
        let plans = r.seq.djReplanCount
        r.dsp.seek(toSongSeconds: 6.5)
        await waitUntil("r1 ended → a normal advance") { r.seq.index == 1 }
        XCTAssertEqual(r.seq.djTransitionCount, 0, "no DJ transition")
        XCTAssertFalse(r.dsp.tailDeckActiveForTesting)
        XCTAssertEqual(r.seq.lastTransitionCause, .naturalEnd, "a song that played in full is a natural end")
        XCTAssertEqual(r.seq.djReplanCount, plans, "no DJ re-order on the advance")
        remote.on = false
        await waitUntil("resumes when the session ends") {
            r.seq.djIndicator != .suspendedRemote && r.seq.djActive && r.dsp.djArmed
        }
    }

    /// The chip never promises a mix that won't happen: repeat-one, Transitions off and the
    /// last song under repeat-all each say why.
    func testIndicatorSaysWhyTheEndWontMix() async throws {
        let r = try rig(["i1", "i2"])
        try await startDJ(r, ["i1", "i2"])
        XCTAssertEqual(r.seq.djIndicator, .nextReady)
        r.seq.setRepeatMode(.one)
        XCTAssertEqual(r.seq.djIndicator, .noMix("repeating this song"))
        r.seq.setRepeatMode(.off)
        var cfg = DJModeSettings.allOn
        cfg.transitions = false
        r.seq.djModeSettings = { cfg }
        XCTAssertEqual(r.seq.djIndicator, .noMix("transitions off"))
        XCTAssertEqual(DJMode.Indicator.noMix("set repeats").chipText, "DJ — set repeats")
    }

    // MARK: Vinyl album runs

    /// A rig whose `side` rows are songs of ONE shared album file (`sideSeconds` long, the songs
    /// `songSeconds` apart), plus ordinary per-song rows.
    private func albumRig(side: [String], songSeconds: Double, singles: [String]) throws -> Rig {
        let rips = RipsStore(ripsBase: URL(string: "https://rips.test")!, session: URLSession(configuration: .ephemeral))
        var manifest: [String: RipsStore.ManifestEntry] = [:]
        for (k, id) in side.enumerated() {
            manifest[id] = RipsStore.ManifestEntry(key: "rips/side-x.mp3", source: "vinyl", startMs: Int(Double(k) * songSeconds * 1000))
        }
        for id in singles { manifest[id] = RipsStore.ManifestEntry(key: "rips/\(id).mp3", source: "digital") }
        rips.setManifest(manifest)
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("pdj-dj-album-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: dir) }
        let sideName = "burn-side.wav"
        try MixBurnFixture.writeSineWAV(to: dir.appendingPathComponent(sideName), seconds: songSeconds * Double(side.count))
        var items: [BurnStore.BurnItem] = []
        for (k, id) in side.enumerated() {
            items.append(BurnStore.BurnItem(
                songId: id, title: id, artist: "A", audioFileName: sideName, sidecarFileName: "", source: "vinyl",
                bpm: 150, musicalKey: nil, camelot: "8A", durationMs: Int(songSeconds * 1000),
                startMs: Int(Double(k) * songSeconds * 1000), bytes: 0, rippedAt: nil, downloadedAt: 0,
                state: .ready, error: nil, wasAppStorage: true))
        }
        for id in singles {
            let name = "burn-\(id).wav"
            try MixBurnFixture.writeSineWAV(to: dir.appendingPathComponent(name), seconds: 8)
            items.append(BurnStore.BurnItem(
                songId: id, title: id, artist: "A", audioFileName: name, sidecarFileName: "", source: "digital",
                bpm: 100, musicalKey: nil, camelot: "8A", durationMs: 8000, startMs: nil, bytes: 0, rippedAt: nil,
                downloadedAt: 0, state: .ready, error: nil, wasAppStorage: true))
        }
        let indexURL = dir.appendingPathComponent("index.json")
        try JSONEncoder().encode(BurnStore.Document(items: items)).write(to: indexURL)
        let burns = BurnStore(rips: rips, fileURL: indexURL)
        burns.appBurnsDirOverride = dir
        let player = PlayerEngine()
        let coord = PlaybackCoordinator(ripProvider: RipServerPlaybackProvider(rips: rips, player: player),
                                        appleMusic: AppleMusicPlaybackProvider(provider: AppleMusicProvider()))
        let seq = SetlistPlayer(player: player, rips: rips, burns: burns, coordinator: coord)
        let dsp = NowPlayingDSP(burns: burns)
        seq.dsp = dsp
        seq.djTimings = { DJMode.Timings(lead: 3, fade: 0.6, glide: 0.3) }
        let cacheURL = dir.appendingPathComponent("loud.json")
        seq.loudnessCache = LoudnessCache(fileURL: cacheURL)
        addTeardownBlock { @MainActor in seq.stop(); dsp.disengage() }
        return Rig(rips: rips, burns: burns, player: player, seq: seq, dsp: dsp)
    }

    /// AN ALBUM PLAYS END TO END with DJ Mode on: a row whose next row is the record's next song
    /// is NOT taken into the DSP (the AVPlayer keeps the one side file and GLIDES — same player
    /// item, no reload), the chip says so, and the record's LAST queued song is engaged so its
    /// end can mix out.
    func testAlbumRunWithDJOnPlaysThroughOnTheGlide() async throws {
        let r = try albumRig(side: ["v1", "v2", "v3"], songSeconds: 3, singles: ["s9"])
        r.seq.play(["v1", "v2", "v3", "s9"].map(item))
        await waitUntil("v1 playing on the side") { r.rips.nowPlaying?.songId == "v1" }
        r.seq.setDJMode(true)
        XCTAssertTrue(r.seq.djMode.enabled)
        XCTAssertFalse(r.seq.mixEngaged, "an album-run row stays on the record (no DSP engage)")
        XCTAssertFalse(r.dsp.djArmed)
        XCTAssertEqual(r.seq.djIndicator, .noMix("album plays through"))
        let item0 = try XCTUnwrap(r.player.currentItemForTesting)
        await waitUntil("glided onto v2", timeout: 10) { r.seq.index == 1 && r.rips.nowPlaying?.songId == "v2" }
        XCTAssertTrue(r.player.currentItemForTesting === item0, "the SAME player item — a glide, not a reload")
        XCTAssertFalse(r.seq.mixEngaged)
        XCTAssertEqual(r.seq.queue.map(\.id), ["v1", "v2", "v3", "s9"], "the run kept its record order")
        await waitUntil("glided onto v3 — the record's last queued song is engaged to mix out", timeout: 10) {
            r.seq.index == 2 && r.rips.nowPlaying?.songId == "v3" && r.seq.mixEngaged
        }
        XCTAssertTrue(r.player.currentItemForTesting === item0 || r.seq.mixEngaged)
        XCTAssertTrue(r.dsp.djArmed, "armed: v3's end can mix into s9")
    }

    /// The selector treats an album run as a FIXED block: it never re-orders the record's own
    /// rows or slips another song between them, even when every other row moves.
    func testSelectorKeepsAnAlbumRunInRecordOrder() async throws {
        let r = try albumRig(side: ["v1", "v2", "v3"], songSeconds: 3, singles: ["c", "u1", "u2", "u3", "u4"])
        let bpm: [String: Double] = ["c": 100, "u1": 140, "u2": 101, "u3": 141, "u4": 102, "v1": 150, "v2": 90, "v3": 150]
        r.seq.djSongFacts = { id in bpm[id].map { DJMode.SongFacts(bpm: $0) } }
        let ids = ["c", "u1", "v1", "v2", "v3", "u2", "u3", "u4"]
        r.seq.play(ids.map(item))
        await waitUntil("c playing") { r.rips.nowPlaying?.songId == "c" }
        r.seq.setDJMode(true)
        try XCTSkipUnless(r.dsp.isReady, "no audio device on this test host")
        let order = r.seq.queue.map(\.id)
        XCTAssertEqual(Set(order), Set(ids), "a re-order, nothing lost")
        let v1 = try XCTUnwrap(order.firstIndex(of: "v1"))
        XCTAssertEqual(Array(order[v1...(v1 + 2)]), ["v1", "v2", "v3"], "the album run is one block, in record order")
        XCTAssertEqual(v1, 2, "…and holds its place")
        XCTAssertGreaterThanOrEqual(r.seq.djReplanCount, 1, "the free rows still re-ordered")
    }

    // MARK: Selector

    /// Listener placements ride the durable snapshot: a relaunch restores the marks, so the
    /// selector still leaves a jukebox request / Play Next row where it was put.
    func testListenerPlacementSurvivesRestore() async throws {
        let r = try rig(["p1", "p2", "p3"])
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("pdj-dj-session-\(UUID().uuidString).json")
        addTeardownBlock { try? FileManager.default.removeItem(at: url) }
        let store = PlaybackSessionStore(fileURL: url)
        r.seq.sessionStore = store
        r.seq.play([item("p1"), item("p2")])
        await waitUntil("p1 playing") { r.rips.nowPlaying?.songId == "p1" }
        r.seq.insertNextInQueue([item("p3")])
        XCTAssertEqual(r.seq.djFixedUids.count, 1)
        r.seq.setDJMode(true)
        r.seq.flushSessionSnapshotNow(); store.flush()
        let snap = try XCTUnwrap(store.load())
        XCTAssertEqual(snap.queue.map { $0.djPlaced ?? false }, [false, true, false])
        let r2 = try rig(["p1", "p2", "p3"])
        r2.seq.restore(from: snap)
        XCTAssertEqual(r2.seq.queue.map(\.djPlaced), [false, true, false], "the mark is back after a relaunch")
        XCTAssertEqual(r2.seq.djFixedUids.count, 1)
    }

    /// AGING: a row the planner keeps pushing back gains score per deferral, so it can't be
    /// deferred forever.
    func testAgingBringsADeferredRowForward() {
        let cur = DJSetPlanner.Candidate(songId: "c", bpm: 100)
        var poor = DJSetPlanner.Candidate(songId: "poor", bpm: 150, camelot: "1A")
        let good = (0..<4).map { DJSetPlanner.Candidate(songId: "g\($0)", bpm: 100 + Double($0)) }
        let fresh = DJSetPlanner.plan(current: cur, upcoming: [poor] + good, state: .init(seed: 1), options: .allOn)
        XCTAssertNotEqual(fresh.order.first, poor.uid, "a poor fit is deferred at first")
        poor.deferrals = 40
        let aged = DJSetPlanner.plan(current: cur, upcoming: [poor] + good, state: .init(seed: 1), options: .allOn)
        XCTAssertEqual(aged.order.first, poor.uid, "a long-deferred row comes forward")
    }
}

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
        XCTAssertEqual(d.levelTrimGainDb, -3, accuracy: 1e-3, "the incoming's leveling gain")
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
        XCTAssertFalse(d.tailDeckActiveForTesting)
        XCTAssertEqual(d.loadedSongId, "A")
        XCTAssertEqual(d.rate, 1.02, accuracy: 1e-9, "the outgoing keeps the listener's controls")
        await waitUntil("A plays on the main chain") { d.mainNodePlayingForTesting() && d.isPlaying }
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

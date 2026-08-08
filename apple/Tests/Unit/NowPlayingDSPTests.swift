import XCTest
import AVFoundation
@testable import PocketDJ

/// F4 — the Now Playing mix mini-panel's single-deck DSP engine (`NowPlayingDSP`) plus the
/// `SetlistPlayer` eligibility gate + track-change reset that drive the AVPlayer↔DSP hand-off.
///
/// Split like `MixEngineTests`:
///  • PURE control state (clamp + reset) — no audio device.
///  • REAL-GRAPH assertions (engage a generated WAV, drive the AUs) — skipped on a host with no
///    audio device (`isReady`).
///  • The eligibility GATE (`SetlistPlayer.mixAvailable`) — pure logic over a real burned-track run.
///  • TRACK-CHANGE reset — drive `skipNext` and assert the DSP is torn down + controls neutralised.
///
/// Honest scope: the ACTUAL audio hand-off (audible gap, auto-advance across the swap, position
/// continuity, single lock-screen card) is NOT headless-testable and needs on-device verification.
@MainActor
final class NowPlayingDSPTests: XCTestCase {
    private let ripsBase = URL(string: "https://rips.test")!

    // MARK: - Fixtures

    private func makeRips(serverURL: String = "") -> RipsStore {
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [NPDSPStubURLProtocol.self]
        let rips = RipsStore(ripsBase: ripsBase, session: URLSession(configuration: config))
        let settings = SettingsStore(defaults: UserDefaults(suiteName: "test.\(UUID().uuidString)")!)
        settings.ripServerURL = serverURL
        settings.ripToken = ""
        rips.settings = settings
        return rips
    }

    private func makeBurns(_ rips: RipsStore) -> BurnStore {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("pdj-npdspburn-\(UUID().uuidString).json")
        addTeardownBlock { try? FileManager.default.removeItem(at: url) }
        return BurnStore(rips: rips, fileURL: url)
    }

    private func makeCoordinator(rips: RipsStore, player: PlayerEngine) -> PlaybackCoordinator {
        PlaybackCoordinator(
            ripProvider: RipServerPlaybackProvider(rips: rips, player: player),
            appleMusic: AppleMusicPlaybackProvider(provider: AppleMusicProvider()))
    }

    /// Actually burn `songId` so the coordinator/sequencer's burned-file path resolves an on-disk file.
    private func burn(_ rips: RipsStore, _ burns: BurnStore, songId: String) async {
        rips.setManifest([songId: .init(key: "rips/\(songId).mp3", source: "digital")])
        NPDSPStubURLProtocol.body = Data("BURNT-MP3".utf8)
        _ = await burns.burn([(id: songId, title: songId, artist: "A")])
        XCTAssertNotNil(burns.localURL(forSong: songId), "precondition: \(songId) is burned")
    }

    private func waitUntil(_ message: String, _ predicate: () -> Bool) async {
        for _ in 0..<200 {
            if predicate() { return }
            try? await Task.sleep(nanoseconds: 5_000_000)
        }
        XCTFail("timed out waiting: \(message)")
    }

    private func makeDSP() -> NowPlayingDSP { NowPlayingDSP(burns: makeBurns(makeRips())) }

    /// 4 REAL decodable sine-WAV stems for `songId`, wired through the "Pocket DJ" profile lane
    /// (`NowPlayingDSP.profileStemResolve`) — `songId` MUST carry the `pdj_` prefix.
    ///
    /// Why not the BURN lane: `BurnStore` names burned stems `stem-<id>-<part>.mp3`, and
    /// `AVAudioFile(forReading:)` picks its decoder from the file EXTENSION, not the bytes — a WAV
    /// body under an `.mp3` name fails to open (`dta?` / kAudioFileInvalidFileError). Apple platforms
    /// ship no MP3 *encoder*, so a test can't synthesize a genuinely-`.mp3` stem at all. The profile
    /// lane takes arbitrary URLs and reaches the IDENTICAL `wireStems` → `scheduleStems` →
    /// `generation` code under test (`NowPlayingDSP.wireStems` line 1 of its source split), so the
    /// regression coverage is the same; only the URL resolution differs.
    private func stemURLs(seconds: Double) throws -> [String: URL] {
        var urls: [String: URL] = [:]
        for name in MixEngine.stemNames {
            let u = try makeSineWAV(seconds: seconds)
            addTeardownBlock { try? FileManager.default.removeItem(at: u) }
            urls[name] = u
        }
        return urls
    }

    /// A DSP that resolves REAL decodable stems for `songId` (see `stemURLs`).
    private func makeStemmedDSP(songId: String, stemSeconds: Double) throws -> NowPlayingDSP {
        XCTAssertTrue(ProfileSourceStore.isProfileSongId(songId),
                      "the stem fixture rides the profile lane — songId needs the pdj_ prefix")
        let urls = try stemURLs(seconds: stemSeconds)
        let d = makeDSP()
        d.profileStemResolve = { $0 == songId ? urls : nil }   // set BEFORE engage (drives stemsAvailable)
        return d
    }

    /// A short sine WAV on disk (mirrors MixEngineTests) so `engage` exercises the real decode +
    /// schedule path.
    private func makeSineWAV(seconds: Double, sr: Double = 44_100) throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("npdsp-\(UUID().uuidString).wav")
        let fmt = AVAudioFormat(standardFormatWithSampleRate: sr, channels: 2)!
        let file = try AVAudioFile(forWriting: url, settings: fmt.settings)
        let frames = AVAudioFrameCount(seconds * sr)
        let buf = AVAudioPCMBuffer(pcmFormat: fmt, frameCapacity: frames)!
        buf.frameLength = frames
        let ch = buf.floatChannelData!
        for c in 0..<2 {
            for i in 0..<Int(frames) { ch[c][i] = Float(sin(2.0 * .pi * 440.0 * Double(i) / sr)) * 0.2 }
        }
        try file.write(from: buf)
        return url
    }

    // MARK: - Pure control state (no audio device)

    func testFreshEngineIsNeutralAndDisengaged() {
        let d = makeDSP()
        XCTAssertFalse(d.isEngaged)
        XCTAssertFalse(d.isPlaying)
        XCTAssertEqual(d.rate, 1.0)
        XCTAssertEqual(d.pitch, 0.0)
        XCTAssertEqual(d.volume, 1.0)
        XCTAssertFalse(d.stemMode)
        for e in MixEngine.Effect.allCases {
            XCTAssertFalse(d.isEnabled(e))
            XCTAssertEqual(d.strength(e), 0.5, accuracy: 1e-9)
        }
    }

    func testControlsClampToRanges() {
        let d = makeDSP()
        d.setRate(3.0);   XCTAssertEqual(d.rate, 2.0)
        d.setRate(0.1);   XCTAssertEqual(d.rate, 0.5)
        d.setRate(1.25);  XCTAssertEqual(d.rate, 1.25, accuracy: 1e-9)
        d.setPitch(99);   XCTAssertEqual(d.pitch, 12)
        d.setPitch(-99);  XCTAssertEqual(d.pitch, -12)
        d.setVolume(9);   XCTAssertEqual(d.volume, 2.0)
        d.setVolume(-1);  XCTAssertEqual(d.volume, 0.0)
        d.setEffectStrength(.reverb, 1.7);  XCTAssertEqual(d.strength(.reverb), 1.0)
        d.setEffectStrength(.reverb, -0.4); XCTAssertEqual(d.strength(.reverb), 0.0)
        d.setEffectStrength(.reverb, 0.66); XCTAssertEqual(d.strength(.reverb), 0.66, accuracy: 1e-9)
    }

    func testResetControlsNeutralizesState() {
        let d = makeDSP()
        d.setRate(1.6); d.setPitch(7); d.setVolume(1.8)
        d.setEffect(.reverb, enabled: true); d.setEffectStrength(.reverb, 0.9)
        d.setEffect(.filter, enabled: true)
        d.toggleStemMute("drums"); d.setStemVolume("bass", 0.3)
        d.resetControls()
        XCTAssertEqual(d.rate, 1.0)
        XCTAssertEqual(d.pitch, 0.0)
        XCTAssertEqual(d.volume, 1.0)
        XCTAssertFalse(d.stemMode)
        XCTAssertFalse(d.isStemMuted("drums"))
        XCTAssertEqual(d.stemVolume("bass"), 1.0)
        for e in MixEngine.Effect.allCases {
            XCTAssertFalse(d.isEnabled(e))
            XCTAssertEqual(d.strength(e), 0.5, accuracy: 1e-9)
        }
    }

    // MARK: - Real-graph (skipped on a host with no audio device)

    func testEngageSchedulesAndPlays() async throws {
        let d = makeDSP()
        let url = try makeSineWAV(seconds: 2)
        defer { try? FileManager.default.removeItem(at: url) }
        d.engage(url: url, startMs: nil, lengthMs: nil, atSeconds: 0, songId: "x", play: true)
        try XCTSkipUnless(d.isReady, "no audio device on this test host")
        XCTAssertTrue(d.isEngaged)
        XCTAssertEqual(d.duration, 2.0, accuracy: 0.1)
        XCTAssertTrue(d.isPlaying)
        try await Task.sleep(nanoseconds: 250_000_000)
        XCTAssertGreaterThan(d.currentTime, 0, "the host clock advances while playing")
        d.disengage()
    }

    func testSetRateAndPitchMoveTheTimePitchUnit() throws {
        let d = makeDSP()
        let url = try makeSineWAV(seconds: 2)
        defer { try? FileManager.default.removeItem(at: url) }
        d.engage(url: url, startMs: nil, lengthMs: nil, atSeconds: 0, songId: "x", play: false)
        try XCTSkipUnless(d.isReady, "no audio device on this test host")
        d.setRate(1.5)
        XCTAssertEqual(d.timePitchRate, 1.5, accuracy: 1e-5)
        d.setPitch(3)
        XCTAssertEqual(d.timePitchPitchCents, 300, accuracy: 1e-3)   // semitones → cents
        d.disengage()
    }

    func testSetVolumeDrivesTheEQGlobalGain() throws {
        let d = makeDSP()
        let url = try makeSineWAV(seconds: 2)
        defer { try? FileManager.default.removeItem(at: url) }
        d.engage(url: url, startMs: nil, lengthMs: nil, atSeconds: 0, songId: "x", play: false)
        try XCTSkipUnless(d.isReady, "no audio device on this test host")
        d.setVolume(1.0)
        XCTAssertEqual(d.eqGlobalGain, 0, accuracy: 1e-4, "unity ⇒ 0 dB boost")
        d.setVolume(2.0)
        XCTAssertEqual(d.eqGlobalGain, 20 * log10(2.0), accuracy: 1e-3, "200% ⇒ +6 dB on the EQ globalGain")
        d.disengage()
    }

    func testEffectReachesTheReverbUnit() throws {
        let d = makeDSP()
        let url = try makeSineWAV(seconds: 2)
        defer { try? FileManager.default.removeItem(at: url) }
        d.engage(url: url, startMs: nil, lengthMs: nil, atSeconds: 0, songId: "x", play: false)
        try XCTSkipUnless(d.isReady, "no audio device on this test host")
        d.setEffect(.reverb, enabled: true)
        d.setEffectStrength(.reverb, 0.8)
        XCTAssertEqual(d.reverbWetDryMix, 80, accuracy: 1e-3)
        d.disengage()
    }

    func testStemModeReturnsFalseWithoutBurnedStems() throws {
        let d = makeDSP()
        let url = try makeSineWAV(seconds: 2)
        defer { try? FileManager.default.removeItem(at: url) }
        d.engage(url: url, startMs: nil, lengthMs: nil, atSeconds: 0, songId: "no-stems", play: false)
        try XCTSkipUnless(d.isReady, "no audio device on this test host")
        XCTAssertFalse(d.stemsAvailable)
        XCTAssertFalse(d.setStemMode(true), "no local stems → refuse stem mode")
        XCTAssertFalse(d.stemMode)
        // …and tempo/pitch still work independently of stems.
        d.setRate(1.5)
        XCTAssertEqual(d.timePitchRate, 1.5, accuracy: 1e-5)
        d.disengage()
    }

    func testDisengageReturnsPositionAndGoesIdle() async throws {
        let d = makeDSP()
        let url = try makeSineWAV(seconds: 3)
        defer { try? FileManager.default.removeItem(at: url) }
        d.engage(url: url, startMs: nil, lengthMs: nil, atSeconds: 0, songId: "x", play: true)
        try XCTSkipUnless(d.isReady, "no audio device on this test host")
        try await Task.sleep(nanoseconds: 300_000_000)
        let live = d.currentTime
        let pos = d.disengage()
        XCTAssertEqual(pos, live, accuracy: 0.1, "disengage returns the song-relative position")
        XCTAssertFalse(d.isEngaged)
        XCTAssertFalse(d.isPlaying)
    }

    func testResetControlsNeutralizesTheLiveGraph() throws {
        let d = makeDSP()
        let url = try makeSineWAV(seconds: 2)
        defer { try? FileManager.default.removeItem(at: url) }
        d.engage(url: url, startMs: nil, lengthMs: nil, atSeconds: 0, songId: "x", play: false)
        try XCTSkipUnless(d.isReady, "no audio device on this test host")
        d.setRate(1.6); d.setPitch(5); d.setVolume(2.0)
        d.resetControls()
        XCTAssertEqual(d.timePitchRate, 1.0, accuracy: 1e-5)
        XCTAssertEqual(d.timePitchPitchCents, 0, accuracy: 1e-3)
        XCTAssertEqual(d.eqGlobalGain, 0, accuracy: 1e-4)
        d.disengage()
    }

    // MARK: - Eligibility gate (SetlistPlayer.mixAvailable) — pure logic over a real burned run

    func testMixAvailableForABurnedLocalTrack() async {
        let rips = makeRips(); let burns = makeBurns(rips)
        let player = PlayerEngine()
        let coord = makeCoordinator(rips: rips, player: player)
        let seq = SetlistPlayer(player: player, rips: rips, burns: burns, coordinator: coord)
        seq.dsp = makeDSP()
        addTeardownBlock { @MainActor in seq.stop() }
        await burn(rips, burns, songId: "np_burn")

        seq.play([.init(id: "np_burn", title: "Burn", artist: "A")])
        await waitUntil("burnt file becomes now-playing") { rips.nowPlaying?.songId == "np_burn" }

        XCTAssertTrue(rips.nowPlaying?.url.isFileURL == true, "precondition: the actual source is a local file")
        XCTAssertTrue(seq.currentTrackMixable)
        XCTAssertTrue(seq.mixAvailable(mixActive: false))
        // Mutually exclusive with a live Mix-tab session.
        XCTAssertFalse(seq.mixAvailable(mixActive: true), "a running Mix session hides the panel")
    }

    /// "Play now" moves the needle to a DIFFERENT track, so it must tear down any Now Playing mix
    /// engagement — exactly as a skip or a rewind does.
    ///
    /// The regression this guards: `playNow` initially started the spliced track with
    /// `playCurrent(fresh: false)`, and `fresh` is what gates `endMixEngagement()`. The DSP kept
    /// rendering the INTERRUPTED track while the AVPlayer started the new one (two songs at once,
    /// against the one-audio-owner rule), and `dsp.onReachedEnd` stayed armed so the old track's
    /// end fired an advance that skipped the very track the user asked to play now. Every other
    /// `fresh: false` caller stays on the same row, which is why only this one was wrong.
    func testPlayNowTearsDownAMixEngagement() async {
        let rips = makeRips(); let burns = makeBurns(rips)
        let player = PlayerEngine()
        let coord = makeCoordinator(rips: rips, player: player)
        let seq = SetlistPlayer(player: player, rips: rips, burns: burns, coordinator: coord)
        seq.dsp = makeDSP()
        addTeardownBlock { @MainActor in seq.stop() }
        await burn(rips, burns, songId: "np_mix1")

        seq.play([.init(id: "np_mix1", title: "One", artist: "A"),
                  .init(id: "np_mix2", title: "Two", artist: "A")])
        await waitUntil("burnt file becomes now-playing") { rips.nowPlaying?.songId == "np_mix1" }
        seq.engageMix()
        XCTAssertTrue(seq.mixEngaged, "precondition: the Now Playing mix panel owns the audio")

        seq.playNow(.init(id: "np_mix1", title: "One", artist: "A"))

        // The tear-down runs inside `playCurrent`, which `playNow` starts as a Task — so this is a
        // wait, not a synchronous assertion. (Same shape as every other transport action here.)
        await waitUntil("the mix engagement is handed back on the track change") { !seq.mixEngaged }
        XCTAssertFalse(seq.mixEngaged,
                       "a track change must hand the audio back — otherwise two songs sound at once")
    }

    func testMixUnavailableWhenAppleMusicIsActive() async {
        let rips = makeRips(); let burns = makeBurns(rips)
        let player = PlayerEngine()
        let coord = makeCoordinator(rips: rips, player: player)
        let seq = SetlistPlayer(player: player, rips: rips, burns: burns, coordinator: coord)
        addTeardownBlock { @MainActor in seq.stop() }
        await burn(rips, burns, songId: "np_burn2")
        seq.play([.init(id: "np_burn2", title: "Burn", artist: "A")])
        await waitUntil("burnt file becomes now-playing") { rips.nowPlaying?.songId == "np_burn2" }
        XCTAssertTrue(seq.currentTrackMixable)

        coord.setActiveBackendForTests(.appleMusic)   // Apple Music now owns audio (uncontrollable)
        XCTAssertFalse(seq.currentTrackMixable, "Apple Music playback cannot be DSP-mixed")
        XCTAssertFalse(seq.mixAvailable(mixActive: false))
    }

    func testMixUnavailableForALiveStream() async {
        // No burned file + a rip server that resolves to a LIVE HLS stream → nowPlaying.url is not a
        // local file, so the track is not mixable.
        let rips = makeRips(serverURL: "https://rip.test")
        let burns = makeBurns(rips)
        let player = PlayerEngine()
        let coord = makeCoordinator(rips: rips, player: player)
        let seq = SetlistPlayer(player: player, rips: rips, burns: burns, coordinator: coord)
        addTeardownBlock { @MainActor in seq.stop() }
        NPDSPStubURLProtocol.streamOnly = true
        defer { NPDSPStubURLProtocol.streamOnly = false }

        seq.play([.init(id: "np_stream", title: "Stream", artist: "A")])
        await waitUntil("coordinator resolves the stream") { rips.nowPlaying?.songId == "np_stream" }
        XCTAssertFalse(rips.nowPlaying?.url.isFileURL == true, "precondition: the source is a remote stream")
        XCTAssertFalse(seq.currentTrackMixable, "a live/remote stream cannot be DSP-mixed")
    }

    func testEngageMixIsANoOpForANonMixableTrack() async {
        let rips = makeRips(serverURL: "https://rip.test")
        let burns = makeBurns(rips)
        let player = PlayerEngine()
        let coord = makeCoordinator(rips: rips, player: player)
        let seq = SetlistPlayer(player: player, rips: rips, burns: burns, coordinator: coord)
        seq.dsp = makeDSP()
        addTeardownBlock { @MainActor in seq.stop() }
        NPDSPStubURLProtocol.streamOnly = true
        defer { NPDSPStubURLProtocol.streamOnly = false }
        seq.play([.init(id: "np_stream2", title: "Stream", artist: "A")])
        await waitUntil("stream resolves") { rips.nowPlaying?.songId == "np_stream2" }

        seq.engageMix()
        XCTAssertFalse(seq.mixEngaged, "engage must refuse a non-mixable current track")
    }

    // MARK: - Track-change reset (needs an audio device for the real DSP swap)

    func testTrackChangeTearsDownMixAndResetsControls() async throws {
        let rips = makeRips(); let burns = makeBurns(rips)
        let player = PlayerEngine()
        let coord = makeCoordinator(rips: rips, player: player)
        let seq = SetlistPlayer(player: player, rips: rips, burns: burns, coordinator: coord)
        let dsp = makeDSP()
        seq.dsp = dsp
        addTeardownBlock { @MainActor in seq.stop() }
        await burn(rips, burns, songId: "np_t1")
        await burn(rips, burns, songId: "np_t2")

        seq.play([.init(id: "np_t1", title: "T1", artist: "A"),
                  .init(id: "np_t2", title: "T2", artist: "A")])
        await waitUntil("track 0 playing") { rips.nowPlaying?.songId == "np_t1" }

        // The first control touch attempts the swap (`engageMix`) and applies the control. (The
        // burned FIXTURE is placeholder bytes, not decodable audio, so the DSP graph can't actually
        // open it here — the real audio engage is covered by `testEngageSchedulesAndPlays` on a real
        // WAV. What this test verifies is the SetlistPlayer-side hand-off wiring: engage flips the
        // flag + applies the control, and a track change tears it all down + resets the controls.)
        seq.engageMix()
        try XCTSkipUnless(dsp.isReady, "no audio device on this test host")
        XCTAssertTrue(seq.mixEngaged, "the first control touch engaged the hand-off")
        dsp.setRate(1.5)
        XCTAssertEqual(dsp.rate, 1.5, accuracy: 1e-9, "the control applied to the DSP")

        seq.skipNext()
        await waitUntil("advanced to track 1") { rips.nowPlaying?.songId == "np_t2" }
        XCTAssertFalse(seq.mixEngaged, "the track change tore the DSP hand-off down")
        XCTAssertFalse(dsp.isEngaged, "the DSP handed the audio back to the AVPlayer")
        XCTAssertEqual(dsp.rate, 1.0, "controls reset on the track change (ephemeral)")
    }

    // MARK: - FIX 2: the playhead is rate-scaled (render clock, not wall clock)

    /// The DSP position must ride the node's render clock, so at any tempo ≠ 1× it tracks the AUDIBLE
    /// position (a pure wall clock would advance at 1× and diverge — the pause/resume seek jump + wrong
    /// lock-screen elapsed + wrong durable-session position the review flagged).
    func testPositionAdvancesAtTheCurrentRate() async throws {
        let d = makeDSP()
        let url = try makeSineWAV(seconds: 6)
        defer { try? FileManager.default.removeItem(at: url) }
        d.engage(url: url, startMs: nil, lengthMs: nil, atSeconds: 0, songId: "x", play: true)
        try XCTSkipUnless(d.isReady, "no audio device on this test host")
        d.setRate(2.0)
        XCTAssertEqual(d.timePitchRate, 2.0, accuracy: 1e-5)
        // Let the render clock settle into the 2× region, then measure the position advance over a
        // known wall-time window. At 2× tempo the SOURCE position advances ~2× wall time.
        try await Task.sleep(nanoseconds: 300_000_000)
        let t0 = d.currentTime
        try await Task.sleep(nanoseconds: 500_000_000)   // 0.5 s of wall time
        let t1 = d.currentTime
        XCTAssertGreaterThan(t0, 0, "the render clock advanced from 0")
        XCTAssertEqual(t1 - t0, 1.0, accuracy: 0.35,
                       "at 2× tempo, 0.5 s of wall time advances ~1.0 s of source (a wall clock would give ~0.5)")
        d.disengage()
    }

    // MARK: - FIX 1: a non-member play tears the engaged DSP down (the double-audio guard)

    /// With the panel engaged on a SET track, a non-member single-row play (a Browse/collection single)
    /// changes `nowPlaying` to a track that is NOT in the running set. The orphaned DSP must be torn
    /// down — otherwise it keeps rendering the OLD set track and two songs sound at once. Pure
    /// SetlistPlayer wiring (no audio device needed): `engageMix` sets the flag, and the nowPlaying
    /// change drives the teardown BEFORE the not-in-set early return.
    func testNonMemberPlayTearsDownEngagedMix() async {
        let rips = makeRips(); let burns = makeBurns(rips)
        let player = PlayerEngine()
        let coord = makeCoordinator(rips: rips, player: player)
        let seq = SetlistPlayer(player: player, rips: rips, burns: burns, coordinator: coord)
        seq.dsp = makeDSP()
        addTeardownBlock { @MainActor in seq.stop() }
        await burn(rips, burns, songId: "np_guard")

        seq.play([.init(id: "np_guard", title: "Guard", artist: "A")])
        await waitUntil("burnt file playing") { rips.nowPlaying?.songId == "np_guard" }
        XCTAssertTrue(seq.currentTrackMixable)

        seq.engageMix()
        XCTAssertTrue(seq.mixEngaged, "the mix engaged the current set track")

        // A non-member single-row play takes the audio over the AVPlayer and points nowPlaying at a
        // track that is NOT in the set.
        let single = FileManager.default.temporaryDirectory
            .appendingPathComponent("np-single-\(UUID().uuidString).mp3")
        rips.setNowPlaying(.init(songId: "not_in_set", title: "Single", artist: "B",
                                 url: single, live: false, startMs: nil, seekMs: nil, waveform: nil))
        await waitUntil("the orphaned DSP tore down") { seq.mixEngaged == false }
        XCTAssertFalse(seq.mixEngaged, "a non-member play tears the engaged DSP down — no double audio")
        XCTAssertEqual(seq.index, 0, "the non-member play left the set index unchanged (not adopted)")
    }

    // MARK: - Node-completion DSP end advances the set across the swap (needs an audio device)

    /// A short WAV engaged into the DSP: when its slice plays to the natural end, the node completion
    /// handler fires `handleDSPEnded`, which tears the engagement down and advances the set index —
    /// headless auto-advance ACROSS the AVPlayer→DSP swap (the review's "not headless-testable" claim
    /// was overstated: the end fires from a real node completion handler).
    func testDSPNaturalEndAdvancesTheSet() async throws {
        let rips = makeRips(); let burns = makeBurns(rips)
        let player = PlayerEngine()
        let coord = makeCoordinator(rips: rips, player: player)
        let seq = SetlistPlayer(player: player, rips: rips, burns: burns, coordinator: coord)
        let dsp = makeDSP()
        seq.dsp = dsp
        addTeardownBlock { @MainActor in seq.stop() }
        // Track 0 is the mixable current track; track 1 has a burned file so the set holds at index 1
        // once advanced (rather than skipping a dead source on to end-of-set).
        await burn(rips, burns, songId: "np_end1")
        await burn(rips, burns, songId: "np_end2")

        seq.play([.init(id: "np_end1", title: "End1", artist: "A"),
                  .init(id: "np_end2", title: "End2", artist: "A")])
        await waitUntil("track 0 playing") { rips.nowPlaying?.songId == "np_end1" }

        // Point the DSP source at a REAL short WAV (engage opens THIS; the burned fixture is only
        // placeholder bytes and just satisfies the mixable gate). Same songId ⇒ not an adopt.
        let wav = try makeSineWAV(seconds: 0.3)
        defer { try? FileManager.default.removeItem(at: wav) }
        rips.setNowPlaying(.init(songId: "np_end1", title: "End1", artist: "A",
                                 url: wav, live: false, startMs: nil, seekMs: nil, waveform: nil))
        XCTAssertTrue(seq.currentTrackMixable)

        seq.engageMix()
        try XCTSkipUnless(dsp.isReady, "no audio device on this test host")
        XCTAssertTrue(dsp.isEngaged, "engaged the real WAV off the AVPlayer")
        if !dsp.isPlaying { dsp.resume() }   // ensure the slice actually plays to its end
        XCTAssertTrue(dsp.isPlaying)

        await waitUntil("DSP node-completion advanced the set index") { seq.index == 1 }
        XCTAssertEqual(seq.index, 1, "the DSP's natural end advanced the set")
        XCTAssertFalse(seq.mixEngaged, "the engagement was torn down before advancing")
        XCTAssertFalse(dsp.isEngaged, "the DSP handed the audio back")
    }

    // MARK: - Stems-toggle regression (the toggle must never fake an end-of-track)
    //
    // `AVAudioPlayerNode.stop()` FIRES the flushed segment's completion handler. `setStemMode`
    // stops voices in both directions, and without a `generation` bump at its commit points the
    // flushed completion passed `handleReachedEnd`'s staleness guard, faked a natural end, and
    // `SetlistPlayer.handleDSPEnded` advanced the set — enabling stems mid-song SKIPPED the song
    // (and `advanceToNext` rewrote the durable-session row at position 0).

    func testEnablingStemsDoesNotEndTheTrack() async throws {
        let d = try makeStemmedDSP(songId: "pdj_stx1", stemSeconds: 3)
        let url = try makeSineWAV(seconds: 3)
        defer { try? FileManager.default.removeItem(at: url) }
        d.engage(url: url, startMs: nil, lengthMs: nil, atSeconds: 0, songId: "pdj_stx1", play: true)
        try XCTSkipUnless(d.isReady, "no audio device on this test host")
        var ends = 0
        d.onReachedEnd = { ends += 1 }
        try await Task.sleep(nanoseconds: 150_000_000)
        let before = d.currentTime
        XCTAssertTrue(d.setStemMode(true), "burned stems → the toggle engages")
        // Long enough for the flushed main-file completion's main-actor hop, far short of the 3 s end.
        try await Task.sleep(nanoseconds: 300_000_000)
        XCTAssertEqual(ends, 0, "the toggle's flushed completion must read stale — no fake end")
        XCTAssertTrue(d.stemMode)
        XCTAssertTrue(d.isPlaying, "still playing, now through the stems")
        XCTAssertLessThan(d.currentTime, d.duration, "nowhere near the end")
        XCTAssertGreaterThanOrEqual(d.currentTime, before - 0.05,
                                    "position continued from the toggle point (no reset to 0)")
        d.disengage()
    }

    func testDisablingStemsDoesNotEndTheTrack() async throws {
        let d = try makeStemmedDSP(songId: "pdj_stx2", stemSeconds: 3)
        let url = try makeSineWAV(seconds: 3)
        defer { try? FileManager.default.removeItem(at: url) }
        d.engage(url: url, startMs: nil, lengthMs: nil, atSeconds: 0, songId: "pdj_stx2", play: true)
        try XCTSkipUnless(d.isReady, "no audio device on this test host")
        var ends = 0
        d.onReachedEnd = { ends += 1 }
        XCTAssertTrue(d.setStemMode(true))
        try await Task.sleep(nanoseconds: 200_000_000)
        XCTAssertTrue(d.setStemMode(false), "toggling back OFF mid-song")
        try await Task.sleep(nanoseconds: 300_000_000)
        XCTAssertEqual(ends, 0, "the flushed lead-stem completion must read stale — no fake end")
        XCTAssertFalse(d.stemMode)
        XCTAssertTrue(d.isPlaying, "still playing, back through the single file")
        XCTAssertLessThan(d.currentTime, d.duration)
        d.disengage()
    }

    func testStemToggleWhilePausedKeepsPosition() async throws {
        let d = try makeStemmedDSP(songId: "pdj_stx3", stemSeconds: 3)
        let url = try makeSineWAV(seconds: 3)
        defer { try? FileManager.default.removeItem(at: url) }
        d.engage(url: url, startMs: nil, lengthMs: nil, atSeconds: 1.0, songId: "pdj_stx3", play: false)
        try XCTSkipUnless(d.isReady, "no audio device on this test host")
        var ends = 0
        d.onReachedEnd = { ends += 1 }
        XCTAssertTrue(d.setStemMode(true))
        XCTAssertTrue(d.setStemMode(false))
        try await Task.sleep(nanoseconds: 250_000_000)
        XCTAssertEqual(ends, 0, "no end fires from a paused toggle")
        XCTAssertFalse(d.isPlaying, "still paused")
        XCTAssertEqual(d.currentTime, 1.0, accuracy: 0.05, "the paused position survives both toggles")
        d.disengage()
    }

    /// The OFF path's `scheduleMain`-failure branch: toggling stems off once the playhead has reached
    /// the slice end leaves nothing to schedule, so the track really IS over. It must report that end
    /// EXACTLY once and land on a coherent stopped state — before this fix it returned `true` with
    /// `isPlaying` stale-true and no end at all (the set would hang on a finished track).
    ///
    /// Driven deterministically by `lengthMs`: the slice is 1 s of a 3 s file while the stems run the
    /// full 3 s, so the stems are still sounding (no natural end yet) once `currentTime` has clamped to
    /// `duration` — exactly the state the branch guards.
    func testTogglingStemsOffAtTheSliceEndReportsTheEndExactlyOnce() async throws {
        let d = try makeStemmedDSP(songId: "pdj_stx9", stemSeconds: 3)
        let url = try makeSineWAV(seconds: 3)
        defer { try? FileManager.default.removeItem(at: url) }
        d.engage(url: url, startMs: nil, lengthMs: 1_000, atSeconds: 0, songId: "pdj_stx9", play: true)
        try XCTSkipUnless(d.isReady, "no audio device on this test host")
        XCTAssertEqual(d.duration, 1.0, accuracy: 0.01, "lengthMs bounds the slice to 1 s")
        var ends = 0
        d.onReachedEnd = { ends += 1 }
        XCTAssertTrue(d.setStemMode(true))
        try await Task.sleep(nanoseconds: 1_300_000_000)   // past the 1 s slice; the 3 s stems play on
        XCTAssertEqual(ends, 0, "the stems have not reached their own end")
        XCTAssertEqual(d.currentTime, d.duration, accuracy: 1e-9, "the playhead clamped to the slice end")

        XCTAssertTrue(d.setStemMode(false), "the toggle still succeeds — it just reports the end")
        try await Task.sleep(nanoseconds: 250_000_000)     // the deferred Task hop
        XCTAssertEqual(ends, 1, "the end is reported exactly once, deferred out of setStemMode")
        XCTAssertFalse(d.isPlaying)
        XCTAssertFalse(d.stemMode)
        XCTAssertEqual(d.currentTime, d.duration, accuracy: 1e-9)
        d.disengage()
    }

    /// The anti-over-correction test: after a toggle the NEW voices' natural end must still fire —
    /// a naive top-of-function `generation` bump (or a bump AFTER `scheduleStems` captured its
    /// generation) would swallow it and the set would stall forever.
    func testNaturalEndStillFiresAfterAStemToggle() async throws {
        let d = try makeStemmedDSP(songId: "pdj_stx4", stemSeconds: 0.3)
        let url = try makeSineWAV(seconds: 0.3)
        defer { try? FileManager.default.removeItem(at: url) }
        d.engage(url: url, startMs: nil, lengthMs: nil, atSeconds: 0, songId: "pdj_stx4", play: true)
        try XCTSkipUnless(d.isReady, "no audio device on this test host")
        var ends = 0
        d.onReachedEnd = { ends += 1 }
        XCTAssertTrue(d.setStemMode(true), "toggle on while playing")
        await waitUntil("the stems' NATURAL end fires") { ends > 0 }
        try await Task.sleep(nanoseconds: 200_000_000)   // room for any stale double-fire to land
        XCTAssertEqual(ends, 1, "exactly one end — the real one")
        d.disengage()
    }

    /// The refusal path must not invalidate the armed end: `setStemMode(true)` without burned stems
    /// returns false BEFORE any generation bump or stop, so the main file's natural end still fires.
    func testStemToggleRefusedWithoutStemsLeavesTheEndArmed() async throws {
        let d = makeDSP()   // no stems burned for this song
        let url = try makeSineWAV(seconds: 0.3)
        defer { try? FileManager.default.removeItem(at: url) }
        d.engage(url: url, startMs: nil, lengthMs: nil, atSeconds: 0, songId: "np_stx5", play: true)
        try XCTSkipUnless(d.isReady, "no audio device on this test host")
        var ends = 0
        d.onReachedEnd = { ends += 1 }
        XCTAssertFalse(d.setStemMode(true), "no burned stems → refused")
        XCTAssertFalse(d.stemMode)
        XCTAssertTrue(d.isPlaying, "the refusal must not touch the playing main file")
        await waitUntil("the main file's natural end still fires") { ends > 0 }
        XCTAssertEqual(ends, 1)
        d.disengage()
    }

    /// Rapid on→off→on with no render time in between: every flushed completion (main file and lead
    /// stem) must read stale against the LATEST generation — zero fake ends, still playing.
    func testRapidDoubleToggleKeepsPlayingWithoutAFakeEnd() async throws {
        let d = try makeStemmedDSP(songId: "pdj_stx7", stemSeconds: 3)
        let url = try makeSineWAV(seconds: 3)
        defer { try? FileManager.default.removeItem(at: url) }
        d.engage(url: url, startMs: nil, lengthMs: nil, atSeconds: 0, songId: "pdj_stx7", play: true)
        try XCTSkipUnless(d.isReady, "no audio device on this test host")
        var ends = 0
        d.onReachedEnd = { ends += 1 }
        XCTAssertTrue(d.setStemMode(true))
        XCTAssertTrue(d.setStemMode(false))
        XCTAssertTrue(d.setStemMode(true))
        try await Task.sleep(nanoseconds: 400_000_000)
        XCTAssertEqual(ends, 0, "three rapid toggles, zero fake ends")
        XCTAssertTrue(d.stemMode)
        XCTAssertTrue(d.isPlaying)
        XCTAssertLessThan(d.currentTime, d.duration)
        d.disengage()
    }

    /// "Toggle mid-seek" is unreachable — the DSP exposes no seek, and `beginExternalNowPlaying`
    /// wires only play/pause — so the closest real race is a toggle landing right after `resume()`
    /// (re)scheduled the main file but before its voice renders (inside the 60 ms start lead). The
    /// toggle must supersede the resume via the higher generation: no fake end, stems playing.
    func testToggleImmediatelyAfterResumeDoesNotEndTheTrack() async throws {
        let d = try makeStemmedDSP(songId: "pdj_stx8", stemSeconds: 3)
        let url = try makeSineWAV(seconds: 3)
        defer { try? FileManager.default.removeItem(at: url) }
        d.engage(url: url, startMs: nil, lengthMs: nil, atSeconds: 0.5, songId: "pdj_stx8", play: true)
        try XCTSkipUnless(d.isReady, "no audio device on this test host")
        var ends = 0
        d.onReachedEnd = { ends += 1 }
        try await Task.sleep(nanoseconds: 150_000_000)
        d.pause()
        d.resume()                            // reschedules the main file (its own generation bump)
        XCTAssertTrue(d.setStemMode(true))    // lands inside the resume's start lead
        try await Task.sleep(nanoseconds: 300_000_000)
        XCTAssertEqual(ends, 0, "the superseded resume's completion reads stale — no fake end")
        XCTAssertTrue(d.stemMode)
        XCTAssertTrue(d.isPlaying)
        XCTAssertLessThan(d.currentTime, d.duration)
        d.disengage()
    }

    /// The integration shape of the bug (modeled on `testDSPNaturalEndAdvancesTheSet`, but with a
    /// 3 s WAV so the real end can't confound it): enabling stems mid-song must NOT advance the set,
    /// must NOT tear the engagement down, and must NOT rewrite the durable-session row.
    func testStemToggleDoesNotAdvanceTheSet() async throws {
        let rips = makeRips(); let burns = makeBurns(rips)
        let player = PlayerEngine()
        let coord = makeCoordinator(rips: rips, player: player)
        let seq = SetlistPlayer(player: player, rips: rips, burns: burns, coordinator: coord)
        let dsp = NowPlayingDSP(burns: burns)
        seq.dsp = dsp
        addTeardownBlock { @MainActor in seq.stop() }

        // Track 0 is a "Pocket DJ" profile row: `profileResolve` plays a REAL 3 s WAV (long enough
        // that its natural end can't confound the assertion) and `profileStemResolve` supplies 4 real
        // decodable stems. It is ALSO burned, because `currentTrackMixable` gates on a burned-or-studio
        // id — the panel's own eligibility check, not something this fix touches. Track 1 is burned so
        // a wrong advance PARKS the set at index 1 instead of running off the end.
        let wav = try makeSineWAV(seconds: 3)
        defer { try? FileManager.default.removeItem(at: wav) }
        let stems = try stemURLs(seconds: 3)
        seq.profileResolve = { $0 == "pdj_stx6a" ? (url: wav, release: nil, title: "S1", lengthMs: 3_000) : nil }
        dsp.profileStemResolve = { $0 == "pdj_stx6a" ? stems : nil }
        await burn(rips, burns, songId: "pdj_stx6a")
        await burn(rips, burns, songId: "np_stx6b")

        seq.play([.init(id: "pdj_stx6a", title: "S1", artist: "A"),
                  .init(id: "np_stx6b", title: "S2", artist: "A")])
        await waitUntil("track 0 playing") { rips.nowPlaying?.songId == "pdj_stx6a" }
        XCTAssertTrue(seq.currentTrackMixable)

        seq.engageMix()
        try XCTSkipUnless(dsp.isReady, "no audio device on this test host")
        XCTAssertTrue(seq.mixEngaged, "precondition: the DSP owns the audio")
        if !dsp.isPlaying { dsp.resume() }
        XCTAssertTrue(dsp.isPlaying)

        XCTAssertTrue(dsp.setStemMode(true), "real stems → the toggle engages")
        try await Task.sleep(nanoseconds: 400_000_000)
        XCTAssertEqual(seq.index, 0, "the toggle must NOT advance the set (the reported skip)")
        XCTAssertTrue(seq.mixEngaged, "the engagement survives — no teardown, no session-row rewrite")
        XCTAssertTrue(dsp.isEngaged)
        XCTAssertTrue(dsp.stemMode)
        XCTAssertTrue(dsp.isPlaying)
    }
}

/// A tiny URLProtocol stub for these tests: serves the burned mp3 bytes for `rips/*.mp3` and drives
/// the rip-server path (POST /rip → job → live HLS) when `streamOnly` is set.
private final class NPDSPStubURLProtocol: URLProtocol {
    nonisolated(unsafe) static var body = Data("MP3".utf8)
    /// When true, the rip server resolves to a LIVE HLS stream (never a durable mp3) — for the
    /// non-mixable stream tests.
    nonisolated(unsafe) static var streamOnly = false

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func stopLoading() {}

    override func startLoading() {
        let url = request.url!
        let path = url.path
        func reply(_ status: Int, _ data: Data, json: Bool = false) {
            let headers = json ? ["Content-Type": "application/json"] : ["Content-Type": "audio/mpeg"]
            let resp = HTTPURLResponse(url: url, statusCode: status, httpVersion: "HTTP/1.1", headerFields: headers)!
            client?.urlProtocol(self, didReceive: resp, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: data)
            client?.urlProtocolDidFinishLoading(self)
        }
        if path.hasSuffix("/manifest.json") {
            reply(200, Data("{}".utf8), json: true)
        } else if path.hasSuffix("/rip") {
            // A job that immediately offers a live HLS stream (streamOnly) — the non-mixable path.
            let job = #"{"jobId":"j1","phase":"streaming","streamUrl":"/hls/np_stream/index.m3u8"}"#
            reply(200, Data(job.utf8), json: true)
        } else if path.contains("/hls/") {
            reply(200, Data("#EXTM3U".utf8))
        } else {
            reply(200, Self.body)
        }
    }
}

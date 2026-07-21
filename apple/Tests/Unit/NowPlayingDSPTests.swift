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

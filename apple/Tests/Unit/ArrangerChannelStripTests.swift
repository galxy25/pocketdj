import XCTest
import AVFoundation
@testable import PocketDJ

/// The arranger's per-track channel strip (pitch/tempo + 3-band EQ + reverb/delay/chorus) and the
/// additive-optional schema around it. Pure/hermetic: the model + clamp + flag logic and a no-engine
/// smoke of the FX kernel (it processes a buffer I allocate; no AVAudioEngine, so CI-safe).
final class ArrangerChannelStripTests: XCTestCase {

    private func roundTrip<T: Codable>(_ v: T, as: T.Type) throws -> T {
        try JSONDecoder().decode(T.self, from: JSONEncoder().encode(v))
    }

    // MARK: clamp

    func testStripClampsEveryFieldIntoRange() {
        var s = StudioChannelStrip()
        s.pitchSemitones = 99; s.tempoRatio = 9; s.eqLowDb = -80; s.eqMidDb = 80
        s.eqHighDb = 0.5; s.reverb = 3; s.delay = -1; s.chorus = 0.4
        let c = s.clamped()
        XCTAssertEqual(c.pitchSemitones, 12)
        XCTAssertEqual(c.tempoRatio, 2)
        XCTAssertEqual(c.eqLowDb, -18)
        XCTAssertEqual(c.eqMidDb, 18)
        XCTAssertEqual(c.eqHighDb, 0.5)
        XCTAssertEqual(c.reverb, 1)
        XCTAssertEqual(c.delay, 0)
        XCTAssertEqual(c.chorus, 0.4)
    }

    // MARK: flags

    func testBakesAudioOnlyForPitchOrTempo() {
        XCTAssertFalse(StudioChannelStrip().bakesAudio)
        var p = StudioChannelStrip(); p.pitchSemitones = 2
        XCTAssertTrue(p.bakesAudio)
        var t = StudioChannelStrip(); t.tempoRatio = 1.1
        XCTAssertTrue(t.bakesAudio)
        // A pure-EQ/FX strip changes NOTHING that needs a re-bake.
        var fx = StudioChannelStrip(); fx.eqMidDb = 6; fx.reverb = 0.5
        XCTAssertFalse(fx.bakesAudio)
        XCTAssertTrue(fx.hasLiveFX)
    }

    func testTrackFXParamsActiveMirrorsStrip() {
        XCTAssertFalse(TrackFXParams(StudioChannelStrip(), bpm: 120).active)
        var s = StudioChannelStrip(); s.delay = 0.2
        XCTAssertTrue(TrackFXParams(s, bpm: 120).active)
        // pitch/tempo are NOT part of the live params → they don't make it "active".
        var p = StudioChannelStrip(); p.pitchSemitones = 5; p.tempoRatio = 1.5
        XCTAssertFalse(TrackFXParams(p, bpm: 120).active)
    }

    // MARK: additive-optional schema (no version bump; old docs survive)

    func testStripRoundTripPreservesFields() throws {
        var s = StudioChannelStrip()
        s.pitchSemitones = -3; s.tempoRatio = 1.25; s.eqLowDb = 4; s.eqMidDb = -2
        s.eqHighDb = 6; s.reverb = 0.3; s.delay = 0.1; s.chorus = 0.7
        XCTAssertEqual(try roundTrip(s, as: StudioChannelStrip.self), s)
    }

    func testLegacyTrackDecodesNeutralStrip() throws {
        // A pre-feature track JSON has no "strip" key → a neutral strip, no throw.
        let json = #"{"id":"trk_1","name":"Drums","gainDb":0,"pan":0}"#
        let t = try JSONDecoder().decode(StudioTrack.self, from: Data(json.utf8))
        XCTAssertEqual(t.strip, StudioChannelStrip())
        XCTAssertFalse(t.strip.bakesAudio)
    }

    func testLegacyClipDecodesNilGrid_andArrangementNoBeatMatch() throws {
        let clip = try JSONDecoder().decode(StudioClip.self,
            from: Data(#"{"id":"clip_1","name":"a","fileName":"clip-a.m4a"}"#.utf8))
        XCTAssertNil(clip.grid)
        let arr = try JSONDecoder().decode(StudioArrangement.self,
            from: Data(#"{"id":"arr_1","name":"Mix","bpm":128}"#.utf8))
        XCTAssertFalse(arr.beatMatchEnabled)
        XCTAssertEqual(arr.bpm, 128)
    }

    func testClipGridRoundTrips() throws {
        var clip = StudioClip(id: "clip_1", name: "a", fileName: "clip-a.m4a")
        clip.grid = StudioGrid(bpm: 174, firstDownbeatMs: 12)
        let back = try roundTrip(clip, as: StudioClip.self)
        XCTAssertEqual(back.grid?.bpm, 174)
        XCTAssertEqual(back.grid?.firstDownbeatMs, 12)
    }

    // MARK: beatGridReady gating

    func testBeatGridReady() {
        var arr = StudioArrangement(id: "arr_1", name: "Mix")
        XCTAssertTrue(arr.beatGridReady)   // no clips → nothing to analyze
        var track = StudioTrack(id: "trk_1", name: "T")
        track.clips = [StudioClip(id: "c1", name: "a", fileName: "clip-a.m4a"),
                       StudioClip(id: "c2", name: "b", fileName: "clip-b.m4a")]
        arr.tracks = [track]
        XCTAssertFalse(arr.beatGridReady)  // neither clip analyzed
        arr.tracks[0].clips[0].grid = StudioGrid(bpm: 120)
        XCTAssertFalse(arr.beatGridReady)  // one still pending
        arr.tracks[0].clips[1].grid = StudioGrid(bpm: 0)   // sentinel "analyzed, no tempo"
        XCTAssertTrue(arr.beatGridReady)   // all analyzed → gate opens
    }

    // MARK: FX kernel — no-engine smoke (finite, audible, stable)

    func testTrackFXKernelProducesFiniteAudibleOutput() throws {
        let fmt = AVAudioFormat(standardFormatWithSampleRate: 44_100, channels: 2)!
        let frames = 8192
        guard let buf = AVAudioPCMBuffer(pcmFormat: fmt, frameCapacity: AVAudioFrameCount(frames)),
              let data = buf.floatChannelData else { return XCTFail("no buffer") }
        buf.frameLength = AVAudioFrameCount(frames)
        for ch in 0..<2 {
            for i in 0..<frames { data[ch][i] = Float(sin(2 * .pi * 220 * Double(i) / 44_100)) * 0.5 }
        }
        var s = StudioChannelStrip()
        s.eqLowDb = 6; s.eqHighDb = -4; s.reverb = 0.6; s.delay = 0.3; s.chorus = 0.5
        let kernel = TrackFXKernel()
        kernel.configure(sampleRate: 44_100, channelCount: 2)
        kernel.update(TrackFXParams(s, bpm: 120))
        XCTAssertTrue(kernel.active)
        kernel.processFloatChannels(data, channelCount: 2, frames: frames)

        var peak: Float = 0
        for ch in 0..<2 {
            for i in 0..<frames {
                let v = data[ch][i]
                XCTAssertTrue(v.isFinite, "sample \(ch),\(i) not finite")
                peak = max(peak, abs(v))
            }
        }
        XCTAssertGreaterThan(peak, 0.01, "kernel silenced the signal")
        XCTAssertLessThan(peak, 8, "kernel blew up the signal")
    }

    func testNeutralKernelIsPassthrough() {
        let fmt = AVAudioFormat(standardFormatWithSampleRate: 44_100, channels: 2)!
        let frames = 1024
        guard let buf = AVAudioPCMBuffer(pcmFormat: fmt, frameCapacity: AVAudioFrameCount(frames)),
              let data = buf.floatChannelData else { return XCTFail("no buffer") }
        buf.frameLength = AVAudioFrameCount(frames)
        for i in 0..<frames { data[0][i] = 0.25; data[1][i] = -0.25 }
        let kernel = TrackFXKernel()
        kernel.configure(sampleRate: 44_100, channelCount: 2)
        kernel.update(TrackFXParams())   // neutral → active == false → early return
        XCTAssertFalse(kernel.active)
        kernel.processFloatChannels(data, channelCount: 2, frames: frames)
        XCTAssertEqual(data[0][10], 0.25, accuracy: 1e-6)   // untouched
        XCTAssertEqual(data[1][10], -0.25, accuracy: 1e-6)
    }
}

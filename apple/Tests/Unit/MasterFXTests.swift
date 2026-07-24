import XCTest
import AVFoundation
@testable import PocketDJ

/// The arranger master-FX kernel is pure, deterministic DSP — so it's unit-testable off-device
/// (unlike live audio quality). These pin the load-bearing invariants: neutral is bit-passthrough,
/// master gain scales, ring-mod actually modulates, and freeze is stripped for a bounce.
final class MasterFXTests: XCTestCase {
    private let fmt = StudioAudio.canonicalFormat
    private let frames = 512

    /// A canonical stereo buffer filled with a constant value on both channels.
    private func makeBuffer(fill: Float) -> AVAudioPCMBuffer {
        let buf = AVAudioPCMBuffer(pcmFormat: fmt, frameCapacity: AVAudioFrameCount(frames))!
        buf.frameLength = AVAudioFrameCount(frames)
        let ch = buf.floatChannelData!
        for c in 0..<2 { for i in 0..<frames { ch[c][i] = fill } }
        return buf
    }

    private func run(_ params: MasterFXParams, on buf: AVAudioPCMBuffer) {
        let kernel = MasterFXKernel()
        kernel.configure(sampleRate: fmt.sampleRate, channelCount: 2)
        kernel.update(params)
        kernel.processFloatChannels(buf.floatChannelData!, channelCount: 2, frames: frames, framePos: 0)
    }

    /// Neutral params (no effects, unity gain) leave the signal untouched — `active` is false and
    /// `process` early-returns, so nothing is even read.
    func testNeutralIsPassthrough() {
        let buf = makeBuffer(fill: 0.1)
        run(MasterFXParams(), on: buf)
        let ch = buf.floatChannelData!
        for i in stride(from: 0, to: frames, by: 97) {
            XCTAssertEqual(ch[0][i], 0.1, accuracy: 1e-6)
            XCTAssertEqual(ch[1][i], 0.1, accuracy: 1e-6)
        }
    }

    /// Master gain scales every sample (linear from dB). +6 dB ≈ ×2.
    func testMasterGainScales() {
        var p = MasterFXParams()
        p.masterGain = 2.0
        let buf = makeBuffer(fill: 0.1)
        run(p, on: buf)
        let ch = buf.floatChannelData!
        XCTAssertEqual(ch[0][0], 0.2, accuracy: 1e-4)
        XCTAssertEqual(ch[1][frames - 1], 0.2, accuracy: 1e-4)
    }

    /// Ring modulation multiplies the through-signal by an internal carrier — a DC input comes out
    /// oscillating: the first sample (carrier phase 0 ⇒ sin 0) is ~0, and later samples diverge from
    /// the input.
    func testRingModModulatesDC() {
        var p = MasterFXParams()
        p.ringMod = true; p.ringFreq = 100; p.ringMix = 1.0
        let buf = makeBuffer(fill: 0.5)
        run(p, on: buf)
        let ch = buf.floatChannelData!
        XCTAssertEqual(ch[0][0], 0, accuracy: 0.02)                 // carrier starts at sin(0)=0
        var moved = false
        for i in 0..<frames where abs(ch[0][i] - 0.5) > 0.1 { moved = true; break }
        XCTAssertTrue(moved, "ring mod must change a DC input")
        for i in 0..<frames { XCTAssertLessThanOrEqual(abs(ch[0][i]), 0.51) }   // |x·sin| ≤ |x|
    }

    /// A bounce strips freeze (a live-only capture-and-hold); playback keeps it.
    func testFreezeBypassedForBounceParams() {
        var fx = StudioMasterFX()
        fx.freezeEnabled = true
        XCTAssertTrue(MasterFXParams(fx, bpm: 120, allowFreeze: true).freeze)
        XCTAssertFalse(MasterFXParams(fx, bpm: 120, allowFreeze: false).freeze)
    }
}

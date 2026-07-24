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

    /// Freezer holds REAL audio even when it's the only effect: a dry master keeps the capture ring
    /// warm, so enabling only the Freezer over a now-silent input outputs the held tail, not silence.
    /// (Regression: the ring used to be warmed only on the active path → a standalone Freezer went
    /// silent.)
    func testFreezerHoldsWarmedAudioNotSilence() {
        let kernel = MasterFXKernel()
        kernel.configure(sampleRate: fmt.sampleRate, channelCount: 2)
        // Warm the ring past its 0.25 s length with a non-zero signal while the master is DRY.
        let warmFrames = Int(fmt.sampleRate * 0.25) + 128
        let warm = AVAudioPCMBuffer(pcmFormat: fmt, frameCapacity: AVAudioFrameCount(warmFrames))!
        warm.frameLength = AVAudioFrameCount(warmFrames)
        for c in 0..<2 { for i in 0..<warmFrames { warm.floatChannelData![c][i] = 0.4 } }
        kernel.update(MasterFXParams())    // dry → passthrough, but ring stays warm
        kernel.processFloatChannels(warm.floatChannelData!, channelCount: 2, frames: warmFrames, framePos: 0)
        // Now enable ONLY freeze and feed silence — output should be the held 0.4, not 0.
        var fp = MasterFXParams(); fp.freeze = true
        kernel.update(fp)
        let silent = makeBuffer(fill: 0.0)
        kernel.processFloatChannels(silent.floatChannelData!, channelCount: 2, frames: frames, framePos: Double(warmFrames))
        let ch = silent.floatChannelData!
        XCTAssertGreaterThan(abs(ch[0][frames - 1]), 0.3, "freeze must hold the warmed audio, not silence")
    }

    /// A bounce strips freeze (a live-only capture-and-hold); playback keeps it.
    func testFreezeBypassedForBounceParams() {
        var fx = StudioMasterFX()
        fx.freezeEnabled = true
        XCTAssertTrue(MasterFXParams(fx, bpm: 120, allowFreeze: true).freeze)
        XCTAssertFalse(MasterFXParams(fx, bpm: 120, allowFreeze: false).freeze)
    }
}

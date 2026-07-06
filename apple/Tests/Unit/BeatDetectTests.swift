import XCTest
import AVFoundation
@testable import PocketDJ

/// On-device beat detection (`BeatDetect`, Studio round 4). Hermetic: builds synthetic click
/// tracks in memory (no engine, no session, no fixture audio) and asserts the whole chain —
/// spectral-flux onset envelope → autocorrelation tempo → octave-fold → downbeat phase — recovers
/// the planted tempo. Integer autocorrelation at the STFT frame rate (~86 fps) quantizes the lag,
/// so the BPM tolerance below (±3.5) is the honest resolution of the constant-grid estimate, not
/// slack — a slice grid only needs the tempo, not sample-accurate beats.
final class BeatDetectTests: XCTestCase {
    private let sr = 44_100.0
    private let tol = 3.5

    // MARK: - octave fold (mirrors analyze-beatgrid.py octave_fold)

    func testOctaveFoldPullsIntoDJWindow() {
        XCTAssertEqual(BeatDetect.octaveFold(60), 120, accuracy: 0.001)   // slow → doubled
        XCTAssertEqual(BeatDetect.octaveFold(65), 130, accuracy: 0.001)
        XCTAssertEqual(BeatDetect.octaveFold(200), 100, accuracy: 0.001)  // fast → halved
        XCTAssertEqual(BeatDetect.octaveFold(240), 120, accuracy: 0.001)  // two halvings
        XCTAssertEqual(BeatDetect.octaveFold(120), 120, accuracy: 0.001)  // in-window: untouched
        XCTAssertEqual(BeatDetect.octaveFold(75), 75, accuracy: 0.001)
        XCTAssertEqual(BeatDetect.octaveFold(180), 180, accuracy: 0.001)  // hi edge stays
    }

    func testOctaveFoldGuardsNonPositive() {
        XCTAssertEqual(BeatDetect.octaveFold(0), 0)
        XCTAssertEqual(BeatDetect.octaveFold(-4), -4)
    }

    // MARK: - tempo recovery across the DJ window

    func testDetectsInWindowTempos() throws {
        for bpm in [90.0, 100, 120, 128, 140, 160] {
            let grid = try XCTUnwrap(BeatDetect.detectGrid(clickTrack(bpm: bpm, seconds: 10)),
                                     "no grid at \(bpm) BPM")
            XCTAssertEqual(grid.bpm, bpm, accuracy: tol, "detected \(grid.bpm) for planted \(bpm)")
            XCTAssertTrue(grid.beatsMs.isEmpty, "constant grid — no measured per-beat timestamps")
            XCTAssertGreaterThanOrEqual(grid.firstDownbeatMs, 0)
        }
    }

    func testFoldsOctaveErrorsIntoWindow() throws {
        // A 60 BPM pulse train has no autocorrelation lag inside [70,180]'s window at its
        // fundamental (that lag is too long), so detection locks the octave it CAN see and the
        // fold reports the musical 120. Likewise a 200 BPM train reports 100.
        let slow = try XCTUnwrap(BeatDetect.detectGrid(clickTrack(bpm: 60, seconds: 10)))
        XCTAssertEqual(slow.bpm, 120, accuracy: tol)
        let fast = try XCTUnwrap(BeatDetect.detectGrid(clickTrack(bpm: 200, seconds: 8)))
        XCTAssertEqual(fast.bpm, 100, accuracy: tol)
    }

    // MARK: - downbeat phase

    func testDownbeatLandsOnAccentedBeat() throws {
        // Accent every 4th beat (a 4/4 kick); the onset-energy heuristic should pick that beat as
        // the downbeat. The accent phase here starts on beat 0, so the first downbeat should fall
        // within one beat of 0:00.
        let bpm = 120.0
        let grid = try XCTUnwrap(BeatDetect.detectGrid(clickTrack(bpm: bpm, seconds: 12, accentEvery: 4)))
        let beatMs = 60_000.0 / bpm
        let phase = Double(grid.firstDownbeatMs).truncatingRemainder(dividingBy: 4 * beatMs)
        // within half a beat of a bar start (0 or a full bar)
        XCTAssertTrue(phase < beatMs * 0.5 || phase > 4 * beatMs - beatMs * 0.5,
                      "downbeat phase \(phase)ms not aligned to an accented beat (beat=\(beatMs)ms)")
    }

    // MARK: - reject non-signals

    func testSilenceYieldsNoGrid() {
        let fmt = AVAudioFormat(standardFormatWithSampleRate: sr, channels: 2)!
        let buf = AVAudioPCMBuffer(pcmFormat: fmt, frameCapacity: AVAudioFrameCount(sr * 5))!
        buf.frameLength = buf.frameCapacity                       // all-zero (fresh buffers zeroed here)
        XCTAssertNil(BeatDetect.detectGrid(buf))
    }

    func testTooShortYieldsNoGrid() {
        XCTAssertNil(BeatDetect.detectGrid(clickTrack(bpm: 120, seconds: 1)))  // < 2 s
    }

    // MARK: - synthetic click track

    /// Stereo 44.1k buffer with a short 1 kHz decaying click every `60/bpm` seconds. `accentEvery`
    /// (>0) makes every Nth click louder — a crude kick-on-the-downbeat for phase tests.
    private func clickTrack(bpm: Double, seconds: Double, accentEvery: Int = 0) -> AVAudioPCMBuffer {
        let fmt = AVAudioFormat(standardFormatWithSampleRate: sr, channels: 2)!
        let frames = Int(seconds * sr)
        let buf = AVAudioPCMBuffer(pcmFormat: fmt, frameCapacity: AVAudioFrameCount(frames))!
        buf.frameLength = AVAudioFrameCount(frames)
        let ch = buf.floatChannelData!
        for c in 0..<2 { memset(ch[c], 0, frames * MemoryLayout<Float>.size) }

        let period = Int(60.0 / bpm * sr)
        let clickLen = min(Int(0.012 * sr), period)               // ~12 ms burst
        var t = 0
        var beatIndex = 0
        while t < frames {
            let gain: Float = (accentEvery > 0 && beatIndex % accentEvery == 0) ? 1.0 : 0.4
            let len = min(clickLen, frames - t)
            for i in 0..<len {
                let decay = Float(1.0 - Double(i) / Double(clickLen))
                let s = gain * decay * sinf(Float(2.0 * Double.pi * 1000.0 * Double(i) / sr))
                ch[0][t + i] = s
                ch[1][t + i] = s
            }
            t += period
            beatIndex += 1
        }
        return buf
    }
}

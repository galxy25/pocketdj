import XCTest
import AVFoundation
@testable import PocketDJ

/// KeyDetector — on-device key (Camelot) detection for performance media. The correlation +
/// rotation + Camelot mapping are exercised against crafted pitch-class profiles (deterministic),
/// the MIDI path against clear triads, and the audio path against a synthesized tone.
final class KeyDetectorTests: XCTestCase {

    // The Krumhansl-Kessler profiles (C-rooted), duplicated here so the tests are self-checking.
    private let major: [Double] = [6.35, 2.23, 3.48, 2.33, 4.38, 4.09, 2.52, 5.19, 2.39, 3.66, 2.29, 2.88]
    private let minor: [Double] = [6.33, 2.68, 3.52, 5.38, 2.60, 3.53, 2.54, 4.75, 3.98, 2.69, 3.34, 3.17]

    /// Rotate a C-rooted profile so its tonic sits on pitch class `t` (chroma[i] = profile[i−t]).
    private func rooted(_ profile: [Double], at t: Int) -> [Double] {
        (0..<12).map { profile[(($0 - t) % 12 + 12) % 12] }
    }

    func testChromaProfileMapsToExpectedCamelot() {
        // A chroma EQUAL to a rooted profile correlates perfectly with that key.
        XCTAssertEqual(KeyDetector.detect(chroma: major)?.camelot, "8B")            // C major
        XCTAssertEqual(KeyDetector.detect(chroma: rooted(major, at: 2))?.camelot, "10B")  // D major
        XCTAssertEqual(KeyDetector.detect(chroma: rooted(major, at: 7))?.camelot, "9B")   // G major
        XCTAssertEqual(KeyDetector.detect(chroma: minor)?.camelot, "5A")            // C minor
        XCTAssertEqual(KeyDetector.detect(chroma: rooted(minor, at: 9))?.camelot, "8A")   // A minor
        XCTAssertEqual(KeyDetector.detect(chroma: rooted(minor, at: 4))?.camelot, "9A")   // E minor
    }

    func testEmptyChromaAndSilenceReturnNil() {
        XCTAssertNil(KeyDetector.detect(chroma: [Double](repeating: 0, count: 12)))
        XCTAssertNil(KeyDetector.detect(chroma: [1, 2, 3]))       // wrong length
        XCTAssertNil(KeyDetector.detect(noteEvents: []))
    }

    func testMidiTriadsDetectTheirKey() {
        // A C-major triad (C E G) held long ⇒ C major = 8B.
        let cMaj = [60, 64, 67].map { StudioNoteEvent(onMs: 0, offMs: 2_000, note: $0, velocity: 100) }
        XCTAssertEqual(KeyDetector.detect(noteEvents: cMaj)?.camelot, "8B")
        // An A-minor triad (A C E) ⇒ A minor = 8A.
        let aMin = [57, 60, 64].map { StudioNoteEvent(onMs: 0, offMs: 2_000, note: $0, velocity: 100) }
        XCTAssertEqual(KeyDetector.detect(noteEvents: aMin)?.camelot, "8A")
    }

    func testMidiOctaveFoldingIsPitchClassOnly() {
        // Notes in different octaves fold to the same pitch class — the detected key is unchanged.
        let low = [48, 52, 55].map { StudioNoteEvent(onMs: 0, offMs: 2_000, note: $0, velocity: 100) }
        XCTAssertEqual(KeyDetector.detect(noteEvents: low)?.camelot, "8B")   // C major, an octave down
    }

    /// The audio chromagram peaks at a pure tone's pitch class (a 261.63 Hz "C" sine ⇒ chroma at C).
    func testChromagramPeaksAtToneePitchClass() throws {
        let sr = 44_100.0
        let fmt = AVAudioFormat(standardFormatWithSampleRate: sr, channels: 1)!
        let frames = AVAudioFrameCount(sr * 2)
        let buf = AVAudioPCMBuffer(pcmFormat: fmt, frameCapacity: frames)!
        buf.frameLength = frames
        let freq = 261.63   // middle C
        let p = buf.floatChannelData![0]
        for i in 0..<Int(frames) { p[i] = sinf(Float(2.0 * .pi * freq * Double(i) / sr)) * 0.5 }
        let chroma = try XCTUnwrap(KeyDetector.chromagram(buf))
        let peak = chroma.firstIndex(of: chroma.max()!)!
        XCTAssertEqual(peak, 0, "a middle-C sine peaks at pitch class C (0)")
    }
}

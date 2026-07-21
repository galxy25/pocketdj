import XCTest
import AVFoundation
@testable import PocketDJ

/// MelodyTracker (Studio/Demux/MelodyTracker.swift) — F8 slice B. The monophonic f0 estimator on
/// synthetic pure tones, and the PURE note segmentation (voiced/unvoiced gate, median smooth,
/// stable-MIDI merge, blip rejection, gap coalescing) + scale-snap / octave-correction on
/// hand-built frame sequences. Hermetic + deterministic (no audio files needed for segmentation).
final class MelodyTrackerTests: XCTestCase {

    // MARK: - f0 estimator on synthetic pure tones

    private func tone(_ freq: Double, sr: Double = 44_100, amp: Float = 0.5) -> [Float] {
        (0..<MelodyTracker.frameSize).map { i in amp * Float(sin(2 * .pi * freq * Double(i) / sr)) }
    }

    private func midi(of f0: Double) -> Int { Int((69.0 + 12.0 * log2(f0 / 440.0)).rounded()) }

    func testEstimateF0OnPureTones() {
        for (freq, expectedMidi) in [(220.0, 57), (440.0, 69), (880.0, 81)] {
            let f = MelodyTracker.estimateF0(frame: tone(freq), sampleRate: 44_100)
            XCTAssertGreaterThan(f.periodicity, 0.8, "a clean \(freq) Hz tone is strongly periodic")
            XCTAssertEqual(midi(of: f.f0), expectedMidi, accuracy: 1,
                           "\(freq) Hz → MIDI \(expectedMidi) within ±1 (got f0 \(f.f0))")
        }
    }

    func testEstimateF0OnNoiseIsUnvoiced() {
        var rng = SystemRandomNumberGenerator()
        let noise = (0..<MelodyTracker.frameSize).map { _ in Float.random(in: -0.5...0.5, using: &rng) }
        let f = MelodyTracker.estimateF0(frame: noise, sampleRate: 44_100)
        XCTAssertLessThan(f.periodicity, MelodyTracker.periodicityFloor,
                          "white noise has no clear period ⇒ gated out as unvoiced")
    }

    // MARK: - Segmentation (pure — gate / merge / blip / gap)

    private func voiced(_ f0: Double, _ n: Int) -> [MelodyTracker.F0Frame] {
        Array(repeating: .init(f0: f0, periodicity: 0.9, rms: 1.0), count: n)
    }
    private func silent(_ n: Int) -> [MelodyTracker.F0Frame] {
        Array(repeating: .init(f0: 0, periodicity: 0.0, rms: 0.0), count: n)
    }
    /// A4 = 440 → MIDI 69; C5 = 523.25 → 72.
    private let a4 = 440.0, c5 = 523.2511

    func testBuildNotesMergesStableFramesAndGatesSilence() {
        // 8 frames A4, 2 silent, 8 frames C5, at 25 ms/hop → two 200 ms notes with a 50 ms gap.
        let frames = voiced(a4, 8) + silent(2) + voiced(c5, 8)
        let notes = MelodyTracker.buildNotes(frames: frames, hopMs: 25)
        XCTAssertEqual(notes.count, 2)
        XCTAssertEqual(notes[0].midi, 69)
        XCTAssertEqual(notes[0].startMs, 0)
        XCTAssertEqual(notes[0].endMs, 200)
        XCTAssertEqual(notes[1].midi, 72)
        XCTAssertEqual(notes[1].startMs, 250)
        XCTAssertEqual(notes[1].endMs, 450)
    }

    func testBuildNotesDropsSubMinNoteBlips() {
        // A 3-frame (75 ms < 100 ms) voiced blip between two real notes is dropped.
        let frames = voiced(a4, 8) + silent(2) + voiced(c5, 3) + silent(2) + voiced(a4, 8)
        let notes = MelodyTracker.buildNotes(frames: frames, hopMs: 25)
        XCTAssertEqual(notes.map(\.midi), [69, 69], "the 75 ms C5 blip never becomes a note")
    }

    func testBuildNotesCoalescesBriefSamePitchGap() {
        // Same pitch either side of a 50 ms unvoiced gap (< 90 ms) → ONE held note (a breath).
        let frames = voiced(a4, 8) + silent(2) + voiced(a4, 8)
        let notes = MelodyTracker.buildNotes(frames: frames, hopMs: 25)
        XCTAssertEqual(notes.count, 1, "a brief same-pitch gap is bridged, not a note boundary")
        XCTAssertEqual(notes[0].midi, 69)
        XCTAssertEqual(notes[0].startMs, 0)
        XCTAssertEqual(notes[0].endMs, 450)
    }

    func testBuildNotesLongGapSplitsSamePitch() {
        // A 150 ms gap (> 90 ms) is a real boundary even at the same pitch.
        let frames = voiced(a4, 8) + silent(6) + voiced(a4, 8)
        let notes = MelodyTracker.buildNotes(frames: frames, hopMs: 25)
        XCTAssertEqual(notes.count, 2, "a long same-pitch gap splits into two notes")
    }

    // MARK: - Scale snap + octave correction (pure)

    private func note(_ midi: Int, _ start: Int = 0, _ end: Int = 200) -> DemuxMelodyNote {
        DemuxMelodyNote(midi: midi, startMs: start, endMs: end)
    }

    func testSnapToScaleForcesOutOfKeyNotesOntoTheScale() {
        // C major {0,2,4,5,7,9,11}. C#4 (61, pc 1) snaps DOWN to C4 (60) deterministically.
        let scale = KeyDetector.scalePitchClasses(tonic: 0, major: true)
        let out = MelodyTracker.snapToScale(notes: [note(61, 0, 100), note(64, 100, 200)], scalePCs: scale)
        XCTAssertEqual(out.map(\.midi), [60, 64], "C# folds to the nearer (lower) C; E is already in key")
    }

    func testOctaveCorrectionPullsAnOctaveJumpBack() {
        // No scale: a spurious octave jump (60 → 72 → 60) collapses onto the melody's register.
        let out = MelodyTracker.snapToScale(notes: [note(60), note(72), note(60)], scalePCs: [])
        XCTAssertEqual(out.map(\.midi), [60, 60, 60], "the octave-up outlier is corrected to its neighbours")
    }

    func testOctaveCorrectionLeavesGenuineStepsAlone() {
        // A stepwise line (all intervals ≤ a fifth) is untouched by octave correction.
        let out = MelodyTracker.snapToScale(notes: [note(60), note(64), note(67), note(65)], scalePCs: [])
        XCTAssertEqual(out.map(\.midi), [60, 64, 67, 65], "real stepwise motion survives intact")
    }

    func testOctaveCorrectionPreservesSixthButFoldsOctave() {
        // FIX 3: the fold now corrects ONLY near-octave slips (> 10 st), not "any leap over a
        // fifth". A genuine ascending minor sixth (60 → 68, +8 st) is a REAL interval — it must
        // survive intact; the old ">a fifth" fold pulled 68 down to 56, INVERTING the ascending
        // sixth into a descending major third.
        let sixth = MelodyTracker.snapToScale(notes: [note(60), note(68)], scalePCs: [])
        XCTAssertEqual(sixth.map(\.midi), [60, 68],
                       "an ascending minor sixth is a real leap, not an octave slip — left intact")
        // A true ±12 octave error IS still folded back onto the melody's register.
        let octaveUp = MelodyTracker.snapToScale(notes: [note(60), note(72)], scalePCs: [])
        XCTAssertEqual(octaveUp.map(\.midi), [60, 60], "a +12 octave error folds back down")
        let octaveDown = MelodyTracker.snapToScale(notes: [note(60), note(48)], scalePCs: [])
        XCTAssertEqual(octaveDown.map(\.midi), [60, 60], "a −12 octave error folds back up")
    }

    // MARK: - End-to-end over a synthesized single-tone stem (the seed-fixture shape)

    /// A 2 s 220 Hz tone (the PDJ_SEED_DEMUX melody-smoke shape) tracks to a sustained MIDI-57
    /// line — proves the streamed reader + YIN + segmentation compose without a real vocal.
    func testDetectOnSynthesizedTone() throws {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("melody-\(UUID().uuidString).caf")
        defer { try? FileManager.default.removeItem(at: url) }
        let sr = 44_100.0
        let fmt = AVAudioFormat(standardFormatWithSampleRate: sr, channels: 1)!
        let file = try AVAudioFile(forWriting: url, settings: fmt.settings)
        let total = AVAudioFrameCount(sr * 2)
        let buf = AVAudioPCMBuffer(pcmFormat: fmt, frameCapacity: total)!
        buf.frameLength = total
        let p = buf.floatChannelData![0]
        for i in 0..<Int(total) { p[i] = 0.5 * Float(sin(2 * .pi * 220 * Double(i) / sr)) }
        try file.write(from: buf)

        let notes = MelodyTracker.detect(melodyURL: url)
        XCTAssertFalse(notes.isEmpty, "the 220 Hz tone tracks to at least one note")
        // The dominant note is MIDI 57 (A3 = 220 Hz), covering most of the 2 s.
        let dominant = notes.max { ($0.endMs - $0.startMs) < ($1.endMs - $1.startMs) }
        XCTAssertEqual(dominant?.midi, 57, "220 Hz → MIDI 57")
        XCTAssertGreaterThan((dominant.map { $0.endMs - $0.startMs }) ?? 0, 1_000,
                             "the note sustains across most of the tone")
    }
}

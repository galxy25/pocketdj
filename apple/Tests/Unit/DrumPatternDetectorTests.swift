import XCTest
import AVFoundation
@testable import PocketDJ

/// Drum-pattern extraction: hit classification from band energies (pure), adaptive peak
/// picking over synthetic flux envelopes, bar building (measured downbeats + constant-bpm
/// fallback), 16th-step quantization incl. the bar-edge carry, the kit-sample region picker,
/// and an end-to-end onset pass over a synthesized drums file. Hermetic + deterministic.
final class DrumPatternDetectorTests: XCTestCase {

    private typealias Frame = DrumPatternDetector.FluxFrame

    // MARK: - Classification (pure)

    private func frames(low: Float, mid: Float, high: Float, count: Int = 8) -> [Frame] {
        Array(repeating: Frame(flux: 1, low: low, mid: mid, high: high), count: count)
    }

    func testClassifyByBandDominance() {
        XCTAssertEqual(DrumPatternDetector.classify(frames: frames(low: 10, mid: 2, high: 1), onset: 0),
                       .kick, "low-dominant attack is a kick")
        XCTAssertEqual(DrumPatternDetector.classify(frames: frames(low: 0.5, mid: 2, high: 10), onset: 0),
                       .percussive, "top-heavy attack is hats/cymbals")
        XCTAssertEqual(DrumPatternDetector.classify(frames: frames(low: 1, mid: 6, high: 3), onset: 0),
                       .snare, "broadband mid attack is a snare")
        XCTAssertEqual(DrumPatternDetector.classify(frames: frames(low: 0, mid: 0, high: 0), onset: 0),
                       .other, "silence degrades to other, never a crash")
    }

    // MARK: - Peak picking (pure)

    /// A flat noise floor with two well-separated spikes → exactly two hits at those frames.
    func testPickHitsFindsSeparatedPeaks() {
        var fs = (0..<100).map { _ in Frame(flux: 0.01, low: 1, mid: 1, high: 1) }
        fs[20] = Frame(flux: 1.0, low: 10, mid: 1, high: 1)      // kick-shaped
        fs[60] = Frame(flux: 0.8, low: 0.2, mid: 1, high: 10)    // hat-shaped
        let hits = DrumPatternDetector.pickHits(frames: fs, frameMs: 10, kindOverride: nil)
        XCTAssertEqual(hits.count, 2)
        XCTAssertEqual(hits[0].ms, 200)
        XCTAssertEqual(hits[0].kind, .kick)
        XCTAssertEqual(hits[0].strength, 1.0, accuracy: 0.001, "strengths normalize to the loudest")
        XCTAssertEqual(hits[1].ms, 600)
        XCTAssertEqual(hits[1].kind, .percussive)
        XCTAssertEqual(hits[1].strength, 0.8, accuracy: 0.001)
    }

    func testPickHitsEnforcesMinimumGap() {
        // 5 ms frames: two clean local maxima 30 ms apart (past the ±3-frame peak radius but
        // inside the 45 ms gap) — only the first survives.
        var fs = (0..<60).map { _ in Frame(flux: 0.01, low: 1, mid: 1, high: 1) }
        fs[20] = Frame(flux: 1.0, low: 10, mid: 1, high: 1)
        fs[26] = Frame(flux: 0.9, low: 10, mid: 1, high: 1)
        let hits = DrumPatternDetector.pickHits(frames: fs, frameMs: 5, kindOverride: nil)
        XCTAssertEqual(hits.count, 1, "a double-trigger inside minGapMs collapses to one hit")
        XCTAssertEqual(hits[0].ms, 100)
    }

    func testPickHitsKindOverride() {
        var fs = (0..<40).map { _ in Frame(flux: 0.01, low: 1, mid: 1, high: 1) }
        fs[10] = Frame(flux: 1.0, low: 0, mid: 0, high: 10)
        let hits = DrumPatternDetector.pickHits(frames: fs, frameMs: 10, kindOverride: .bass)
        XCTAssertEqual(hits.map(\.kind), [.bass], "the bass-stem pass forces every hit to .bass")
    }

    // MARK: - Bars (pure)

    func testBarsFromMeasuredDownbeatsExtendAtMedian() {
        let bars = DrumPatternDetector.bars(downbeatsMs: [0, 2_000, 4_000], bpm: nil,
                                            firstDownbeatMs: nil, durationMs: 9_500)
        XCTAssertEqual(bars.count, 5, "2 measured bars + median-length extension to the duration")
        XCTAssertEqual(bars[0].startMs, 0)
        XCTAssertEqual(bars[1].endMs, 4_000)
        XCTAssertEqual(bars[4].startMs, 8_000)
        XCTAssertEqual(bars.map(\.index), Array(0..<5))
    }

    func testBarsFromConstantBpmAnchorAtFirstDownbeat() {
        // 120 BPM ⇒ 2 000 ms bars; anchor 500 ms with room before it pulls one bar back to
        // near 0 so the intro isn't dropped (start would go negative → stays at 500-2000…).
        let bars = DrumPatternDetector.bars(downbeatsMs: [], bpm: 120,
                                            firstDownbeatMs: 4_500, durationMs: 10_000)
        XCTAssertEqual(bars.first?.startMs, 500, "whole bars pull back toward 0 from the anchor")
        XCTAssertEqual((bars[1].startMs - bars[0].startMs), 2_000)
        XCTAssertTrue(DrumPatternDetector.bars(downbeatsMs: [], bpm: nil,
                                               firstDownbeatMs: nil, durationMs: 10_000).isEmpty,
                      "no tempo at all ⇒ no bars (the panel shows a hint)")
    }

    // MARK: - Step quantization (pure)

    func testStepGridQuantizesToNearestSixteenthWithBarCarry() {
        let bars = [DrumPatternDetector.Bar(index: 0, startMs: 0, endMs: 2_000),
                    DrumPatternDetector.Bar(index: 1, startMs: 2_000, endMs: 4_000)]
        let hits = [DemuxDrumHit(ms: 0, kind: .kick, strength: 1),
                    DemuxDrumHit(ms: 510, kind: .snare, strength: 1),      // 4.08 → slot 4
                    DemuxDrumHit(ms: 1_970, kind: .kick, strength: 1),     // 15.76 → next bar slot 0
                    DemuxDrumHit(ms: 2_120, kind: .bass, strength: 1)]     // bar 1, 0.96 → slot 1
        let grid = DrumPatternDetector.stepGrid(hits: hits, bars: bars)
        XCTAssertEqual(grid.count, 2)
        XCTAssertEqual(grid[0][.kick]?[0], true)
        XCTAssertEqual(grid[0][.snare]?[4], true)
        XCTAssertNil(grid[0][.bass])
        XCTAssertEqual(grid[1][.kick]?[0], true, "a hit on the bar's far edge carries to the next bar's step 0")
        XCTAssertEqual(grid[1][.bass]?[1], true)
    }

    func testBarIndexBinarySearch() {
        let bars = (0..<10).map { DrumPatternDetector.Bar(index: $0, startMs: $0 * 1_000,
                                                          endMs: ($0 + 1) * 1_000) }
        XCTAssertEqual(DrumPatternDetector.barIndex(forMs: 0, bars: bars), 0)
        XCTAssertEqual(DrumPatternDetector.barIndex(forMs: 5_500, bars: bars), 5)
        XCTAssertEqual(DrumPatternDetector.barIndex(forMs: 9_999, bars: bars), 9)
        XCTAssertNil(DrumPatternDetector.barIndex(forMs: 10_000, bars: bars))
        XCTAssertNil(DrumPatternDetector.barIndex(forMs: -1, bars: bars))
    }

    // MARK: - Kit-sample region (pure)

    func testHitRegionCutsAtNextSameStemHit() {
        let hits = [DemuxDrumHit(ms: 1_000, kind: .kick, strength: 0.9),
                    DemuxDrumHit(ms: 1_300, kind: .snare, strength: 0.6),
                    DemuxDrumHit(ms: 5_000, kind: .kick, strength: 0.5),
                    DemuxDrumHit(ms: 1_100, kind: .bass, strength: 1.0)]
        let kick = DemuxDrumPatternView.hitRegion(for: .kick, hits: hits, durationMs: 60_000)
        XCTAssertEqual(kick?.start, 1_000, "the strongest hit of the class is the donor")
        XCTAssertEqual(kick?.end, 1_300, "cut at the DRUMS stem's next hit — bass never cuts drums")
        let bass = DemuxDrumPatternView.hitRegion(for: .bass, hits: hits, durationMs: 60_000)
        XCTAssertEqual(bass?.start, 1_100)
        XCTAssertEqual(bass?.end, 1_600, "no later bass hit ⇒ the 500 ms one-shot cap")
        XCTAssertNil(DemuxDrumPatternView.hitRegion(for: .percussive, hits: hits, durationMs: 60_000))
    }

    // MARK: - End-to-end over synthesized audio

    /// 4 s file: decaying 60 Hz kick bursts at 0.5/1.5/2.5 s and 8 kHz hat bursts at 1.0/2.0 s
    /// ⇒ five hits, kick/percussive classes at the right times. Exercises the streaming STFT,
    /// flux, picking, and classification together.
    func testOnsetsOnSynthesizedDrums() throws {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("drum-detect-\(UUID().uuidString).caf")
        defer { try? FileManager.default.removeItem(at: url) }
        let sr = 44_100.0
        let fmt = AVAudioFormat(standardFormatWithSampleRate: sr, channels: 1)!
        let file = try AVAudioFile(forWriting: url, settings: fmt.settings)
        let total = AVAudioFrameCount(sr * 4)
        let buf = AVAudioPCMBuffer(pcmFormat: fmt, frameCapacity: total)!
        buf.frameLength = total
        let p = buf.floatChannelData![0]
        for i in 0..<Int(total) { p[i] = 0 }
        func burst(atMs ms: Int, freq: Double, lengthMs: Int) {
            let start = Int(Double(ms) / 1_000 * sr)
            let n = Int(Double(lengthMs) / 1_000 * sr)
            for i in 0..<n where start + i < Int(total) {
                let t = Double(i) / sr
                let env = Float(exp(-t * 30))
                p[start + i] += env * 0.8 * Float(sin(2 * .pi * freq * t))
            }
        }
        for ms in [500, 1_500, 2_500] { burst(atMs: ms, freq: 60, lengthMs: 150) }
        for ms in [1_000, 2_000] { burst(atMs: ms, freq: 8_000, lengthMs: 80) }
        try file.write(from: buf)

        let hits = DrumPatternDetector.onsets(url: url, fluxBandHi: nil, kindOverride: nil)
        func hit(near ms: Int) -> DemuxDrumHit? {
            hits.min { abs($0.ms - ms) < abs($1.ms - ms) }.flatMap { abs($0.ms - ms) <= 80 ? $0 : nil }
        }
        for ms in [500, 1_500, 2_500] {
            let h = hit(near: ms)
            XCTAssertNotNil(h, "kick at \(ms) ms detected")
            XCTAssertEqual(h?.kind, .kick, "60 Hz burst at \(ms) ms classes as kick")
        }
        for ms in [1_000, 2_000] {
            let h = hit(near: ms)
            XCTAssertNotNil(h, "hat at \(ms) ms detected")
            XCTAssertEqual(h?.kind, .percussive, "8 kHz burst at \(ms) ms classes as percussive")
        }
    }
}

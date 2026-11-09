import AVFoundation
import XCTest
@testable import PocketDJ

/// np-dj-mode §5 — BS.1770 integrated loudness, the −14 LUFS leveling gain + clamp, and the
/// songId+size loudness cache.
final class LoudnessAnalyzerTests: XCTestCase {

    /// `seconds` of a sine at peak `amplitude`, interleaved over `channels` identical channels.
    private func sine(_ hz: Double = 997, amplitude: Double, seconds: Double, sampleRate: Double,
                      channels: Int = 2) -> [Float] {
        let n = Int(seconds * sampleRate)
        var out = [Float](repeating: 0, count: n * channels)
        for i in 0..<n {
            let v = Float(amplitude * sin(2 * .pi * hz * Double(i) / sampleRate))
            for c in 0..<channels { out[i * channels + c] = v }
        }
        return out
    }

    private func dbfs(_ db: Double) -> Double { pow(10, db / 20) }

    // EBU Tech 3341 test 1: a stereo 1 kHz sine at −23 dBFS reads −23 LUFS — the K-weighting's
    // ≈ +0.69 dB at 1 kHz cancels the −0.691 offset, and the two channels' mean squares
    // (A²/2 each) sum to A². So a −20 dBFS stereo sine ⇒ −20 LUFS.
    func testStereoSineMatchesBS1770Expectation() throws {
        for fs in [48_000.0, 44_100.0, 96_000.0] {
            let x = sine(amplitude: dbfs(-20), seconds: 5, sampleRate: fs)
            let l = try XCTUnwrap(LoudnessAnalyzer.integratedLoudness(samples: x, channels: 2, sampleRate: fs))
            XCTAssertEqual(l, -20, accuracy: 0.5, "fs=\(fs)")
            XCTAssertEqual(l, -20, accuracy: 0.1, "fs=\(fs) — tighter than the spec's ±0.5")
        }
        let x = sine(amplitude: dbfs(-23), seconds: 5, sampleRate: 48_000)
        XCTAssertEqual(LoudnessAnalyzer.integratedLoudness(samples: x, channels: 2, sampleRate: 48_000)!,
                       -23, accuracy: 0.1, "EBU 3341 case 1")
    }

    func testMonoIsOneChannel() throws {
        // One channel carries half the stereo energy: −20 dBFS mono ⇒ ≈ −23.0 LUFS.
        let x = sine(amplitude: dbfs(-20), seconds: 5, sampleRate: 48_000, channels: 1)
        let l = try XCTUnwrap(LoudnessAnalyzer.integratedLoudness(samples: x, sampleRate: 48_000))
        XCTAssertEqual(l, -20 - 10 * log10(2), accuracy: 0.1)
    }

    func testFilterCoefficientsMatchTheStandardAt48k() {
        // ITU-R BS.1770-4 Tables 1 and 2.
        let pre = LoudnessAnalyzer.preFilter(sampleRate: 48_000)
        XCTAssertEqual(pre.b0, 1.53512485958697, accuracy: 1e-6)
        XCTAssertEqual(pre.b1, -2.69169618940638, accuracy: 1e-6)
        XCTAssertEqual(pre.b2, 1.19839281085285, accuracy: 1e-6)
        XCTAssertEqual(pre.a1, -1.69065929318241, accuracy: 1e-6)
        XCTAssertEqual(pre.a2, 0.73248077421585, accuracy: 1e-6)
        let rlb = LoudnessAnalyzer.rlbFilter(sampleRate: 48_000)
        XCTAssertEqual(rlb.a1, -1.99004745483398, accuracy: 1e-6)
        XCTAssertEqual(rlb.a2, 0.99007225036621, accuracy: 1e-6)
    }

    func testSilenceAndTooShortAreNil() {
        XCTAssertNil(LoudnessAnalyzer.integratedLoudness(samples: [Float](repeating: 0, count: 96_000 * 2),
                                                         channels: 2, sampleRate: 48_000))
        // Below the absolute gate (−80 dBFS ⇒ ≈ −80 LUFS) is gated out too.
        XCTAssertNil(LoudnessAnalyzer.integratedLoudness(
            samples: sine(amplitude: dbfs(-80), seconds: 3, sampleRate: 48_000), channels: 2, sampleRate: 48_000))
        // < 400 ms: no full gating block.
        XCTAssertNil(LoudnessAnalyzer.integratedLoudness(
            samples: sine(amplitude: 0.5, seconds: 0.3, sampleRate: 48_000), channels: 2, sampleRate: 48_000))
        XCTAssertNil(LoudnessAnalyzer.integratedLoudness(samples: [], channels: 2, sampleRate: 48_000))
    }

    func testGatingIgnoresASilentHalf() throws {
        let tone = sine(amplitude: dbfs(-20), seconds: 5, sampleRate: 48_000)
        let withSilence = tone + [Float](repeating: 0, count: tone.count)
        let a = try XCTUnwrap(LoudnessAnalyzer.integratedLoudness(samples: tone, channels: 2, sampleRate: 48_000))
        let b = try XCTUnwrap(LoudnessAnalyzer.integratedLoudness(samples: withSilence, channels: 2, sampleRate: 48_000))
        // The three overlapping blocks straddling the tone→silence edge sit above both gates and
        // pull the mean down ≈ 0.13 LU — correct BS.1770 behavior; the 5 s of silence add nothing.
        XCTAssertEqual(a, b, accuracy: 0.2, "the absolute gate drops the silent half")
    }

    func testRelativeGateDropsAQuietPassage() throws {
        // 5 s at −20 then 5 s at −50 (30 LU down, above the absolute gate): ungated it would read
        // ≈ −23; the −10 LU relative gate drops the quiet half.
        let x = sine(amplitude: dbfs(-20), seconds: 5, sampleRate: 48_000)
            + sine(amplitude: dbfs(-50), seconds: 5, sampleRate: 48_000)
        let l = try XCTUnwrap(LoudnessAnalyzer.integratedLoudness(samples: x, channels: 2, sampleRate: 48_000))
        XCTAssertEqual(l, -20, accuracy: 0.2)
    }

    func testNoiseLoudnessTracksRMS() throws {
        var rng = SplitMix64(seed: 4)
        let n = 48_000 * 4
        let noise: [Float] = (0..<n * 2).map { _ in Float(rng.nextUnit() * 2 - 1) * 0.1 }
        let a = try XCTUnwrap(LoudnessAnalyzer.integratedLoudness(samples: noise, channels: 2, sampleRate: 48_000))
        let b = try XCTUnwrap(LoudnessAnalyzer.integratedLoudness(samples: noise.map { $0 * 2 }, channels: 2,
                                                                  sampleRate: 48_000))
        XCTAssertEqual(b - a, 20 * log10(2), accuracy: 0.05, "doubling the amplitude adds 6.02 LU")
        // White noise of RMS 0.1/√3 per channel: K-weighting's +4 dB shelf over most of the band
        // puts it a few LU above the unweighted level (≈ −19.7 dB summed).
        let unweighted = 10 * log10(2 * 0.01 / 3)
        XCTAssertGreaterThan(a, unweighted)
        XCTAssertLessThan(a, unweighted + 5)
    }

    // MARK: leveling gain

    func testGainTargetAndClamp() {
        XCTAssertEqual(LoudnessLeveling.targetLufs, -14)
        XCTAssertEqual(LoudnessLeveling.gainDb(lufs: -14), 0)
        XCTAssertEqual(LoudnessLeveling.gainDb(lufs: -18), 4)
        XCTAssertEqual(LoudnessLeveling.gainDb(lufs: -20), 6)
        XCTAssertEqual(LoudnessLeveling.gainDb(lufs: -40), 6, "boost clamps at +6")
        XCTAssertEqual(LoudnessLeveling.gainDb(lufs: -8), -6)
        XCTAssertEqual(LoudnessLeveling.gainDb(lufs: 0), -12, "cut clamps at −12")
        XCTAssertEqual(LoudnessLeveling.gainDb(lufs: 3), -12)
        XCTAssertNil(LoudnessLeveling.gainDb(lufs: nil))
        XCTAssertNil(LoudnessLeveling.gainDb(lufs: -.infinity))
        XCTAssertEqual(LoudnessLeveling.linear(db: -6.0206), 0.5, accuracy: 1e-4)
    }

    // MARK: cache + file analysis

    private func tempDir() throws -> URL {
        let d = FileManager.default.temporaryDirectory.appendingPathComponent("loud-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: d, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: d) }
        return d
    }

    @MainActor
    func testCacheRoundTrip() throws {
        let url = try tempDir().appendingPathComponent("sub/loudness.json")
        let k = LoudnessCache.Key(songId: "s1", byteSize: 1234)
        let silent = LoudnessCache.Key(songId: "s2", byteSize: 9)
        let cache = LoudnessCache(fileURL: url)
        XCTAssertNil(cache.gainDb(for: k))
        XCTAssertFalse(cache.contains(k))
        cache.store(-20, for: k)
        cache.store(nil, for: silent)
        XCTAssertEqual(cache.gainDb(for: k), 6)

        let again = LoudnessCache(fileURL: url)
        XCTAssertEqual(again.lufs(for: k), -20)
        XCTAssertEqual(again.gainDb(for: k), 6)
        XCTAssertTrue(again.contains(silent), "an unmeasurable file is remembered, not re-analyzed")
        XCTAssertNil(again.gainDb(for: silent))
        XCTAssertNil(again.gainDb(for: .init(songId: "s1", byteSize: 1235)), "a different size is a different file")
    }

    @MainActor
    func testAnalyzeFileAndCacheOnce() async throws {
        let dir = try tempDir()
        let url = dir.appendingPathComponent("tone.wav")
        let fs = 44_100.0
        let format = try XCTUnwrap(AVAudioFormat(standardFormatWithSampleRate: fs, channels: 2))
        do {
            let file = try AVAudioFile(forWriting: url, settings: [
                AVFormatIDKey: kAudioFormatLinearPCM, AVSampleRateKey: fs, AVNumberOfChannelsKey: 2,
                AVLinearPCMBitDepthKey: 32, AVLinearPCMIsFloatKey: true, AVLinearPCMIsNonInterleaved: false,
            ], commonFormat: .pcmFormatFloat32, interleaved: false)
            let frames = AVAudioFrameCount(fs * 4)
            let buf = try XCTUnwrap(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frames))
            buf.frameLength = frames
            let amp = Float(dbfs(-18))
            for i in 0..<Int(frames) {
                let v = amp * Float(sin(2 * .pi * 997 * Double(i) / fs))
                buf.floatChannelData![0][i] = v
                buf.floatChannelData![1][i] = v
            }
            try file.write(from: buf)
        }
        // Small chunks exercise the filter state carried across reads.
        let direct = try XCTUnwrap(LoudnessAnalyzer.analyzeSync(url: url, chunkFrames: 1000))
        XCTAssertEqual(direct, -18, accuracy: 0.1)
        let viaAsync = try await LoudnessAnalyzer.analyze(url: url)
        XCTAssertEqual(try XCTUnwrap(viaAsync), direct, accuracy: 1e-9)

        let cache = LoudnessCache(fileURL: dir.appendingPathComponent("loudness.json"))
        let measured = await cache.analyzeIfNeeded(songId: "tone", url: url)
        XCTAssertEqual(try XCTUnwrap(measured), -18, accuracy: 0.1)
        let key = try XCTUnwrap(LoudnessCache.key(songId: "tone", url: url))
        XCTAssertEqual(try XCTUnwrap(cache.gainDb(for: key)), 4, accuracy: 0.1)
        XCTAssertTrue(LoudnessCache(fileURL: dir.appendingPathComponent("loudness.json")).contains(key))
    }
}

import AVFoundation
import Observation
import XCTest
@testable import PocketDJ

/// DJ Mode's progressive analysis (np-dj-mode §5a): the quick window, the precedence ladder,
/// hints → finals, the head-only growing file, low-confidence hints, the scheduler's order.
@MainActor
final class AudioAnalysisTests: XCTestCase {

    private func waitUntil(_ message: String, timeout: TimeInterval = 8, _ predicate: () -> Bool) async {
        let deadline = Date().addingTimeInterval(timeout)
        while !predicate() && Date() < deadline { try? await Task.sleep(nanoseconds: 20_000_000) }
        XCTAssertTrue(predicate(), message)
    }

    private func key(_ id: String) -> LoudnessCache.Key { .init(songId: id, byteSize: 1000) }

    private func tempCache() -> AudioAnalysisCache {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("pdj-analysis-\(UUID().uuidString).json")
        addTeardownBlock { try? FileManager.default.removeItem(at: url) }
        return AudioAnalysisCache(fileURL: url)
    }

    // MARK: Window

    func testQuickWindowSkipsTheIntroAndUsesTheHeadOfAGrowingFile() {
        // A whole 200 s song: 20 s from ~30 % in — past a beatless / quiet intro.
        XCTAssertEqual(AudioAnalysis.quickWindow(durationSeconds: 200, availableSeconds: 200, complete: true),
                       .init(startSeconds: 60, lengthSeconds: 20, headOnly: false))
        // A short song: the whole of it.
        XCTAssertEqual(AudioAnalysis.quickWindow(durationSeconds: 12, availableSeconds: 12, complete: true),
                       .init(startSeconds: 0, lengthSeconds: 12, headOnly: false))
        // Near the end the window still fits.
        let w = AudioAnalysis.quickWindow(durationSeconds: 25, availableSeconds: 25, complete: true)
        XCTAssertEqual(w?.startSeconds ?? -1, 5, accuracy: 1e-9)
        // A growing file: nothing until 15 s exist, then its head (≤ 30 s), flagged head-only.
        XCTAssertNil(AudioAnalysis.quickWindow(durationSeconds: 200, availableSeconds: 10, complete: false))
        XCTAssertEqual(AudioAnalysis.quickWindow(durationSeconds: 200, availableSeconds: 18, complete: false),
                       .init(startSeconds: 0, lengthSeconds: 18, headOnly: true))
        XCTAssertEqual(AudioAnalysis.quickWindow(durationSeconds: 200, availableSeconds: 70, complete: false)?.lengthSeconds, 30)
    }

    // MARK: Precedence

    func testPrecedenceLadderNeverLetsAHintOverwriteBetterData() {
        let quick = AudioAnalysis.Result(kind: .quick, bpm: 128, bpmConfidence: 0.8, camelot: "8A", keyConfidence: 0.9, lufs: -20)
        let full = AudioAnalysis.Result(kind: .full, bpm: 126, bpmConfidence: 0.9, camelot: "9A", keyConfidence: 0.95)
        XCTAssertEqual(AudioAnalysis.bpm(measured: 124, full: full, quick: quick).source, .measured, "server / catalog wins")
        XCTAssertEqual(AudioAnalysis.bpm(measured: 124, full: full, quick: quick).value, 124)
        XCTAssertEqual(AudioAnalysis.bpm(measured: nil, full: full, quick: quick).value, 126, "full beats the hint")
        XCTAssertEqual(AudioAnalysis.bpm(measured: nil, full: nil, quick: quick).value, 128)
        XCTAssertEqual(AudioAnalysis.bpm(measured: nil, full: nil, quick: nil).source, .none)
        XCTAssertEqual(AudioAnalysis.camelot(measured: "1B", full: full, quick: quick).value, "1B")
        XCTAssertEqual(AudioAnalysis.camelot(measured: nil, full: full, quick: quick).value, "9A")
        // Loudness: the full measurement, else the hint CLAMPED (−20 LUFS ⇒ +6 dB → +4).
        XCTAssertEqual(AudioAnalysis.levelGain(fullGainDb: -3, quick: quick).db, -3)
        XCTAssertEqual(AudioAnalysis.levelGain(fullGainDb: nil, quick: quick).db, AudioAnalysis.hintGainClampDb)
        XCTAssertEqual(AudioAnalysis.levelGain(fullGainDb: nil, quick: quick).source, .quick)
        // The cache never lets a hint replace a final.
        let c = tempCache()
        c.store(full, for: key("s"))
        c.store(quick, for: key("s"))
        XCTAssertNil(c.quick(for: key("s")))
        XCTAssertEqual(c.full(for: key("s"))?.bpm, 126)
        // Finals persist; hints don't.
        let again = AudioAnalysisCache(fileURL: c.fileURL)
        XCTAssertEqual(again.full(for: key("s"))?.bpm, 126)
    }

    /// A LOW-CONFIDENCE hint is treated as missing (the planner / glide degrade as before).
    func testLowConfidenceHintIsIgnored() {
        let weak = AudioAnalysis.Result(kind: .quick, bpm: 97, bpmConfidence: 0.1, camelot: "3B", keyConfidence: 0.4)
        XCTAssertNil(weak.usableBPM)
        XCTAssertNil(weak.usableCamelot)
        XCTAssertEqual(AudioAnalysis.bpm(measured: nil, full: nil, quick: weak).source, .none)
        XCTAssertNil(AudioAnalysis.camelot(measured: nil, full: nil, quick: weak).value)
    }

    // MARK: Real passes

    /// The real quick pass on a click track at 120 BPM finds it confidently; silence finds nothing usable.
    func testQuickPassDetectsAClickTrack() throws {
        let sr = 44_100.0
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("aa-click-\(UUID().uuidString).wav")
        addTeardownBlock { try? FileManager.default.removeItem(at: url) }
        do {                                                   // the writer finalizes when it goes
            let fmt = AVAudioFormat(standardFormatWithSampleRate: sr, channels: 1)!
            let file = try AVAudioFile(forWriting: url, settings: fmt.settings)
            let frames = AVAudioFrameCount(40 * sr)
            let buf = AVAudioPCMBuffer(pcmFormat: fmt, frameCapacity: frames)!
            buf.frameLength = frames
            let p = buf.floatChannelData![0]
            let beat = Int(sr * 0.5)
            for i in 0..<Int(frames) {
                let k = i % beat
                p[i] = k < 400 ? sinf(Float(k) * 2 * .pi * 1000 / Float(sr)) * 0.8 * (1 - Float(k) / 400) : 0
            }
            try file.write(from: buf)
        }
        let w = try XCTUnwrap(AudioAnalysis.quickWindow(durationSeconds: 40, availableSeconds: 40, complete: true))
        let r = try XCTUnwrap(AudioAnalysis.quickPass(url: url, window: w))
        XCTAssertEqual(r.usableBPM ?? 0, 120, accuracy: 1.5, "confidence \(r.bpmConfidence)")
        XCTAssertNotNil(r.lufs)
    }

    // MARK: Scheduler

    private func scheduler(_ c: AudioAnalysisCache, available: Double = 60) -> AudioAnalysisScheduler {
        let s = AudioAnalysisScheduler(cache: c)
        s.quickPass = { _, _, w in AudioAnalysis.Result(kind: .quick, headOnly: w.headOnly, bpm: 120, bpmConfidence: 0.9, lufs: -10) }
        s.fullPass = { _, _, _ in AudioAnalysis.Result(kind: .full, bpm: 121, bpmConfidence: 0.95) }
        s.available = { _, _ in available }
        return s
    }

    private func job(_ id: String, _ p: AudioAnalysisScheduler.Priority, complete: Bool = true) -> AudioAnalysisScheduler.Job {
        .init(key: key(id), open: { (URL(fileURLWithPath: "/tmp/\(id)"), nil) }, sliceStartSeconds: 0,
              durationSeconds: 180, complete: complete, priority: p)
    }

    /// Current → the listener's next-up pick → the planned next → the rest of the window; nothing
    /// runs while Low Power Mode / a serious thermal state holds it.
    func testSchedulerOrderAndPowerGate() async {
        let c = tempCache()
        let s = scheduler(c)
        var allowed = false
        s.mayRun = { allowed }
        s.enqueue(job("w1", .window))
        s.enqueue(job("n", .next))
        s.enqueue(job("w2", .window))
        s.enqueue(job("cur", .current))
        s.enqueue(job("pick", .userNext))
        XCTAssertTrue(s.startedOrderForTesting.isEmpty, "held while on battery saver / thermal serious")
        XCTAssertEqual(s.pendingKeysForTesting, ["cur", "pick", "n", "w1", "w2"])
        allowed = true
        s.enqueue(job("w3", .window))                       // any enqueue / completion resumes it
        await waitUntil("all ran") { s.startedOrderForTesting.count == 6 }
        XCTAssertEqual(s.startedOrderForTesting, ["cur", "pick", "n", "w1", "w2", "w3"], "one at a time, in priority order")
        await waitUntil("finals stored") { c.full(for: self.key("w3")) != nil }
        XCTAssertEqual(c.results(songId: "cur").full?.bpm, 121)
    }

    /// A GROWING file: no hint until 15 s exist; then a HEAD-ONLY hint; no full pass until it's complete.
    func testGrowingFileGetsAHeadOnlyHintThenTheFullPass() async {
        let c = tempCache()
        var avail = 8.0
        let s = scheduler(c)
        s.available = { _, _ in avail }
        AudioAnalysisScheduler.headRetrySeconds = 0.05
        defer { AudioAnalysisScheduler.headRetrySeconds = 5 }
        s.enqueue(job("g", .current, complete: false))
        try? await Task.sleep(nanoseconds: 150_000_000)
        XCTAssertNil(c.quick(for: key("g")), "8 s isn't enough")
        avail = 20
        await waitUntil("head hint") { c.quick(for: self.key("g")) != nil }
        XCTAssertEqual(c.quick(for: key("g"))?.headOnly, true)
        XCTAssertNil(c.full(for: key("g")), "no full pass on a file still arriving")
        avail = 180
        s.enqueue(job("g", .current, complete: true))       // the file completed
        await waitUntil("full pass") { c.full(for: self.key("g")) != nil }
    }
}

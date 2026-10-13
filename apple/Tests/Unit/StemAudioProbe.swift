import Accelerate
import AVFoundation
import XCTest
@testable import PocketDJ

/// Sample-resolution audio probes shared by the stem handover / drift suites (the
/// `MixStemsHandoverTests` instruments, lifted so Now Playing and every synced-start site are
/// judged by the same yardstick): decode a fixture, measure dead air in samples, and check a
/// capture is ONE continuous, sample-aligned read of its source.
enum StemAudioProbe {

    /// A bundled mp3 fixture (`stem-noise-12s` — headerless, ¼-level pink noise like a Demucs
    /// part; `stream-noise-12s` — the same noise, TAGGED, the full mix).
    static func bundled(_ name: String, in testCase: AnyClass) throws -> Data {
        let url = try XCTUnwrap(Bundle(for: testCase).url(forResource: name, withExtension: "mp3"))
        return try Data(contentsOf: url)
    }

    /// Write `data` to a fresh temp `.mp3` (AVAudioFile picks its decoder by EXTENSION).
    static func tempMP3(_ data: Data, tag: String) throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("pdj-probe-\(tag)-\(UUID().uuidString).mp3")
        try data.write(to: url)
        return url
    }

    /// Channel 0 of `data` decoded by Core Audio (a TAGGED mp3 decodes song-time aligned).
    static func decoded(_ data: Data) throws -> [Float] {
        let url = try tempMP3(data, tag: "src")
        defer { try? FileManager.default.removeItem(at: url) }
        let f = try AVAudioFile(forReading: url)
        let buf = try XCTUnwrap(AVAudioPCMBuffer(pcmFormat: f.processingFormat, frameCapacity: AVAudioFrameCount(f.length)))
        try f.read(into: buf)
        return Array(UnsafeBufferPointer(start: buf.floatChannelData![0], count: Int(buf.frameLength)))
    }

    /// The longest run of consecutive near-zero samples — dead air at SAMPLE resolution.
    static func longestSilence(_ y: [Float], threshold: Float = 1e-4) -> Int {
        var best = 0, run = 0
        for v in y {
            if abs(v) < threshold { run += 1; best = max(best, run) } else { run = 0 }
        }
        return best
    }

    /// Where in `src` each `block`-sample block of `y` matches best: that source offset minus the
    /// block's own offset (CONSTANT ⇔ one continuous, sample-aligned read) and the normalized
    /// correlation of the match.
    static func blockLags(_ y: [Float], _ src: [Float], block: Int = 1024, search: Int = 1500) -> [(lag: Int, corr: Float)] {
        var out: [(lag: Int, corr: Float)] = []
        guard y.count >= block, src.count >= block else { return out }
        y.withUnsafeBufferPointer { yp in
            src.withUnsafeBufferPointer { sp in
                guard let yb0 = yp.baseAddress, let sb = sp.baseAddress else { return }
                var prev: Int?
                var b = 0
                while b + block <= y.count {
                    let yb = yb0 + b
                    var ey: Float = 0
                    vDSP_svesq(yb, 1, &ey, vDSP_Length(block))
                    let lo = prev.map { max(0, b + $0 - search) } ?? 0
                    let hi = prev.map { min(src.count - block, b + $0 + search) } ?? (src.count - block)
                    var best = (s: lo, c: -Float.infinity)
                    if hi >= lo {
                        for s in lo...hi {
                            var d: Float = 0, es: Float = 0
                            vDSP_dotpr(yb, 1, sb + s, 1, &d, vDSP_Length(block))
                            vDSP_svesq(sb + s, 1, &es, vDSP_Length(block))
                            let c = d / max(1e-12, (ey * es).squareRoot())
                            if c > best.c { best = (s, c) }
                        }
                    }
                    out.append((best.s - b, best.c))
                    prev = best.s - b
                    b += block
                }
            }
        }
        return out
    }

    /// `y` is ONE continuous, sample-aligned read of `src` (every block at the same source offset
    /// ±2 samples, matching at r > 0.95) with no dead air longer than 2 ms.
    static func assertSeamless(_ y: [Float], against src: [Float], _ what: String,
                               file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertGreaterThan(y.count, 22_050, "\(what): captured too little", file: file, line: line)
        let gap = longestSilence(y)
        XCTAssertLessThan(gap, 88, "\(what): \(gap) samples (\(gap * 1000 / 44_100) ms) of dead air", file: file, line: line)
        let lags = blockLags(y, src)
        guard let first = lags.first else { return XCTFail("\(what): nothing to align", file: file, line: line) }
        let slips = lags.enumerated().filter { abs($0.element.lag - first.lag) > 2 }
        XCTAssertTrue(slips.isEmpty, "\(what): the source offset slips at block(s) "
                      + "\(slips.prefix(4).map { "\($0.offset):\($0.element.lag - first.lag)" }) — audio replayed/skipped",
                      file: file, line: line)
        let worst = lags.map(\.corr).min() ?? 0
        XCTAssertGreaterThan(worst, 0.95, "\(what): a block matches the source only at \(worst) — voices out of step",
                             file: file, line: line)
    }

    /// Poll `predicate` on the main actor (10 ms) until true or `timeout`.
    @MainActor
    static func wait(timeout: TimeInterval = 5, until predicate: () -> Bool) async {
        let deadline = Date().addingTimeInterval(timeout)
        while !predicate() && Date() < deadline {
            try? await Task.sleep(nanoseconds: 10_000_000)
        }
    }

    /// Wait until `cap` has `seconds` MORE samples (44.1 kHz) than it had.
    @MainActor
    static func capture(_ cap: MixDeckCapture, atLeast seconds: Double) async {
        let target = cap.count + Int(seconds * 44_100)
        await wait(timeout: seconds + 3) { cap.count >= target }
    }
}

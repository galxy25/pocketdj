import XCTest
import AVFoundation
import Speech
@testable import PocketDJ

/// FIELD PROBE (env-gated — skipped in the normal bundle): runs the REAL on-device
/// transcriber over a REAL song and reports per-window outcomes, time coverage, and —
/// given a reference lyrics file — token recall. This is the harness for the "lyrics
/// only cover a snip" field bug: it makes the recognizer's per-window behavior visible
/// instead of guessed-at. Run in the iPhone simulator (or macOS) with:
///   TEST_RUNNER_PDJ_DEMUX_PROBE_FILE=/path/to/song.mp3 \
///   TEST_RUNNER_PDJ_DEMUX_PROBE_LYRICS=/path/to/lyrics.txt (optional) \
///   xcodebuild test ... -only-testing:PocketDJTests/DemuxTranscriberFieldProbeTests
final class DemuxTranscriberFieldProbeTests: XCTestCase {

    func testRealSongCoverageProbe() async throws {
        let env = ProcessInfo.processInfo.environment
        guard let path = env["PDJ_DEMUX_PROBE_FILE"] else {
            throw XCTSkip("set PDJ_DEMUX_PROBE_FILE to run the field probe")
        }
        let url = URL(fileURLWithPath: path)
        XCTAssertTrue(FileManager.default.fileExists(atPath: path), "probe file missing: \(path)")

        print("PROBE: on-device supported = \(DemuxTranscriber.isSupported)")
        print("PROBE: auth status = \(SFSpeechRecognizer.authorizationStatus().rawValue)")
        guard DemuxTranscriber.isSupported else {
            throw XCTSkip("no on-device speech recognition in this environment")
        }

        let file = try AVAudioFile(forReading: url)
        let durationS = Double(file.length) / file.processingFormat.sampleRate
        print(String(format: "PROBE: file %.1fs — %@", durationS, url.lastPathComponent))

        let clock = ContinuousClock()
        let t0 = clock.now
        let words: [DemuxWord]
        do {
            words = try await DemuxTranscriber.transcribe(url: url) { r in
                let status = r.failure ?? "\(r.words.count) words"
                print(String(format: "PROBE: window %d/%d [%d–%d ms] → %@",
                             r.index + 1, r.total, r.startMs, r.endMs, status))
            }
        } catch DemuxTranscriber.TranscribeError.recognitionFailed(let msg)
                    where msg.localizedCaseInsensitiveContains("initialize") {
            // `supportsOnDeviceRecognition` lies in asset-less environments (the iPhone
            // SIMULATOR claims support, then every window 1101-fails at daemon init) —
            // that's the environment's failure, not the transcriber's.
            throw XCTSkip("local speech daemon can't initialize here (\(msg)) — run on device/macOS")
        }
        print("PROBE: total \(words.count) words in \(clock.now - t0)")

        // Time coverage: first→last word span and any silent gap > 20 s inside it.
        if let first = words.first, let last = words.last {
            print(String(format: "PROBE: coverage %.1fs → %.1fs of %.1fs",
                         Double(first.startMs) / 1000, Double(last.endMs) / 1000, durationS))
            var prevEnd = first.endMs
            for w in words {
                if w.startMs - prevEnd > 20_000 {
                    print(String(format: "PROBE: gap %.1fs → %.1fs",
                                 Double(prevEnd) / 1000, Double(w.startMs) / 1000))
                }
                prevEnd = max(prevEnd, w.endMs)
            }
        } else {
            print("PROBE: NO WORDS AT ALL")
        }

        // Token recall vs the reference lyrics, if provided.
        if let lyricsPath = env["PDJ_DEMUX_PROBE_LYRICS"],
           let reference = try? String(contentsOfFile: lyricsPath, encoding: .utf8) {
            let norm: (String) -> [String] = { text in
                text.lowercased()
                    .components(separatedBy: CharacterSet.alphanumerics.inverted)
                    .filter { $0.count > 2 }
            }
            let ref = norm(reference)
            let heard = Set(norm(words.map(\.text).joined(separator: " ")))
            let hit = ref.filter { heard.contains($0) }.count
            print(String(format: "PROBE: token recall %d/%d (%.0f%%) vs reference lyrics",
                         hit, ref.count, ref.isEmpty ? 0 : Double(hit) / Double(ref.count) * 100))
        }

        XCTAssertFalse(words.isEmpty, "probe song has known lyrics — zero words is a failure")
    }
}

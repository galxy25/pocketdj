import XCTest
import AVFoundation
@testable import PocketDJ

/// The transcriber's CHUNKED-recognition math (the silent-transcript field fix): slicing a
/// long file into dictation-length windows, passthrough for short files, and re-anchoring a
/// window's words onto the song timeline. Recognition itself needs on-device Speech models
/// (not present headless) — these pin the pure file/offset layer the fix rides on.
final class DemuxTranscriberChunkTests: XCTestCase {

    /// Write a mono silence CAF of `seconds` at 44.1k.
    private func makeAudio(seconds: Double) throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("pdj-chunk-test-\(UUID().uuidString).caf")
        addTeardownBlock { try? FileManager.default.removeItem(at: url) }
        let format = AVAudioFormat(standardFormatWithSampleRate: 44_100, channels: 1)!
        let file = try AVAudioFile(forWriting: url, settings: format.settings)
        let frames = AVAudioFrameCount(seconds * 44_100)
        let buf = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frames)!
        buf.frameLength = frames
        try file.write(from: buf)
        return url
    }

    func testShortFilePassesThroughUnsliced() throws {
        let url = try makeAudio(seconds: 40)
        let chunks = try DemuxTranscriber.slice(url: url)
        XCTAssertEqual(chunks.count, 1)
        XCTAssertEqual(chunks[0].url, url, "no temp copy for a single-shot file")
        XCTAssertEqual(chunks[0].startMs, 0)
        XCTAssertEqual(chunks[0].endMs, 40_000)
        XCTAssertFalse(chunks[0].temporary)
    }

    func testLongFileSlicesIntoAnchoredWindows() throws {
        let url = try makeAudio(seconds: 130)
        let chunks = try DemuxTranscriber.slice(url: url)
        defer { for c in chunks where c.temporary { try? FileManager.default.removeItem(at: c.url) } }
        XCTAssertEqual(chunks.count, 3, "130 s at 50 s windows → 50+50+30")
        XCTAssertEqual(chunks.map(\.startMs), [0, 50_000, 100_000])
        // The resume contract: a window's endMs IS the next window's startMs, exactly.
        XCTAssertEqual(chunks.map(\.endMs), [50_000, 100_000, 130_000])
        XCTAssertTrue(chunks.allSatisfy(\.temporary))
        // Every window is a real, readable audio file of the expected length.
        let lengths = try chunks.map { chunk -> Double in
            let f = try AVAudioFile(forReading: chunk.url)
            return Double(f.length) / f.processingFormat.sampleRate
        }
        // CAF packet alignment shaves ~15 ms off a written file's reported length.
        XCTAssertEqual(lengths[0], 50, accuracy: 0.05)
        XCTAssertEqual(lengths[1], 50, accuracy: 0.05)
        XCTAssertEqual(lengths[2], 30, accuracy: 0.05)
    }

    func testPendingSkipsCoveredWindows() throws {
        let url = try makeAudio(seconds: 130)
        let chunks = try DemuxTranscriber.slice(url: url)
        defer { for c in chunks where c.temporary { try? FileManager.default.removeItem(at: c.url) } }
        // Fresh run: everything pending, original numbering.
        XCTAssertEqual(DemuxTranscriber.pending(chunks, resumeFromMs: 0).map(\.index), [0, 1, 2])
        // Resume from a finished window's endMs: exactly the later windows remain.
        XCTAssertEqual(DemuxTranscriber.pending(chunks, resumeFromMs: 50_000).map(\.index), [1, 2])
        XCTAssertEqual(DemuxTranscriber.pending(chunks, resumeFromMs: 100_000).map(\.index), [2])
        // Fully covered (died after the last window, before the final status write).
        XCTAssertTrue(DemuxTranscriber.pending(chunks, resumeFromMs: 130_000).isEmpty)
    }

    func testOffsetReanchorsWords() {
        let words = [DemuxWord(text: "back", startMs: 1_000, endMs: 1_400),
                     DemuxWord(text: "forth", startMs: 2_000, endMs: 2_500)]
        let moved = DemuxTranscriber.offset(words, byMs: 50_000)
        XCTAssertEqual(moved.map(\.startMs), [51_000, 52_000])
        XCTAssertEqual(moved.map(\.endMs), [51_400, 52_500])
        XCTAssertEqual(moved.map(\.text), ["back", "forth"])
        // Zero offset is identity (the single-shot path).
        XCTAssertEqual(DemuxTranscriber.offset(words, byMs: 0).map(\.startMs), [1_000, 2_000])
    }
}

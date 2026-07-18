import XCTest
import AVFoundation
@testable import PocketDJ

/// PROBE (uncommitted): reproduce the Demuxer seek-while-playing crash in the simulator.
/// The Demuxer is the FIRST single-file caller of StemPlayer — it loads the full mix as
/// `["vocals": url]`, so drums/bass/other stay attached-but-never-connected. This probes:
///  1. load(single file) → playAll  (does the initial play survive?)
///  2. seek(to:) while playing      (the field-crash path — startSynced with engine running)
///  3. seek to/past EOF             (count <= 0 → nothing scheduled, play(at:) still fires)
@MainActor
final class StemPlayerSeekProbeTests: XCTestCase {

    private func makeTone(seconds: Double = 4) throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("stem-probe-\(UUID().uuidString).caf")
        let sr = 44_100.0
        let fmt = AVAudioFormat(standardFormatWithSampleRate: sr, channels: 1)!
        let file = try AVAudioFile(forWriting: url, settings: fmt.settings)
        let frames = AVAudioFrameCount(sr * seconds)
        let buf = AVAudioPCMBuffer(pcmFormat: fmt, frameCapacity: frames)!
        buf.frameLength = frames
        let p = buf.floatChannelData![0]
        for i in 0..<Int(frames) { p[i] = sinf(Float(2.0 * .pi * 440 * Double(i) / sr)) * 0.1 }
        try file.write(from: buf)
        return url
    }

    func testStage1_SingleFileLoadAndPlay() throws {
        let url = try makeTone()
        defer { try? FileManager.default.removeItem(at: url) }
        let p = StemPlayer()
        p.load(songId: "probe#mix", localURLs: ["vocals": url])
        XCTAssertTrue(p.ready)
        XCTAssertEqual(p.duration, 4, accuracy: 0.05)
        p.playAll()                                   // initial play — field report says this works
        XCTAssertTrue(p.isPlaying)
        p.stop()
    }

    func testStage2_SeekWhilePlaying() throws {
        let url = try makeTone()
        defer { try? FileManager.default.removeItem(at: url) }
        let p = StemPlayer()
        p.load(songId: "probe#mix", localURLs: ["vocals": url])
        p.playAll()
        XCTAssertTrue(p.isPlaying)
        // Let the engine actually render a little before the scrub.
        let e = expectation(description: "roll")
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { e.fulfill() }
        wait(for: [e], timeout: 2)
        p.seek(to: 2.0)                               // the field-crash gesture
        XCTAssertTrue(p.isPlaying)
        p.seek(to: 0.5)                               // scrub again (re-entrant startSynced)
        XCTAssertTrue(p.isPlaying)
        p.stop()
    }

    func testStage3_SeekToEOFWhilePlaying() throws {
        let url = try makeTone()
        defer { try? FileManager.default.removeItem(at: url) }
        let p = StemPlayer()
        p.load(songId: "probe#mix", localURLs: ["vocals": url])
        p.playAll()
        p.seek(to: 999)                               // clamps to duration → count == 0 → nothing scheduled
        XCTAssertFalse(p.isPlaying, "EOF seek with nothing schedulable must land in a stopped state")
        p.stop()
    }

    func testStage4_PausedJumpThenPlay() throws {
        let url = try makeTone()
        defer { try? FileManager.default.removeItem(at: url) }
        let p = StemPlayer()
        p.load(songId: "probe#mix", localURLs: ["vocals": url])
        p.seek(to: 2.5)                               // paused jump (timeline tap before play)
        XCTAssertEqual(p.currentTime, 2.5, accuracy: 0.01)
        p.togglePlayPause()                           // startSynced(from: 2.5)
        XCTAssertTrue(p.isPlaying)
        p.stop()
    }
}

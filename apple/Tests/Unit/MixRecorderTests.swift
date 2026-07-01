import XCTest
import AVFoundation
@testable import PocketDJ

/// MixRecorder — the app-scoped bridge from the engine's audio tap to the session store + on-disk
/// session folder. This drives the FULL record → stop → file flow on a real graph and asserts the take
/// lands on the session it was recorded in (not orphaned) and resolves to real audio.
@MainActor
final class MixRecorderTests: XCTestCase {

    func testRecordFilesTakeToCurrentSessionAndResolvesAudio() async throws {
        let rips = RipsStore(ripsBase: URL(string: "https://rips.test")!, session: .shared)
        let burnsURL = FileManager.default.temporaryDirectory.appendingPathComponent("mrtest-burns-\(UUID().uuidString).json")
        let engine = MixEngine(burns: BurnStore(rips: rips, fileURL: burnsURL))
        engine.ensureEngine()
        try XCTSkipUnless(engine.isReady, "no audio device on this test host")
        let store = MixSessionStore(fileURL: FileManager.default.temporaryDirectory
            .appendingPathComponent("mrtest-\(UUID().uuidString).json"))
        let recorder = MixRecorder(engine: engine, sessions: store)
        recorder.settings = SettingsStore(defaults: UserDefaults(suiteName: "mrtest-\(UUID().uuidString)")!)

        let src = try makeSineWAV(seconds: 2)
        defer { try? FileManager.default.removeItem(at: src) }
        engine.loadFile(src, release: nil, startMs: nil,
                        meta: MixEngine.LoadedTrack(songId: "x", title: "T", artist: "A", bpm: 120,
                                                    camelot: nil, key: nil, albumId: nil), on: .a)
        engine.play(.a)

        let sessionId = store.currentId
        defer {
            if let folder = SessionFolders.sessionFolder(sessionId, bookmark: nil, create: false) {
                try? FileManager.default.removeItem(at: folder.url)
            }
        }
        XCTAssertTrue(recorder.start())
        try await Task.sleep(nanoseconds: 600_000_000)
        recorder.stop()

        // The take is filed to the session it was recorded in — NOT orphaned into a "Recovered recording".
        let recs = store.recordings(forSession: sessionId)
        XCTAssertEqual(recs.count, 1, "the take should be filed to the current session")
        XCTAssertFalse(store.sessions.contains { $0.name == "Recovered recording" },
                       "the take must not be orphaned into a recovered session")

        // The file resolves + finalizes (async AVAssetWriter) to real audio.
        let rec = try XCTUnwrap(recs.first)
        var url: URL?
        for _ in 0..<40 {
            try await Task.sleep(nanoseconds: 100_000_000)
            if let resolved = SessionFolders.recordingURL(sessionId: sessionId, fileName: rec.fileName,
                                                          wasUserFolder: rec.wasUserFolder, bookmark: nil),
               let f = try? AVAudioFile(forReading: resolved.url), f.length > 0 {
                url = resolved.url; resolved.release?(); break
            }
        }
        let fileURL = try XCTUnwrap(url, "the recording file should resolve and hold real audio")
        // The Sessions player uses AVAudioPlayer — assert it can actually PLAY the (fragmented) m4a.
        let player = try AVAudioPlayer(contentsOf: fileURL)
        XCTAssertGreaterThan(player.duration, 0, "AVAudioPlayer must be able to play the recording")
        engine.teardown()
    }

    private func makeSineWAV(seconds: Double, sr: Double = 44_100, channels: AVAudioChannelCount = 2) throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("mrtest-\(UUID().uuidString).wav")
        let fmt = AVAudioFormat(standardFormatWithSampleRate: sr, channels: channels)!
        let file = try AVAudioFile(forWriting: url, settings: fmt.settings)
        let frames = AVAudioFrameCount(seconds * sr)
        let buf = AVAudioPCMBuffer(pcmFormat: fmt, frameCapacity: frames)!
        buf.frameLength = frames
        let ch = buf.floatChannelData!
        for c in 0..<Int(channels) {
            for i in 0..<Int(frames) { ch[c][i] = Float(sin(2.0 * .pi * 440.0 * Double(i) / sr)) * 0.2 }
        }
        try file.write(from: buf)
        return url
    }
}

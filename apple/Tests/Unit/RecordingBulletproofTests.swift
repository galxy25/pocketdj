import XCTest
import AVFoundation
@testable import PocketDJ

/// Pins the recording feature's crash-safety + zero-data-loss hardening (the route-change crash
/// investigation): dead-engine transport must never trap, the fragmented writer's output must be
/// readable WITHOUT a finalize, writer death must surface + auto-stop instead of silently dropping
/// forever, crash-orphan recovery must skip unreadable stubs, never truncate an unrecovered take,
/// and re-arm after a failed root resolve.
@MainActor
final class RecordingBulletproofTests: XCTestCase {

    // MARK: - Helpers

    private func makeEngine() -> MixEngine {
        let rips = RipsStore(ripsBase: URL(string: "https://rips.test")!, session: .shared)
        let burnsURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("rbtest-burns-\(UUID().uuidString).json")
        return MixEngine(burns: BurnStore(rips: rips, fileURL: burnsURL))
    }

    private func makeStore() -> MixSessionStore {
        MixSessionStore(fileURL: FileManager.default.temporaryDirectory
            .appendingPathComponent("rbtest-\(UUID().uuidString).json"))
    }

    private func makeSineWAV(seconds: Double, sr: Double = 44_100) throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("rbtest-\(UUID().uuidString).wav")
        let fmt = AVAudioFormat(standardFormatWithSampleRate: sr, channels: 2)!
        let file = try AVAudioFile(forWriting: url, settings: fmt.settings)
        let frames = AVAudioFrameCount(seconds * sr)
        let buf = AVAudioPCMBuffer(pcmFormat: fmt, frameCapacity: frames)!
        buf.frameLength = frames
        let ch = buf.floatChannelData!
        for c in 0..<2 {
            for i in 0..<Int(frames) { ch[c][i] = Float(sin(2.0 * .pi * 440.0 * Double(i) / sr)) * 0.2 }
        }
        try file.write(from: buf)
        return url
    }

    private func meta(_ id: String) -> MixEngine.LoadedTrack {
        MixEngine.LoadedTrack(songId: id, title: "T", artist: "A", bpm: 120,
                              camelot: nil, key: nil, albumId: nil)
    }

    /// One 4096-frame stereo float buffer of quiet sine — the tap's shape.
    private func makeTapBuffer(sr: Double = 44_100) -> AVAudioPCMBuffer {
        let fmt = AVAudioFormat(standardFormatWithSampleRate: sr, channels: 2)!
        let buf = AVAudioPCMBuffer(pcmFormat: fmt, frameCapacity: 4096)!
        buf.frameLength = 4096
        let ch = buf.floatChannelData!
        for c in 0..<2 {
            for i in 0..<4096 { ch[c][i] = Float(sin(2.0 * .pi * 440.0 * Double(i) / sr)) * 0.1 }
        }
        return buf
    }

    /// Feed `seconds` of media through a sink (4096-frame buffers at 44.1 kHz).
    private func feed(_ sink: MixTapSink, seconds: Double) {
        let buf = makeTapBuffer()
        let count = Int((seconds * 44_100 / 4096).rounded(.up))
        for _ in 0..<count { sink.write(buf) }
    }

    /// A hermetic temp session-root, installed as the app root for the duration of a test.
    private func withTempAppRoot<T>(_ body: (URL) async throws -> T) async rethrows -> T {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("rbtest-root-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        SessionFolders.appRootOverride = root
        defer {
            SessionFolders.appRootOverride = nil
            try? FileManager.default.removeItem(at: root)
        }
        return try await body(root)
    }

    // MARK: - M1/M2: dead-engine transport must never trap, and must self-recover

    /// The reported crash: the system stops the engine (route change) and a transport call runs
    /// next. Every path must guard + restart instead of trapping in `AVAudioPlayerNode.play()`.
    func testTransportSurvivesAndRecoversFromStoppedEngine() async throws {
        let e = makeEngine()
        e.ensureEngine()
        try XCTSkipUnless(e.isReady, "no audio device on this test host")
        let src = try makeSineWAV(seconds: 5)
        defer { try? FileManager.default.removeItem(at: src) }
        e.loadFile(src, release: nil, startMs: nil, meta: meta("x"), on: .a)
        e.play(.a)
        XCTAssertTrue(e.engineIsRunningForTesting)

        // Route change stops the engine out from under the app…
        e.stopEngineForTesting()
        XCTAssertFalse(e.engineIsRunningForTesting)
        // …and every transport path recovers instead of crashing (pre-fix: uncatchable ObjC trap).
        e.seek(.a, toSeconds: 1.0)
        XCTAssertTrue(e.engineIsRunningForTesting, "seek must restart a system-stopped engine")

        e.stopEngineForTesting()
        e.restart(.a)
        XCTAssertTrue(e.engineIsRunningForTesting, "restart must restart a system-stopped engine")

        e.stopEngineForTesting()
        e.play(.a)
        XCTAssertTrue(e.engineIsRunningForTesting, "play must restart a system-stopped engine")

        e.stopEngineForTesting()
        e.playBoth()
        XCTAssertTrue(e.engineIsRunningForTesting, "playBoth must restart a system-stopped engine")
        e.teardown()
    }

    /// A capture must ride through an engine stop: media keeps appending once transport recovers.
    func testRecordingRidesThroughEngineStop() async throws {
        let e = makeEngine()
        e.ensureEngine()
        try XCTSkipUnless(e.isReady, "no audio device on this test host")
        let src = try makeSineWAV(seconds: 6)
        defer { try? FileManager.default.removeItem(at: src) }
        e.loadFile(src, release: nil, startMs: nil, meta: meta("x"), on: .a)
        e.play(.a)
        let out = FileManager.default.temporaryDirectory
            .appendingPathComponent("rbtest-ride-\(UUID().uuidString).m4a")
        defer { try? FileManager.default.removeItem(at: out) }
        XCTAssertTrue(e.startRecording(to: out, release: nil))
        try await Task.sleep(nanoseconds: 700_000_000)
        let beforeStall = e.recordingAppendedSeconds
        XCTAssertGreaterThan(beforeStall, 0, "capture should be appending media")

        e.stopEngineForTesting()                       // the route change
        try await Task.sleep(nanoseconds: 300_000_000) // stalled: tap silent, nothing appended
        e.seek(.a, toSeconds: 2.0)                     // any transport recovers the engine
        try await Task.sleep(nanoseconds: 700_000_000)
        XCTAssertGreaterThan(e.recordingAppendedSeconds, beforeStall,
                             "capture must resume appending after the engine recovers")
        e.stopRecording()
        e.teardown()
    }

    // MARK: - Fragmented writer: crash-durable without a finalize

    /// The core of the guarantee: a take ABANDONED without `end()` (crash) must still be readable
    /// by both of the app's consumption paths, up to the last flushed ~2 s fragment.
    func testUnfinalizedFragmentedTakeIsReadable() async throws {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("rbtest-frag-\(UUID().uuidString).m4a")
        defer { try? FileManager.default.removeItem(at: url) }
        let sink = MixTapSink()
        XCTAssertTrue(sink.begin(url: url, sampleRate: 44_100, channels: 2))
        feed(sink, seconds: 5)                          // well past the 2 s fragment interval
        try await Task.sleep(nanoseconds: 1_500_000_000) // let the queue encode + fragments flush
        // NO end() — the writer is simply abandoned, as a crash would leave it.

        let af = try AVAudioFile(forReading: url)
        let seconds = Double(af.length) / af.processingFormat.sampleRate
        XCTAssertGreaterThan(seconds, 1.5, "at least the first flushed fragment must survive")
        let player = try AVAudioPlayer(contentsOf: url)
        XCTAssertGreaterThan(player.duration, 1.5, "AVAudioPlayer must play the un-finalized take")
    }

    // MARK: - M4/M5: writer death surfaces once, never crashes, auto-stops the recorder

    /// startWriting fails (target dir vanished) → exactly ONE failure callback, and later buffers
    /// are cheap no-ops. Pre-fix: the second buffer re-called startWriting on the failed writer —
    /// an uncatchable NSInternalInconsistencyException ~93 ms after the record press.
    func testWriterFailureFiresOnceAndNeverRetriesStartWriting() async throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("rbtest-gone-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let url = dir.appendingPathComponent("take.m4a")
        let sink = MixTapSink()
        XCTAssertTrue(sink.begin(url: url, sampleRate: 44_100, channels: 2))
        try FileManager.default.removeItem(at: dir)     // yank the folder before the first buffer

        let failures = expectation(description: "one writer-failure callback")
        failures.assertForOverFulfill = true
        sink.onWriterFailure = { _ in failures.fulfill() }
        feed(sink, seconds: 0.5)                        // several buffers → still ONE callback, no trap
        await fulfillment(of: [failures], timeout: 5)
        sink.end()
    }

    /// The engine's failure hook auto-stops the recorder and FILES the partial take.
    func testWriterFailureAutoStopsRecorderAndFilesTake() async throws {
        try await withTempAppRoot { _ in
            let e = makeEngine()
            e.ensureEngine()
            try XCTSkipUnless(e.isReady, "no audio device on this test host")
            let src = try makeSineWAV(seconds: 4)
            defer { try? FileManager.default.removeItem(at: src) }
            e.loadFile(src, release: nil, startMs: nil, meta: meta("x"), on: .a)
            e.play(.a)
            let store = makeStore()
            let recorder = MixRecorder(engine: e, sessions: store)
            let sessionId = store.currentId
            XCTAssertTrue(recorder.start())
            try await Task.sleep(nanoseconds: 500_000_000)

            e.onRecordingFailed?()                      // what the sink fires on writer death

            XCTAssertFalse(recorder.isRecording, "writer death must auto-stop the capture")
            XCTAssertNotNil(recorder.writerFailureMessage, "the UI must learn why it stopped")
            XCTAssertEqual(store.recordings(forSession: sessionId).count, 1,
                           "the partial take must be FILED, not orphaned")
            e.teardown()
        }
    }

    // MARK: - M6/S3: orphan recovery — skip unreadable stubs, file healthy takes, idempotent

    func testRecoverOrphansFilesHealthySkipsCorrupt() async throws {
        try await withTempAppRoot { root in
            let sessionDir = root.appendingPathComponent("mses_rbtest", isDirectory: true)
            try FileManager.default.createDirectory(at: sessionDir, withIntermediateDirectories: true)

            // Healthy orphan: finalized fragmented take (crash AFTER fragments flushed + a clean
            // finalize is the strongest readable case; the un-finalized case is covered above).
            let healthy = sessionDir.appendingPathComponent("recording-1.m4a")
            let sink = MixTapSink()
            XCTAssertTrue(sink.begin(url: healthy, sampleRate: 44_100, channels: 2))
            feed(sink, seconds: 3)
            try await Task.sleep(nanoseconds: 800_000_000)
            sink.end()
            try await Task.sleep(nanoseconds: 800_000_000)

            // Corrupt orphan: garbage bytes (a take that died before its first fragment).
            let corrupt = sessionDir.appendingPathComponent("recording-2.m4a")
            try Data(repeating: 0xAB, count: 4096).write(to: corrupt)

            let store = makeStore()
            let recorder = MixRecorder(engine: makeEngine(), sessions: store)
            recorder.recoverOrphans()

            let recs = store.recordings(forSession: "mses_rbtest")
            XCTAssertEqual(recs.count, 1, "healthy filed, corrupt skipped (no phantom 0:00 rows)")
            XCTAssertEqual(recs.first?.fileName, "recording-1.m4a")
            XCTAssertGreaterThan(recs.first?.durationMs ?? 0, 0,
                                 "a recovered healthy take must carry a real duration")
            XCTAssertTrue(FileManager.default.fileExists(atPath: corrupt.path),
                          "the corrupt stub is left on disk (the sweep cleans it), never deleted here")

            // Idempotent across recorder instances (fresh launch): no duplicate filing.
            let recorder2 = MixRecorder(engine: makeEngine(), sessions: store)
            recorder2.recoverOrphans()
            XCTAssertEqual(store.recordings(forSession: "mses_rbtest").count, 1)
        }
    }

    /// The old single `didScanOrphans` latch skipped a momentarily-unresolvable user folder for
    /// the whole launch. The per-root latch must keep RETRYING the user root while still scanning
    /// the app root exactly once.
    func testRecoverOrphansRetriesUnresolvableUserRoot() async throws {
        try await withTempAppRoot { root in
            let sessionDir = root.appendingPathComponent("mses_rblatch", isDirectory: true)
            try FileManager.default.createDirectory(at: sessionDir, withIntermediateDirectories: true)
            let healthy = sessionDir.appendingPathComponent("recording-1.m4a")
            let sink = MixTapSink()
            XCTAssertTrue(sink.begin(url: healthy, sampleRate: 44_100, channels: 2))
            feed(sink, seconds: 3)
            try await Task.sleep(nanoseconds: 800_000_000)
            sink.end()
            try await Task.sleep(nanoseconds: 800_000_000)

            let store = makeStore()
            let recorder = MixRecorder(engine: makeEngine(), sessions: store)
            // A bookmark that can never resolve — the user root must NOT latch off.
            let settings = SettingsStore(defaults: UserDefaults(suiteName: "rbtest-\(UUID().uuidString)")!)
            settings.sessionFolderBookmark = Data([0x00, 0x01, 0x02, 0x03])
            recorder.settings = settings

            recorder.recoverOrphans()   // app root scanned + filed; user root failed to resolve
            XCTAssertEqual(store.recordings(forSession: "mses_rblatch").count, 1)
            // A later call must still be willing to touch the user root — observable as: it keeps
            // being ATTEMPTED (no crash, no double-file of the app root either).
            recorder.recoverOrphans()
            XCTAssertEqual(store.recordings(forSession: "mses_rblatch").count, 1,
                           "the app root is latched after success — no duplicates")
        }
    }

    // MARK: - Seq bump: a fresh recording must never truncate an unrecovered crash take

    func testNewRecordingNeverTruncatesUnrecoveredOrphan() async throws {
        try await withTempAppRoot { root in
            let e = makeEngine()
            e.ensureEngine()
            try XCTSkipUnless(e.isReady, "no audio device on this test host")
            let src = try makeSineWAV(seconds: 4)
            defer { try? FileManager.default.removeItem(at: src) }
            e.loadFile(src, release: nil, startMs: nil, meta: meta("x"), on: .a)
            e.play(.a)

            let store = makeStore()
            let recorder = MixRecorder(engine: e, sessions: store)
            let sessionId = store.currentId
            // An UNRECOVERED crash orphan sits at the name the next take would naturally get
            // (metadata says 0 takes → seq 1). `MixTapSink.begin` deletes its target — without
            // the fileExists bump this would truncate the user's crash take.
            let sessionDir = root.appendingPathComponent(sessionId, isDirectory: true)
            try FileManager.default.createDirectory(at: sessionDir, withIntermediateDirectories: true)
            let orphan = sessionDir.appendingPathComponent("recording-1.m4a")
            let orphanBytes = Data(repeating: 0xCD, count: 8192)
            try orphanBytes.write(to: orphan)

            XCTAssertTrue(recorder.start())
            XCTAssertEqual(recorder.activeTake?.fileName, "recording-2.m4a",
                           "the seq bump must step past the on-disk orphan")
            try await Task.sleep(nanoseconds: 400_000_000)
            recorder.stop()
            XCTAssertEqual(try Data(contentsOf: orphan), orphanBytes,
                           "the orphan's bytes must be untouched")
            e.teardown()
        }
    }

    // MARK: - Sweep ordering: recover-then-sweep leaves no invisible loss

    /// The Storage flow now runs recovery BEFORE the destructive sweep — an orphan the user has
    /// never seen becomes a visible take (and its metadata drops cleanly with the file), instead
    /// of being silently destroyed while invisible.
    func testSweepAfterRecoveryDropsFileAndMetadataTogether() async throws {
        try await withTempAppRoot { root in
            let sessionDir = root.appendingPathComponent("mses_rbsweep", isDirectory: true)
            try FileManager.default.createDirectory(at: sessionDir, withIntermediateDirectories: true)
            let healthy = sessionDir.appendingPathComponent("recording-1.m4a")
            let sink = MixTapSink()
            XCTAssertTrue(sink.begin(url: healthy, sampleRate: 44_100, channels: 2))
            feed(sink, seconds: 3)
            try await Task.sleep(nanoseconds: 800_000_000)
            sink.end()
            try await Task.sleep(nanoseconds: 800_000_000)

            let store = makeStore()
            let recorder = MixRecorder(engine: makeEngine(), sessions: store)
            recorder.recoverOrphans()
            XCTAssertEqual(store.recordings(forSession: "mses_rbsweep").count, 1,
                           "the orphan is VISIBLE before anything destructive runs")

            store.deleteAllRecordings(bookmark: nil)
            XCTAssertFalse(FileManager.default.fileExists(atPath: healthy.path))
            XCTAssertTrue(store.recordings(forSession: "mses_rbsweep").isEmpty,
                          "file + metadata drop together — no phantom rows")
        }
    }

    #if os(iOS)
    // MARK: - M3: interruption .began parks the mix; declined resume stays parked

    func testInterruptionBeganParksAndDeclinedResumeStaysPaused() async throws {
        let e = makeEngine()
        e.ensureEngine()
        try XCTSkipUnless(e.isReady, "no audio device on this test host")
        let src = try makeSineWAV(seconds: 6)
        defer { try? FileManager.default.removeItem(at: src) }
        e.loadFile(src, release: nil, startMs: nil, meta: meta("x"), on: .a)
        e.play(.a)
        XCTAssertTrue(e.isPlaying(.a))

        func post(_ type: AVAudioSession.InterruptionType, options: AVAudioSession.InterruptionOptions? = nil) {
            var info: [AnyHashable: Any] = [AVAudioSessionInterruptionTypeKey: type.rawValue]
            if let options { info[AVAudioSessionInterruptionOptionKey] = options.rawValue }
            NotificationCenter.default.post(name: AVAudioSession.interruptionNotification,
                                            object: AVAudioSession.sharedInstance(), userInfo: info)
        }

        post(.began)                                          // phone call mid-mix
        try await Task.sleep(nanoseconds: 200_000_000)        // drain the main-queue delivery
        XCTAssertFalse(e.isPlaying(.a), ".began must park the decks (no wall-clock drive into a dead engine)")

        post(.ended, options: [])                             // iOS says: do NOT auto-resume
        try await Task.sleep(nanoseconds: 200_000_000)
        XCTAssertFalse(e.isPlaying(.a), "declined resume stays parked — no silence into an open take")

        post(.ended, options: [.shouldResume])                // iOS says: resume
        try await Task.sleep(nanoseconds: 200_000_000)
        XCTAssertTrue(e.isPlaying(.a), ".shouldResume must bring the parked deck back")
        e.teardown()
    }
    #endif
}

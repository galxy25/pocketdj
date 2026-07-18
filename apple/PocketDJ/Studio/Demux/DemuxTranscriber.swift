import Foundation
import AVFoundation
import Speech

/// ON-DEVICE speech-to-text for the Demuxer: an audio file URL → timed words (`DemuxWord`).
/// Apple's Speech framework (`SFSpeechURLRecognitionRequest`) with `requiresOnDeviceRecognition`
/// — the audio NEVER leaves the device (the user's music is not shipped to a server), and it
/// works offline. Per-word timestamps come from the transcription segments, which is what makes
/// the karaoke-style synced overlay possible.
///
/// CHUNKED recognition (the Aaliyah "Back & Forth" field bug): a one-shot URL request over a
/// full-length song makes the on-device recognizer silently give up — it returns nothing (or
/// the spurious kAFAssistantErrorDomain 1110) for music that a human plainly hears words in.
/// Dictation-length windows (~50 s) recognize reliably, so the file is sliced into windows and
/// each window's words are re-offset onto the song timeline. Each window also carries a hard
/// TIMEOUT — a Speech callback that never fires must not wedge the run (and its dedup key)
/// forever.
///
/// Accuracy note: recognition over a FULL MIX (vocals buried in instruments) is best-effort;
/// when the song's Demucs VOCALS stem is burned, callers pass that instead — dramatically
/// better (DemuxAnalyzer owns that choice).
enum DemuxTranscriber {

    enum TranscribeError: Error {
        case unauthorized          // user denied the speech-recognition permission
        case unsupported           // no recognizer / no on-device support for the locale
        case recognitionFailed(String)
    }

    /// Window length — dictation-scale, where the on-device recognizer is dependable.
    nonisolated static let chunkSeconds: Double = 50
    /// Files at most this long skip slicing entirely (recognized in place, no temp copy).
    nonisolated static let singleShotMaxSeconds: Double = 62.5
    /// Per-window ceiling: a wedged recognition callback fails the window, not the run.
    nonisolated static let chunkTimeoutSeconds: Double = 120

    /// A recognizer that can run fully on device for `locale`, or nil.
    nonisolated private static func onDeviceRecognizer(_ locale: Locale) -> SFSpeechRecognizer? {
        guard let r = SFSpeechRecognizer(locale: locale) ?? SFSpeechRecognizer() else { return nil }
        guard r.supportsOnDeviceRecognition else { return nil }
        return r
    }

    /// True when this device/locale can transcribe on device at all (drives the UI's
    /// enabled/unavailable state without prompting for permission).
    nonisolated static var isSupported: Bool {
        onDeviceRecognizer(Locale.current) != nil
    }

    /// Ask for (or confirm) speech-recognition permission. Safe to call repeatedly — the system
    /// prompts only once; afterwards it resolves instantly from the recorded grant.
    static func ensureAuthorized() async -> Bool {
        switch SFSpeechRecognizer.authorizationStatus() {
        case .authorized: return true
        case .denied, .restricted: return false
        case .notDetermined:
            return await withCheckedContinuation { cont in
                SFSpeechRecognizer.requestAuthorization { cont.resume(returning: $0 == .authorized) }
            }
        @unknown default: return false
        }
    }

    /// Transcribe `url` fully on device, window by window. Returns the timed words (may
    /// legitimately be empty — an instrumental has no lyrics). Throws for setup/authorization
    /// failures, and — unlike v1 — when EVERY window failed hard: a broken recognition run
    /// must surface as `.failed` (retryable), never masquerade as an instrumental.
    static func transcribe(url: URL, locale: Locale = .current) async throws -> [DemuxWord] {
        guard let recognizer = onDeviceRecognizer(locale) else { throw TranscribeError.unsupported }
        guard await ensureAuthorized() else { throw TranscribeError.unauthorized }

        let chunks = try slice(url: url)
        defer {
            for c in chunks where c.temporary { try? FileManager.default.removeItem(at: c.url) }
        }
        var all: [DemuxWord] = []
        var hardFailures = 0
        var lastFailure = ""
        for chunk in chunks {
            try Task.checkCancellation()
            do {
                let words = try await recognizeWindow(chunk.url, recognizer: recognizer)
                all.append(contentsOf: offset(words, byMs: chunk.startMs))
            } catch is CancellationError {
                throw CancellationError()
            } catch {
                // One bad window (timeout, transient Speech failure) must not sink the song —
                // keep going; only an all-windows wipeout throws below.
                hardFailures += 1
                lastFailure = (error as? TranscribeError).flatMap {
                    if case .recognitionFailed(let m) = $0 { return m } else { return nil }
                } ?? error.localizedDescription
            }
        }
        if all.isEmpty, hardFailures == chunks.count, hardFailures > 0 {
            throw TranscribeError.recognitionFailed(lastFailure)
        }
        return all.sorted { $0.startMs < $1.startMs }
    }

    // MARK: - Windows

    struct AudioChunk {
        let url: URL
        let startMs: Int
        /// True for sliced temp files (deleted after the run); false for the original URL.
        let temporary: Bool
    }

    /// Slice `url` into `chunkSeconds` windows (CAF, the file's own processing format).
    /// Short files pass through untouched. Pure file work — unit-tested.
    nonisolated static func slice(url: URL,
                                  windowSeconds: Double = chunkSeconds,
                                  singleShotMax: Double = singleShotMaxSeconds) throws -> [AudioChunk] {
        let file = try AVAudioFile(forReading: url)
        let sr = file.processingFormat.sampleRate
        guard sr > 0, file.length > 0 else { return [AudioChunk(url: url, startMs: 0, temporary: false)] }
        let totalSeconds = Double(file.length) / sr
        guard totalSeconds > singleShotMax else {
            return [AudioChunk(url: url, startMs: 0, temporary: false)]
        }
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("pdj-demux-chunks-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let framesPerWindow = AVAudioFrameCount(windowSeconds * sr)
        var out: [AudioChunk] = []
        var start: AVAudioFramePosition = 0
        while start < file.length {
            let frames = AVAudioFrameCount(min(AVAudioFramePosition(framesPerWindow), file.length - start))
            guard let buf = AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: frames) else { break }
            file.framePosition = start
            try file.read(into: buf, frameCount: frames)
            let chunkURL = dir.appendingPathComponent("chunk-\(out.count).caf")
            let writer = try AVAudioFile(forWriting: chunkURL, settings: file.processingFormat.settings)
            try writer.write(from: buf)
            out.append(AudioChunk(url: chunkURL, startMs: Int((Double(start) / sr * 1000).rounded()),
                                  temporary: true))
            start += AVAudioFramePosition(frames)
        }
        return out.isEmpty ? [AudioChunk(url: url, startMs: 0, temporary: false)] : out
    }

    /// Re-anchor a window's words onto the song timeline. Pure — unit-tested.
    nonisolated static func offset(_ words: [DemuxWord], byMs ms: Int) -> [DemuxWord] {
        guard ms != 0 else { return words }
        return words.map { DemuxWord(text: $0.text, startMs: $0.startMs + ms, endMs: $0.endMs + ms) }
    }

    // MARK: - One window

    /// Recognize one window with the hard per-window timeout racing the Speech callback.
    private static func recognizeWindow(_ url: URL, recognizer: SFSpeechRecognizer) async throws -> [DemuxWord] {
        try await withThrowingTaskGroup(of: [DemuxWord].self) { group in
            group.addTask { try await recognizeOnce(url: url, recognizer: recognizer) }
            group.addTask {
                try await Task.sleep(for: .seconds(chunkTimeoutSeconds))
                throw TranscribeError.recognitionFailed("recognition timed out")
            }
            guard let first = try await group.next() else { return [] }
            group.cancelAll()
            return first
        }
    }

    /// Callback-holder so the timeout/cancellation path can abort the Speech task.
    private final class TaskBox: @unchecked Sendable {
        var task: SFSpeechRecognitionTask?
    }

    private static func recognizeOnce(url: URL, recognizer: SFSpeechRecognizer) async throws -> [DemuxWord] {
        let request = SFSpeechURLRecognitionRequest(url: url)
        request.requiresOnDeviceRecognition = true
        request.shouldReportPartialResults = false
        request.taskHint = .dictation

        let box = TaskBox()
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { cont in
                var finished = false
                box.task = recognizer.recognitionTask(with: request) { result, error in
                    guard !finished else { return }
                    if let result, result.isFinal {
                        finished = true
                        cont.resume(returning: words(from: result.bestTranscription))
                    } else if let error {
                        finished = true
                        // "No speech detected" surfaces as an error on some OS versions — for a
                        // WINDOW that's a legitimately wordless stretch (instrumental bridge),
                        // not a failure.
                        let ns = error as NSError
                        if ns.domain == "kAFAssistantErrorDomain", ns.code == 1110 {
                            cont.resume(returning: [])
                        } else {
                            cont.resume(throwing: TranscribeError.recognitionFailed(error.localizedDescription))
                        }
                    }
                }
            }
        } onCancel: {
            box.task?.cancel()
        }
    }

    /// Segment list → timed words. Zero-duration segments get a nominal 200 ms so they render.
    nonisolated static func words(from transcription: SFTranscription) -> [DemuxWord] {
        transcription.segments.compactMap { seg in
            let text = seg.substring.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !text.isEmpty else { return nil }
            let start = Int(seg.timestamp * 1_000)
            let dur = max(Int(seg.duration * 1_000), 200)
            return DemuxWord(text: text, startMs: start, endMs: start + dur)
        }
    }
}

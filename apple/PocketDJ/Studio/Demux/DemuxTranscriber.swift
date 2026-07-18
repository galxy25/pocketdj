import Foundation
import Speech

/// ON-DEVICE speech-to-text for the Demuxer: an audio file URL → timed words (`DemuxWord`).
/// Apple's Speech framework (`SFSpeechURLRecognitionRequest`) with `requiresOnDeviceRecognition`
/// — the audio NEVER leaves the device (the user's music is not shipped to a server), and it
/// works offline. Per-word timestamps come from the transcription segments, which is what makes
/// the karaoke-style synced overlay possible.
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

    /// Transcribe `url` fully on device. Returns the timed words (may legitimately be empty —
    /// an instrumental has no lyrics). Throws only for setup/authorization/engine failures.
    static func transcribe(url: URL, locale: Locale = .current) async throws -> [DemuxWord] {
        guard let recognizer = onDeviceRecognizer(locale) else { throw TranscribeError.unsupported }
        guard await ensureAuthorized() else { throw TranscribeError.unauthorized }

        let request = SFSpeechURLRecognitionRequest(url: url)
        request.requiresOnDeviceRecognition = true
        request.shouldReportPartialResults = false
        request.taskHint = .dictation

        // Bridge the callback API. The handler can fire multiple times (non-final results even
        // with partials off, then a final or an error) — resume the continuation exactly once.
        return try await withCheckedThrowingContinuation { cont in
            var finished = false
            var task: SFSpeechRecognitionTask?
            task = recognizer.recognitionTask(with: request) { result, error in
                guard !finished else { return }
                if let result, result.isFinal {
                    finished = true
                    _ = task
                    cont.resume(returning: words(from: result.bestTranscription))
                } else if let error {
                    finished = true
                    // A "no speech detected" outcome surfaces as an error on some OS versions —
                    // treat it as an empty (successful) transcript, not a failure.
                    let ns = error as NSError
                    if ns.domain == "kAFAssistantErrorDomain", ns.code == 1110 {
                        cont.resume(returning: [])
                    } else {
                        cont.resume(throwing: TranscribeError.recognitionFailed(error.localizedDescription))
                    }
                }
            }
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

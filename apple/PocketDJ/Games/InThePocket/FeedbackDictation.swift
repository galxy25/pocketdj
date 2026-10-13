import Foundation
import Observation
import AVFoundation
#if canImport(Speech) && !os(tvOS)
import Speech
#endif

/// What the dictation controller needs from a speech engine — the seam the unit tests fake.
/// The real one (`SystemFeedbackSpeechEngine`) is `SFSpeechRecognizer` + the mic, ON DEVICE ONLY
/// (`requiresOnDeviceRecognition`; a device/locale that can't recognise locally simply has no mic
/// button — the DemuxTranscriber rule, no server fallback): the spoken AUDIO never leaves the
/// device, and only the transcript TEXT the user chooses to submit is ever uploaded.
@MainActor
protocol FeedbackSpeechEngine: AnyObject {
    /// This device/locale can dictate at all (no prompt is shown to find out).
    var isAvailable: Bool { get }
    /// Ask for microphone + speech-recognition permission (prompts only the first time).
    func requestAuthorization() async -> FeedbackDictationAuthorization
    /// Start listening. `onTranscript` receives the WHOLE transcript so far (not a delta), any
    /// number of times; `onFinish` fires once when recognition ends (nil = cleanly).
    func start(onTranscript: @escaping @MainActor (String) -> Void,
               onFinish: @escaping @MainActor (String?) -> Void) throws
    func stop()
}

enum FeedbackDictationAuthorization: Equatable {
    case authorized
    /// The user said no (or a profile restricts it).
    case denied
    /// No recognizer for this device / locale.
    case unavailable
}

/// The feedback field's mic button: tap → live transcript APPENDED to whatever was typed; tap
/// again → stop. Permission denied / no recognizer ⇒ the mic is hidden or disabled with a
/// one-line explanation, and the field stays a plain text field — dictation is never required.
@MainActor
@Observable
final class FeedbackDictationController {

    enum State: Equatable {
        case idle
        case requesting
        case listening
        /// Mic or speech permission is off — the explanation line shows; typing still works.
        case denied
        case unavailable
        case failed(String)
    }

    private(set) var state: State = .idle
    /// Hidden when false: the device can't dictate (tvOS, no recognizer for the locale).
    var isAvailable: Bool { engine?.isAvailable ?? false }
    var isListening: Bool { state == .listening }

    /// The user-facing reason the mic can't be used, or nil.
    var explanation: String? {
        switch state {
        case .denied:
            return "Dictation needs microphone and speech-recognition access — turn them on for PocketDJ in Settings. You can still type."
        case .unavailable:
            return "Dictation isn't available on this device. You can still type."
        case .failed(let m):
            return m
        default:
            return nil
        }
    }

    @ObservationIgnored private let engine: FeedbackSpeechEngine?
    /// The text that was in the field when listening started — the transcript is appended to it.
    @ObservationIgnored private var base = ""
    @ObservationIgnored private var sink: ((String) -> Void)?

    init(engine: FeedbackSpeechEngine?) {
        self.engine = engine
    }

    /// The production controller for this platform.
    static func system() -> FeedbackDictationController {
        #if canImport(Speech) && !os(tvOS)
        return FeedbackDictationController(engine: SystemFeedbackSpeechEngine())
        #else
        return FeedbackDictationController(engine: nil)
        #endif
    }

    /// Mic button. `current` is the field's text now; `update` writes the field.
    func toggle(current: String, update: @escaping (String) -> Void) async {
        if state == .listening { stop(); return }
        guard let engine, engine.isAvailable else { state = .unavailable; return }
        state = .requesting
        switch await engine.requestAuthorization() {
        case .denied: state = .denied; return
        case .unavailable: state = .unavailable; return
        case .authorized: break
        }
        base = current
        sink = update
        do {
            try engine.start(onTranscript: { [weak self] text in
                guard let self, self.state == .listening else { return }
                self.sink?(Self.join(self.base, text))
            }, onFinish: { [weak self] error in
                guard let self else { return }
                if let error, self.state == .listening { self.state = .failed(error) }
                else if self.state == .listening { self.state = .idle }
                self.sink = nil
            })
            state = .listening
        } catch {
            state = .failed("Couldn't start dictation.")
        }
    }

    func stop() {
        guard state == .listening || state == .requesting else { return }
        state = .idle
        engine?.stop()
        sink = nil
    }

    /// Typed text + a space + the transcript (no double spaces, nothing added for an empty side).
    static func join(_ typed: String, _ spoken: String) -> String {
        let t = typed.trimmingCharacters(in: .whitespaces)
        let s = spoken.trimmingCharacters(in: .whitespaces)
        if t.isEmpty { return s }
        if s.isEmpty { return typed }
        let sep = t.hasSuffix("\n") ? "" : " "
        return t + sep + s
    }
}

#if canImport(Speech) && !os(tvOS)
/// SFSpeechRecognizer + AVAudioEngine input tap, `requiresOnDeviceRecognition` ALWAYS — a
/// recognizer that can't run locally reports unavailable rather than fall back to Apple's
/// servers, so the audio stays on the device. The shared audio session is borrowed
/// exactly the way `StudioMicRecorder` borrows it (`AudioSessionPolicy` flag first, then
/// `.playAndRecord` with speaker + A2DP so the round's music keeps playing through it), and given
/// back to `.playback` on stop.
@MainActor
final class SystemFeedbackSpeechEngine: FeedbackSpeechEngine {
    private lazy var recognizer: SFSpeechRecognizer? = SFSpeechRecognizer(locale: Locale.current) ?? SFSpeechRecognizer()
    private var audioEngine: AVAudioEngine?
    private var request: SFSpeechAudioBufferRecognitionRequest?
    private var task: SFSpeechRecognitionTask?
    private var finished = true

    var isAvailable: Bool { recognizer?.supportsOnDeviceRecognition == true }

    func requestAuthorization() async -> FeedbackDictationAuthorization {
        guard isAvailable else { return .unavailable }
        let speech: SFSpeechRecognizerAuthorizationStatus
        switch SFSpeechRecognizer.authorizationStatus() {
        case .notDetermined:
            speech = await withCheckedContinuation { cont in
                SFSpeechRecognizer.requestAuthorization { cont.resume(returning: $0) }
            }
        case let s:
            speech = s
        }
        guard speech == .authorized else { return .denied }
        let mic: Bool
        switch AVAudioApplication.shared.recordPermission {
        case .granted: mic = true
        case .denied: mic = false
        case .undetermined: mic = await AVAudioApplication.requestRecordPermission()
        @unknown default: mic = false
        }
        return mic ? .authorized : .denied
    }

    func start(onTranscript: @escaping @MainActor (String) -> Void,
               onFinish: @escaping @MainActor (String?) -> Void) throws {
        guard let recognizer, recognizer.isAvailable, recognizer.supportsOnDeviceRecognition else {
            throw DictationError.unavailable
        }
        // The studio sampler owns the mic right now — don't fight it for the session.
        guard !AudioSessionPolicy.micCaptureActive else { throw DictationError.busy }
        stop()
        AudioSessionPolicy.beginMicCapture()
        #if os(iOS)
        do {
            try AVAudioSession.sharedInstance().setCategory(
                .playAndRecord, mode: .default, options: [.defaultToSpeaker, .allowBluetoothA2DP])
            try AVAudioSession.sharedInstance().setActive(true)
        } catch {
            AudioSessionPolicy.endMicCapture()
            throw error
        }
        #endif
        let req = SFSpeechAudioBufferRecognitionRequest()
        req.shouldReportPartialResults = true
        req.requiresOnDeviceRecognition = true
        let engine = AVAudioEngine()
        let input = engine.inputNode
        let format = input.outputFormat(forBus: 0)
        guard format.sampleRate > 0 else { restoreSession(); throw DictationError.unavailable }
        input.installTap(onBus: 0, bufferSize: 1024, format: format) { buffer, _ in
            req.append(buffer)
        }
        engine.prepare()
        do { try engine.start() } catch {
            input.removeTap(onBus: 0)
            restoreSession()
            throw error
        }
        audioEngine = engine
        request = req
        finished = false
        task = recognizer.recognitionTask(with: req) { [weak self] result, error in
            let text = result?.bestTranscription.formattedString
            let isFinal = result?.isFinal ?? false
            let failed = error != nil
            Task { @MainActor [weak self] in
                if let text { onTranscript(text) }
                guard isFinal || failed, let self, !self.finished else { return }
                self.teardown()
                // A cancel/stop surfaces as an error too — only a failure with nothing heard is one.
                onFinish(failed && text == nil ? "Dictation stopped — try again." : nil)
            }
        }
    }

    func stop() {
        guard !finished else { return }
        request?.endAudio()
        teardown()
    }

    private func teardown() {
        finished = true
        if let engine = audioEngine {
            engine.inputNode.removeTap(onBus: 0)
            engine.stop()
        }
        audioEngine = nil
        task?.finish()
        task = nil
        request = nil
        restoreSession()
    }

    private func restoreSession() {
        AudioSessionPolicy.endMicCapture()
        #if os(iOS)
        try? AVAudioSession.sharedInstance().setCategory(.playback, mode: .default)
        try? AVAudioSession.sharedInstance().setActive(true)
        #endif
    }

    enum DictationError: Error { case unavailable, busy }
}
#endif

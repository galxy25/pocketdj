import Foundation
import Observation

/// State machine for the "?♪?" mic button. The `ShazamButton` view drives its tint
/// and animation off `phase`; `ShazamResultSheet` reads `phase`'s `.matched(...)`.
enum ShazamPhase: Equatable {
    case idle
    case listening           // mic open, capturing audio
    case recognizing         // signature generated, querying the Shazam catalog
    case matched(ShazamMatch)
    case noMatch
    case denied              // microphone permission denied
    case failed(String)

    var isActive: Bool {
        switch self {
        case .listening, .recognizing: return true
        default: return false
        }
    }
}

// ============================================================================
// MARK: - Recognizer
// ============================================================================
//
// ShazamKit ships with the SDK and the app's deployment targets (iOS 18 / macOS 15)
// far exceed ShazamKit's floor (iOS 15 / macOS 12), so no `#available` guard is
// needed at call sites. The `#if canImport(ShazamKit)` keeps the file portable to
// any toolchain without the framework; the `#else` stub keeps the button compiling
// (it simply reports `.failed` if tapped).
#if canImport(ShazamKit)
import ShazamKit
#if canImport(AVFAudio)
import AVFAudio
#endif

/// Owns a `SHManagedSession` (which manages its own `AVAudioEngine` mic tap +
/// signature generation) and turns its results into a `ShazamMatch` against the
/// in-memory catalog. `@MainActor @Observable` so the button observes `phase`.
///
/// Runtime requirements (NOT needed to build): the `com.apple.developer.shazamkit`
/// entitlement and `NSMicrophoneUsageDescription`; the public Shazam catalog needs
/// no developer token. We request mic permission ourselves so `.denied` is a clean,
/// actionable state rather than a thrown error.
///
/// `SHManagedSession` (which owns the mic + signature pipeline for us) is iOS 17 /
/// macOS 14+. The app's deployment targets (18 / 15) clear that, so no `#available`
/// branch is needed at call sites; the annotation just pins the floor.
@available(iOS 17.0, macOS 14.0, *)
@MainActor
@Observable
final class ShazamRecognizer {
    private(set) var phase: ShazamPhase = .idle

    /// Snapshot of the catalog to match against (the recognizer is decoupled from
    /// `AppModel`'s lifecycle — the caller passes the current songs).
    private var songsProvider: () -> [IndexSong]

    private var session: SHManagedSession?
    private var listenTask: Task<Void, Never>?

    /// `songs` is an autoclosure so the button can pass `app.songs` and always get
    /// the current catalog at match time.
    init(songs: @escaping @autoclosure () -> [IndexSong] = []) {
        self.songsProvider = songs
    }

    /// Begin listening. Idempotent: a second tap while active stops first.
    func start() {
        guard !phase.isActive else { stop(); return }
        phase = .listening
        listenTask = Task { @MainActor in await self.run() }
    }

    /// Stop the mic + cancel any in-flight query, returning to `.idle` unless a
    /// terminal phase (matched/noMatch/denied/failed) is already set.
    func stop() {
        listenTask?.cancel(); listenTask = nil
        session?.cancel()
        session = nil
        if phase.isActive { phase = .idle }
    }

    /// Dismiss a result and reset for another tap.
    func reset() {
        stop()
        phase = .idle
    }

    private func run() async {
        // Microphone permission first so denial is a clean state.
        guard await Self.ensureMicPermission() else { phase = .denied; return }

        let session = SHManagedSession()
        self.session = session
        let stream = session.results

        // Move to "recognizing" shortly after capture begins (the session is
        // generating the signature + querying); purely cosmetic for the button.
        Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: 600_000_000)
            if case .listening = self?.phase { self?.phase = .recognizing }
        }

        for await result in stream {
            if Task.isCancelled { return }
            switch result {
            case .match(let match):
                if let item = match.mediaItems.first {
                    let info = Self.hitInfo(from: item)
                    let m = ShazamCatalogMatch.resolve(info, in: songsProvider())
                    phase = .matched(m)
                } else {
                    phase = .noMatch
                }
                stopMicKeepingPhase()
                return
            case .noMatch:
                phase = .noMatch
                stopMicKeepingPhase()
                return
            case .error(let error, _):
                phase = .failed(error.localizedDescription)
                stopMicKeepingPhase()
                return
            @unknown default:
                continue
            }
        }
    }

    /// Tear the mic down but DON'T overwrite a terminal phase (matched/noMatch/…).
    private func stopMicKeepingPhase() {
        listenTask = nil
        session?.cancel()
        session = nil
    }

    // MARK: SHMediaItem → ShazamKit-free info

    private static func hitInfo(from item: SHMediaItem) -> ShazamHitInfo {
        ShazamHitInfo(
            title: item.title,
            artist: item.artist,
            artworkURL: item.artworkURL,
            appleMusicID: item.appleMusicID)
    }

    // MARK: Microphone permission (platform-split)

    private static func ensureMicPermission() async -> Bool {
        #if canImport(AVFAudio)
        if #available(iOS 17.0, macOS 14.0, *) {
            switch AVAudioApplication.shared.recordPermission {
            case .granted: return true
            case .denied:  return false
            case .undetermined:
                return await AVAudioApplication.requestRecordPermission()
            @unknown default: return false
            }
        } else {
            return await withCheckedContinuation { cont in
                AVAudioSession.sharedInstance().requestRecordPermission { cont.resume(returning: $0) }
            }
        }
        #else
        return true
        #endif
    }
}

#else
// ============================================================================
// MARK: - Stub (ShazamKit unavailable)
// ============================================================================

/// No-op recognizer so `ShazamButton` compiles where ShazamKit isn't linked.
@MainActor
@Observable
final class ShazamRecognizer {
    private(set) var phase: ShazamPhase = .idle
    init(songs: @escaping @autoclosure () -> [IndexSong] = []) {}
    func start() { phase = .failed("Recognition isn’t available in this build.") }
    func stop() { phase = .idle }
    func reset() { phase = .idle }
}
#endif

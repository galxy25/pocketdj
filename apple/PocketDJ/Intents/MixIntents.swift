import Foundation
import AppIntents

// Auto-DJ intents. Start mirrors MixView's ▶/🔀 path (resolver → engine); pause/resume
// use the LOCK-SCREEN seam (`remotePause`/`remotePlay`) — the only pair that suspends
// the transition machine with a frozen wall clock and resumes exactly what was paused
// (the in-app pause keeps audio running for hand-mixing; `pauseBoth` would END the mix).

struct StartAutoMixIntent: AudioPlaybackIntent {
    static let title: LocalizedStringResource = "Auto-Mix"
    static let description = IntentDescription("""
        Starts an Auto-DJ mix from a pocket, playlist, or set list, with timed crossfades. \
        Auto-mix plays songs burned onto this device.
        """)

    @Parameter(title: "Pocket, Playlist, or Set List", requestValueDialog: "Which pocket, playlist, or set list?")
    var source: AutoMixSourceEntity
    @Parameter(title: "Shuffle", default: false)
    var shuffle: Bool

    static var parameterSummary: some ParameterSummary {
        Summary("Auto-mix \(\.$source)") { \.$shuffle }
    }

    @Dependency private var services: IntentServices

    @MainActor
    func perform() async throws -> some IntentResult & ProvidesDialog {
        guard let mixSource = source.mixSource else { throw PocketDJIntentError.mixSourceNotFound }
        let started = try await services.startAutoMix(source: mixSource, shuffle: shuffle)
        let lead = shuffle ? "Auto-mixing \(started.name), shuffled" : "Auto-mixing \(started.name)"
        return .result(dialog: "\(lead) — \(started.count) burned \(started.count == 1 ? "song" : "songs").")
    }
}

struct PauseAutoMixIntent: AudioPlaybackIntent {
    static let title: LocalizedStringResource = "Pause Auto-Mix"
    static let description = IntentDescription("Pauses a running Auto-DJ mix (freezes the mix clock; Resume picks up exactly where it left off).")

    static var parameterSummary: some ParameterSummary {
        Summary("Pause the auto-mix")
    }

    @Dependency private var services: IntentServices

    @MainActor
    func perform() async throws -> some IntentResult & ProvidesDialog {
        try services.pauseAutoMix()
        return .result(dialog: "Auto-mix paused.")
    }
}

struct ResumeAutoMixIntent: AudioPlaybackIntent {
    static let title: LocalizedStringResource = "Resume Auto-Mix"
    static let description = IntentDescription("Resumes a paused Auto-DJ mix, picking up the frozen crossfade exactly where it stopped.")

    static var parameterSummary: some ParameterSummary {
        Summary("Resume the auto-mix")
    }

    @Dependency private var services: IntentServices

    @MainActor
    func perform() async throws -> some IntentResult & ProvidesDialog {
        try services.resumeAutoMix()
        return .result(dialog: "Auto-mix resumed.")
    }
}

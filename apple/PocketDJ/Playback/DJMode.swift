import Foundation

/// Now Playing DJ Mode (docs/design/np-dj-mode.md). Session state on `SetlistPlayer`, a sibling of
/// Mix Mode's `NPMixModeState`; persisted in the playback snapshot as an optional `djMode`.
struct DJModeState: Codable, Equatable {
    var enabled = false
}

/// The Settings ▸ DJ Mode toggles as one value (np-dj-mode §6). Every part defaults ON; the
/// player reads this through its `djModeSettings` closure (like `mixModeSettings`), and the
/// toggles MASK parts of the orchestration off — they never change the shared Mix-tab timings.
struct DJModeSettings: Equatable, Sendable {
    /// DJ transitions (crossfade orchestration). Off ⇒ every advance is a normal advance.
    var transitions = true
    /// FX texture sweep during a transition. Off ⇒ no texture.
    var effectSweeps = true
    /// Tempo meet-in-the-middle. Off ⇒ rate targets 1.
    var tempoMatch = true
    /// ±1 key pitch bend. Off ⇒ pitch 0.
    var keyMatch = true
    /// Loudness leveling toward `LoudnessLeveling.targetLufs`.
    var volumeLeveling = true
    /// The selector's 10-BPM tempo waves.
    var tempoWaves = true
    /// The selector's genre / year / collection pockets.
    var pockets = true

    static let allOn = DJModeSettings()

    /// The selector-facing subset (`DJSetPlanner.Options`). Key fit in the planner follows
    /// `keyMatch` — the "Key/pitch match" toggle governs both the bend and key-aware ordering.
    var plannerOptions: DJSetPlanner.Options {
        DJSetPlanner.Options(tempoWaves: tempoWaves, pockets: pockets, key: keyMatch)
    }
}

enum DJMode {
    /// The `[dj]` DiagLog lane (song ids only, never titles) + the Now Playing trace — plan,
    /// transition start / decline reasons, leveling gains.
    @MainActor
    static func log(_ message: String) {
        DiagLog.shared.log("dj", message)
        NPLog.trace("dj \(message)")
    }
}

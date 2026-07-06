import Foundation
import os

// MARK: - Process-wide audio-session coexistence policy (spec §4)

/// The ONE cross-engine rule about the shared `AVAudioSession`: while the studio mic recorder
/// holds it at `.playAndRecord` for a live input tap, NO playback path may re-arm `.playback`.
///
/// WHY this must exist at all: there is deliberately no single session owner in this app — every
/// playback engine (`MixEngine.activateAudioSession`, `PlayerEngine.configureAudioSession`,
/// `StemPlayer.configureSession`, and `MixSessionsView`'s `RecordingAudioPlayer`) DEFENSIVELY
/// calls `setCategory(.playback) + setActive(true)` on its own init/load/start. That's harmless
/// between playback engines (idempotent), but `setCategory` is itself a route-changing operation:
/// flipping the live `.playAndRecord` session back to `.playback` tears the INPUT route out from
/// under the mic engine's installed tap mid-take — the tap goes silent (a dead take that still
/// pulses "recording") and the engine can be stopped outright, the same family of failures the
/// recording-bulletproof work closed for route changes. A setlist auto-advance, a Mix deck load,
/// or a take-replay tap can fire at ANY moment while the user records a sample, so the guard has
/// to be process-wide and checkable from every playback path — a convention would rot.
///
/// WHY nonisolated + atomic: the flag is read inside `#if os(iOS)` session-setup code on the main
/// actor today, but a static policy must not bake that assumption in (and the recorder writes it
/// around session flips, where an actor hop would open a race window between "flag set" and
/// "category changed"). `OSAllocatedUnfairLock` gives an uncontended-cheap atomic Bool without
/// dragging actor isolation into session code. Deliberately a Bool, not a count: exactly one mic
/// recorder exists (`StudioMicRecorder`, app-scoped), so begin/end pairs can never nest.
enum AudioSessionPolicy {
    /// Locked backing store — only touched through the members below.
    private static let state = OSAllocatedUnfairLock(initialState: false)

    /// True while the studio mic recorder is monitoring/recording through the shared session
    /// (`.playAndRecord`). Every `setCategory(.playback)` call site guards on this and NO-OPS
    /// while it is set: playback keeps working under `.playAndRecord` (the output side is
    /// unaffected), so skipping the re-arm costs nothing — and saves the live input tap.
    static var micCaptureActive: Bool { state.withLock { $0 } }

    /// Called by the recorder BEFORE it flips the session to `.playAndRecord`, so a playback
    /// load racing the flip can't slip a `.playback` re-arm in between the flag and the change.
    static func beginMicCapture() { state.withLock { $0 = true } }

    /// Capture/monitoring ended — the recorder restores `.playback` itself immediately after
    /// clearing this (clear-first so its own restore is never confused for a hostile re-arm).
    static func endMicCapture() { state.withLock { $0 = false } }
}

import Foundation
import Observation

/// The ZERO-TO-HERO first-run flow (Levi 2026-07-18): three staged choices a fresh
/// install (or reinstall) walks before the app proper — profile (on-device vs iCloud),
/// Apple Music sign-in, and which global sources to import (Vinyl / Digital / Streaming).
///
/// This store owns WHEN the flow shows and WHERE it stands; the stage UIs live in
/// `Views/Onboarding/`. The decision is made ONCE at init (presentation is launch-only)
/// from an explicit persisted marker — never inferred from the settings blob alone:
///   • marker absent + no settings blob  → fresh install / reinstall → show.
///   • marker absent + settings blob     → an EXISTING user updating into this version →
///     stamp `completed` silently (they must never see a first-run wall).
///   • `started(stage)`                  → a mid-flow force-quit → resume at that stage
///     (the blob may exist by then — stage 1 persists settings — so blob-existence alone
///     would strand the remaining stages; the marker outranks it).
///   • `pending`                         → forced re-run (mushroom-cloud reset writes it,
///     BEFORE the reset UI can re-persist a settings blob on tab changes).
///   • `completed`                       → never again (until reinstall wipes defaults —
///     which is exactly the re-onboard semantic the feature asks for).
///
/// LAUNCH GATING: RootView's `.task` awaits `waitUntilComplete()` FIRST, so the launch
/// pipeline (cloud sync, session restores, catalog load) runs with the user's choices.
/// While incomplete, CloudSyncService refuses pushes and IntentServices vetoes mutating
/// intents — see the Q1/R1–R4 notes in docs/design (a half-born profile or an empty
/// synced doc must never overwrite a returning user's cloud data).
///
/// TEST SEAMS: `PDJ_SHOW_ONBOARDING=1` forces the flow (onboarding's own UI tests, always
/// alongside PDJ_USE_FIXTURE); every deterministic harness (PDJ_USE_FIXTURE,
/// PDJ_INTEGRATION_PLAYBACK, PDJ_PERF_SMOKE — the one UI-test file with no fixture var)
/// suppresses it so existing suites never meet a first-run wall. visionOS auto-completes:
/// the visionOS-27 blank-first-window bug is still open, and a modal gate on a window
/// that may never render would strand the install (revisit when that bug is fixed).
@MainActor
@Observable
final class OnboardingStore {

    // MARK: - Stages

    enum Stage: Int, Codable, CaseIterable {
        case profile = 0
        case appleMusic = 1
        case sources = 2
    }

    // MARK: - Persisted marker

    /// The explicit persisted state under `pdj.onboarding.v1` (same defaults object as
    /// SettingsStore — constructed once in PocketDJApp.init and passed to both, because
    /// `SettingsStore.launchDefaults()` re-wipes the fixture suite on every call).
    enum Marker: Equatable {
        case pending
        case started(Stage)
        case completed
    }

    private struct MarkerFile: Codable {
        var version: Int
        var state: String          // "pending" | "started" | "completed"
        var stage: Int?
        var completedAtMs: Double?
    }

    nonisolated static let markerKey = "pdj.onboarding.v1"

    // MARK: - Live state

    /// The flow is done (either never needed or finished). Gates the cover UI, the
    /// scenePhase sync hooks, CloudSync pushes, and the intent veto.
    private(set) var isComplete: Bool
    /// The stage the flow currently shows (meaningful only while `!isComplete`).
    private(set) var stage: Stage = .profile
    /// Fired once when the user finishes the last stage (the app wires catalog reload).
    @ObservationIgnored var onComplete: (() -> Void)?

    @ObservationIgnored private let defaults: UserDefaults
    @ObservationIgnored private var waiters: [CheckedContinuation<Void, Never>] = []

    // MARK: - Init / decision

    init(defaults: UserDefaults,
         hadPersistedSettings: Bool,
         environment: [String: String] = ProcessInfo.processInfo.environment) {
        self.defaults = defaults
        var decision = Self.decide(marker: Self.readMarker(defaults),
                                   hadPersistedSettings: hadPersistedSettings,
                                   environment: environment)
        #if os(visionOS) || os(tvOS)
        // Auto-complete on visionOS while the blank-first-window bug is open (see header),
        // and on tvOS ALWAYS: the TV has no import surface (file pickers are TVCompat
        // no-ops), so the three-stage flow can't be walked there — profile, collections,
        // and connection credentials all arrive via the iCloud pull at launch instead.
        if case .show = decision { decision = .skipAndStamp }
        #endif
        switch decision {
        case .skip:
            isComplete = true
        case .skipAndStamp:
            isComplete = true
            Self.writeMarker(.completed, to: defaults)
        case .show(let s):
            isComplete = false
            stage = s
            // Stamp `started` the moment the flow first presents, so a force-quit at any
            // stage resumes HERE — never silently skips the rest (the settings blob may
            // already exist once stage 1 persists a choice).
            Self.writeMarker(.started(s), to: defaults)
        }
    }

    enum Decision: Equatable {
        case skip
        case skipAndStamp
        case show(Stage)
    }

    /// Pure decision tree (unit-tested directly). Order is load-bearing:
    /// force-seam → suppression → marker → upgrade-stamp → fresh.
    nonisolated static func decide(marker: Marker?,
                                   hadPersistedSettings: Bool,
                                   environment: [String: String]) -> Decision {
        if environment["PDJ_SHOW_ONBOARDING"] == "1" { return .show(.profile) }
        if environment["PDJ_USE_FIXTURE"] != nil
            || environment["PDJ_INTEGRATION_PLAYBACK"] == "1"
            || environment["PDJ_PERF_SMOKE"] != nil {
            return .skip
        }
        switch marker {
        case .completed:          return .skip
        case .pending:            return .show(.profile)
        case .started(let s):     return .show(s)
        case nil:                 return hadPersistedSettings ? .skipAndStamp : .show(.profile)
        }
    }

    // MARK: - Flow control (driven by the stage UIs)

    /// Move to the next stage, or finish after the last. Persists progress so a
    /// force-quit resumes exactly here.
    func advance() {
        guard !isComplete else { return }
        if let next = Stage(rawValue: stage.rawValue + 1) {
            stage = next
            Self.writeMarker(.started(next), to: defaults)
        } else {
            complete()
        }
    }

    /// Step back one stage (never past the first).
    func back() {
        guard !isComplete, let prev = Stage(rawValue: stage.rawValue - 1) else { return }
        stage = prev
        Self.writeMarker(.started(prev), to: defaults)
    }

    /// Finish the flow: persist `completed`, release the launch pipeline, run the hook.
    func complete() {
        guard !isComplete else { return }
        isComplete = true
        Self.writeMarker(.completed, to: defaults)
        onComplete?()
        let resumed = waiters
        waiters = []
        for w in resumed { w.resume() }
    }

    /// Suspend until the flow completes (returns immediately when it never shows).
    /// RootView's `.task` awaits this before ANY launch action.
    func waitUntilComplete() async {
        guard !isComplete else { return }
        await withCheckedContinuation { (c: CheckedContinuation<Void, Never>) in
            if isComplete { c.resume() } else { waiters.append(c) }
        }
    }

    // MARK: - Marker persistence (static so SettingsStore.resetEverything can force a re-run)

    /// Mushroom-cloud reset: force onboarding on the next launch REGARDLESS of the
    /// settings blob (RootView re-persists the blob on any section change after a reset,
    /// so blob-absence can't be the signal). Presentation stays launch-only.
    nonisolated static func markPendingAfterReset(in defaults: UserDefaults) {
        writeMarker(.pending, to: defaults)
    }

    nonisolated static func readMarker(_ defaults: UserDefaults) -> Marker? {
        guard let data = defaults.data(forKey: markerKey),
              let file = try? JSONDecoder().decode(MarkerFile.self, from: data) else { return nil }
        switch file.state {
        case "pending":   return .pending
        case "completed": return .completed
        case "started":   return .started(file.stage.flatMap(Stage.init(rawValue:)) ?? .profile)
        default:          return nil
        }
    }

    nonisolated private static func writeMarker(_ marker: Marker, to defaults: UserDefaults) {
        let file: MarkerFile
        switch marker {
        case .pending:
            file = MarkerFile(version: 1, state: "pending", stage: nil, completedAtMs: nil)
        case .started(let s):
            file = MarkerFile(version: 1, state: "started", stage: s.rawValue, completedAtMs: nil)
        case .completed:
            file = MarkerFile(version: 1, state: "completed", stage: nil,
                              completedAtMs: Date().timeIntervalSince1970 * 1000)
        }
        if let data = try? JSONEncoder().encode(file) {
            defaults.set(data, forKey: markerKey)
        }
    }
}

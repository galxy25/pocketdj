import SwiftUI

/// History ▸ Pockets: **Wheel | List** (W1, decided 2026-10-29). Wheel is the default and needs
/// only local history; List is the cloud listening-pockets view, unchanged (it keeps the opt-in
/// offer). tvOS has no History tab and never builds the wheel.
struct PocketsTabView: View {
    @Binding var path: NavigationPath
    /// Per-viewer convenience (which segment you were on) — the wheel itself never depends on it.
    @AppStorage("pdj.history.pockets.segment") private var segment = Segment.wheel.rawValue
    @Environment(PocketWheelController.self) private var controller: PocketWheelController?
    @Environment(SettingsStore.self) private var settings: SettingsStore?
    @Environment(PocketRunStore.self) private var runs: PocketRunStore?

    enum Segment: String, CaseIterable { case wheel = "Wheel", list = "List" }

    var body: some View {
        VStack(spacing: 0) {
            // A listener who DECLINED cloud pockets sees the (local) wheel only — the List segment
            // would just re-offer the opt-in they already turned down.
            if showsList {
            Picker("Pockets view", selection: $segment) {
                ForEach(Segment.allCases, id: \.rawValue) { Text($0.rawValue).tag($0.rawValue) }
            }
            .pickerStyle(.segmented)
            .padding(.horizontal, 16)
            .padding(.top, 8)
            .accessibilityIdentifier("pockets-segment")
            }
            if showsList && segment == Segment.list.rawValue {
                ListeningPocketsView(path: $path)
            } else {
                #if os(tvOS)
                ListeningPocketsView(path: $path)
                #else
                PocketWheelScreen()
                    .environment(\.pocketWheelActions, actions)
                    .task { await controller?.refreshIfStale() }
                #endif
            }
        }
        .onAppear {
            if let raw = ProcessInfo.processInfo.environment["PDJ_POCKETS_SEGMENT"], Segment(rawValue: raw) != nil {
                segment = raw
            }
        }
    }

    private var showsList: Bool { settings?.listeningPocketsChoice != false }

    /// The wheel's buttons, bound to the app-scoped best match + run store.
    private var actions: PocketWheelActions {
        guard let controller else { return .none }
        var a = PocketWheelActions()
        a.bestMatch = controller.bestSummary
        a.playBest = { Task { await controller.playBest() } }
        a.alternatives = controller.alternativeSummaries
        a.playAlternative = { alt in Task { await controller.play(alternative: alt) } }
        a.playMoment = { key in Task { await controller.playMoment(key) } }
        if let runs {
            _ = runs.revision
            a.runProgress = runs.progress
            a.pauseRun = { runs.togglePause() }
            a.runHistory = { runs.runHistory(for: $0) }
        }
        return a
    }
}

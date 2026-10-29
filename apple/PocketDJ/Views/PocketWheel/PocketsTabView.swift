import SwiftUI

/// History ▸ Pockets: **Wheel | List** (W1, decided 2026-10-29). Wheel is the default and needs
/// only local history; List is the cloud listening-pockets view, unchanged (it keeps the opt-in
/// offer). tvOS has no History tab and never builds this.
struct PocketsTabView: View {
    @Binding var path: NavigationPath
    /// Per-viewer convenience (which segment you were on) — the wheel itself never depends on it.
    @AppStorage("pdj.history.pockets.segment") private var segment = Segment.wheel.rawValue

    enum Segment: String, CaseIterable { case wheel = "Wheel", list = "List" }

    var body: some View {
        VStack(spacing: 0) {
            Picker("Pockets view", selection: $segment) {
                ForEach(Segment.allCases, id: \.rawValue) { Text($0.rawValue).tag($0.rawValue) }
            }
            .pickerStyle(.segmented)
            .padding(.horizontal, 16)
            .padding(.top, 8)
            .accessibilityIdentifier("pockets-segment")
            if segment == Segment.list.rawValue {
                ListeningPocketsView(path: $path)
            } else {
                #if os(tvOS)
                ListeningPocketsView(path: $path)
                #else
                PocketWheelScreen()
                #endif
            }
        }
        .onAppear {
            if let raw = ProcessInfo.processInfo.environment["PDJ_POCKETS_SEGMENT"], Segment(rawValue: raw) != nil {
                segment = raw
            }
        }
    }
}

import SwiftUI
#if os(iOS)
import UIKit   // openSettingsURLString — the denied / When-In-Use hand-off
#endif

/// Settings ▸ Recommendations ▸ "Use places & trips in pockets" (design spec §3.5).
///
/// Renders ROWS, not a `Section`, so the host can drop it straight under the "Find my listening
/// pockets" toggle inside its own Section (a nested Section misrenders in a grouped Form); the
/// privacy note rides as a footnote row. Reads `ListeningLocationStore` from the environment
/// (optional — absent or unsupported renders nothing). Every platform but iOS: `EmptyView()`.
struct ListeningLocationSettingsSection: View {
    let pocketsEnabled: Bool

    init(pocketsEnabled: Bool) { self.pocketsEnabled = pocketsEnabled }

    @Environment(ListeningLocationStore.self) private var store: ListeningLocationStore?

    var body: some View {
        #if os(iOS)
        if let store, store.isSupported {
            ListeningLocationSettingsRows(store: store, pocketsEnabled: pocketsEnabled)
        }
        #else
        EmptyView()
        #endif
    }
}

#if os(iOS)
private struct ListeningLocationSettingsRows: View {
    let store: ListeningLocationStore
    let pocketsEnabled: Bool
    @State private var showEraseConfirm = false

    var body: some View {
        // `revision` is read so place/trip lists recompute whenever the engine changes.
        let _ = store.revision
        Toggle("Use places & trips in pockets", isOn: Binding(
            get: { store.isEnabled },
            set: { store.setEnabled($0) }))
            .disabled(!pocketsEnabled)
            .accessibilityIdentifier("pockets-location-toggle")

        if store.isEnabled {
            authorizationRow

            let places = store.placeLabels()
            if places.isEmpty {
                Text("No places yet. They appear after you've spent some time somewhere.")
                    .font(.caption).foregroundStyle(.secondary)
                    .accessibilityIdentifier("pockets-location-no-places")
            } else {
                ForEach(places) { p in
                    LabeledContent(p.label) {
                        Text("\(Int((p.shareOfTime * 100).rounded())) % of time")
                            .foregroundStyle(.secondary)
                    }
                    .accessibilityIdentifier("pockets-location-place-\(p.rank)")
                }
            }
            let trips = store.tripLabels()
            if !trips.isEmpty {
                ForEach(trips) { t in
                    LabeledContent(t.label) {
                        Text("\(t.occurrences)×").foregroundStyle(.secondary)
                    }
                    .accessibilityIdentifier("pockets-location-trip")
                }
            }

            Button("Erase location data", role: .destructive) { showEraseConfirm = true }
                .accessibilityIdentifier("pockets-location-erase")
                .confirmationDialog("Erase your places and trips from this device?",
                                    isPresented: $showEraseConfirm, titleVisibility: .visible) {
                    Button("Erase location data", role: .destructive) { store.eraseAll() }
                        .accessibilityIdentifier("pockets-location-erase-confirm")
                    Button("Cancel", role: .cancel) {}
                } message: {
                    Text("PocketDJ starts learning your places again from now. Pockets you already have keep their labels as \"Earlier place\".")
                }
        }

        Text("Your location never leaves this device. PocketDJ only learns which of your places, A, B, C…, you were at, or that you were travelling between them. Those anonymous labels can be included with your listening pockets.")
            .font(.footnote).foregroundStyle(.secondary)
    }

    @ViewBuilder private var authorizationRow: some View {
        LabeledContent("Location access") {
            Text(statusText).foregroundStyle(store.authorization.isGranted ? Color.secondary : Theme.danger)
                .accessibilityIdentifier("pockets-location-status")
        }
        switch store.authorization {
        case .denied, .restricted:
            Button("Open Settings") { openSettings() }
                .accessibilityIdentifier("pockets-location-open-settings")
        case .whenInUse:
            // The system's Always prompt is offered once; after that it's the Settings app.
            if store.didRequestAlways {
                Button("Allow Always in Settings") { openSettings() }
                    .accessibilityIdentifier("pockets-location-open-settings")
            } else {
                Button("Allow Always") { store.requestAlwaysUpgrade() }
                    .accessibilityIdentifier("pockets-location-allow-always")
            }
            Text("Always lets PocketDJ notice trips between your places while music plays in the background.")
                .font(.caption).foregroundStyle(.secondary)
        default:
            EmptyView()
        }
    }

    private var statusText: String {
        switch store.authorization {
        case .always: return "Always"
        case .whenInUse: return "While using the app"
        case .denied: return "Denied"
        case .restricted: return "Restricted"
        case .notDetermined: return "Not yet asked"
        case .unsupported: return "Unavailable"
        }
    }

    private func openSettings() {
        if let url = URL(string: UIApplication.openSettingsURLString) {
            UIApplication.shared.open(url)
        }
    }
}
#endif

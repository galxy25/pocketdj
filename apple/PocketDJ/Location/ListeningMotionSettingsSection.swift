import SwiftUI
#if os(iOS)
import UIKit   // openSettingsURLString — the denied hand-off
#endif

/// Settings ▸ Pocket Wheel ▸ "Notice walking & running" (docs/design/pocket-wheel.md §1.4).
///
/// Renders ROWS (not a Section) so the host can place it in its own Section, exactly like
/// `ListeningLocationSettingsSection`. Reads `ListeningMotionStore` from the environment
/// (optional — absent or unsupported renders nothing). Every platform but iOS: `EmptyView()`.
struct ListeningMotionSettingsSection: View {
    @Environment(ListeningMotionStore.self) private var store: ListeningMotionStore?
    /// Whether listening pockets (the cloud upload) is on — only changes the privacy wording.
    var pocketsEnabled: Bool = false

    var body: some View {
        #if os(iOS)
        if let store, store.isSupported {
            ListeningMotionSettingsRows(store: store, pocketsEnabled: pocketsEnabled)
        }
        #else
        EmptyView()
        #endif
    }
}

#if os(iOS)
private struct ListeningMotionSettingsRows: View {
    let store: ListeningMotionStore
    let pocketsEnabled: Bool

    var body: some View {
        Toggle("Notice walking & running", isOn: Binding(
            get: { store.isEnabled },
            set: { on in Task { await store.setEnabled(on) } }))
            .accessibilityIdentifier("wheel-motion-toggle")

        if store.isEnabled {
            LabeledContent("Motion access") {
                Text(statusText)
                    .foregroundStyle(store.authorization == .authorized ? Color.secondary : Theme.danger)
                    .accessibilityIdentifier("wheel-motion-status")
            }
            if store.authorization == .denied || store.authorization == .restricted {
                Text(store.authorization == .restricted
                     ? "Motion & Fitness is restricted on this iPhone, so walking and running can't be noticed."
                     : "Motion & Fitness access is off for PocketDJ. Turn it on in Settings to tell a run from a commute.")
                    .font(.caption).foregroundStyle(.secondary)
                if store.authorization == .denied {
                    Button("Open Settings") {
                        if let url = URL(string: UIApplication.openSettingsURLString) {
                            UIApplication.shared.open(url)
                        }
                    }
                    .accessibilityIdentifier("wheel-motion-open-settings")
                }
            }
        }

        Text(pocketsEnabled
             ? "PocketDJ notices when you were walking, running, cycling or in a car while a song played, so your pocket wheel can tell a run from a commute. With listening pockets on, the activity of each play (walking, running, and so on) is sent with your pockets. No location or step counts are ever sent."
             : "PocketDJ notices when you were walking, running, cycling or in a car while a song played, so your pocket wheel can tell a run from a commute. It uses the motion history iPhone already keeps; no GPS, and nothing extra runs in the background.")
            .font(.footnote).foregroundStyle(.secondary)
    }

    private var statusText: String {
        switch store.authorization {
        case .authorized:    return "Allowed"
        case .notDetermined: return "Not asked yet"
        case .denied:        return "Denied"
        case .restricted:    return "Restricted"
        case .unsupported:   return "Unavailable"
        }
    }
}
#endif

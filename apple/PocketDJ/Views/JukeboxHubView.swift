import SwiftUI

/// Which half of the Jukebox panel is showing. Jukebox Hero (QR request line for a room) and
/// Remote (SharePlay Listen Together / Backseat / Mix Together) share one panel — Levi
/// 2026-11-08: "merge remote into jukebox panel". Both are "other people steer the music"
/// surfaces, so they live side by side instead of as two sidebar tabs.
/// rawValue is persisted (`storageKey`) — never rename.
enum JukeboxPanelMode: String, CaseIterable, Identifiable {
    case hero = "Jukebox Hero"
    case remote = "Remote"
    var id: String { rawValue }
    /// UserDefaults key shared by the panel's picker and the deep entries (⌘R, the retired
    /// "Remote" section token, the PDJ_START_SECTION / PDJ_TV_TAB seams).
    static let storageKey = "jukeboxPanelMode"
}

/// The Jukebox panel: a Jukebox Hero | Remote switch over the two surfaces. Each child keeps
/// its own navigation title and content unchanged.
struct JukeboxHubView: View {
    @AppStorage(JukeboxPanelMode.storageKey) private var modeRaw = JukeboxPanelMode.hero.rawValue
    @Environment(RemoteSessionController.self) private var remote

    private var mode: Binding<JukeboxPanelMode> {
        Binding(get: { JukeboxPanelMode(rawValue: modeRaw) ?? .hero },
                set: { modeRaw = $0.rawValue })
    }

    var body: some View {
        Group {
            switch mode.wrappedValue {
            case .hero:
                #if os(tvOS)
                TVJukeboxView()
                #else
                JukeboxView()
                #endif
            case .remote:
                #if os(tvOS)
                TVRemoteView()
                #else
                RemoteView()
                #endif
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        // The switch rides a top safe-area inset (not a VStack row above the content), so the
        // child's scroll view stays the primary one: the large title collapses on scroll and
        // rows slide under an opaque bar instead of being sliced at the switch's edge.
        .safeAreaInset(edge: .top, spacing: 0) {
            VStack(spacing: 0) {
                Picker("Jukebox panel", selection: mode) {
                    ForEach(JukeboxPanelMode.allCases) { m in
                        Text(m.rawValue).tag(m)
                    }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .frame(maxWidth: 420)
                .padding(.horizontal, 16).padding(.vertical, 8)
                .accessibilityIdentifier("jukebox-panel-mode")
                Divider().overlay(Theme.border)
            }
            .frame(maxWidth: .infinity)
            .background(Theme.bg)
        }
        .background(Theme.bg)
        // A SharePlay session arriving while the panel shows Jukebox Hero flips it to Remote,
        // so the session's controls are one tap away (the old Remote tab was always visible).
        .onChange(of: remote.isActive) { _, active in
            if active { modeRaw = JukeboxPanelMode.remote.rawValue }
        }
    }
}

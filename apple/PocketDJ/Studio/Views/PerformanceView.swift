import SwiftUI

// MARK: - Sub-tabs (spec §1)

/// The five Studio sub-tabs. `rawValue` is the persistence token in `SettingsStore.studioTab`
/// AND the shadow-button name fragment (`studio-tab-<rawValue>-shadow`) — it is stable forever,
/// never rename a case (the RootView.Section rawValue doctrine, one level down).
enum StudioSubTab: String, CaseIterable, Identifiable {
    case samples, loops, sequencer, instruments, cues

    var id: String { rawValue }

    /// User-facing segment title — shown only at REGULAR width (compact is symbol-only,
    /// because five text segments truncate into unreadable mush on an iPhone in portrait).
    var label: String {
        switch self {
        case .samples:     return "Samples"
        case .loops:       return "Loops"
        case .sequencer:   return "Sequencer"
        case .instruments: return "Instruments"
        case .cues:        return "Cues"
        }
    }

    /// SF Symbols per spec §1: waveform / repeat / square.grid.4x3.fill / pianokeys / flag.
    var icon: String {
        switch self {
        case .samples:     return "waveform"
        case .loops:       return "repeat"
        case .sequencer:   return "square.grid.4x3.fill"
        case .instruments: return "pianokeys"
        case .cues:        return "flag"
        }
    }

    /// ⌘1…⌘5 in declaration order (spec §1). These keys are ALSO Browse's Albums/Songs
    /// toggle — safe only because both registrations are view-scoped shadow buttons that
    /// are never mounted simultaneously (the spec §0 scoping rule).
    var shortcutKey: KeyEquivalent {
        switch self {
        case .samples:     return "1"
        case .loops:       return "2"
        case .sequencer:   return "3"
        case .instruments: return "4"
        case .cues:        return "5"
        }
    }
}

// MARK: - Performance tab shell (spec §1/§11)

/// The Performance ("Studio") tab: a segmented sub-tab switcher over the five Studio surfaces.
/// Pure shell — every sub-view is no-argument + environment-driven (the cross-agent view-name
/// contract), and the Studio launch hooks (store reconcile, fixture seed, mic orphan recovery)
/// deliberately live in RootView's launch `.task` beside the mixRecorder precedent, so they run
/// exactly once at launch no matter which tab the app restores into.
struct PerformanceView: View {
    @Environment(SettingsStore.self) private var settings
    #if os(iOS)
    // Compact width (iPhone portrait) drives the symbol-only segment rendering below.
    @Environment(\.horizontalSizeClass) private var horizontalSizeClass
    #endif
    @State private var tab: StudioSubTab = .samples

    /// macOS has no size classes — it is always "regular" (symbol + text segments).
    private var isCompact: Bool {
        #if os(iOS)
        return horizontalSizeClass == .compact
        #else
        return false
        #endif
    }

    var body: some View {
        VStack(spacing: 0) {
            // The sub-tab switcher lives IN CONTENT, not the toolbar (the iPhone-portrait
            // overflow lesson: critical controls must never collapse into a nested "•••").
            Picker("Studio", selection: $tab) {
                ForEach(StudioSubTab.allCases) { t in
                    if isCompact {
                        Image(systemName: t.icon).tag(t)
                    } else {
                        Label(t.label, systemImage: t.icon).tag(t)
                    }
                }
            }
            .pickerStyle(.segmented)
            .padding(.horizontal, 16).padding(.vertical, 8)
            .accessibilityIdentifier("studio-tab-picker")

            content
        }
        .background { tabShortcuts }
        .navigationTitle("Producer")
        .background(Theme.bg)
        .task {
            // Restore the last-open sub-tab ("open where you left off" — the
            // settings.lastSection pattern one level down). Unknown/absent ⇒ Samples.
            // Idempotent on re-entry: onChange keeps settings.studioTab == tab.
            if let raw = settings.studioTab, let t = StudioSubTab(rawValue: raw) { tab = t }
        }
        .onChange(of: tab) {
            settings.studioTab = tab.rawValue
            settings.persist()
        }
    }

    /// The five sub-views (cross-agent contract: no-argument, environment-driven — they pull
    /// StudioStore/StudioEngine/StudioMicRecorder/InstrumentEngine/InstrumentPackStore from
    /// the environment themselves).
    @ViewBuilder private var content: some View {
        switch tab {
        case .samples:     StudioSamplesView()
        case .loops:       StudioLoopsView()
        case .sequencer:   StudioSequencerView()
        case .instruments: StudioInstrumentsView()
        case .cues:        StudioCuesView()
        }
    }

    /// ⌘1…⌘5 sub-tab shortcuts as hidden shadow buttons (the BrowseView.kindShortcuts
    /// pattern): mounted ONLY while this view is — so Browse's own ⌘1/⌘2 never see a second
    /// live registration — and the reliable way to drive the segmented picker in macOS
    /// XCUITests (where segments aren't tappable; XCUIHelpers drives via typeKey).
    private var tabShortcuts: some View {
        Group {
            ForEach(StudioSubTab.allCases) { t in
                Button("studio-tab-\(t.rawValue)-shadow") { tab = t }
                    .keyboardShortcut(t.shortcutKey, modifiers: .command)
            }
        }
        .frame(width: 1, height: 1)
        .opacity(0.01)
    }
}

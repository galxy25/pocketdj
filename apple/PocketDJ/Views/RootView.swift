import SwiftUI

/// Adaptive shell: a sidebar split view that collapses to a stack on iPhone and
/// becomes a true two-column layout on iPad and Mac.
struct RootView: View {
    @Environment(AppModel.self) private var app
    @Environment(SettingsStore.self) private var settings
    @Environment(EditsStore.self) private var edits
    // Optional selection: the non-optional List(selection:) initializer is macOS-only.
    @State private var section: Section? = .browse
    @State private var path = NavigationPath()   // heterogeneous: albums + songs

    enum Section: String, CaseIterable, Identifiable, Hashable {
        case browse = "Browser"
        case pockets = "Pockets"
        case playlists = "Playlists"
        case settings = "Settings"
        var id: String { rawValue }
        var icon: String {
            switch self {
            case .browse:    return "list.bullet"
            case .pockets:   return "rectangle.stack"
            case .playlists: return "music.note.list"
            case .settings:  return "gearshape"
            }
        }
    }

    var body: some View {
        NavigationSplitView {
            List(Section.allCases, selection: $section) { item in
                Label(item.rawValue, systemImage: item.icon).tag(item)
            }
            .navigationTitle("✦ PocketDJ")
            .toolbar(removing: .sidebarToggle)
            #if os(macOS)
            .navigationSplitViewColumnWidth(min: 200, ideal: 220, max: 280)
            #endif
        } detail: {
            NavigationStack(path: $path) {
                detail
                    .navigationDestination(for: IndexAlbum.self) { AlbumDetailView(album: $0) }
                    .navigationDestination(for: IndexSong.self) { SongDetailView(song: $0) }
            }
        }
        .background { navigationShortcuts }
        .task {
            app.settings = settings   // wire the live multi-source config before loading
            app.edits = edits         // overlay local metadata edits
            // Testing seam: `PDJ_START_SECTION=Settings` lands on a section headlessly.
            if let raw = ProcessInfo.processInfo.environment["PDJ_START_SECTION"],
               let s = Section(rawValue: raw) {
                section = s
            }
            await app.loadIfNeeded()
            // Testing seam: `PDJ_OPEN_FIRST_ALBUM=1` deep-links into an album so the
            // track table can be screenshotted headlessly. No-op in normal use.
            if ProcessInfo.processInfo.environment["PDJ_OPEN_FIRST_ALBUM"] != nil,
               let first = app.albums.first {
                path.append(first)
            }
        }
    }

    /// App-wide keyboard navigation: ⌘B → Browser, ⌘, → Settings (hidden buttons).
    private var navigationShortcuts: some View {
        Group {
            Button("Browser-shadow") { section = .browse; path = NavigationPath() }
                .keyboardShortcut("b", modifiers: .command)
            Button("Settings-shadow") { section = .settings }
                .keyboardShortcut(",", modifiers: .command)
        }
        .frame(width: 1, height: 1).opacity(0.01)
    }

    @ViewBuilder private var detail: some View {
        switch section ?? .browse {
        case .browse:
            BrowseView()
        case .settings:
            SettingsView(settings: settings)
        case let other:
            ComingSoon(title: other.rawValue, icon: other.icon)
        }
    }
}

struct ComingSoon: View {
    let title: String
    let icon: String
    var body: some View {
        ContentUnavailableView {
            Label(title, systemImage: icon)
        } description: {
            Text("Native \(title) view is on the roadmap.")
        }
        .navigationTitle(title)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Theme.bg)
    }
}

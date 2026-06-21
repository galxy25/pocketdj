import SwiftUI

/// Adaptive shell: a sidebar split view that collapses to a stack on iPhone and
/// becomes a true two-column layout on iPad and Mac.
struct RootView: View {
    @Environment(AppModel.self) private var app
    @Environment(SettingsStore.self) private var settings
    @Environment(EditsStore.self) private var edits
    @Environment(CollectionsStore.self) private var collections
    @Environment(RipsStore.self) private var rips
    @Environment(PlayerEngine.self) private var player
    @Environment(PlaybackCoordinator.self) private var coordinator
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
                    .navigationDestination(for: Pocket.self) { PocketDetailView(pocketId: $0.id) }
                    .navigationDestination(for: Playlist.self) { PlaylistDetailView(playlistId: $0.id, path: $path) }
                    .navigationDestination(for: SourcePlaylist.self) { IndexPlaylistDetailView(source: $0, path: $path) }
                    .navigationDestination(for: Setlist.self) { SetlistDetailView(setlistId: $0.id) }
            }
        }
        .background { navigationShortcuts }
        .overlay(alignment: .bottomTrailing) { testProbe }
        .task {
            app.settings = settings   // wire the live multi-source config before loading
            app.edits = edits         // overlay local metadata edits
            collections.app = app     // give realize() the catalog to resolve ids against
            rips.settings = settings  // rip server URL + token come from settings
            // The matching engine orders providers by a song's ORIGIN SOURCE — give it the
            // catalog's per-id source map so an Apple Music (Local) track tries Apple Music
            // streaming first. (Captured by closure; AppModel is a long-lived @Observable.)
            coordinator.sourceOfSong = { [weak app] id in app?.source(ofSong: id) }
            applyTestLaunchConfig()   // test seam: load sources / set search creds from env
            Task { await rips.refreshManifest() }   // learn what's already ripped (public S3)
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

    /// A tiny, always-in-the-a11y-tree readout of the shared `PlayerEngine` so a UI
    /// test can poll real playback state regardless of which surface drove play/pause.
    /// `player-state` value is "playing"/"paused"; `player-elapsed` is the seconds.
    /// Gated behind `PDJ_TEST_PROBE` so it never ships in normal use. Rendered as a
    /// 1×1 nearly-invisible element that is NOT marked hidden, so XCUITest can read it.
    @ViewBuilder private var testProbe: some View {
        if ProcessInfo.processInfo.environment["PDJ_TEST_PROBE"] != nil {
            VStack(spacing: 0) {
                // Each is its OWN leaf static-text element so XCUITest resolves
                // `staticTexts["player-state"]` and reads `.value`/`.label` directly.
                Text(player.isPlaying ? "playing" : "paused")
                    .accessibilityIdentifier("player-state")
                    .accessibilityValue(player.isPlaying ? "playing" : "paused")
                Text(String(format: "%.1f", player.currentTime))
                    .accessibilityIdentifier("player-elapsed")
                    .accessibilityValue(String(format: "%.1f", player.currentTime))
                Text("\(player.toggleCount)")
                    .accessibilityIdentifier("player-toggles")
                    .accessibilityValue("\(player.toggleCount)")
            }
            .font(.system(size: 2))
            .foregroundStyle(Theme.bg)        // blend into the background — present but unobtrusive
            .frame(width: 2, height: 4)
            .allowsHitTesting(false)
        }
    }

    /// Test seam (no-op in normal use): wire real resources from `launchEnvironment` so
    /// an integration UI test can drive the live app. `PDJ_LOAD_APPLE_MUSIC=1` adds the
    /// Apple Music (Local) source (so its catalog — incl. the cached, publicly-playable
    /// rips — is searchable). Online-search creds, when supplied, enable cloud search.
    private func applyTestLaunchConfig() {
        let env = ProcessInfo.processInfo.environment
        if env["PDJ_LOAD_APPLE_MUSIC"] == "1" { settings.loadAppleMusic() }
        if let key = env["PDJ_AOSS_ACCESS_KEY_ID"], let secret = env["PDJ_AOSS_SECRET_ACCESS_KEY"],
           !key.isEmpty, !secret.isEmpty {
            settings.searchAccessKeyID = key
            settings.searchSecretKey = secret
            if let ep = env["PDJ_AOSS_ENDPOINT"] { settings.searchEndpoint = ep }
            settings.persist()
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
        case .browse:    BrowseView(path: $path)
        case .pockets:   PocketsView()
        case .playlists: PlaylistsView(path: $path)
        case .settings:  SettingsView(settings: settings)
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

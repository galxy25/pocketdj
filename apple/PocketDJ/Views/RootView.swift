import SwiftUI

/// Adaptive shell: a sidebar split view that collapses to a stack on iPhone and
/// becomes a true two-column layout on iPad and Mac.
struct RootView: View {
    @Environment(AppModel.self) private var app
    @Environment(SettingsStore.self) private var settings
    @Environment(CollectionsStore.self) private var collections
    @Environment(RipsStore.self) private var rips
    @Environment(PlayerEngine.self) private var player
    @Environment(BurnStore.self) private var burns
    @Environment(IntentServices.self) private var intents
    // Optional selection: the non-optional List(selection:) initializer is macOS-only.
    @State private var section: Section? = .browse
    @State private var path = NavigationPath()   // heterogeneous: albums + songs

    enum Section: String, CaseIterable, Identifiable, Hashable {
        case browse = "Browser"
        case playlists = "Playlists"
        case mix = "Mix"
        case settings = "Settings"
        var id: String { rawValue }
        var icon: String {
            switch self {
            case .browse:    return "list.bullet"
            case .playlists: return "music.note.list"
            case .mix:       return "slider.horizontal.3"
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
                    .navigationDestination(for: IndexAlbum.self) { AlbumDetailView(album: $0, path: $path) }
                    .navigationDestination(for: IndexSong.self) { SongDetailView(song: $0) }
                    .navigationDestination(for: Pocket.self) { PocketDetailView(pocketId: $0.id, path: $path) }
                    .navigationDestination(for: Playlist.self) { PlaylistDetailView(playlistId: $0.id, path: $path) }
                    .navigationDestination(for: SourcePlaylist.self) { IndexPlaylistDetailView(source: $0, path: $path) }
                    .navigationDestination(for: Setlist.self) { SetlistDetailView(setlistId: $0.id, path: $path) }
                    .navigationDestination(for: SetlistLaunch.self) { SetlistDetailView(setlistId: $0.setlistId, autoplay: $0.autoplay, path: $path) }
                    .navigationDestination(for: MixSessionsRoute.self) { _ in MixSessionsView() }
                    .navigationDestination(for: MixSessionRoute.self) { MixSessionDetailView(sessionId: $0.sessionId) }
            }
        }
        .background { navigationShortcuts }
        .overlay(alignment: .bottomTrailing) { testProbe }
        // Intent-driven navigation (Spotlight "Open playlist/pocket"): the intent parks a
        // route on the bridge; this view owns the NavigationPath, so it consumes it —
        // whether the app was already open (`onChange`) or launched by the intent (`.task`).
        // The handler re-reads the LIVE value (not onChange's captured parameter): with
        // several windows open (iPad split, macOS ⌘N) every RootView's onChange fires with
        // the same captured route, but only the first finds the live value non-nil — the
        // guard-let + clear inside consumeIntentRoute is an atomic take on the main actor.
        .onChange(of: intents.pendingRoute) { _, _ in consumeIntentRoute(intents.pendingRoute) }
        .task {
            // Store cross-wiring happens in PocketDJApp.init() (so background intent
            // launches are wired too); this task runs the launch ACTIONS.
            Task { await SearchService.ensureConfigLoaded() }  // pre-warm online-search host from search-config.json
            // Prune any burned files iOS purged while the app was gone.
            burns.reconcileOnLaunch()
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
            consumeIntentRoute(intents.pendingRoute)   // route parked by a cold intent launch
        }
    }

    /// Consume a pending intent route on a FRESH stack (Spotlight/Siri asked for
    /// *this* destination — whatever was pushed before doesn't belong underneath it;
    /// mirrors the ⌘B Browser shortcut's reset).
    private func consumeIntentRoute(_ route: IntentRoute?) {
        guard let route else { return }
        intents.pendingRoute = nil
        path = NavigationPath()
        switch route {
        case .playlist(let id):
            section = .playlists
            if let pl = collections.playlist(id) { path.append(pl) }
        case .pocket(let id):
            section = .playlists
            if let p = collections.pocket(id) { path.append(p) }
        case .browseSearch:
            // The search term itself rides `pendingBrowseQuery`, consumed by BrowseView.
            section = .browse
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
            Button("Playlists-shadow") { section = .playlists }
                .keyboardShortcut("p", modifiers: .command)
            // ⌘M → Mix. On macOS this INTENTIONALLY overrides the system "minimize" shortcut
            // (the user asked for it); the Mix tab exists on iPhone, iPad, AND Mac.
            Button("Mix-shadow") { section = .mix }
                .keyboardShortcut("m", modifiers: .command)
        }
        .frame(width: 1, height: 1).opacity(0.01)
    }

    @ViewBuilder private var detail: some View {
        switch section ?? .browse {
        case .browse:    BrowseView(path: $path)
        case .playlists: PlaylistsView(path: $path)
        case .mix:       MixView(path: $path)
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

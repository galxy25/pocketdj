import SwiftUI
#if canImport(UIKit)
import UIKit
#endif

/// Adaptive shell: a sidebar split view that collapses to a stack on iPhone and
/// becomes a true two-column layout on iPad and Mac.
struct RootView: View {
    @Environment(AppModel.self) private var app
    @Environment(SettingsStore.self) private var settings
    @Environment(CollectionsStore.self) private var collections
    @Environment(RipsStore.self) private var rips
    @Environment(PlayerEngine.self) private var player
    @Environment(BurnStore.self) private var burns
    @Environment(SetlistPlayer.self) private var sequencer
    @Environment(MixEngine.self) private var mix
    @Environment(MixRecorder.self) private var mixRecorder
    @Environment(StudioStore.self) private var studio
    @Environment(StudioMicRecorder.self) private var studioMic
    @Environment(PlayHistoryStore.self) private var playHistory
    @Environment(IntentServices.self) private var intents
    // System actions behind the leading "+" (open a New Window). supportsMultipleWindows is
    // false on iPhone (can't show two windows) and true on iPad/macOS/visionOS — it gates the
    // button so it self-hides exactly where ⌘N does (see NewWindowCommands in PocketDJApp).
    @Environment(\.openWindow) private var openWindow
    @Environment(\.supportsMultipleWindows) private var supportsMultipleWindows
    // Optional selection: the non-optional List(selection:) initializer is macOS-only.
    // Launch default: macOS lands on the MIX tab; iOS lands on the HOME menu (nil —
    // the collapsed split view rests on the sidebar) unless a previously-persisted
    // section is restored in `.task` ("open to wherever you last left off").
    #if os(macOS)
    @State private var section: Section? = .mix
    #else
    @State private var section: Section?
    #endif
    @State private var path = NavigationPath()   // heterogeneous: albums + songs

    enum Section: String, CaseIterable, Identifiable, Hashable {
        case browse = "Browser"
        case history = "History"
        case playlists = "Playlists"
        case mix = "Mix"
        // The Studio tab (samples/loops/sequencer/instruments/cues). rawValue triple-duties
        // as sidebar label + settings.lastSection token + PDJ_START_SECTION seam — never
        // rename it (spec §0's collision table pins the string).
        case performance = "Performance"
        case settings = "Settings"
        var id: String { rawValue }
        var icon: String {
            switch self {
            case .browse:      return "list.bullet"
            case .history:     return "clock.arrow.circlepath"
            case .playlists:   return "music.note.list"
            case .mix:         return "slider.horizontal.3"
            case .performance: return "pianokeys"
            case .settings:    return "gearshape"
            }
        }
    }

    /// The home Now Playing element shows for collection playback (the app-scoped
    /// sequencer) in every mode EXCEPT Mix — a running/suspended Auto-DJ or live
    /// deck owns the audio, so the panel yields.
    private var nowPlayingVisible: Bool {
        NowPlayingPanel.isVisible(sequencer: sequencer, mix: mix)
    }

    var body: some View {
        NavigationSplitView {
            // Sidebar = the iPhone HOME menu screen / the iPad+macOS left column.
            // The Now Playing element rides UNDER the menu items in both shapes;
            // while it's up, the menu list keeps just its rows' height and the
            // panel (record player + queue + add-search) gets the rest.
            VStack(spacing: 0) {
                List(Section.allCases, selection: $section) { item in
                    rowLabel(item).tag(item)
                }
                .frame(maxHeight: nowPlayingVisible ? 236 : .infinity)
                if nowPlayingVisible {
                    Divider().overlay(Theme.border)
                    NowPlayingPanel()
                }
            }
            // Plain "PocketDJ" home title on every platform — the old ✦ AI sparkle is gone.
            // Its leading spot now holds the "+" New Window button (multi-window platforms only).
            .navigationTitle("PocketDJ")
            .toolbar(removing: .sidebarToggle)
            .toolbar { newWindowToolbar }
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
            // Re-file any crash-orphaned recording AT LAUNCH — a crashed take must reappear no
            // matter which tab the app restores into (waiting for a Mix-tab visit left it
            // invisible everywhere while the Storage sweep could still delete it).
            mixRecorder.recoverOrphans()
            // Studio (Performance tab) launch hooks — the same at-launch doctrine as the two
            // lines above, and deliberately in THIS order: reconcile drops records whose files
            // are PROVABLY gone (unreachable user roots skip, never prune); the UI-test fixture
            // seed runs BEFORE the mic orphan scan so a leftover fixture file from a previous
            // run is re-adopted as the seeded sample (an orphan-scan adoption first would file
            // it as "Recovered recording" and veto the seed's empty-document guard); the scan
            // then re-files crash-orphaned mic takes regardless of which tab the app lands on.
            studio.reconcileOnLaunch()
            studio.seedFixtureIfRequested()
            studioMic.recoverOrphans()
            // History demo seed (PDJ_SEED_HISTORY) — populate the timeline for UI tests / demos.
            playHistory.seedDemoIfRequested()
            applyTestLaunchConfig()   // test seam: load sources / set search creds from env
            Task { await rips.refreshManifest() }   // learn what's already ripped (public S3)
            // Testing seam: `PDJ_START_SECTION=Settings` lands on a section headlessly.
            if let raw = ProcessInfo.processInfo.environment["PDJ_START_SECTION"],
               let s = Section(rawValue: raw) {
                section = s
            } else {
                #if os(iOS)
                // Restore the last-visited section ("open to wherever you last left
                // off"); "" or nothing persisted ⇒ stay on the HOME menu. macOS
                // deliberately skips this — it always lands on Mix.
                if let raw = settings.lastSection, let s = Section(rawValue: raw) {
                    section = s
                } else if UIDevice.current.userInterfaceIdiom == .pad {
                    // iPad's split view always shows a detail column — with nothing to
                    // restore it opens on MIX (like the Mac: the DJ surface), with the
                    // sidebar row selected to match.
                    section = .mix
                }
                #endif
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
        // Remember where the user is so the next iOS launch reopens there (nil —
        // the home menu — persists as "" and restores as home).
        .onChange(of: section) {
            settings.lastSection = section?.rawValue ?? ""
            settings.persist()
        }
    }

    /// Leading toolbar: a "+" that opens a NEW app window — the on-screen twin of ⌘N /
    /// File ▸ New Window. Sits to the leading edge of the "PocketDJ" home title, where the
    /// old ✦ sparkle used to be. Gated on `supportsMultipleWindows`, so it appears on
    /// iPad/macOS/visionOS and self-hides on iPhone (which can't display a second window).
    /// Placement mirrors MixView's leading cluster: `.topBarLeading` on iOS/iPadOS,
    /// `.navigation` on macOS/visionOS.
    @ToolbarContentBuilder private var newWindowToolbar: some ToolbarContent {
        if supportsMultipleWindows {
            #if os(iOS)
            ToolbarItem(placement: .topBarLeading) { newWindowButton }
            #else
            ToolbarItem(placement: .navigation) { newWindowButton }
            #endif
        }
    }

    private var newWindowButton: some View {
        Button { openWindow(id: "main") } label: { Image(systemName: "plus") }
            .help("New Window — run another surface (Mix, Performance…) alongside this one")
            .accessibilityIdentifier("new-window")
    }

    /// Menu row: every section uses its SF Symbol except MIX, which wears Apple
    /// Music's AutoMix mark (two overlapping records — one solid, one open ring).
    /// No public SF Symbol exists for it, so it's drawn as a tiny vector that
    /// follows `.tint` exactly like the surrounding symbol icons.
    @ViewBuilder private func rowLabel(_ item: Section) -> some View {
        if item == .mix {
            // No explicit foreground style: the Canvas inherits the Label icon
            // slot's, so it colors exactly like the sibling SF Symbol icons on
            // every platform (white here, accent when the platform tints them).
            Label { Text(item.rawValue) } icon: {
                AutoMixIcon()
                    .frame(width: 25, height: 15)
            }
        } else {
            Label(item.rawValue, systemImage: item.icon)
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
            // ⌘H → History from anywhere. On macOS this INTENTIONALLY overrides the system
            // "Hide" shortcut (same deliberate override as ⌘M over "minimize" below).
            Button("History-shadow") { section = .history; path = NavigationPath() }
                .keyboardShortcut("h", modifiers: .command)
            Button("Settings-shadow") { section = .settings }
                .keyboardShortcut(",", modifiers: .command)
            // ⌘P → Performance, ⇧⌘P → Playlists (spec §0's collision table): plain ⌘P
            // belonged to Playlists, but the Performance tab claims it — and one key must
            // never have two live registrations (the ⌘L ambiguity lesson in BrowseView),
            // so Playlists moves to ⇧⌘P and Browse's play-focused moves to ⌥⌘P. The
            // shadow LABELS keep their names — they are load-bearing XCUITest queries.
            Button("Performance-shadow") { section = .performance }
                .keyboardShortcut("p", modifiers: .command)
            Button("Playlists-shadow") { section = .playlists }
                .keyboardShortcut("p", modifiers: [.command, .shift])
            // ⌘M → Mix. On macOS this INTENTIONALLY overrides the system "minimize" shortcut
            // (the user asked for it); the Mix tab exists on iPhone, iPad, AND Mac.
            Button("Mix-shadow") { section = .mix }
                .keyboardShortcut("m", modifiers: .command)
        }
        .frame(width: 1, height: 1).opacity(0.01)
    }

    @ViewBuilder private var detail: some View {
        switch section {
        case .browse:      BrowseView(path: $path)
        case .history:     HistoryView(path: $path)
        case .playlists:   PlaylistsView(path: $path)
        case .mix:         MixView(path: $path)
        case .performance: PerformanceView()
        case .settings:    SettingsView(settings: settings)
        case .none:
            // No section = the iPhone HOME menu (the sidebar owns the screen; this detail isn't
            // shown). Render a neutral backdrop — NOT the old `?? .browse` fallback — so popping a
            // tab back to home never briefly re-renders the Browser album grid mid pop-animation.
            // That flash only became visible once the catalog started painting instantly off the
            // main actor; before, the fallback Browser was empty/mid-load so nothing showed.
            Theme.bg.ignoresSafeArea()
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

/// Apple Music's AUTOMIX glyph, redrawn: two same-size overlapping records — the
/// left one solid, the right one an open ring sitting ON TOP with a small cut gap
/// where it crosses the solid disc (matching Apple's mark). Drawn with the current
/// foreground style, so `.foregroundStyle(.tint)` renders it in the same accent as
/// the neighboring SF Symbol tab icons.
struct AutoMixIcon: View {
    var body: some View {
        Canvas { context, size in
            let h = size.height
            let r = h / 2                       // both records span the full height
            let stroke = h * 0.22               // the open record's ring thickness
            let gap = h * 0.10                  // cut gap where the ring crosses the disc
            let leftCenter = CGPoint(x: r, y: r)
            let rightCenter = CGPoint(x: size.width - r, y: r)

            func circle(_ center: CGPoint, _ radius: CGFloat) -> Path {
                Path(ellipseIn: CGRect(x: center.x - radius, y: center.y - radius,
                                       width: radius * 2, height: radius * 2))
            }

            // Solid left record, with the ring's footprint (plus the gap) knocked out.
            var disc = context
            disc.clip(to: circle(rightCenter, r + gap), options: .inverse)
            disc.fill(circle(leftCenter, r), with: .style(.foreground))
            var punch = context
            punch.clip(to: circle(rightCenter, r - stroke - gap))
            punch.fill(circle(leftCenter, r), with: .style(.foreground))

            // Open right record: a ring (outer circle minus its hole).
            var ring = circle(rightCenter, r)
            ring.addPath(circle(rightCenter, r - stroke))
            context.fill(ring, with: .style(.foreground), style: FillStyle(eoFill: true))
        }
        .accessibilityHidden(true)   // decorative — the Label's text names the tab
    }
}

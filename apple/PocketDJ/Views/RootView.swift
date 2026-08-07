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
    @Environment(SetlistPlayer.self) private var sequencer
    @Environment(MixEngine.self) private var mix
    @Environment(MixRecorder.self) private var mixRecorder
    @Environment(StudioStore.self) private var studio
    @Environment(StudioMicRecorder.self) private var studioMic
    @Environment(PlayHistoryStore.self) private var playHistory
    @Environment(CollectionActivityStore.self) private var collectionActivity
    @Environment(IntentServices.self) private var intents
    @Environment(CloudSyncService.self) private var cloudSync
    @Environment(OnboardingStore.self) private var onboarding
    @Environment(JukeboxStore.self) private var jukebox
    @Environment(PlaybackCoordinator.self) private var coordinator
    @Environment(DemuxStore.self) private var demux
    @Environment(MusicWithFriendsStore.self) private var friends
    @Environment(GameScoreboardStore.self) private var gameScores
    // System actions behind the leading "+" (open a New Window). supportsMultipleWindows is
    // false on iPhone (can't show two windows) and true on iPad/macOS/visionOS — it gates the
    // button so it self-hides exactly where ⌘N does (see NewWindowCommands in PocketDJApp).
    @Environment(\.openWindow) private var openWindow
    @Environment(\.supportsMultipleWindows) private var supportsMultipleWindows
    // Optional selection: the non-optional List(selection:) initializer is macOS-only.
    // Launch default: HISTORY on every platform (Levi 2026-07-22). macOS and visionOS land
    // on it directly (no resume — their `.task` never runs the iOS restore block below);
    // iOS/iPad restore a previously-persisted section in `.task` ("open to wherever you last
    // left off") and fall back to History when there's nothing to restore.
    #if os(macOS) || os(visionOS)
    @State private var section: Section? = .history
    #else
    @State private var section: Section?
    #endif
    @State private var path = NavigationPath()   // heterogeneous: albums + songs
    #if os(iOS)
    /// Now Playing collapsed to the thin bottom strip (Levi 2026-07-18). Persisted so the
    /// home screen comes back in the shape it was left in.
    @AppStorage("nowPlayingCollapsed") private var npCollapsed = false
    #endif

    enum Section: String, CaseIterable, Identifiable, Hashable {
        case browse = "Browser"
        case history = "History"
        case playlists = "Playlists"
        case mix = "Mix"
        // The Studio tab (samples/loops/sequencer/instruments/cues/demuxer). rawValue
        // triple-duties as settings.lastSection token + PDJ_START_SECTION seam + shadow-button
        // name — never rename it (spec §0's collision table pins the string). The USER-VISIBLE
        // name is `title` ("Producer" — renamed 2026-07; the token stays "Performance" forever).
        case performance = "Performance"
        case jukebox = "Jukebox Hero"
        case games = "Games"          // pinned token — never rename
        case settings = "Settings"
        var id: String { rawValue }
        /// User-visible sidebar/menu label. Diverges from `rawValue` only where a tab was
        /// renamed after its token was pinned (Performance → Producer).
        var title: String {
            switch self {
            case .performance: return "Producer"      // token stays "Performance"
            case .playlists:   return "Collections"    // token stays "Playlists" (2026-07 rename)
            default:           return rawValue
            }
        }
        var icon: String {
            switch self {
            case .browse:      return "magnifyingglass"
            case .history:     return "clock.arrow.circlepath"
            case .playlists:   return "music.note.list"
            case .mix:         return "slider.horizontal.3"
            case .performance: return "pianokeys"
            case .jukebox:     return "qrcode"
            case .games:       return "gamecontroller"
            case .settings:    return "gearshape"
            }
        }
    }

    /// The onboarding cover's presentation binding: driven by the store, never by the
    /// system (interactive dismissal is disabled; the set side is deliberately inert —
    /// only `OnboardingStore.complete()` takes the cover down).
    private var onboardingPresented: Binding<Bool> {
        Binding(get: { !onboarding.isComplete }, set: { _ in })
    }

    /// The home Now Playing element shows for collection playback (the app-scoped
    /// sequencer) in every mode EXCEPT Mix — a running/suspended Auto-DJ or live
    /// deck owns the audio, so the panel yields.
    private var nowPlayingVisible: Bool {
        NowPlayingPanel.isVisible(sequencer: sequencer, mix: mix)
    }

    /// The FULL panel is up (visible and not collapsed to the strip) — only then does the
    /// menu list yield its height.
    private var nowPlayingExpanded: Bool {
        #if os(iOS)
        return nowPlayingVisible && !npCollapsed
        #else
        return nowPlayingVisible
        #endif
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
                .frame(maxHeight: nowPlayingExpanded ? 236 : .infinity)
                if nowPlayingVisible {
                    Divider().overlay(Theme.border)
                    #if os(iOS)
                    if npCollapsed {
                        NowPlayingMiniBar { npCollapsed = false }
                    } else {
                        // Collapse chevron rides the panel's upper right (Levi): down to
                        // the thin strip; the strip's chevron-up brings the deck back.
                        NowPlayingPanel()
                            .overlay(alignment: .topTrailing) {
                                Button { npCollapsed = true } label: {
                                    Image(systemName: "chevron.down")
                                        .font(.footnote.weight(.semibold))
                                        .foregroundStyle(Theme.fgDim)
                                        .padding(8)
                                        .background(Theme.bgRaised.opacity(0.85), in: Circle())
                                }
                                .buttonStyle(.plain)
                                .padding(.top, 6).padding(.trailing, 10)
                                .accessibilityIdentifier("np-collapse")
                            }
                    }
                    #else
                    NowPlayingPanel()
                    #endif
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
                    .navigationDestination(for: Artist.self) { ArtistDetailView(artistName: $0.name, path: $path) }
                    .navigationDestination(for: Pocket.self) { PocketDetailView(pocketId: $0.id, path: $path) }
                    .navigationDestination(for: Playlist.self) { PlaylistDetailView(playlistId: $0.id, path: $path) }
                    .navigationDestination(for: SourcePlaylist.self) { IndexPlaylistDetailView(source: $0, path: $path) }
                    .navigationDestination(for: Setlist.self) { SetlistDetailView(setlistId: $0.id, path: $path) }
                    .navigationDestination(for: SetlistLaunch.self) { SetlistDetailView(setlistId: $0.setlistId, autoplay: $0.autoplay, path: $path) }
                    .navigationDestination(for: MixSessionsRoute.self) { _ in MixSessionsView() }
                    .navigationDestination(for: MixSessionRoute.self) { MixSessionDetailView(sessionId: $0.sessionId) }
                    .navigationDestination(for: JukeboxRoute.self) { _ in JukeboxView() }
                    .navigationDestination(for: JukeboxJoinRoute.self) { JukeboxJoinView(entry: $0.entry) }
                    .navigationDestination(for: CollectorsPuzzleRoute.self) { _ in CollectorsPuzzleView(path: $path) }
                    .navigationDestination(for: MwFSessionRoute.self) { MusicWithFriendsSessionView(sessionId: $0.sessionId, path: $path) }
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
        // Jukebox deep-link (shared Universal Link / pocketdj:// scheme / "Open in PocketDJ" banner):
        // onOpenURL adds the session then parks its id here; consume it to open the live join panel —
        // same atomic-take-across-windows discipline as the intent route above.
        .onChange(of: jukebox.pendingOpenId) { _, _ in consumeJukeboxOpen(jukebox.pendingOpenId) }
        // MwF deep-link / tapped push: same atomic-take discipline as the jukebox consume.
        .onChange(of: friends.pendingOpenId) { _, _ in consumeFriendsOpen(friends.pendingOpenId) }
        // ZERO-TO-HERO gate: a fresh install (or reinstall) walks the three-stage
        // onboarding before the app proper. fullScreenCover on iOS/visionOS; macOS has
        // no fullScreenCover, so a non-dismissable sheet. Every window of a multi-window
        // session shows the same store-driven cover (they stay in lockstep and all
        // dismiss on completion — accepted + documented in the design review).
        #if os(macOS)
        .sheet(isPresented: onboardingPresented) { OnboardingView().frame(minWidth: 600, minHeight: 640) }
        #else
        .fullScreenCover(isPresented: onboardingPresented) { OnboardingView() }
        #endif
        .task {
            // Store cross-wiring happens in PocketDJApp.init() (so background intent
            // launches are wired too); this task runs the launch ACTIONS.
            // FIRST: hold the ENTIRE launch pipeline until onboarding resolves (returns
            // immediately when it never shows). Everything below — cloud sync, session
            // restores, catalog load — must run with the user's choices (profile mode,
            // sources), and the stage-1 restore must land BEFORE any store file is
            // touched. Intent/CarPlay launches never run this task; they are vetoed at
            // the IntentServices seam instead.
            await onboarding.waitUntilComplete()
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
            demux.seedFixtureIfRequested()   // PDJ_SEED_DEMUX — the Demuxer UI-proof source
            studioMic.recoverOrphans()
            // History demo seed (PDJ_SEED_HISTORY) — populate the timeline for UI tests / demos.
            playHistory.seedDemoIfRequested()
            // Finish any download the user asked for whose rip landed while the app was closed.
            Task { await burns.drainPendingAfterRip() }
            // Collection-activity seed (PDJ_SEED_ACTIVITY) — the three row-resolution states.
            collectionActivity.seedFixtureIfRequested()
            // Games scoreboard seed (PDJ_SEED_GAMES) — deterministic best/recent rows.
            gameScores.seedFixtureIfRequested()
            // MUST precede the catalog load kicked off below: it can call
            // `settings.loadAppleMusic()`, and the load reads `settings.enabledSourceURLs` to
            // decide WHICH sources to fetch. Synchronous and env-only, so hoisting it here costs
            // nothing and removes the race. (Was after the CloudKit pass, which was fine only
            // because the catalog load used to be the very last thing in this task.)
            applyTestLaunchConfig()   // test seam: load sources / set search creds from env
            // Start the catalog load NOW rather than at the end of this task. It is what fills
            // `songsById` / `indexPlaylists`, i.e. the ONLY thing that lets a collection show a
            // real song count or a source playlist appear at all — and it was queued behind the
            // 8-second-deadline CloudKit pass below, so a cold launch on a slow network showed
            // collections reading "0 songs" for that whole window. It is awaited at its original
            // position below, so anything that relied on "the catalog is loaded by then" still
            // does; the two waits now just overlap instead of serializing.
            let catalogLoad = Task { await app.loadIfNeeded() }
            // iCloud session sync: pull any NEWER cloud session documents BEFORE the two
            // durable-session restores below read their files — a fresh device (a beta
            // tester's second install) restores the cloud session, not an empty one.
            // Deadline-bounded inside (8 s): a slow/absent network can never hang launch;
            // a late pull still lands for next launch. No-op when disabled / no account.
            await cloudSync.syncAtLaunch()
            // Durable playback session: rehydrate the Now Playing deck from the last run's
            // snapshot — HELD (never auto-plays; the first ▶ resumes at the saved position).
            // Self-contained (title/artist ride the snapshot), so it renders before the
            // catalog loads. Skips itself when playback is already active (an intent/widget
            // launch beat us here) and under PDJ_DISABLE_SESSION_RESTORE.
            sequencer.restorePersistedSessionIfIdle()
            // Durable MIX-DECK session (phase 2): read the snapshot and PARK it on the engine —
            // no audio, no graph build. The Mix tab MATERIALIZES it on first appearance
            // (`materializePendingRestoreIfNeeded` in MixView's `.task` — which on macOS may
            // already have run; the engine finishes the handoff either way). Both a setlist
            // session and a mix snapshot may restore held side by side — whichever the user
            // plays first becomes the audio owner through the normal arbiter paths.
            mix.restorePersistedMixIfIdle()
            Task { await rips.refreshManifest() }   // learn what's already ripped (public S3)
            // Testing seam: `PDJ_START_SECTION=Settings` lands on a section headlessly.
            // Accepts either the pinned token ("Performance") or the visible title ("Producer").
            if let raw = ProcessInfo.processInfo.environment["PDJ_START_SECTION"],
               let s = Section(rawValue: raw) ?? Section.allCases.first(where: { $0.title == raw }) {
                section = s
            } else {
                #if os(iOS)
                // Restore the last-visited section ("open to wherever you last left
                // off"). macOS/visionOS deliberately skip this — the @State init above
                // already lands them on History (they carry no resume).
                if let raw = settings.lastSection, let s = Section(rawValue: raw) {
                    section = s
                } else {
                    // Nothing valid to restore ⇒ History is the default landing tab on
                    // every platform (Levi 2026-07-22). iPhone previously rested on the
                    // HOME menu (nil) and iPad on Mix — both now open straight to History.
                    // (A last-visited section still wins above; "" — the home menu — has
                    // no matching Section, so it correctly falls through to this default.)
                    section = .history
                }
                #endif
            }
            await catalogLoad.value      // kicked off above, alongside the CloudKit pass
            // Testing seam: `PDJ_OPEN_FIRST_ALBUM=1` deep-links into an album so the
            // track table can be screenshotted headlessly. No-op in normal use.
            if ProcessInfo.processInfo.environment["PDJ_OPEN_FIRST_ALBUM"] != nil,
               let first = app.albums.first {
                path.append(first)
            }
            consumeIntentRoute(intents.pendingRoute)   // route parked by a cold intent launch
            consumeJukeboxOpen(jukebox.pendingOpenId)  // jukebox link tapped at cold launch
            consumeFriendsOpen(friends.pendingOpenId)  // MwF link/push tapped at cold launch
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
            .help("New Window — run another surface (Mix, Producer…) alongside this one")
            .accessibilityIdentifier("new-window")
    }

    /// Pan-African flag hues (the Ethiopian tricolor that most African flags share),
    /// laid LEFT→RIGHT — tints the Producer tab's piano keys (Levi 2026-07-22).
    static let panAfrican = LinearGradient(
        colors: [Color(red: 0.12, green: 0.71, blue: 0.23),   // green
                 Color(red: 0.99, green: 0.82, blue: 0.09),   // gold
                 Color(red: 0.89, green: 0.13, blue: 0.11)],  // red
        startPoint: .leading, endPoint: .trailing)

    /// Menu row: most sections use their SF Symbol, but a few wear custom marks — MIX
    /// (Apple Music's AutoMix records, here in platinum + gold), JUKEBOX HERO (the pride
    /// jukebox), PRODUCER (piano keys under the left→right Pan-African tricolor), and COLLECTIONS
    /// (a gem diamond). AutoMix + Jukebox aren't public SF Symbols, so both are tiny vectors.
    @ViewBuilder private func rowLabel(_ item: Section) -> some View {
        if item == .mix {
            Label { Text(item.title) } icon: {
                AutoMixIcon()
                    .frame(width: 25, height: 15)
            }
        } else if item == .jukebox {
            Label { Text(item.rawValue) } icon: {
                JukeboxIcon(mode: jukeboxIconMode)
                    .frame(width: 16, height: 20)
            }
        } else if item == .performance {
            // Piano keys tinted with the Pan-African flag hues, running LEFT→RIGHT.
            Label { Text(item.title) } icon: {
                Image(systemName: item.icon)
                    .foregroundStyle(Self.panAfrican)
            }
        } else if item == .playlists {
            // Collections wears a faceted brilliant-cut diamond (custom vector — the flat
            // SF Symbol read as a card suit; this one is a shiny 3-D gem like the 💎 emoji).
            Label { Text(item.title) } icon: {
                DiamondIcon()
                    .frame(width: 20, height: 18)
            }
        } else {
            Label(item.title, systemImage: item.icon)
        }
    }

    /// The jukebox mark's animation state. "Playing" is the NowPlayingPanel routing
    /// rule (whichever backend owns the audio), gated on a running set — the same
    /// music the jukebox's guests are hearing.
    private var jukeboxIconMode: JukeboxIconMode {
        let audible = sequencer.isRunning &&
            (coordinator.activeBackend == .appleMusic ? coordinator.isPlaying : player.isPlaying)
        return JukeboxIconMode.resolve(sessionActive: jukebox.session != nil, isPlaying: audible)
    }

    /// Consume a pending intent route on a FRESH stack (Spotlight/Siri asked for
    /// *this* destination — whatever was pushed before doesn't belong underneath it;
    /// mirrors the ⌘B Browser shortcut's reset).
    private func consumeIntentRoute(_ route: IntentRoute?) {
        guard let route else { return }
        intents.pendingRoute = nil
        path = NavigationPath()
        // Section lands NOW; the PUSH is staged onto a later runloop pass. Setting both
        // in one update drops the push whenever the stack re-roots underneath it — the
        // collapsed (iPhone) split view swapping detail columns, or a presenting sheet
        // (the platter's song-detail hotlinks) still mid-dismiss — leaving the user at
        // the section's home instead of the destination.
        var push: (() -> Void)?
        switch route {
        case .playlist(let id):
            section = .playlists
            if let pl = collections.playlist(id) { push = { path.append(pl) } }
        case .pocket(let id):
            section = .playlists
            if let p = collections.pocket(id) { push = { path.append(p) } }
        case .setlist(let id):
            section = .playlists
            if let s = collections.setlist(id) { push = { path.append(s) } }
        case .album(let id):
            section = .browse
            if let a = app.albumsById[id] { push = { path.append(a) } }
        case .artist(let name):
            section = .browse
            push = { path.append(Artist(name: name)) }
        case .sourcePlaylist(let id):
            section = .playlists
            if let sp = app.indexPlaylists.first(where: { $0.id == id }) { push = { path.append(sp) } }
        case .browseSearch:
            // The search term itself rides `pendingBrowseQuery`, consumed by BrowseView.
            section = .browse
        }
        if let push {
            Task { @MainActor in
                // Long enough for the sheet-dismiss/section-swap animations to settle
                // (sheet dismissal is ~400 ms on iOS — racing it re-drops the push).
                try? await Task.sleep(for: .milliseconds(450))
                push()
            }
        }
    }

    /// Consume a pending jukebox deep-link (shared link / "Open in PocketDJ" banner): switch to the
    /// Jukebox tab and PUSH the live join panel on a FRESH stack. Same discipline as
    /// `consumeIntentRoute` — clear the signal FIRST (atomic take; with several windows open only the
    /// first finds it non-nil), section lands now, and the push is staged a runloop later so a
    /// section-swap / sheet-dismiss mid-flight can't drop it.
    private func consumeJukeboxOpen(_ id: String?) {
        guard let id else { return }
        jukebox.pendingOpenId = nil
        guard let entry = jukebox.joinedSessions.first(where: { $0.id == id }) else { return }
        path = NavigationPath()
        section = .jukebox
        Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(450))
            path.append(JukeboxJoinRoute(entry: entry))
        }
    }

    /// Consume a pending Music with Friends open (tapped link / tapped push): land on the
    /// Games tab with the session screen pushed on a FRESH stack. Same atomic-take +
    /// staged-push discipline as `consumeJukeboxOpen`. An id with no local entry (a link
    /// for an unknown session) is left to the Join sheet (`friends.pendingJoin`).
    private func consumeFriendsOpen(_ id: String?) {
        guard let id else { return }
        friends.pendingOpenId = nil
        path = NavigationPath()
        section = .games
        guard friends.entry(id) != nil else { return }
        Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(450))
            path.append(MwFSessionRoute(sessionId: id))
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
            // ⌘P → Performance. The shadow LABELS keep their names — they are load-bearing
            // XCUITest queries — even though the Playlists tab is now titled "Collections".
            Button("Performance-shadow") { section = .performance }
                .keyboardShortcut("p", modifiers: .command)
            // ⌘C → the Collections tab (was ⇧⌘P). NOTE: ⌘C is the system Copy shortcut; this
            // registers it as a tab jump. Levi asked for the C-for-Collections mnemonic — if it
            // ever shadows Copy in a focused text field, ⌘L is the conflict-free alternative.
            Button("Playlists-shadow") { section = .playlists }
                .keyboardShortcut("c", modifiers: .command)
            // ⌘M → Mix. On macOS this INTENTIONALLY overrides the system "minimize" shortcut
            // (the user asked for it); the Mix tab exists on iPhone, iPad, AND Mac.
            Button("Mix-shadow") { section = .mix }
                .keyboardShortcut("m", modifiers: .command)
            // ⌘J → Jukebox Hero (free key — nothing else claims J in the collision table).
            Button("Jukebox-shadow") { section = .jukebox; path = NavigationPath() }
                .keyboardShortcut("j", modifiers: .command)
            // ⌘G → Games (unclaimed per the collision table).
            Button("Games-shadow") { section = .games; path = NavigationPath() }
                .keyboardShortcut("g", modifiers: .command)
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
        case .jukebox:     JukeboxView()
        case .games:       GamesView(path: $path)
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

/// A faceted **brilliant-cut diamond** — the Collections mark. Six flat facets shaded
/// light-from-top-left (bright near-white table → deep-blue pavilion point), crisp light
/// facet seams, and a white sparkle: a shiny 3-D gem in the spirit of the 💎 emoji (the flat
/// `diamond.fill` SF Symbol read as a playing-card suit, not a jewel).
struct DiamondIcon: View {
    var body: some View {
        Canvas { context, size in
            let w = size.width, h = size.height
            func pt(_ x: CGFloat, _ y: CGFloat) -> CGPoint { CGPoint(x: x * w, y: y * h) }

            // Vertices: a flat table on top, widest at the girdle (~⅓ down), a point at the bottom.
            let tL = pt(0.30, 0.04), tR = pt(0.70, 0.04)      // table corners
            let gL = pt(0.03, 0.37), gR = pt(0.97, 0.37)      // girdle (widest) corners
            let gML = pt(0.33, 0.37), gMR = pt(0.67, 0.37)    // girdle points under the table corners
            let tip = pt(0.50, 0.98)                           // culet (bottom point)

            func facet(_ pts: [CGPoint], _ color: Color) {
                var path = Path()
                path.move(to: pts[0])
                for p in pts.dropFirst() { path.addLine(to: p) }
                path.closeSubpath()
                context.fill(path, with: .color(color))
            }

            // Crown — the bright table plus two slanted side facets.
            facet([tL, tR, gMR, gML], Color(red: 0.83, green: 0.97, blue: 1.00))   // table (brightest)
            facet([tL, gML, gL],      Color(red: 0.55, green: 0.87, blue: 0.99))   // left crown
            facet([tR, gR, gMR],      Color(red: 0.36, green: 0.75, blue: 0.96))   // right crown
            // Pavilion — three triangles converging to the point, deepening toward it.
            facet([gL, gML, tip],  Color(red: 0.24, green: 0.62, blue: 0.92))      // left pavilion
            facet([gML, gMR, tip], Color(red: 0.13, green: 0.48, blue: 0.85))      // center pavilion
            facet([gMR, gR, tip],  Color(red: 0.07, green: 0.36, blue: 0.73))      // right pavilion

            // Crisp light facet seams (outline + girdle + the crown/pavilion edges).
            var edges = Path()
            edges.addLines([tL, tR, gR, tip, gL]); edges.closeSubpath()   // silhouette
            edges.move(to: gL);  edges.addLine(to: gR)                     // girdle
            edges.move(to: tL);  edges.addLine(to: gML); edges.addLine(to: tip)
            edges.move(to: tR);  edges.addLine(to: gMR); edges.addLine(to: tip)
            context.stroke(edges, with: .color(Color(red: 0.93, green: 0.99, blue: 1.0).opacity(0.75)),
                           lineWidth: max(0.6, w * 0.035))

            // A white 4-point sparkle on the table for the "shine."
            let s = w * 0.11
            let c = pt(0.43, 0.19)
            var star = Path()
            star.move(to:    CGPoint(x: c.x,             y: c.y - s))
            star.addLine(to: CGPoint(x: c.x + s * 0.3,   y: c.y - s * 0.3))
            star.addLine(to: CGPoint(x: c.x + s,         y: c.y))
            star.addLine(to: CGPoint(x: c.x + s * 0.3,   y: c.y + s * 0.3))
            star.addLine(to: CGPoint(x: c.x,             y: c.y + s))
            star.addLine(to: CGPoint(x: c.x - s * 0.3,   y: c.y + s * 0.3))
            star.addLine(to: CGPoint(x: c.x - s,         y: c.y))
            star.addLine(to: CGPoint(x: c.x - s * 0.3,   y: c.y - s * 0.3))
            star.closeSubpath()
            context.fill(star, with: .color(.white))
        }
        .accessibilityHidden(true)   // decorative — the Label's text names the tab
    }
}

/// Apple Music's AUTOMIX glyph, redrawn: two same-size overlapping records — the
/// left one a solid PLATINUM disc, the right one an open GOLD ring sitting ON TOP with a
/// small cut gap where it crosses the disc (matching Apple's mark). The two precious-metal
/// discs are fixed vertical gradients (Levi 2026-07-22), not the inherited foreground tint.
struct AutoMixIcon: View {
    var body: some View {
        Canvas { context, size in
            let h = size.height
            let r = h / 2                       // both records span the full height
            let stroke = h * 0.22               // the open record's ring thickness
            let gap = h * 0.10                  // cut gap where the ring crosses the disc
            let leftCenter = CGPoint(x: r, y: r)
            let rightCenter = CGPoint(x: size.width - r, y: r)

            // Brushed platinum (left disc) and warm gold (right ring), lit top→bottom.
            let platinum = GraphicsContext.Shading.linearGradient(
                Gradient(colors: [Color(red: 0.95, green: 0.95, blue: 0.97),
                                  Color(red: 0.60, green: 0.62, blue: 0.66)]),
                startPoint: CGPoint(x: 0, y: 0), endPoint: CGPoint(x: 0, y: size.height))
            let gold = GraphicsContext.Shading.linearGradient(
                Gradient(colors: [Color(red: 1.00, green: 0.87, blue: 0.45),
                                  Color(red: 0.78, green: 0.55, blue: 0.11)]),
                startPoint: CGPoint(x: 0, y: 0), endPoint: CGPoint(x: 0, y: size.height))

            func circle(_ center: CGPoint, _ radius: CGFloat) -> Path {
                Path(ellipseIn: CGRect(x: center.x - radius, y: center.y - radius,
                                       width: radius * 2, height: radius * 2))
            }

            // Solid left record (platinum), with the ring's footprint (plus the gap) knocked out.
            var disc = context
            disc.clip(to: circle(rightCenter, r + gap), options: .inverse)
            disc.fill(circle(leftCenter, r), with: platinum)
            var punch = context
            punch.clip(to: circle(rightCenter, r - stroke - gap))
            punch.fill(circle(leftCenter, r), with: platinum)

            // Open right record (gold): a ring (outer circle minus its hole).
            var ring = circle(rightCenter, r)
            ring.addPath(circle(rightCenter, r - stroke))
            context.fill(ring, with: gold, style: FillStyle(eoFill: true))
        }
        .accessibilityHidden(true)   // decorative — the Label's text names the tab
    }
}

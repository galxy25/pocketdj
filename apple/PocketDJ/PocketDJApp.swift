import SwiftUI
import AppIntents

/// PocketDJ — native SwiftUI app (iPhone · iPad · Mac).
///
/// A client-only reimplementation of the PocketDJ PWA. It talks to the SAME
/// backends as the web app:
///   • catalog + cover art  → CloudFront/S3 (see Config.catalogBase)
///   • on-demand rips + HLS  → iMac rip server over Tailscale (see Config.ripServerBase)
///   • durable rips          → public S3 rips bucket (see Config.ripsBase)
/// User collections (pockets / playlists / setlists) are the only client-side
/// state and live locally on-device.
@main
struct PocketDJApp: App {
    @State private var app: AppModel
    @State private var settings: SettingsStore
    @State private var edits: EditsStore
    @State private var collections: CollectionsStore
    @State private var rips: RipsStore
    /// Apple Music (Local) sync client (Settings ▸ "Sync Apple Music library"). Talks to the
    /// SAME rip server (URL + token from settings) to detect newly-added library tracks.
    @State private var musicSync: MusicSyncClient
    @State private var player: PlayerEngine
    @State private var streaming: StreamingStore
    /// App-side BURN queue (Feature 2): downloads ripped songs + sidecars into managed
    /// storage. Shares the SAME rips instance whose manifest/cachedURL drive its skip logic.
    @State private var burns: BurnStore
    /// The provider-cycling matching engine behind ▶: tries Apple Music streaming first for
    /// Apple Music (Local) songs (when ready), always falls back to the rip server. Built
    /// from the SAME rips/player/streaming instances so the rip path is unchanged.
    @State private var coordinator: PlaybackCoordinator
    /// APP-SCOPED Play-All sequencer (Feature 3) — owned here, NOT by SetlistDetailView, so a
    /// playing set keeps advancing after the user leaves the screen to build other collections.
    /// Only starting a different collection (a fresh `play`) stops it.
    @State private var setlistPlayer: SetlistPlayer
    /// Lazily resolves streaming cover art (Apple Music) for albums lacking a bundled
    /// cover, keyed off the indexer's catalog id — fetched ONLY when an album is on-screen.
    @State private var albumArt: AlbumArtworkStore
    /// On-demand lyrics: fetches `{catalogBase}/lyrics/<songId>.txt` when a song detail
    /// opens and caches the text on disk for instant + offline re-opens.
    @State private var lyrics: LyricsStore
    /// APP-SCOPED DJ mix engine (AVAudioEngine two-deck graph) — owned here, NOT by MixView, so a
    /// running mix keeps playing across tab switches (mirrors SetlistPlayer's app-scoping). Built
    /// from the SAME BurnStore so each deck loads ONLY locally-burned files (`localURLForPlayback`).
    /// Lazily builds its audio graph on first Mix-tab use (so launch never spins up audio).
    @State private var mix: MixEngine
    /// App-side recorder for mix SESSIONS (played tracks + the full time-stamped action log, kept
    /// until Reset). Wired as `mix.recorder` so every deck action is logged; persists its own JSON.
    @State private var mixSessions: MixSessionStore
    /// APP-SCOPED audio recorder — captures the live mix's house output into the current session's
    /// folder. Owned here (not by MixView) so a recording keeps running across Mix-tab switches, just
    /// like `mix`. Its `settings` (session-folder location) is pushed in from the Mix tab's `.task`.
    @State private var mixRecorder: MixRecorder
    /// The App Intents bridge (Siri/Shortcuts/Spotlight → live stores). Constructed +
    /// registered with `AppDependencyManager` in `init()` so an intent that background-
    /// launches the app (no scene) still finds fully-wired stores. Also injected into
    /// the environment so RootView can consume intent navigation (`pendingRoute`).
    @State private var intents: IntentServices
    @Environment(\.scenePhase) private var scenePhase

    // The App/Scene delegate receives background-URLSession launch events (iOS) + registers/
    // handles BGTasks (iOS); on macOS it only force-creates the background session. SwiftUI
    // instantiates the adaptor, so the delegate reaches the shared stores via
    // `TransferCoordinator.shared` (a process-wide singleton).
    #if os(iOS)
    @UIApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    #elseif os(macOS)
    @NSApplicationDelegateAdaptor(MacAppDelegate.self) private var appDelegate
    #endif

    init() {
        let app = AppModel()
        let settings = SettingsStore(defaults: SettingsStore.launchDefaults())
        let edits = EditsStore(fileURL: EditsStore.launchURL())
        let collections = CollectionsStore(fileURL: CollectionsStore.launchURL())
        let musicSync = MusicSyncClient()
        let rips = RipsStore()
        let player = PlayerEngine()
        // Lock-screen / Control Center Now Playing artwork: resolve the now-playing song id to its
        // album's cover-art candidate URLs from the loaded catalog. Whichever engine currently owns
        // the card (PlayerEngine for normal playback, MixEngine while a Mix deck is playing — see
        // NowPlayingArbiter) fetches the first candidate that decodes and attaches it to the card
        // (title/artist-only when the track has no art).
        let artworkURLsProvider: @MainActor (String) -> [URL] = { [weak app] songId in
            app?.album(forSongId: songId)?.artCandidates ?? []
        }
        player.artworkURLsProvider = artworkURLsProvider
        let streaming = StreamingStore()
        let amProvider = streaming.appleMusicProvider ?? AppleMusicProvider()
        // Inject the shared background-transfer coordinator so Burn hands each song to a
        // background download task that survives suspend (nil in tests ⇒ the in-process loop).
        // macOS is NOT suspended like iOS, and the background `URLSession` (nsurlsessiond) path
        // doesn't reliably deliver downloads on Mac (burns stuck at "Burning 1 of N"). So on macOS
        // use the in-process serial loop, which runs to completion in the foreground.
        #if os(macOS)
        let burns = BurnStore(rips: rips, transfers: nil, fileURL: BurnStore.launchURL())
        #else
        let burns = BurnStore(rips: rips, transfers: .shared, fileURL: BurnStore.launchURL())
        #endif
        let coordinator = PlaybackCoordinator(
            ripProvider: RipServerPlaybackProvider(rips: rips, player: player),
            appleMusic: AppleMusicPlaybackProvider(provider: amProvider))
        _app = State(initialValue: app)
        _settings = State(initialValue: settings)
        _edits = State(initialValue: edits)
        _collections = State(initialValue: collections)
        _musicSync = State(initialValue: musicSync)
        _rips = State(initialValue: rips)
        _player = State(initialValue: player)
        _streaming = State(initialValue: streaming)
        _burns = State(initialValue: burns)
        _coordinator = State(initialValue: coordinator)
        // App-scoped Play-All sequencer (survives navigation — see the property comment).
        let setlistPlayer = SetlistPlayer(player: player, rips: rips, burns: burns, coordinator: coordinator)
        _setlistPlayer = State(initialValue: setlistPlayer)
        // Lazy streaming cover art: resolve an album's art via the Apple Music provider
        // (recognize one of its tracks by catalog id → its artwork URL). Ready only when
        // the provider can resolve; both gated so the default build never hits the network.
        _albumArt = State(initialValue: AlbumArtworkStore(
            ready: { amProvider.canResolve },
            resolve: { song in await amProvider.resolve(song)?.artworkURL }))
        _lyrics = State(initialValue: LyricsStore())
        // App-scoped two-deck AVAudioEngine mix engine. Shares `burns` so a deck resolves the on-disk
        // burned file (+ holds its security scope) for the song it loads. Its `recorder` is the
        // app-side session store, wired here so every deck action is logged into the current session.
        let mixSessions = MixSessionStore(fileURL: MixSessionStore.launchURL())
        let mix = MixEngine(burns: burns)
        mix.recorder = mixSessions
        mix.artworkURLsProvider = artworkURLsProvider
        _mix = State(initialValue: mix)
        _mixSessions = State(initialValue: mixSessions)
        // App-scoped audio recorder: captures the mix's house output into the current session's
        // folder. Shares the app's `mix` (audio tap) + `mixSessions` (metadata); its session-folder
        // `settings` are pushed in from the Mix tab.
        _mixRecorder = State(initialValue: MixRecorder(engine: mix, sessions: mixSessions))

        // ── Store cross-wiring ─────────────────────────────────────────────────
        // Wired HERE (not in RootView.task) so an App Intent that background-launches
        // the app — Siri/Shortcuts with no scene — finds working stores. RootView.task
        // keeps only launch ACTIONS (manifest refresh, reconcile, catalog load).
        app.settings = settings   // the live multi-source config, read by loadIfNeeded()
        app.edits = edits         // overlay local metadata edits
        collections.app = app     // give realize()/playNow() the catalog to resolve ids
        // Feed the app-scoped sequencer the live device/cloud mode (read fresh per track).
        setlistPlayer.playbackMode = { [weak settings] in settings?.playbackMode ?? .cloud }
        rips.settings = settings       // rip server URL + token come from settings
        musicSync.settings = settings  // AM-sync uses the SAME rip server URL + token
        // Give the BURN sidecar builder the catalog to resolve IndexSong/IndexAlbum.
        burns.lookup = { [weak app] id in (app?.songsById[id], app?.songsById[id]?.albumId.flatMap { app?.albumsById[$0] }) }
        burns.settings = settings   // Feature 2: resolve the user-picked burnt-music folder
        // The matching engine orders providers by a song's ORIGIN SOURCE — give it the
        // catalog's per-id source map so an Apple Music (Local) track tries Apple Music
        // streaming first. (Captured by closure; AppModel is a long-lived @Observable.)
        coordinator.sourceOfSong = { [weak app] id in app?.source(ofSong: id) }
        #if os(iOS)
        // Let the BGAppRefreshTask reconcile the rips manifest while backgrounded (the rip
        // itself is server-side; this only catches up the client's "ripped" view).
        RipReconcileBridge.shared.refresh = { [weak rips] in await rips?.refreshManifest() }
        #endif

        // ── App Intents (Siri / Shortcuts / Spotlight) ─────────────────────────
        // One bridge instance carries the live stores to intents + entity queries.
        let intents = IntentServices(app: app, settings: settings, collections: collections,
                                     setlistPlayer: setlistPlayer, mix: mix, burns: burns, rips: rips)
        _intents = State(initialValue: intents)
        AppDependencyManager.shared.add(dependency: intents)
        // Donations: keep Spotlight's entity index + Siri's speakable playlist/pocket
        // vocabulary in sync with the collections, at launch and after every mutation.
        collections.onChange = { [weak collections] in
            guard let collections else { return }
            CollectionsSpotlight.scheduleReindex(collections)
            PocketDJShortcuts.updateAppShortcutParameters()
        }
        CollectionsSpotlight.scheduleReindex(collections)
        PocketDJShortcuts.updateAppShortcutParameters()
    }

    var body: some Scene {
        WindowGroup {
            RootView()
                .environment(app)
                .environment(settings)
                .environment(edits)
                .environment(collections)
                .environment(rips)
                .environment(musicSync)
                .environment(player)
                .environment(streaming)
                .environment(burns)
                .environment(coordinator)
                .environment(setlistPlayer)
                .environment(albumArt)
                .environment(lyrics)
                .environment(mix)
                .environment(mixSessions)
                .environment(mixRecorder)
                .environment(intents)
                .preferredColorScheme(.dark)
                .tint(Theme.accent)
                // A streaming provider's OAuth redirect (if any) comes back through
                // here; route it to the owning provider.
                .onOpenURL { streaming.handleCallback(url: $0) }
                .onChange(of: scenePhase) { _, phase in
                    switch phase {
                    case .active:
                        streaming.onScenePhaseActive()
                        // Resume the background transfer reconcile on foreground (idempotent).
                        TransferCoordinator.shared.reconcileOnLaunch()
                    case .background:
                        streaming.onScenePhaseBackground()
                        mixSessions.flush()    // persist the latest session state before suspension
                        // Submit/re-submit the BGTasks (burn-drain + rip-reconcile) so a
                        // backgrounded burn/rip keeps advancing/reconciling. iOS-only.
                        #if os(iOS)
                        AppDelegate.scheduleBackgroundTasks()
                        #endif
                    default: break
                    }
                }
        }
        #if os(macOS)
        .defaultSize(width: 1180, height: 800)
        .windowToolbarStyle(.unified)
        #endif
    }
}

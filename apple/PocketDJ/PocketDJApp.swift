import SwiftUI

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
    @State private var app = AppModel()
    @State private var settings = SettingsStore(defaults: SettingsStore.launchDefaults())
    @State private var edits = EditsStore(fileURL: EditsStore.launchURL())
    @State private var collections = CollectionsStore(fileURL: CollectionsStore.launchURL())
    @State private var rips: RipsStore
    /// Apple Music (Local) sync client (Settings ▸ "Sync Apple Music library"). Talks to the
    /// SAME rip server (URL + token from settings) to detect newly-added library tracks.
    @State private var musicSync = MusicSyncClient()
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
        let rips = RipsStore()
        let player = PlayerEngine()
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
        _rips = State(initialValue: rips)
        _player = State(initialValue: player)
        _streaming = State(initialValue: streaming)
        _burns = State(initialValue: burns)
        _coordinator = State(initialValue: coordinator)
        // App-scoped Play-All sequencer (survives navigation — see the property comment).
        _setlistPlayer = State(initialValue: SetlistPlayer(player: player, rips: rips, burns: burns, coordinator: coordinator))
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
        _mix = State(initialValue: mix)
        _mixSessions = State(initialValue: mixSessions)
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
                .preferredColorScheme(.dark)
                .tint(Theme.accent)
                // Streaming OAuth redirect (e.g. pocketdj://spotify-login-callback)
                // comes back through here; route it to the owning provider.
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

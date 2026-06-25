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
    @State private var player: PlayerEngine
    @State private var streaming: StreamingStore
    /// App-side BURN queue (Feature 2): downloads ripped songs + sidecars into managed
    /// storage. Shares the SAME rips instance whose manifest/cachedURL drive its skip logic.
    @State private var burns: BurnStore
    /// The provider-cycling matching engine behind ▶: tries Apple Music streaming first for
    /// Apple Music (Local) songs (when ready), always falls back to the rip server. Built
    /// from the SAME rips/player/streaming instances so the rip path is unchanged.
    @State private var coordinator: PlaybackCoordinator
    /// Lazily resolves streaming cover art (Apple Music) for albums lacking a bundled
    /// cover, keyed off the indexer's catalog id — fetched ONLY when an album is on-screen.
    @State private var albumArt: AlbumArtworkStore
    /// On-demand lyrics: fetches `{catalogBase}/lyrics/<songId>.txt` when a song detail
    /// opens and caches the text on disk for instant + offline re-opens.
    @State private var lyrics: LyricsStore
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
        _rips = State(initialValue: rips)
        _player = State(initialValue: player)
        _streaming = State(initialValue: streaming)
        // Inject the shared background-transfer coordinator so Burn hands each song to a
        // background download task that survives suspend (nil in tests ⇒ the in-process loop).
        _burns = State(initialValue: BurnStore(rips: rips, transfers: .shared, fileURL: BurnStore.launchURL()))
        _coordinator = State(initialValue: PlaybackCoordinator(
            ripProvider: RipServerPlaybackProvider(rips: rips, player: player),
            appleMusic: AppleMusicPlaybackProvider(provider: amProvider)))
        // Lazy streaming cover art: resolve an album's art via the Apple Music provider
        // (recognize one of its tracks by catalog id → its artwork URL). Ready only when
        // the provider can resolve; both gated so the default build never hits the network.
        _albumArt = State(initialValue: AlbumArtworkStore(
            ready: { amProvider.canResolve },
            resolve: { song in await amProvider.resolve(song)?.artworkURL }))
        _lyrics = State(initialValue: LyricsStore())
    }

    var body: some Scene {
        WindowGroup {
            RootView()
                .environment(app)
                .environment(settings)
                .environment(edits)
                .environment(collections)
                .environment(rips)
                .environment(player)
                .environment(streaming)
                .environment(burns)
                .environment(coordinator)
                .environment(albumArt)
                .environment(lyrics)
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

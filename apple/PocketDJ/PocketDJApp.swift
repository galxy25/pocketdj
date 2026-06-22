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
    @Environment(\.scenePhase) private var scenePhase

    init() {
        let rips = RipsStore()
        let player = PlayerEngine()
        let streaming = StreamingStore()
        let amProvider = streaming.appleMusicProvider ?? AppleMusicProvider()
        _rips = State(initialValue: rips)
        _player = State(initialValue: player)
        _streaming = State(initialValue: streaming)
        _burns = State(initialValue: BurnStore(rips: rips, fileURL: BurnStore.launchURL()))
        _coordinator = State(initialValue: PlaybackCoordinator(
            ripProvider: RipServerPlaybackProvider(rips: rips, player: player),
            appleMusic: AppleMusicPlaybackProvider(provider: amProvider)))
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
                .preferredColorScheme(.dark)
                .tint(Theme.accent)
                // Streaming OAuth redirect (e.g. pocketdj://spotify-login-callback)
                // comes back through here; route it to the owning provider.
                .onOpenURL { streaming.handleCallback(url: $0) }
                .onChange(of: scenePhase) { _, phase in
                    switch phase {
                    case .active: streaming.onScenePhaseActive()
                    case .background: streaming.onScenePhaseBackground()
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

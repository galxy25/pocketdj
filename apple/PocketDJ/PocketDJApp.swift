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
    /// Device-local play stats (count + last-played per song) — every playback surface
    /// funnels in; the storage manager's soft-cap prune orders by least-recently-played.
    @State private var playStats: PlayStatsStore
    @State private var playHistory: PlayHistoryStore
    /// The Settings ▸ Storage prune engine: when the user sets a soft cap, a once-a-day
    /// pass evicts least-recently-played burned media until the footprint fits. Cap unset
    /// (default) ⇒ never deletes anything on its own.
    @State private var storage: StorageManager
    /// The Studio (Performance tab) document store — samples, loops, sequencer patterns,
    /// instrument takes, and cue points, persisted as `pocketdj-studio.json`. App-scoped like
    /// every long-lived store so launch hooks (reconcile/orphan recovery in RootView's task)
    /// and background intent launches find it wired.
    @State private var studio: StudioStore
    /// APP-SCOPED Studio audition/sequencer engine (sample chain + loop audition + 16-step
    /// pattern playback) — owned here, NOT by the Performance tab's views, so audition keeps
    /// playing across tab switches (the MixEngine/SetlistPlayer ownership doctrine).
    @State private var studioEngine: StudioEngine
    /// APP-SCOPED mic recorder for Studio samples — its capture must survive navigating away
    /// from the tab mid-take, and its crash-orphan recovery runs from RootView's launch task
    /// (the MixRecorder lifecycle, input-side edition).
    @State private var studioMic: StudioMicRecorder
    /// APP-SCOPED virtual-instrument engine (sampler + MIDI + take recording). Owned here so
    /// a wired MIDI keyboard keeps sounding across tabs and an in-flight take can be filed by
    /// the exit bridge even when the Performance tab isn't mounted.
    @State private var instrumentEngine: InstrumentEngine
    /// Instrument sound-bank pack downloads (S3 manifest + file-based downloadTask). App-scoped
    /// so an in-flight 32 MB bank download survives tab switches.
    @State private var instrumentPacks: InstrumentPackStore
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
        // Debug capture persists across launches: a relaunch mid-repro starts a fresh session
        // immediately (the buffer is memory-only — see MixDiag / Settings ▸ Debug).
        if settings.debugLoggingEnabled { MixDiag.shared.start() }
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
        // folder. Shares the app's `mix` (audio tap) + `mixSessions` (metadata). Its session-folder
        // `settings` are wired HERE (not only from the Mix tab) so launch-time crash-orphan
        // recovery (RootView's task) can scan the user-picked folder too.
        let mixRecorder = MixRecorder(engine: mix, sessions: mixSessions)
        mixRecorder.settings = settings
        _mixRecorder = State(initialValue: mixRecorder)
        let playStats = PlayStatsStore(fileURL: PlayStatsStore.launchURL())
        _playStats = State(initialValue: playStats)
        // Append-only play TIMELINE (History mode) — distinct from the aggregate playStats above.
        let playHistory = PlayHistoryStore(fileURL: PlayHistoryStore.launchURL())
        _playHistory = State(initialValue: playHistory)
        let storage = StorageManager(burns: burns, playStats: playStats, settings: settings)
        _storage = State(initialValue: storage)
        // ── Studio (Performance tab) stores + engines ──────────────────────────
        // All app-scoped for the same two reasons as the Mix stack: audition/recording/
        // instrument state must survive tab switches, and cross-wiring happens HERE (not in a
        // view task) so background App-Intent launches and the exit bridge find working stores.
        let studio = StudioStore(fileURL: StudioStore.launchURL())
        let studioEngine = StudioEngine()
        let studioMic = StudioMicRecorder()
        let instrumentEngine = InstrumentEngine()
        let instrumentPacks = InstrumentPackStore()
        _studio = State(initialValue: studio)
        _studioEngine = State(initialValue: studioEngine)
        _studioMic = State(initialValue: studioMic)
        _instrumentEngine = State(initialValue: instrumentEngine)
        _instrumentPacks = State(initialValue: instrumentPacks)

        // ── Store cross-wiring ─────────────────────────────────────────────────
        // Wired HERE (not in RootView.task) so an App Intent that background-launches
        // the app — Siri/Shortcuts with no scene — finds working stores. RootView.task
        // keeps only launch ACTIONS (manifest refresh, reconcile, catalog load).
        app.settings = settings   // the live multi-source config, read by loadIfNeeded()
        app.edits = edits         // overlay local metadata edits
        collections.app = app     // give realize()/playNow() the catalog to resolve ids
        collections.performerName = settings.pocketDJName   // artist stamped on performance items
        // Feed the app-scoped sequencer the live device/cloud mode (read fresh per track).
        setlistPlayer.playbackMode = { [weak settings] in settings?.playbackMode ?? .cloud }
        // Let the sequencer snapshot each run's Play-History origin (source-kind + set name) at
        // play() time, resolved from the collections' now-playing source.
        setlistPlayer.historyContextProvider = { [weak collections] in
            collections?.historyContext(forSourceSetlistId: $0) ?? (.setlist, nil)
        }
        rips.settings = settings       // rip server URL + token come from settings
        musicSync.settings = settings  // AM-sync uses the SAME rip server URL + token
        // Give the BURN sidecar builder the catalog to resolve IndexSong/IndexAlbum.
        burns.lookup = { [weak app] id in (app?.songsById[id], app?.songsById[id]?.albumId.flatMap { app?.albumsById[$0] }) }
        burns.settings = settings   // Feature 2: resolve the user-picked burnt-music folder
        // The matching engine orders providers by a song's ORIGIN SOURCE — give it the
        // catalog's per-id source map so an Apple Music (Local) track tries Apple Music
        // streaming first. (Captured by closure; AppModel is a long-lived @Observable.)
        coordinator.sourceOfSong = { [weak app] id in app?.source(ofSong: id) }
        // Play-tracking hooks — every surface that starts a song notes it to BOTH the aggregate
        // playStats (for the storage prune) AND the append-only playHistory timeline (History
        // mode). Both stores share a 30 s re-count window that absorbs the burned-play overlap
        // between rips + coordinator (they both fire for one burned play).
        //
        // History needs the CONTEXT the collapsed songId-only seam drops, so it is resolved here:
        //   • rips/coordinator (non-Mix): a play is attributed to the RUNNING sequencer's set
        //     (source-kind + name via collections.historyContext) when the sequencer is on that
        //     exact song; otherwise it's a standalone Browser single.
        //   • mix: source is .mix; the name is the Auto-DJ source (autoSourceLabel) during an
        //     auto-mix, else the current manual mix session's name.
        let recordNonMixHistory: (String) -> Void = { [weak playHistory, weak setlistPlayer, weak app] songId in
            guard let playHistory else { return }
            let title = app?.songsById[songId]?.name
            let artist = app?.songsById[songId]?.artist
            let context: PlayHistoryStore.PlayContext
            // A member of the RUNNING queue is attributed to that set (tapping a member row to
            // jump ahead adopts it into the set); read the run's CAPTURED origin so a newer
            // playNow mid-navigation can't retag it. Anything else is a standalone Browser play.
            if let sp = setlistPlayer, sp.inRunningQueue(songId) {
                let origin = sp.capturedHistoryContext
                context = PlayHistoryStore.PlayContext(source: origin?.source ?? .setlist,
                                                       contextId: sp.sourceSetlistId,
                                                       contextName: origin?.name)
            } else {
                context = .browser
            }
            playHistory.record(songId: songId, title: title, artist: artist, context: context)
        }
        rips.onPlay = { [weak playStats] in playStats?.notePlayed($0); recordNonMixHistory($0) }
        coordinator.onPlay = { [weak playStats] in playStats?.notePlayed($0); recordNonMixHistory($0) }
        mix.onSongPlayed = { [weak playStats, weak playHistory, weak mix, weak mixSessions, weak app] songId in
            playStats?.notePlayed(songId)
            guard let playHistory else { return }
            let name = (mix?.autoMixing == true ? mix?.autoSourceLabel : nil) ?? mixSessions?.currentName
            let context = PlayHistoryStore.PlayContext(source: .mix, contextId: mixSessions?.currentId, contextName: name)
            playHistory.record(songId: songId, title: app?.songsById[songId]?.name,
                               artist: app?.songsById[songId]?.artist, context: context)
        }
        // The prune must never delete a file an engine holds OPEN: both Mix decks, the
        // inline/now-playing track, and the sequencer's current queue item are off-limits.
        storage.protectedSongIds = { [weak mix, weak rips, weak setlistPlayer] in
            var ids = Set<String>()
            if let m = mix {
                if let a = m.loaded(.a)?.songId { ids.insert(a) }
                if let b = m.loaded(.b)?.songId { ids.insert(b) }
            }
            if let np = rips?.nowPlaying?.songId { ids.insert(np) }
            if let sp = setlistPlayer, sp.isRunning, sp.index < sp.queue.count {
                ids.insert(sp.queue[sp.index].id)
            }
            return ids
        }
        #if os(iOS)
        // Let the BGAppRefreshTask reconcile the rips manifest while backgrounded (the rip
        // itself is server-side; this only catches up the client's "ripped" view).
        RipReconcileBridge.shared.refresh = { [weak rips] in await rips?.refreshManifest() }
        // Let the daily storage-prune BGTask reach the live prune engine (gate included).
        StoragePruneBridge.shared.prune = { [weak storage] in storage?.pruneIfDue() }
        #endif
        // ── Studio cross-wiring ────────────────────────────────────────────────
        // The store resolves per-family folder bookmarks through settings; the mic recorder
        // files finished/auto-stopped samples into the store and resolves the samples-folder
        // bookmark itself (the MixRecorder.settings pattern — pushed here, not from a view,
        // so launch-time orphan recovery can scan the user-picked folder too).
        studio.settings = settings
        studioMic.store = studio
        studioMic.settings = settings
        // Storage sweeps must never delete the file a recorder holds OPEN — and EITHER capture
        // engine can own the in-flight file (a mic sample take or an instrument take), so the
        // store's active-take guard asks both.
        studio.activeTakeFileName = { [weak studioMic, weak instrumentEngine] in
            studioMic?.activeTakeFileName ?? instrumentEngine?.activeTakeFileName
        }
        // Engine-ended instrument takes (engine outage / interruption / media reset / writer
        // death) are FILED, never dropped — the partial audio + events are data (the
        // MixRecorder auto-file doctrine). The view files clean stops itself; this callback
        // is exclusively the unattended path.
        instrumentEngine.onTakeAutoStopped = { [weak studio] result in
            studio?.addTake(StudioTake(autoFiled: result))
        }
        // Collections ↔ Studio seams (spec §8's per-consumer table): `studioLookup` feeds
        // counts/runtime/playNow snapshots + realize's synthetic entries (metadata only, no
        // disk touch); `studioResolve` is SetlistPlayer's playback branch (scope-held local
        // file). Camelot stays nil in v1 — loops inherit bpm from their grid, key inheritance
        // is a documented follow-up, and Harmonics drops nil axes safely.
        collections.studioLookup = { [weak studio] id in
            guard let info = studio?.displayInfo(forStudioId: id) else { return nil }
            return (title: info.title, lengthMs: info.lengthMs, bpm: info.bpm, camelot: nil)
        }
        setlistPlayer.studioResolve = { [weak studio] id in
            studio?.localURLForPlayback(id: id)
        }
        // Orderly exits (macOS Cmd-Q / iOS willTerminate) finalize + FILE an in-flight take —
        // without this every quit-mid-recording relied on next-launch orphan recovery. The flush
        // is what makes the filing DURABLE: addRecording persists via an async actor write that
        // loses the race with `.terminateNow`/exit().
        RecordingExitBridge.shared.finalize = { [weak mixRecorder, weak mixSessions,
                                                 weak studioMic, weak instrumentEngine, weak studio] in
            mixRecorder?.stop()
            mixSessions?.flush()
            // Studio's quit paths ride the same bridge: the mic recorder files + flushes its
            // own in-flight sample take; an in-flight INSTRUMENT take is stopped and filed
            // here (stopTake during the count-in is a cancel → nil, nothing to file), then the
            // studio document is flushed SYNCHRONOUSLY — addTake's normal save is the same
            // async actor write that loses the race with `.terminateNow`/exit().
            studioMic?.finalizeForExit()
            if let instrumentEngine, instrumentEngine.isRecordingTake {
                if let result = instrumentEngine.stopTake() {
                    studio?.addTake(StudioTake(autoFiled: result))
                }
                studio?.flush()
            }
        }
        // A stale-but-resolvable session-folder bookmark mints fresh data mid-resolve; persist it
        // back so it keeps resolving next launch (a stale bookmark eventually stops working —
        // which silently orphans every user-folder recording).
        SessionFolders.onStaleBookmark = { [weak settings] data in
            Task { @MainActor in
                settings?.sessionFolderBookmark = data
                settings?.persist()   // must land in UserDefaults NOW — no later persist() is
                                      // guaranteed to run before quit (macOS can sit on one section)
            }
        }
        // Same stale-bookmark re-mint doctrine, per Studio FAMILY: the fresh data must land in
        // the MATCHING settings field and hit UserDefaults immediately (an un-persisted re-mint
        // silently orphans every user-folder sample/loop/pattern on the next launch — the S6
        // lesson generalized).
        StudioFolders.onStaleBookmark = { [weak settings] family, data in
            Task { @MainActor in
                guard let settings else { return }
                switch family {
                case .samples: settings.samplesFolderBookmark = data
                case .loops: settings.loopsFolderBookmark = data
                case .sequences: settings.sequencesFolderBookmark = data
                case .takes: settings.takesFolderBookmark = data
                case .instruments: return   // always app-managed — no bookmark exists (spec §3)
                }
                settings.persist()
            }
        }

        // ── App Intents (Siri / Shortcuts / Spotlight) ─────────────────────────
        // One bridge instance carries the live stores to intents + entity queries.
        let intents = IntentServices(app: app, settings: settings, collections: collections,
                                     setlistPlayer: setlistPlayer, mix: mix, burns: burns, rips: rips)
        _intents = State(initialValue: intents)
        AppDependencyManager.shared.add(dependency: intents)
        // Donations: keep Spotlight's entity index + Siri's speakable playlist/pocket
        // vocabulary in sync with the collections, at launch and after every mutation.
        // Both run inside scheduleReindex — debounced (saves come in bursts) and gated
        // off under PDJ_USE_FIXTURE so test runs never pollute system state.
        collections.onChange = { [weak collections] in
            guard let collections else { return }
            CollectionsSpotlight.scheduleReindex(collections)
        }
        CollectionsSpotlight.scheduleReindex(collections)
        // The iOS/macOS 27 audio-schema layer (Siri AI natural language): only
        // compiled when built with the Xcode 27 SDK, only active on a 27 runtime.
        #if canImport(MediaIntents)
        if #available(iOS 27.0, macOS 27.0, *) {
            AudioSchemaBootstrap.install(services: intents)
        }
        #endif
    }

    var body: some Scene {
        // A value-less WindowGroup with an explicit id: `openWindow(id: "main")` opens a genuinely
        // NEW window on every call (multi-window ⌘N — see NewWindowCommands). Because every store is
        // @State on the App (created ONCE in init), all windows share the SAME engines/collections;
        // only RootView's per-window @State (selected tab + NavigationStack) is independent. The id
        // is required — without it openWindow(id:) has nothing to match and silently no-ops.
        WindowGroup(id: "main") {
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
                .environment(playStats)
                .environment(playHistory)
                .environment(storage)
                .environment(studio)
                .environment(studioEngine)
                .environment(studioMic)
                .environment(instrumentEngine)
                .environment(instrumentPacks)
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
                        // Foreground fallback for the daily soft-cap prune (macOS has no
                        // BGTaskScheduler; iOS BGTasks are best-effort). Gated inside; a
                        // plain Task defers it past the activation tick so foregrounding
                        // never waits on disk scans.
                        Task { storage.pruneIfDue() }
                    case .background:
                        streaming.onScenePhaseBackground()
                        mixSessions.flush()    // persist the latest session state before suspension
                        studio.flush()         // studio document too — same suspension-race doctrine
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
        // ⌘N → New Window. Lets the user run e.g. a Performance surface in one window and the Mix
        // surface in another without switching tabs. Applies on every platform, but the command
        // registers only where a second window can actually show (macOS + iPadOS; NOT iPhone).
        .commands { NewWindowCommands() }
    }
}

/// File ▸ New Window (⌘N). REPLACES the framework's automatic macOS "New Window" item so there is
/// exactly one ⌘N binding (appending instead would double-bind it on Mac), and ADDS the command to
/// iPadOS, which has no automatic New Window. Gated on `\.supportsMultipleWindows` — false on iPhone
/// (which can't display two windows) and true on iPad/Mac — so iPhone registers no ⌘N at all.
///
/// A Commands struct does NOT inherit the environment injected into the WindowGroup content, so this
/// reads ONLY system actions (`openWindow`, `supportsMultipleWindows`) and opens the window with no
/// payload — the shared app-scoped stores are reached by the new RootView through `.environment(...)`
/// exactly as the first window's is.
private struct NewWindowCommands: Commands {
    @Environment(\.openWindow) private var openWindow
    @Environment(\.supportsMultipleWindows) private var supportsMultipleWindows

    var body: some Commands {
        CommandGroup(replacing: .newItem) {
            if supportsMultipleWindows {
                Button("New Window") { openWindow(id: "main") }
                    .keyboardShortcut("n", modifiers: .command)
            }
        }
    }
}

/// Map an engine-ended instrument take to its filed record with the default "Take <date>" name
/// (the user renames later in the Instruments tab). One mapping shared by the auto-stop callback
/// AND the orderly-exit bridge so both unattended paths file byte-identical records.
private extension StudioTake {
    @MainActor init(autoFiled r: InstrumentEngine.TakeResult) {
        self.init(id: r.takeId,
                  name: "Take " + Date.now.formatted(date: .abbreviated, time: .shortened),
                  instrument: r.instrument, fileName: r.fileName, bpm: r.bpm,
                  events: r.events, durationMs: r.durationMs,
                  createdAt: Date().timeIntervalSince1970 * 1000)
    }
}

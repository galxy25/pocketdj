import SwiftUI
import AppIntents

/// PocketDJ — native SwiftUI app (iPhone · iPad · Mac).
///
/// A client-only reimplementation of the PocketDJ PWA. It talks to the SAME
/// backends as the web app:
///   • catalog + cover art  → CloudFront/S3 (see Config.catalogBase)
///   • on-demand rips + HLS  → a user-configured rip server (Settings ▸ Rip server; no default)
///   • durable rips          → public S3 rips bucket (see Config.ripsBase)
/// User collections (pockets / playlists / setlists) are the only client-side
/// state and live locally on-device.
@main
struct PocketDJApp: App {
    @State private var app: AppModel
    /// A collection file (.pdjcollection or a legacy .zip export) tapped in Files/iMessage,
    /// stashed until onboarding completes (the catalog must be loaded before import resolves
    /// members). Drained by the onboarding-complete onChange below.
    @State private var pendingOpenURL: URL?
    /// A jukebox deep-link tapped during onboarding — deferred (like `pendingOpenURL`) and joined
    /// once onboarding completes, so a first-run link never joins behind the onboarding modal.
    @State private var pendingJukeboxLink: JukeboxLink?

    /// Import a tapped collection file and route to the newly-created item, so the open visibly
    /// lands on it. Mirrors the manual pickers (security-scoped access + collections.importAny);
    /// the new item is found by diffing ids across the import (importAny returns Void).
    @MainActor private func importCollectionFile(_ url: URL) {
        let access = url.startAccessingSecurityScopedResource()
        defer { if access { url.stopAccessingSecurityScopedResource() } }
        let beforePlaylists = Set(collections.playlists.map(\.id))
        let beforePockets = Set(collections.pockets.map(\.id))
        try? collections.importAny(url: url)
        if let p = collections.playlists.first(where: { !beforePlaylists.contains($0.id) }) {
            intents.pendingRoute = .playlist(p.id)
        } else if let k = collections.pockets.first(where: { !beforePockets.contains($0.id) }) {
            intents.pendingRoute = .pocket(k.id)
        }
    }
    /// Kick a favorites sync pass — at launch (once the catalog is loaded), on foreground, and
    /// when onboarding completes. NEVER awaited by a caller: a pass can walk hundreds of ratings
    /// batches, and nothing on screen depends on it finishing.
    ///
    /// Two guards, both load-bearing. The CATALOG must be loaded, because the inbound pull maps
    /// Apple Music catalog ids onto song ids and an empty catalog silently pulls nothing.
    /// ONBOARDING must be resolved, for the same reason CloudSync's passes are held: a first-run
    /// profile that hasn't decided yet must not have a seed applied over it. Re-entry is free —
    /// `run()` single-flights on `isSyncing`, so a second window's trigger folds into the first.
    @MainActor private func syncFavoritesIfReady() {
        guard onboarding.isComplete, app.state == .loaded else { return }
        Task { await favoritesSync.run() }
    }

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
    /// F4 — the single-deck DSP engine the Now Playing mix mini-panel drives. App-scoped (like every
    /// engine) and wired into `SetlistPlayer` so the AVPlayer↔DSP hand-off is owned by the sequencer.
    @State private var nowPlayingDSP: NowPlayingDSP
    /// Durable playback session: the sequencer's real-time snapshot (queue + index + position)
    /// so a force-quit/restart rehydrates the Now Playing deck. Constructed here WITHOUT any
    /// disk read (the visionOS first-frame lesson) — the snapshot is read later, by
    /// `restorePersistedSessionIfIdle()` in RootView's launch task.
    @State private var playbackSession: PlaybackSessionStore
    /// Publishes the Now Playing state into the App Group so the widget extension can render it,
    /// and routes the widget's transport buttons back to real playback. Held app-scoped so its
    /// state observation lives for the app's lifetime.
    @State private var widgetSync: WidgetSync
    /// Lazily resolves streaming cover art (Apple Music) for albums lacking a bundled
    /// cover, keyed off the indexer's catalog id — fetched ONLY when an album is on-screen.
    @State private var albumArt: AlbumArtworkStore
    /// On-demand lyrics: fetches `{catalogBase}/lyrics/<songId>.txt` when a song detail
    /// opens and caches the text on disk for instant + offline re-opens.
    @State private var lyrics: LyricsStore
    /// The Producer tab's Demuxer documents (on-device transcript + chord timeline per audio
    /// source), persisted under `demux-cache/` — app-scoped so an analysis keeps running
    /// across tab switches.
    @State private var demux: DemuxStore
    /// APP-SCOPED DJ mix engine (AVAudioEngine two-deck graph) — owned here, NOT by MixView, so a
    /// running mix keeps playing across tab switches (mirrors SetlistPlayer's app-scoping). Built
    /// from the SAME BurnStore so each deck loads ONLY locally-burned files (`localURLForPlayback`).
    /// Lazily builds its audio graph on first Mix-tab use (so launch never spins up audio).
    @State private var mix: MixEngine
    /// App-side recorder for mix SESSIONS (played tracks + the full time-stamped action log, kept
    /// until Reset). Wired as `mix.recorder` so every deck action is logged; persists its own JSON.
    @State private var mixSessions: MixSessionStore
    /// Durable mix-deck session (phase 2 of durable playback sessions): the Mix engine's
    /// real-time snapshot (decks + mixer + Auto-DJ queue) so a force-quit/restart rehydrates
    /// the Mix tab held. Constructed WITHOUT any disk read (the visionOS first-frame lesson) —
    /// the snapshot is read later, by `restorePersistedMixIfIdle()` in RootView's launch task.
    @State private var mixDeckSession: MixDeckSessionStore
    /// APP-SCOPED audio recorder — captures the live mix's house output into the current session's
    /// folder. Owned here (not by MixView) so a recording keeps running across Mix-tab switches, just
    /// like `mix`. Its `settings` (session-folder location) is pushed in from the Mix tab's `.task`.
    @State private var mixRecorder: MixRecorder
    /// Device-local play stats (count + last-played per song) — every playback surface
    /// funnels in; the storage manager's soft-cap prune orders by least-recently-played.
    @State private var playStats: PlayStatsStore
    @State private var playHistory: PlayHistoryStore
    /// Device-local, append-only COLLECTION ACTIVITY log (F11) — add/heart/unheart/remove events
    /// behind the History view's Activity segment. Its own synced JSON, distinct from the play log.
    @State private var collectionActivity: CollectionActivityStore
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
    /// APP-SCOPED Jukebox Hero session engine — while a jukebox is live it publishes
    /// player-state snapshots (via the jukebox server → S3, for the guests' pages) and
    /// polls guest song requests into the host's inbox. App-scoped so the party survives
    /// navigation; its session persists so it survives relaunches too.
    @State private var jukebox: JukeboxStore
    /// The App Intents bridge (Siri/Shortcuts/Spotlight → live stores). Constructed +
    /// registered with `AppDependencyManager` in `init()` so an intent that background-
    /// launches the app (no scene) still finds fully-wired stores. Also injected into
    /// the environment so RootView can consume intent navigation (`pendingRoute`).
    @State private var intents: IntentServices
    /// Per-profile song favorites (the ♥ on every song surface + the Browse favorite filter).
    /// Synced through CloudSyncService like every other session document — i.e. the signed-in
    /// Apple ID's PRIVATE CloudKit DB, so a tester's ♥ never reach anyone else.
    @State private var favorites: FavoritesStore
    /// The OWNER-ONLY bridge from those favorites to Apple Music (push ♥ / pull loves), and
    /// the tester-seed downloader for everyone else. See `OwnerIdentity` for the gate.
    @State private var favoritesSync: FavoritesSyncService
    /// Durable outbound queue for "added a song to an Apple Music source playlist" — the
    /// write-back half of source-playlist adds (see PlaylistWriteBack).
    @State private var playlistWriteBack: PlaylistWriteBack
    /// Provisional Discover-add catalog entries (eventual consistency) — see DiscoverAddsStore.
    @State private var discoverAdds: DiscoverAddsStore
    /// Provisional IMPORTED catalog entries (cross-user playlist/pocket transfers) — see
    /// ImportedSongsStore.
    @State private var importedSongs: ImportedSongsStore
    @State private var profileSource: ProfileSourceStore
    /// The user's synced identity (PocketDJ name + durable id) — see ProfileStore.
    @State private var profile: ProfileStore
    /// iCloud (CloudKit private DB) sync of profile + session-data documents. RootView's
    /// launch task awaits its launch pass BEFORE the durable-session restores so a fresh
    /// device restores cloud session files, not empty ones.
    @State private var cloudSync: CloudSyncService
    /// The zero-to-hero first-run flow's state machine (fresh install / reinstall).
    /// RootView presents its cover and awaits it before ANY launch action; CloudSync
    /// pushes and mutating intents are refused until it completes.
    @State private var onboarding: OnboardingStore
    /// Account-deletion orchestrator (App Store Guideline 5.1.1(v)) — stops live activity,
    /// deletes the private-CloudKit copies, wipes every local store + media + Keychain token,
    /// resets settings (re-arming onboarding), and mints a fresh identity. Injected into the
    /// environment for Settings ▸ Profile's "Delete Account" row. See AccountDeletionService.
    @State private var accountDeletion: AccountDeletionService
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
        // ONE UserDefaults instance shared by settings + onboarding: launchDefaults()
        // re-wipes the fixture suite on EVERY call, so a second call would erase
        // whatever the first store persisted between the two constructions.
        let sharedDefaults = SettingsStore.launchDefaults()
        let settings = SettingsStore(defaults: sharedDefaults)
        // ── Zero-to-hero onboarding (first install / reinstall) ── decided ONCE,
        // HERE, before any store can persist: the decision reads the settings blob's
        // pre-construction presence (existing users updating in never see the flow).
        let onboarding = OnboardingStore(defaults: sharedDefaults,
                                         hadPersistedSettings: settings.hadPersistedSettings)
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
        // Now Playing trace → the same Settings ▸ Debug capture buffer (os_log is unconditional;
        // this mirror only adds the lines to the exportable session while capture is on).
        NPLog.mirror = { MixDiag.shared.append($0) }
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
        // F4 Now Playing mix mini-panel: a single-deck DSP engine sharing the SAME BurnStore (it
        // resolves the on-disk burned file + stems for the CURRENT track). The sequencer owns the
        // AVPlayer↔DSP hand-off, so wire it in here (app-scoped, like every other engine).
        let nowPlayingDSP = NowPlayingDSP(burns: burns)
        setlistPlayer.dsp = nowPlayingDSP
        _nowPlayingDSP = State(initialValue: nowPlayingDSP)
        // Durable playback session — the sequencer writes every structural change + a throttled
        // position refresh into it, so the deck survives force-quit/restart. No disk I/O here.
        let playbackSession = PlaybackSessionStore(fileURL: PlaybackSessionStore.launchURL())
        setlistPlayer.sessionStore = playbackSession
        _playbackSession = State(initialValue: playbackSession)
        // Lazy streaming cover art: resolve an album's art via the Apple Music provider
        // (recognize one of its tracks by catalog id → its artwork URL). Ready only when
        // the provider can resolve; both gated so the default build never hits the network.
        _albumArt = State(initialValue: AlbumArtworkStore(
            ready: { amProvider.canResolve },
            resolve: { song in await amProvider.resolve(song)?.artworkURL }))
        _lyrics = State(initialValue: LyricsStore())
        _demux = State(initialValue: DemuxStore())
        // App-scoped two-deck AVAudioEngine mix engine. Shares `burns` so a deck resolves the on-disk
        // burned file (+ holds its security scope) for the song it loads. Its `recorder` is the
        // app-side session store, wired here so every deck action is logged into the current session.
        let mixSessions = MixSessionStore(fileURL: MixSessionStore.launchURL())
        let mix = MixEngine(burns: burns)
        mix.recorder = mixSessions
        mix.artworkURLsProvider = artworkURLsProvider
        // F4: a Mix-tab session (deck / Auto-DJ) starting must tear down a live Now Playing mix
        // engagement — the panel hides then, so the DSP would otherwise keep rendering a hidden second
        // audio source. Setting this seam arms the sequencer's observation of `isRunning`/`autoMixing`.
        setlistPlayer.mixSessionActive = { [weak mix] in
            guard let mix else { return false }
            return mix.isRunning || mix.autoMixing
        }
        _mix = State(initialValue: mix)
        _mixSessions = State(initialValue: mixSessions)
        // Durable mix-deck session — the engine writes every structural deck / auto-queue change
        // + throttled playheads into it, so the Mix tab survives force-quit/restart. No disk I/O
        // here; RootView's launch task reads the snapshot (`restorePersistedMixIfIdle`).
        let mixDeckSession = MixDeckSessionStore(fileURL: MixDeckSessionStore.launchURL())
        mix.sessionStore = mixDeckSession
        _mixDeckSession = State(initialValue: mixDeckSession)
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
        let collectionActivity = CollectionActivityStore(fileURL: CollectionActivityStore.launchURL())
        _collectionActivity = State(initialValue: collectionActivity)
        // ADD / REMOVE activity: the collections store fires `onActivity` from its user-facing
        // add/remove choke points (never from source-sync reconcile). Record synchronously here.
        collections.onActivity = { [weak collectionActivity] hook in
            collectionActivity?.record(kind: hook.kind == .add ? .add : .remove,
                                       itemId: hook.itemId, itemTitle: hook.itemTitle,
                                       collectionId: hook.collectionId, collectionKind: hook.collectionKind,
                                       collectionName: hook.collectionName)
        }
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
        // Converted-collection source sync: every catalog assign (cache seed + refresh)
        // reconciles source-converted pockets + source-duplicated playlists with their
        // source playlists, gated by the global Settings toggle (per-item opt-outs live
        // on the items themselves).
        app.onCatalogAssigned = { [weak app, weak collections, weak settings] in
            guard let app, let collections, settings?.syncConvertedPockets == true else { return }
            collections.syncConvertedCollections(with: app.indexPlaylists)
        }
        // Feed the app-scoped sequencer the live device/cloud mode (read fresh per track).
        setlistPlayer.playbackMode = { [weak settings] in settings?.playbackMode ?? .cloud }
        // Let the sequencer snapshot each run's Play-History origin (source-kind + set name) at
        // play() time, resolved from the collections' now-playing source.
        setlistPlayer.historyContextProvider = { [weak collections] in
            collections?.historyContext(forSourceSetlistId: $0) ?? (.setlist, nil)
        }
        // …and the NAVIGABLE origin (kind + collection id) — the Up Next header's
        // collection button target, captured per run + persisted in the durable session.
        setlistPlayer.originProvider = { [weak collections] in
            collections?.originCollection(forSourceSetlistId: $0)
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
            // The detected key (Camelot) rides the lookup so a performance item snapshots with its
            // harmonic data — realize's Harmonics + Mix-glide can then see it.
            return (title: info.title, lengthMs: info.lengthMs, bpm: info.bpm,
                    camelot: studio?.camelot(forStudioId: id))
        }
        // Mix decks resolve performance items (audio + beat grid + detected key) through the same
        // studio store — so a sample/loop/sequence/instrumental in a pocket loads onto a deck with
        // its pulse/beat-sync grid + harmonic key.
        mix.studioResolve = { [weak studio] id in studio?.localURLForPlayback(id: id) }
        mix.studioMixInfo = { [weak studio] id in studio?.mixInfo(forStudioId: id) }
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

        // ── Jukebox Hero ───────────────────────────────────────────────────────
        // The session engine reads/edits the SAME app-scoped sequencer the Now Playing
        // panel drives; its matcher searches the Apple Music catalog through the SAME
        // provider instance streaming uses (guarded — silent empty results when the
        // account isn't linked). Seams wired BEFORE resumePersistedSession so a jukebox
        // that survived a relaunch comes back fully functional.
        let jukebox = JukeboxStore(app: app, sequencer: setlistPlayer, player: player,
                                   coordinator: coordinator, rips: rips,
                                   mix: mix, burns: burns)
        jukebox.settings = settings
        jukebox.searchAppleMusic = { [weak amProvider] term in
            guard let amProvider, amProvider.canSearch else { return [] }
            return (try? await amProvider.search(term, limit: 5)) ?? []
        }
        jukebox.resumePersistedSession()
        _jukebox = State(initialValue: jukebox)

        // ── Favorites (♥) + owner-only Apple Music two-way sync ───────────────
        // The store is gate-agnostic: it records intent and fires `onChanged`. The sync
        // service resolves `OwnerIdentity` once per launch and decides whether that intent
        // ever leaves the device — a non-owner's ♥ stay in their own profile, full stop.
        let favorites = FavoritesStore(fileURL: FavoritesStore.launchURL())
        // MusicDataRequest carries no macOS-unavailable annotation (unlike MusicLibrary's
        // writes), so the SAME transport serves every platform that can import MusicKit.
        // Availability is satisfied by the deployment targets (iOS 18 / macOS 15 / visionOS 2).
        #if canImport(MusicKit)
        let favoritesTransport: (any AppleMusicFavoritesTransport)? = MusicKitFavoritesTransport()
        #else
        let favoritesTransport: (any AppleMusicFavoritesTransport)? = nil
        #endif
        let favoritesSync = FavoritesSyncService(favorites: favorites, transport: favoritesTransport)
        // The catalog seams (kept out of the service so it stays free of the data layer):
        // the id space the inbound pull asks about, and the reverse resolution of a loved
        // catalog id back to a PocketDJ song id.
        favoritesSync.catalogAppleMusicIds = { [weak app] in app?.appleMusicCatalogPairs() ?? [] }
        favoritesSync.songIdForAppleMusicId = { [weak app] id in app?.songId(forAppleMusicId: id) }
        // A ♥ tap reaches Apple Music NOW rather than at the next pass. `onChanged` fires only
        // for user-originated changes (never a cloud pull or the seed), and `pushNow` is a
        // silent no-op for a non-owner or a song with no Apple Music identity — so this is
        // safe to wire unconditionally on every install.
        favorites.onChanged = { [weak favoritesSync, weak collectionActivity, weak app] entry in
            // HEART activity (F11): `onChanged` fires ONLY for user-originated toggles (never a
            // cloud pull / seed), so this is the exact user-only choke point. Synchronous record on
            // the main actor — NOT inside the AM-push Task — using `entry.favorited` to pick heart
            // vs unheart. A CarPlay ♥ routes through here too (no separate CarPlay add surface).
            collectionActivity?.record(kind: entry.favorited ? .heart : .unheart,
                                       itemId: entry.songId,
                                       itemTitle: app?.songsById[entry.songId]?.name)
            Task { await favoritesSync?.pushNow(entry) }
        }
        // Lock-screen ♥ (F10): the engine owns the system Now Playing card + the shared remote
        // command center, so it drives `MPRemoteCommandCenter.likeCommand`. These two closures are
        // the ONLY favorites/catalog knowledge it gets — the current track's id comes from the
        // engine's own `nowPlayingSongId`, its catalog id from `songsById` (nil ⇒ still favorited
        // local-only). Same injection pattern as `artworkURLsProvider` above.
        player.toggleCurrentFavorite = { [weak player, weak favorites, weak app] in
            guard let player, let favorites, let songId = player.nowPlayingSongId else { return }
            favorites.toggle(songId, appleMusicId: app?.songsById[songId]?.appleMusicId)
        }
        player.isCurrentFavorite = { [weak player, weak favorites] in
            guard let player, let favorites, let songId = player.nowPlayingSongId else { return false }
            return favorites.isFavorite(songId)
        }
        _favorites = State(initialValue: favorites)
        _favoritesSync = State(initialValue: favoritesSync)

        // Bridge the Now Playing state to the widget extension (App Group snapshot + cover) and
        // wire the widget's ⏮/⏯/⏭/♥ buttons back to the sequencer + player + favorites. Uses the
        // SAME art resolver as the lock-screen card. Constructed AFTER `favorites` (which the ♥
        // needs) so it publishes with the favorite state from first launch.
        _widgetSync = State(initialValue: WidgetSync(
            setlist: setlistPlayer, player: player, rips: rips, coordinator: coordinator,
            artCandidates: { [weak app] in app?.album(forSongId: $0)?.artCandidates ?? [] },
            favorites: favorites,
            appleMusicId: { [weak app] in app?.songsById[$0]?.appleMusicId }))

        // ── Apple Music playlist write-back ────────────────────────────────────
        // Adding a song to a SOURCE (Apple Music) playlist writes locally and queues the
        // upstream half here. Device-local by design: it is an outbound intent log, NOT a
        // synced document — syncing it would make a second device replay a delivered write
        // and duplicate the track in the real Apple Music playlist.
        let playlistWriteBack = PlaylistWriteBack(fileURL: PlaylistWriteBack.launchURL(),
                                                  transport: PlaylistWriteBack.makeDefaultTransport())
        // Catalog seam for the playlist JOIN: when the live library has several playlists by
        // the same name, these store ids are what tells them apart. Kept out of the queue so
        // it stays free of the data layer (the FavoritesSyncService idiom above).
        playlistWriteBack.appleMusicIdsForIndexPlaylist = { [weak app] indexPlaylistId in
            guard let app,
                  let source = app.indexPlaylists.first(where: { $0.id == indexPlaylistId })
            else { return [] }
            return source.songIds.compactMap { app.songsById[$0]?.appleMusicId }
        }
        _playlistWriteBack = State(initialValue: playlistWriteBack)
        // Two-way source sync (Levi 2026-07-22): a song added to a CONVERTED pocket or a
        // DUPLICATED playlist — not just via the Add sheet's "From your sources" row — writes
        // back to the real Apple Music library playlist it came from. Unconditional like the
        // source-row path (append-only + non-destructive), gated only on `canWriteBack`, so
        // macOS / not-yet-authorized just keeps the local add and never queues a dead job.
        collections.enqueueSourceWriteBack = { [weak playlistWriteBack] indexPlaylistId, playlistName, songId, appleMusicId, title, artist, album, durationMs in
            guard let wb = playlistWriteBack, wb.canWriteBack else { return false }
            let job = wb.enqueue(indexPlaylistId: indexPlaylistId, playlistName: playlistName,
                                 songId: songId, appleMusicId: appleMusicId,
                                 title: title, artist: artist, album: album, durationMs: durationMs)
            wb.runSoon()
            return job != nil
        }
        // Re-linking a pocket to a different source cancels the OLD source's still-undelivered
        // write-backs for that pocket's songs (so an offline add can't land in the wrong playlist).
        collections.cancelPendingWriteBacks = { [weak playlistWriteBack] indexPlaylistId, songIds in
            playlistWriteBack?.cancelPending(indexPlaylistId: indexPlaylistId, songIds: songIds)
        }

        // ── Discover adds: provisional catalog entries (eventual consistency) ──
        // "＋ Add" makes the song a catalog citizen NOW; the nightly indexer's real
        // entry supersedes it later (AppModel.withDiscoverAdds → collections remap).
        let discoverAdds = DiscoverAddsStore(fileURL: DiscoverAddsStore.launchURL())
        discoverAdds.onAdded = { [weak app] song in app?.injectDiscoverAdd(song) }
        discoverAdds.onAlbumAdded = { [weak app] album in app?.injectDiscoverAlbumAdd(album) }
        // Batched album add: one rebuild for the whole fan-out (not one per track).
        discoverAdds.onAlbumBatchAdded = { [weak app] songs, album in
            app?.injectDiscoverAlbumBatch(songs: songs, album: album)
        }
        app.discoverAdds = discoverAdds
        // A superseded provisional id must be rewritten EVERYWHERE it is referenced — the
        // collections AND the favorites — or a ♥ made on a Discover add silently detaches
        // when the nightly indexer lands the real track under its permanent id.
        app.onDiscoverSupersede = { [weak collections, weak favorites] pairs in
            collections?.remapSongIds(pairs)
            favorites?.remapSongIds(pairs)
        }
        rips.discoverAdds = discoverAdds
        _discoverAdds = State(initialValue: discoverAdds)

        // ── Imported songs: provisional entries for cross-user transfers ───────
        // A portable playlist/pocket import whose songs live outside this device's
        // enabled sources materializes them as the "Imported" synthetic source — the
        // global rips manifest streams/burns/stems them by id (acceptance test A).
        let importedSongs = ImportedSongsStore(fileURL: ImportedSongsStore.launchURL())
        importedSongs.onAdded = { [weak app] songs, albums in
            app?.injectImported(songs: songs, albums: albums)
        }
        app.importedSongs = importedSongs
        collections.importedSongs = importedSongs
        _importedSongs = State(initialValue: importedSongs)

        // ── User profile + iCloud session sync ─────────────────────────────────
        // The profile is the SYNCED identity (ProfileStore's NAME OWNERSHIP doctrine);
        // the sync service mirrors the session-data documents through the user's private
        // CloudKit DB so a beta tester's data follows their Apple ID across devices.
        let profile = ProfileStore(fileURL: ProfileStore.launchURL())
        profile.migrateIfNeeded(settingsName: settings.pocketDJName)
        // The per-profile "Pocket DJ" custom-audio source. Display name = the profile name (seeded
        // BEFORE onNameChanged is wired, so the seed never fires a spurious launch reload); `onAdded`
        // feeds saved/pulled items to the live catalog; a rename re-tags via a rebuild (onNameChanged).
        let profileSource = ProfileSourceStore(fileURL: ProfileSourceStore.launchURL())
        profileSource.profileName = profile.name.isEmpty ? ProfileSourceStore.defaultName : profile.name
        profileSource.onAdded = { [weak app] songs, albums in app?.injectProfileItem(songs: songs, albums: albums) }
        profileSource.onNameChanged = { [weak app] in Task { await app?.reload() } }
        app.profileSource = profileSource
        _profileSource = State(initialValue: profileSource)
        // Stage 3 — the profileResolve playback seams: a `pdj_` item plays from its device-local
        // original in BOTH Now Playing (setlistPlayer) and the Mix decks (mix). `mix`/`setlistPlayer`
        // locals are already in scope; profileSource just entered scope above.
        mix.profileResolve = { [weak profileSource] id in profileSource?.localURLForPlayback(id: id) }
        setlistPlayer.profileResolve = { [weak profileSource] id in profileSource?.localURLForPlayback(id: id) }
        // Stage 7 — a profile item's stems drive the same per-stem DSP as burned stems (Now Playing + Mix).
        mix.profileStemResolve = { [weak profileSource] id in profileSource?.stemURLs(id: id) }
        nowPlayingDSP.profileStemResolve = { [weak profileSource] id in profileSource?.stemURLs(id: id) }
        // Stage 5 — auto-file every NEW sampler sample as a "Pocket DJ Samples" profile item (copies
        // its durable audio into the profile store; new-only, no backfill of existing samples). The
        // original's security scope is held across the off-main copy.
        studio.onSampleAdded = { [weak profileSource, weak studio] sample in
            guard let profileSource, let studio,
                  let h = studio.localURLForPlayback(id: sample.id) else { return }
            let dur = sample.effectiveDurationMs
            let bpm = sample.grid?.bpm
            Task {
                _ = await profileSource.ingest(kind: .sample, title: sample.name, originalURL: h.url,
                                               durationMs: dur > 0 ? dur : nil, stems: nil,
                                               bpm: bpm, key: nil, camelot: nil)
                h.release?()
            }
        }
        profile.onNameApplied = { [weak settings, weak collections, weak profileSource] name in
            settings?.pocketDJName = name
            settings?.persist()
            collections?.performerName = name
            profileSource?.profileName = name   // re-tag the Pocket DJ source + item artists (→ reload)
        }
        // A device whose profile already pulled a name (second device of the same Apple ID)
        // mirrors it into settings/collections now, before the first frame renders.
        if !profile.name.isEmpty, settings.pocketDJName != profile.name {
            settings.pocketDJName = profile.name
            settings.persist()
            collections.performerName = profile.name
        }
        // Per-user identity header (X-PocketDJ-Profile) on every authenticated server call:
        // give the rip-server + Apple-Music-sync clients the LIVE profile id, read FRESH per
        // request so a cloud-pulled name change — or a post-account-deletion fresh id — is
        // picked up immediately (weak so the id closures never retain the profile graph).
        rips.profileIdProvider = { [weak profile] in profile?.id ?? "" }
        musicSync.profileIdProvider = { [weak profile] in profile?.id ?? "" }
        // Jukebox calls now carry X-PocketDJ-Profile too (host + client). Load the persisted list of
        // JOINED jukeboxes so they show on the Jukebox home (no auto-poll / no auto-present — a panel
        // polls only while it's open). The HOST session persists + resumes separately above.
        jukebox.profileIdProvider = { [weak profile] in profile?.id ?? "" }
        jukebox.loadJoinedSessions()
        _profile = State(initialValue: profile)
        // Fixture guard lives HERE (not inside the service): UI-test runs must never
        // touch a real iCloud account, but the unit-test scheme sets PDJ_USE_FIXTURE
        // globally and the sync engine itself must stay drivable by tests.
        let fixtureRun = ProcessInfo.processInfo.environment["PDJ_USE_FIXTURE"] != nil
        let cloudSync = CloudSyncService(database: CKCloudDocDatabase(),
                                         enabled: { [weak settings] in
                                             !fixtureRun && (settings?.cloudSyncEnabled ?? true)
                                         })
        // The synced-document registry: each entry is (record key, the SAME file URL the
        // store was constructed with, post-pull reload). playback-session/mix-decks are
        // file-only (no reload) — their snapshots are pulled BEFORE RootView's restore
        // calls read them (syncAtLaunch is awaited first).
        cloudSync.register("profile", fileURL: profile.syncFileURL) { [weak profile] in profile?.reloadFromDisk() }
        cloudSync.register("collections", fileURL: collections.syncFileURL) { [weak collections] in collections?.reloadFromDisk() }
        cloudSync.register("edits", fileURL: edits.syncFileURL) { [weak edits, weak app] in
            edits?.reloadFromDisk()
            // Re-overlay a cross-device metadata edit into the LIVE catalog NOW (a title/artist/album
            // edit — incl. on a Pocket DJ item — otherwise only shows on the next catalog build).
            // applyEdits only READS the edits doc, so this can't push back up (no LWW loop).
            app?.applyEdits()
        }
        cloudSync.register("favorites", fileURL: favorites.syncFileURL) { [weak favorites] in
            favorites?.reloadFromDisk()   // no onChanged on reload — a pull must not push back up
        }
        cloudSync.register("play-stats", fileURL: playStats.syncFileURL) { [weak playStats] in playStats?.reloadFromDisk() }
        cloudSync.register("play-history", fileURL: playHistory.syncFileURL) { [weak playHistory] in playHistory?.reloadFromDisk() }
        cloudSync.register("collection-activity", fileURL: collectionActivity.syncFileURL) { [weak collectionActivity] in collectionActivity?.reloadFromDisk() }
        cloudSync.register("mix-sessions", fileURL: mixSessions.syncFileURL) { [weak mixSessions] in mixSessions?.reloadFromDisk() }
        cloudSync.register("playback-session", fileURL: playbackSession.syncFileURL)
        cloudSync.register("mix-decks", fileURL: mixDeckSession.syncFileURL)
        cloudSync.register("discover-adds", fileURL: discoverAdds.syncFileURL) { [weak discoverAdds] in
            discoverAdds?.reloadFromDisk()   // new pulled entries flow through onAdded → live catalog
        }
        cloudSync.register("imported-songs", fileURL: importedSongs.syncFileURL) { [weak importedSongs] in
            importedSongs?.reloadFromDisk()  // same doctrine — imports follow the Apple ID
        }
        cloudSync.register("profile-source", fileURL: profileSource.syncFileURL) { [weak profileSource] in
            profileSource?.reloadFromDisk()  // pulled custom-audio metadata follows the Apple ID
        }
        // ONBOARDING PUSH GATE (R1): until the first-run flow resolves, no push may run —
        // a store file materialized mid-onboarding (an empty flush, an intent-written doc)
        // must never LWW-overwrite a returning user's cloud data. Pulls stay allowed (the
        // stage-1 restore IS a pull), but the scenePhase hooks below hold full passes too.
        cloudSync.pushAllowed = { [weak onboarding] in onboarding?.isComplete ?? true }
        _cloudSync = State(initialValue: cloudSync)
        // R7: completing onboarding re-fetches the catalog with the CHOSEN sources —
        // loadIfNeeded alone would early-return if an intent/CarPlay launch had already
        // loaded the default catalog before the user picked.
        onboarding.onComplete = { [weak app] in Task { await app?.reload() } }
        _onboarding = State(initialValue: onboarding)

        // ── Account deletion (App Store Guideline 5.1.1(v)) ────────────────────
        // Constructed with the LIVE stores/services it must wipe (no globals of its own). It
        // deletes the same 12 PDJDoc keys registered above, via its OWN CKCloudDocDatabase()
        // (a stateless struct, identical to the one cloudSync holds). `cloudDeleteEnabled` is
        // `{ !fixtureRun }` — UI-test runs must never touch a real iCloud account — and the
        // background-transfer cancel is wired to the process-wide TransferCoordinator here so
        // the service stays global-free.
        let accountDeletion = AccountDeletionService(
            jukebox: jukebox, setlistPlayer: setlistPlayer, mix: mix,
            cancelTransfers: { TransferCoordinator.shared.cancelAll() },
            cloudDatabase: CKCloudDocDatabase(),
            cloudDeleteEnabled: { !fixtureRun },
            collections: collections, favorites: favorites, playStats: playStats,
            playHistory: playHistory, collectionActivity: collectionActivity,
            edits: edits, discoverAdds: discoverAdds,
            importedSongs: importedSongs, profileSource: profileSource, playlistWriteBack: playlistWriteBack,
            mixSessions: mixSessions, playbackSession: playbackSession,
            mixDeckSession: mixDeckSession, burns: burns, studio: studio,
            streaming: streaming, settings: settings, cloudSync: cloudSync, profile: profile)
        _accountDeletion = State(initialValue: accountDeletion)

        // ── App Intents (Siri / Shortcuts / Spotlight) ─────────────────────────
        // One bridge instance carries the live stores to intents + entity queries.
        let intents = IntentServices(app: app, settings: settings, collections: collections,
                                     setlistPlayer: setlistPlayer, mix: mix, burns: burns,
                                     studio: studio, rips: rips, favorites: favorites)
        // ONBOARDING VETO (R4): Siri/Shortcuts/CarPlay cold-launch without RootView (and
        // its gate) — mutating intents must not write synced documents mid-onboarding.
        intents.onboardingIncomplete = { [weak onboarding] in !(onboarding?.isComplete ?? true) }
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
                .environment(nowPlayingDSP)
                .environment(albumArt)
                .environment(lyrics)
                .environment(demux)
                .environment(profileSource)
                .environment(mix)
                .environment(mixSessions)
                .environment(mixRecorder)
                .environment(playStats)
                .environment(playHistory)
                .environment(collectionActivity)
                .environment(storage)
                .environment(studio)
                .environment(studioEngine)
                .environment(studioMic)
                .environment(instrumentEngine)
                .environment(instrumentPacks)
                .environment(jukebox)
                .environment(intents)
                .environment(profile)
                .environment(cloudSync)
                .environment(onboarding)
                .environment(favorites)
                .environment(favoritesSync)
                .environment(playlistWriteBack)
                .environment(accountDeletion)
                .preferredColorScheme(.dark)
                .tint(Theme.accent)
                // A streaming provider's OAuth redirect (if any) comes back through
                // here; route it to the owning provider.
                .onOpenURL { url in
                    // A shared jukebox link (Universal Link https://jukebox.pocket-dj.com/<id>/ OR
                    // the pocketdj://jukebox/<id> fallback) → JOIN it as a client. Parsed first
                    // because it's a non-file URL that would otherwise fall into the OAuth branch;
                    // `JukeboxLink` returns nil for redirects + .pdjcollection files, so those still
                    // route below unchanged.
                    // Gate on onboarding like the file-import branch below (a link tapped during
                    // first-run is DEFERRED via pendingJukeboxLink). `addJoined` ADDS the jukebox to
                    // the persisted Jukebox-home list AND parks its id in `jukebox.pendingOpenId`, which
                    // RootView consumes to switch to the Jukebox tab and push the live join panel — so a
                    // tapped link/banner TAKES the user into the session, not just onto the home list.
                    if let link = JukeboxLink(url: url) {
                        if onboarding.isComplete { jukebox.addJoined(link) } else { pendingJukeboxLink = link }
                        return
                    }
                    // A streaming provider's OAuth redirect, OR a collection file
                    // (.pdjcollection / legacy .zip) tapped in Files/iMessage/AirDrop.
                    guard url.isFileURL else { streaming.handleCallback(url: url); return }
                    if onboarding.isComplete { importCollectionFile(url) } else { pendingOpenURL = url }
                }
                // Drain a file opened at cold launch once onboarding finishes (catalog loaded).
                .onChange(of: onboarding.isComplete) { _, done in
                    if done, let u = pendingOpenURL { pendingOpenURL = nil; importCollectionFile(u) }
                    if done, let link = pendingJukeboxLink { pendingJukeboxLink = nil; jukebox.addJoined(link) }
                    if done { syncFavoritesIfReady() }
                }
                // The LAUNCH favorites pass. It hangs off the catalog reaching `.loaded`
                // rather than a `.task`, because the inbound pull resolves Apple Music
                // catalog ids against the catalog — running it earlier would ask about an
                // empty id space and pull nothing.
                .onChange(of: app.state) { _, _ in syncFavoritesIfReady() }
                .onChange(of: scenePhase) { _, phase in
                    switch phase {
                    case .active:
                        streaming.onScenePhaseActive()
                        // Cross-device freshness beyond launch (throttled inside).
                        // HELD during onboarding: .active fires at cold launch too, and a
                        // full pass would pull/push before stage 1 decides the profile mode.
                        if onboarding.isComplete { cloudSync.syncOnForeground() }
                        // Cross-device/-app freshness for ♥ (a love added in the Music app
                        // shows up here) — same launch/foreground cadence as cloudSync, and
                        // likewise never blocking: fire-and-forget, guarded inside.
                        syncFavoritesIfReady()
                        // Drain any Apple Music playlist write-back queued in a previous
                        // session (or backed off after a failure) — the queue has no internal
                        // timer, so launch/foreground is what re-arms it.
                        playlistWriteBack.runSoon()
                        // A widget transport tap that fired while the app was fully quit dropped a
                        // command in the App Group — apply it now that playback stores are live.
                        widgetSync.drainPendingCommand(now: Date().timeIntervalSince1970)
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
                        // Playback session: land the freshest position synchronously before a
                        // possible suspension→kill (the same race the two flushes above close).
                        playbackSession.flush()
                        // Mix-deck session: same doctrine — the decks' latest playheads (and any
                        // debounced slider value still in memory) land before a suspension→kill.
                        mixDeckSession.flush()
                        // Push any session documents whose files advanced since the last
                        // sync — AFTER the flushes above so the freshest bytes upload.
                        // (pushAllowed also refuses inside while onboarding is unresolved.)
                        if onboarding.isComplete { cloudSync.pushOnBackground() }
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

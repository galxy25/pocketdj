"""Final packages — surfaces (SURF), playback (PB), services (SVC)."""
from spec_common import M, T, A, R, TR, MANIFEST, GRADLE, TOML, ARCH_DOC, AREA_GRAPH, m, t

G = AREA_GRAPH


def P(id, area, src=(), partial=(), title=None, goal=None, files=(), shared=(), deps=(), est=0, prio="P1",
      rank=50, acc=(), ut=(), emu=(), device=None):
    return dict(id=id, area=area, src=list(src), partial=list(partial), title=title, goal=goal, files=list(files),
                shared=list(shared), deps=list(deps), est=est, prio=prio, rank=rank, acc=list(acc), ut=list(ut),
                emu=list(emu), device=device)


PACKAGES = [
    # ───────────────────────────── SURFACES ─────────────────────────────
    P("SURF-1", "surfaces", src=["SHELL-1"], partial=["SET-1", "SRCH-1", "CRED-1", "PB-9", "DIAG-1", "DBG-1", "LIFE-1", "XFER-1", "WID-1", "STU-2", "LOC-2", "ACT-1", "INST-2", "INST-3", "GAMES-8", "STU-3", "SHZ-1", "COL-2", "AMSYNC-1"],
      title="Shell foundation: adaptive scaffold, FeatureModule registry + area sidecar graphs, settings section registry, typed settings keys, SecretStore, dependency + Manifest sweep",
      goal=("Bring the shell to iOS section parity (adaptive NavigationSuiteScaffold, 7th Games placeholder destination with labels on the selected item only, History default landing, "
            "last-tab restore, ShellRoute + NavRequestBus with atomic-take + staged push) AND create every extension point the rest of the program plugs into (decision D3): "
            "`shell/FeatureModule.kt` (navEntries, settingsSections, deepLinkHandlers, flushables, resetHooks, syncEntries, rowResolvers, playOutcomeListeners, periodicWork) "
            "implemented by eight sidecar graphs in `di/` that AppGraph lists once; `screens/settings/SettingsSections.kt` registry with the existing Settings blocks moved into "
            "`sections/*.kt`; `data/settings/PrefKey.kt` + a generic `AppSettingsStore` so later packages declare keys in their own files; `shell/IntentSink.kt` so MainActivity forwards every launch/new intent to a registered handler (deep links SURF-4, MwF GM-10, file opens COL-15) without being edited again;`data/credentials/SecretStore.kt` "
            "(EncryptedSharedPreferences; ripToken/jukeboxToken/musicUserToken migrated out of DataStore and blanked); and the one-time Gradle/Manifest sweep from decision D4 "
            "(all planned dependencies, permissions, FileProvider + file_paths.xml, empty shortcuts.xml, buildConfigField DIAG_CHANNEL)."),
      files=m("navigation/PocketDjDestination.kt", "shell/ShellRoute.kt", "shell/NavRequestBus.kt", "shell/LastSectionStore.kt", "shell/ShellNavigation.kt",
              "shell/FeatureModule.kt", "shell/IntentSink.kt", "MainActivity.kt", "di/AppGraph.kt", "di/PlaybackGraph.kt", "di/MixGraph.kt", "di/StudioGraph.kt", "di/GamesGraph.kt",
              "di/CollectionsGraph.kt", "di/BrowseGraph.kt", "di/ServicesGraph.kt", "di/ShellGraph.kt", "data/settings/AppSettingsStore.kt", "data/settings/PrefKey.kt",
              "data/credentials/SecretStore.kt", "screens/settings/SettingsSections.kt", "screens/settings/SettingsScreen.kt",
              "screens/settings/sections/DataSourcesSection.kt", "screens/settings/sections/CatalogSection.kt", "screens/settings/sections/AppleMusicSection.kt",
              "screens/settings/sections/HistorySection.kt", "screens/settings/sections/StorageSection.kt", "screens/settings/sections/AboutSection.kt",
              "screens/PlaceholderScreen.kt")
            + [MANIFEST, GRADLE, TOML, R + "xml/file_paths.xml", R + "xml/shortcuts.xml"]
            + t("shell/NavRequestBusTest.kt", "shell/ShellRouteResolverTest.kt", "shell/FeatureModuleRegistryTest.kt", "navigation/PocketDjDestinationTest.kt",
                "screens/settings/SettingsSectionsTest.kt", "data/settings/PrefKeyTest.kt", "data/credentials/SecretStoreMigrationTest.kt"),
      deps=[], est=2000, prio="P0", rank=0,
      acc=["Every one of the eight sidecar graphs compiles as an empty FeatureModule and AppGraph aggregates their lists; a JVM test registers a fake module and sees its nav entry, settings section, flush hook and row resolver surface in the aggregated lists",
           "After this package no other roadmap package lists MainActivity, AppGraph, AppSettingsStore, SettingsScreen or PocketDjDestination in its files (check_roadmap.py asserts it)",
           "SecretStore holds ripToken/jukeboxToken/musicUserToken; the one-shot migration blanks the DataStore copies and is idempotent; existing rip/jukebox flows still authenticate",
           "Manifest declares RECORD_AUDIO, POST_NOTIFICATIONS, FOREGROUND_SERVICE_DATA_SYNC, FOREGROUND_SERVICE_MEDIA_PLAYBACK, BLUETOOTH_CONNECT/SCAN, the FileProvider and the shortcuts meta-data; the app installs and launches on the emulator with no new runtime prompt at launch",
           "Version catalog carries every dependency named in decision D4 and `./gradlew :app:assembleDebug` is green"],
      ut=["FeatureModuleRegistryTest: aggregation order is stable (area order) and duplicate route ids fail fast", "PrefKeyTest: typed get/set/flow round-trip + default; legacy key names unchanged",
          "SecretStoreMigrationTest: migration runs once, blanks plaintext, survives relaunch"],
      emu=["Launch: History is the landing tab; switch to Mix, kill, relaunch → Mix restored", "Seven destinations visible at 411 dp with only the selected label shown; Games opens the placeholder",
           "Settings renders every pre-existing block in registry order"]),

    P("SURF-2", "surfaces", src=["LIFE-1"],
      title="Application lifecycle + background work: PocketDjApplication, ProcessLifecycle flush funnel (FlushRegistry), WorkScheduler over FeatureModule.periodicWork",
      files=m("PocketDjApplication.kt", "shell/FlushRegistry.kt", "shell/AppLifecycleObserver.kt", "work/WorkScheduler.kt", "screens/browse/BrowseSessionPersistence.kt",
              "di/ShellGraph.kt") + [MANIFEST] + t("shell/FlushRegistryTest.kt", "work/WorkSchedulerPolicyTest.kt"),
      shared=[MANIFEST + " (android:name=.PocketDjApplication only)"],
      deps=["SURF-1"], est=700, prio="P0", rank=1,
      acc=["WorkScheduler schedules only the periodic work the sidecar graphs declare (none yet) and is idempotent (`ensureScheduled` twice ⇒ one unique work per id)"]),

    P("SURF-3", "surfaces", src=["ONB-1@surfaces", "ONB-1@services"],
      title="Zero-to-hero onboarding (store, 3 stages, launch gate, mutating-intent veto, link-a-device stub)",
      goal=("Port OnboardingStore's decision tree and the iOS marker JSON (`pdj.onboarding.v1`: version/state/stage/completedAtMs) plus the 3-stage Compose flow: PocketDJ name + "
            "'Use on this device' / 'Link a device' (probe seam stubbed until SVC-9; iCloud branch N/A) → Apple Music sign-in → Sources (applyOnboardingSources vinyl/digital/streaming). "
            "The launch pipeline (catalog loadIfNeeded, rips loadAtLaunch, jukebox bootstrap, future sync push) awaits `waitUntilComplete`; every mutating ShellActions call is vetoed while incomplete; `hadPersistedSettings` is captured at construction so upgrades skip onboarding."),
      files=m("onboarding/OnboardingStore.kt", "onboarding/OnboardingScreen.kt", "onboarding/OnboardingStages.kt", "onboarding/OnboardingSettings.kt", "onboarding/LinkDeviceProbe.kt",
              "shell/ShellNavigation.kt", "di/ShellGraph.kt") + t("onboarding/OnboardingStoreTest.kt", "onboarding/OnboardingMarkerCodecTest.kt"),
      deps=["SURF-1"], est=1400, prio="P0", rank=2,
      device="Real Apple Music sign-in completion in stage 2 (emulator verifies cancel/fail path only)."),

    P("SURF-4", "surfaces", src=["LINK-1"],
      title="Deep links + file opens: manifest filters, DeepLinkParser, pending-until-onboarding, dispatcher over FeatureModule.deepLinkHandlers",
      goal=("Manifest VIEW/BROWSABLE filters for pocketdj://{play,album,artist,playlist,pocket,setlist,jukebox,mwf,search}, https://jukebox.pocket-dj.com/{join,mwf}/ (autoVerify), "
            "and file opens for .pdjcollection / .pocketdj.zip / .pdjdiagkey (MIME + extension). `DeepLinkParser` → sealed DeepLink; `PendingOpenStore` parks links until onboarding completes; "
            "`DeepLinkDispatcher` routes to the first FeatureModule handler that accepts (MwF and collection-file handlers arrive later via GM-10 / COL-15 / SVC-5) else NavRequestBus.routeMessage."),
      files=m("shell/DeepLinkParser.kt", "shell/PendingOpenStore.kt", "shell/DeepLinkDispatcher.kt", "di/ShellGraph.kt") + [MANIFEST]
            + t("shell/DeepLinkParserTest.kt", "shell/PendingOpenStoreTest.kt"),
      shared=[M + "di/ShellGraph.kt (registers the dispatcher as the IntentSink SURF-1 created; MainActivity is not edited)"],
      deps=["SURF-1", "SURF-3"], est=700, prio="P0", rank=6),

    P("SURF-5", "surfaces", src=["ACT-1"],
      title="ShellActions façade (IntentServices analogue) + MixFacade seam + Assistant media search + static/dynamic shortcuts",
      files=m("shell/ShellActions.kt", "shell/MixFacade.kt", "assistant/MediaSearchHandler.kt", "assistant/ShortcutsPublisher.kt", "playback/PlaybackService.kt", "di/ShellGraph.kt")
            + [R + "xml/shortcuts.xml"] + t("shell/ShellActionsTest.kt", "assistant/MediaSearchHandlerTest.kt", "assistant/ShortcutsPublisherTest.kt"),
      shared=[M + "playback/PlaybackService.kt (MEDIA_PLAY_FROM_SEARCH / onSetMediaItems search hook only)"],
      deps=["SURF-1", "SURF-3", "PB-2"], est=1200, prio="P0", rank=12),

    P("SURF-6", "surfaces", partial=["SET-1"],
      title="Settings shell rows: Profile name, Collections default recently-added count, Import server 'Rip from cloud source', Jukebox require-token default",
      goal="The shell-owned Settings rows from the iOS Settings parity list, as registry sections: ProfileSection (PocketDJ name, edits the onboarding/profile name), CollectionsSection (defaultRecentlyAddedCount 50 clamp 1…500), ImportServerSection ('Rip from cloud source' → `ripFromCloud` in the POST /rip body — read RipsStore.swift for the field name), Jukebox default (only if SURF-10 has not placed it).",
      files=m("screens/settings/sections/ProfileSection.kt", "screens/settings/sections/CollectionsSection.kt", "screens/settings/sections/ImportServerSection.kt",
              "data/settings/ShellSettings.kt", "data/rips/RipServerClient.kt", "di/ShellGraph.kt") + t("screens/settings/ShellSettingsRowsTest.kt", "data/rips/RipFromCloudBodyTest.kt"),
      shared=[M + "data/rips/RipServerClient.kt (one body field)"],
      deps=["SURF-1", "SURF-3", "SVC-1"], est=600, prio="P1", rank=30,
      acc=["Each row persists through relaunch; the recently-added count clamps to 1…500; POST /rip carries ripFromCloud exactly as iOS names it"],
      ut=["ShellSettingsRowsTest: clamp + defaults", "RipFromCloudBodyTest: body field present/absent by toggle"],
      emu=["Change the count and the rip toggle, kill, relaunch, values restored"]),

    P("SURF-7", "surfaces", src=["WID-1"],
      title="Glance Now Playing widget (small/medium/large + idle) with snapshot sync and offline command queue",
      files=m("widget/NowPlayingSnapshot.kt", "widget/NowPlayingSnapshotStore.kt", "widget/WidgetSync.kt", "widget/NowPlayingWidget.kt", "widget/NowPlayingWidgetReceiver.kt",
              "widget/WidgetActionReceiver.kt", "widget/PendingWidgetCommands.kt", "di/ShellGraph.kt") + [R + "xml/now_playing_widget_info.xml", MANIFEST]
            + t("widget/NowPlayingSnapshotCodecTest.kt", "widget/PendingWidgetCommandsTest.kt"),
      deps=["PB-2", "SURF-2", "COL-10"], est=1500, prio="P1", rank=40),

    P("SURF-8", "surfaces", src=["AUTO-1"],
      title="Android Auto: MediaLibraryService browse tree (Playlists · Pockets · Continue), play/add-to actions, artwork, warm-up",
      files=m("auto/AutoBrowseTree.kt", "auto/AutoLibraryCallback.kt", "auto/AutoArtwork.kt", "auto/AutoAddTargets.kt", "playback/PlaybackService.kt")
            + [MANIFEST, R + "xml/automotive_app_desc.xml"] + t("auto/AutoBrowseTreeTest.kt", "auto/AutoLibraryCallbackTest.kt"),
      shared=[M + "playback/PlaybackService.kt (MediaSessionService → MediaLibraryService)"],
      deps=["SURF-5", "PB-2", "COL-4"], est=1500, prio="P1", rank=42,
      device="Real head unit / DHU rendering, voice; emulator uses the Desktop Head Unit."),

    P("SURF-9", "surfaces", src=["AUTO-2"],
      title="Android Auto Mix tab + Jukebox session rows (two-crate Auto DJ remote)",
      files=m("auto/AutoMixTab.kt", "auto/AutoBrowseTree.kt", "auto/AutoLibraryCallback.kt") + t("auto/AutoMixTabTest.kt"),
      deps=["SURF-8", "SURF-10", "MIX-16"], est=600, prio="P2", rank=90),

    P("SURF-10", "surfaces", src=["JBX-1"],
      title="Jukebox host parity gaps: played-history dedup rule, require-token default toggle, sessions list/adopt, AM-search match seam, Mix placement seam",
      files=m("data/jukebox/JukeboxRepository.kt", "data/jukebox/JukeboxClient.kt", "data/jukebox/JukeboxUrls.kt", "data/jukebox/JukeboxModels.kt", "data/jukebox/JukeboxMatcher.kt",
              "data/jukebox/JukeboxSettings.kt", "screens/jukebox/JukeboxScreen.kt", "screens/settings/sections/JukeboxSection.kt", "di/ShellGraph.kt")
            + t("data/jukebox/JukeboxPlayedDedupTest.kt", "data/jukebox/JukeboxSessionsClientTest.kt"),
      deps=["SURF-1"], est=700, prio="P1", rank=14),

    P("SURF-11", "surfaces", src=["JBX-2"],
      title="Jukebox guest: JukeboxLink, joined-sessions list, join panel with request line + Tune In (via the sequencer's playUrl seam)",
      files=m("data/jukebox/JukeboxLink.kt", "data/jukebox/JukeboxGuestState.kt", "data/jukebox/JukeboxGuestClient.kt", "data/jukebox/JoinedSessionsStore.kt",
              "screens/jukebox/JukeboxJoinScreen.kt", "screens/jukebox/JoinedSessionsStrip.kt", "screens/jukebox/JukeboxScreen.kt", "data/jukebox/JukeboxGraph.kt", "di/ShellGraph.kt")
            + t("data/jukebox/JukeboxLinkTest.kt", "data/jukebox/JoinedSessionsStoreTest.kt", "screens/jukebox/TuneInSeekMathTest.kt"),
      deps=["SURF-4", "SURF-10", "PB-1"], est=1500, prio="P1", rank=34),

    # ───────────────────────────── PLAYBACK ─────────────────────────────
    P("PB-1", "playback", src=["PB-1"],
      title="SetlistSequencer core: cursor queue, live edits, repeat/shuffle, per-row resolve ladder, RowResolverRegistry, playUrl + appendRows(runTag) seams",
      goal=("The Android SetlistPlayer (decision D11): app-scoped `SetlistSequencer` owning `queue[QueueItem(uid)]`, index, isRunning/isHeldForResume, source, captured context/origin, repeat/shuffle (+canonicalOrder), "
            "notice, playGeneration; ExoPlayer holds only the current row through `PlayerPort`. Per-row resolve ladder through `RowResolverRegistry` aggregated from FeatureModule.rowResolvers "
            "(burned-first SVC-4, studio-local STU-7, AM PB-8, cloud/rip-on-demand PB-3 register later; default = manifest/direct). Also owns: `EditionDecider` seam (default unchanged), "
            "`PlayOutcomeListener` registry fan-out, `playUrl(title, artist, url, seekMs)` for jukebox Tune-In, `appendRows(items, runTag)`/`currentIndex()` for game runs, and the rewrite of "
            "PlaybackController/QueuePlan/SetlistDetailScreen onto the sequencer. Logs through NPLog lanes."),
      files=m("playback/sequencer/SetlistSequencer.kt", "playback/sequencer/QueueItem.kt", "playback/sequencer/SequencerState.kt", "playback/sequencer/RowSourceResolver.kt",
              "playback/sequencer/RowResolverRegistry.kt", "playback/sequencer/LocalFileResolver.kt", "playback/sequencer/EditionDecider.kt", "playback/sequencer/PlayerPort.kt",
              "playback/sequencer/RepeatMode.kt", "playback/sequencer/AdvanceCause.kt", "playback/outcome/PlayOutcomeListener.kt", "playback/PlaybackController.kt",
              "playback/PlaybackContract.kt", "playback/PlayEvents.kt", "playback/QueuePlan.kt", "playback/PlaybackSettings.kt", "di/PlaybackGraph.kt",
              "screens/nowplaying/NowPlayingRoutes.kt", "screens/playlists/SetlistDetailScreen.kt")
            + t("playback/sequencer/SetlistSequencerTest.kt", "playback/sequencer/RepeatShuffleTest.kt", "playback/sequencer/LiveEditsTest.kt", "playback/sequencer/ResolveLadderTest.kt",
                "playback/sequencer/FakePlayerPort.kt"),
      deps=["SURF-1", "SVC-5"], est=2500, prio="P0", rank=3,
      acc=["`playUrl` plays an arbitrary stream with a seek offset without disturbing a held queue; `appendRows(runTag)` rows carry the tag into PlayContext",
           "`screens/nowplaying/NowPlayingRoutes.kt` ships as the (empty) nav-entry list PlaybackGraph already consumes, so PB-6 adds the Now Playing route without editing the sidecar"]),

    P("PB-2", "playback", src=["PB-2", "LOCK-1"], partial=["MIX-6"],
      title="Session transport + one-owner arbiter: SequencerForwardingPlayer, SessionSwitchboard (TransportOwner, set-gated commands, ♥ custom command), idle-play ladder, instant metadata",
      goal=("Make the single Media3 MediaSession drive the sequencer as MPRemoteCommandCenter drives SetlistPlayer (decision D2): `SequencerForwardingPlayer` intercepts next/prev/repeat/shuffle/idle-play "
            "(resumeHeld / startCurrent / startInFlight ignore, `pendingRemotePlayAt` 15 s latch); `SessionSwitchboard` is the arbiter — holds the MediaSession, `setOwner(TransportOwner)`, last-STARTED-owns, "
            "restored-never-sounded is not a remote target, starting one owner pauses the other (Mix, Apple Music adapter and Now Playing DSP plug in later); `SetGatedPlayer` masks next/prev/repeat/shuffle "
            "unless a set is running; `FavoriteCommand` (pdj.favorite CommandButton behind a `FavoriteSeam`, null ⇒ no ♥); `TransportLog` `[transport] rc cmd=… verdict=…`; instant metadata on start."),
      files=m("playback/session/SequencerForwardingPlayer.kt", "playback/session/SessionSwitchboard.kt", "playback/session/TransportOwner.kt", "playback/session/SetGatedPlayer.kt",
              "playback/session/FavoriteCommand.kt", "playback/session/TransportLog.kt", "playback/PlaybackService.kt", "playback/sequencer/SetlistSequencer.kt",
              "playback/PlaybackController.kt", "playback/PlaybackContract.kt", "di/PlaybackGraph.kt")
            + t("playback/session/SequencerForwardingPlayerTest.kt", "playback/session/IdlePlayLadderTest.kt", "playback/session/SessionSwitchboardTest.kt", "playback/session/SetGatedCommandsTest.kt"),
      deps=["PB-1"], est=2400, prio="P0", rank=4,
      device="Bluetooth/headset routes, AVRCP head units and the actual lock-screen render."),

    P("PB-3", "playback", src=["PB-3"],
      title="Zero dead air: rip-on-demand resolver in runs, runway, watchdogs, stall hop, cascade breaker, rip window, live backstop, supervisor, DeadAirMeter, pause discriminator",
      files=m("playback/session/ResolvingSongDataSource.kt", "playback/sequencer/CloudRowResolver.kt", "playback/health/PlaybackRunway.kt", "playback/health/StartWatchdog.kt",
              "playback/health/ResolveStallHop.kt", "playback/health/AutoAdvanceCascadeBreaker.kt", "playback/health/PlaybackRipWindow.kt", "playback/health/LiveBackstop.kt",
              "playback/health/PlaybackSupervisor.kt", "playback/health/DeadAirMeter.kt", "playback/health/PauseDiscriminator.kt", "playback/sequencer/SetlistSequencer.kt",
              "playback/PlaybackService.kt", "di/PlaybackGraph.kt")
            + t("playback/health/PlaybackSupervisorTest.kt", "playback/health/CascadeBreakerTest.kt", "playback/health/RipWindowTest.kt", "playback/health/DeadAirMeterTest.kt",
                "playback/health/StartWatchdogTest.kt", "playback/health/PauseDiscriminatorTest.kt", "playback/sequencer/CloudRowResolverTest.kt"),
      deps=["PB-1", "PB-2", "SVC-1"], est=2400, prio="P0", rank=5),

    P("PB-4", "playback", src=["PB-4"], partial=["LOCK-1"],
      title="Durable playback session: real-time snapshot, held restore, resume at position, materialize Now Playing setlist, playback-resumption provider",
      files=m("playback/durable/PlaybackSessionStore.kt", "playback/durable/SessionSnapshot.kt", "playback/durable/SessionWriter.kt", "playback/durable/AppLifecycleFlusher.kt",
              "playback/durable/ResumptionProvider.kt", "playback/sequencer/SetlistSequencer.kt", "data/collections/CollectionsStore.kt", "di/PlaybackGraph.kt")
            + [TR + "fixtures/ios-playback-session-v1.json"]
            + t("playback/durable/PlaybackSessionStoreTest.kt", "playback/durable/SessionWriterOrderingTest.kt", "playback/durable/HeldRestoreTest.kt", "playback/durable/ResumptionSnapshotTest.kt"),
      shared=[M + "data/collections/CollectionsStore.kt (materializeNowPlayingSetlist only)"],
      deps=["PB-1", "PB-2", "COL-2", "SURF-2"], est=1500, prio="P0", rank=7,
      acc=["onPlaybackResumption restores the held queue without auto-playing (iOS held rule); the file mtime changes only on real play/edit, never on restore"]),

    P("PB-5", "playback", src=["PB-5", "HIST-1", "GAMES-6"],
      title="History outcomes: SkipTracker + additive PlayEvent fields + progress/advance-away events + GAME/MIX source tokens + PlayOutcomeListener fan-out",
      goal=("Decision D9. `playback/outcome/SkipTracker` (strict <0.5 rule, high-water position, one-deep previous stash, classified latch) sampled 1 Hz by the sequencer ticker; PlayEvent gains "
            "`wasSkipped`, `listenedFraction`, `tzOffsetMin`, `originInstallId`, `originCollectionId` (iOS keys; `carPlay`/`listeningContext` reserved absent); `PlayHistoryStore.record` stamps tz/install/origin "
            "and returns the event, `markSkipped`, `noteListened` max-merge (<0.01 dropped), `onRecord`/`onResume` hooks, lenient decode of old docs, local-only recount window; `PlayProgress`/`PlayAdvancedAway`/"
            "`PlayStopped` on PlayEventBus; `PlaySource.GAME` + `PlayContext.game(runTag,label)` and `PlaySource.MIX` tokens so rows read 'Game · Gem Collector' / 'Mix' exactly as iOS."),
      files=m("playback/outcome/SkipTracker.kt", "data/history/PlayHistoryModels.kt", "data/history/PlayHistoryStore.kt", "playback/PlayEvents.kt", "playback/sequencer/SetlistSequencer.kt",
              "di/PlaybackGraph.kt")
            + t("playback/outcome/SkipTrackerTest.kt", "data/history/PlayHistoryStoreOutcomesTest.kt", "data/history/PlayEventCodecTest.kt"),
      deps=["PB-1"], est=1500, prio="P0", rank=5),

    P("PB-6", "playback", src=["PB-6"],
      title="Now Playing deck screen (gold record at beat-grid BPM, transport, notices) + mini bar upgrade + NowPlayingSeams (DSP/stem-lock slots)",
      files=m("screens/nowplaying/NowPlayingScreen.kt", "screens/nowplaying/NowPlayingDeckCluster.kt", "screens/nowplaying/RecordPlayer.kt", "screens/nowplaying/NowPlayingTransport.kt",
              "screens/nowplaying/NowPlayingViewModel.kt", "screens/nowplaying/NowPlayingSeams.kt", "screens/nowplaying/NowPlayingRoutes.kt", "screens/browse/MiniPlayerBar.kt",
              "screens/playlists/PlaylistsComponents.kt")
            + t("screens/nowplaying/RecordPlayerMathTest.kt", "screens/nowplaying/NowPlayingViewModelTest.kt"),
      shared=[M + "screens/playlists/PlaylistsComponents.kt (▶/🔀 funnels route to nowplaying)"],
      deps=["PB-1", "PB-2"], est=1900, prio="P0", rank=6),

    P("PB-7", "playback", src=["PB-7"],
      title="Up Next, previously played, add-search, open set list, queue reorder; jukebox routed through the sequencer",
      files=m("screens/nowplaying/UpNextList.kt", "screens/nowplaying/PlayedList.kt", "screens/nowplaying/NowPlayingSearch.kt", "screens/nowplaying/NowPlayingSearchBar.kt",
              "screens/nowplaying/NowPlayingExpandedLayout.kt", "screens/nowplaying/NowPlayingScreen.kt", "screens/nowplaying/QueueReorder.kt", "data/jukebox/JukeboxRepository.kt")
            + t("screens/nowplaying/QueueReorderTest.kt", "screens/nowplaying/UpNextUidEditsTest.kt"),
      shared=[M + "data/jukebox/JukeboxRepository.kt (inserts go through the sequencer)"],
      deps=["PB-1", "PB-6", "SURF-10", "BRW-1"], est=2000, prio="P1", rank=20),

    P("PB-8", "playback", src=["PB-8"],
      title="Apple Music rows in a run: AppleMusicPlayerAdapter (SimpleBasePlayer TransportOwner) + end/skip/interruption verdicts + AM row resolver",
      files=m("playback/session/AppleMusicPlayerAdapter.kt", "playback/am/AppleMusicController.kt", "playback/am/AppleMusicEndMonitor.kt", "playback/sequencer/AppleMusicRowResolver.kt",
              "playback/AppleMusicBackend.kt", "playback/session/SessionSwitchboard.kt", "playback/sequencer/SetlistSequencer.kt")
            + t("playback/am/EndReasonTest.kt", "playback/am/AppleMusicEndMonitorTest.kt", "playback/session/AppleMusicAdapterStateMapTest.kt"),
      deps=["PB-1", "PB-2", "PB-3"], est=1500, prio="P1", rank=22,
      device="Full-track DRM playback requires a real device with a subscription (vendored mediaplayback AAR); emulator verifies the preview fallback and the adapter state machine."),

    P("PB-10", "playback", src=["PB-10"],
      title="Gapless preload window (next resolved row pre-added to ExoPlayer)",
      files=m("playback/sequencer/NextRowPreloader.kt", "playback/sequencer/SetlistSequencer.kt", "playback/sequencer/PlayerPort.kt") + t("playback/sequencer/NextRowPreloaderTest.kt"),
      deps=["PB-1", "PB-3", "PB-8"], est=900, prio="P2", rank=80),

    # ───────────────────────────── SERVICES ─────────────────────────────
    P("SVC-1", "services", src=["RIP-1"], partial=["DL-1", "STU-3"],
      title="Rip client parity: presign + prefetch, 20 s bounded interactive wait + StillRipping, job tracker, manifest generation guard, batch rip/cancel, stems/beat-grid/lyrics manifest fields",
      goal=("RIP-1 verbatim plus the additive RipsModels fields every other area needs (stems{vocals,drums,bass,other}, stemVersion, stemFormat, beatgrid, firstBeatMs, firstDownbeatMs, beatGridBpm, beatsPerBar, "
            "tempoConfidence, steady, cutKey, lyrics; `stemUrls()`/`beatgridKey`), `cancelRips(ids)` for the rip window, PresignCache prefetch, RipJobTracker.pollToReady (2 s, ≤1 h, never terminates on phase=error) + onRipReady, "
            "and the `StillRipping` outcome replacing the 30-minute foreground await in the current PlaybackController."),
      files=m("data/rips/RipsModels.kt", "data/rips/RipServerClient.kt", "data/rips/PresignCache.kt", "data/rips/RipJobTracker.kt", "data/rips/RipsRepository.kt", "data/rips/RipSettings.kt",
              "playback/PlaybackController.kt", "di/ServicesGraph.kt")
            + t("data/rips/RipServerClientTest.kt", "data/rips/RipJobTrackerTest.kt", "data/rips/PresignCacheTest.kt", "data/rips/RipsModelsStemsTest.kt", "data/rips/RipsRepositoryGenerationTest.kt"),
      shared=[M + "playback/PlaybackController.kt (replace 30-min await with 20 s wait + StillRipping; PB-1 rebuilds on top)"],
      deps=["SURF-1"], est=1300, prio="P0", rank=1),

    P("SVC-2", "services", src=["BURN-1"], partial=["DL-1"],
      title="BurnStore core (ONE offline store): ledger, byte-identical file names, sidecar, stems + beat-grid sidecars, in-process burn loop, reconcile, removal, usage, eviction planner, pendingAfterRip",
      goal=("Decision D5. iOS `pocketdj-burns.json` v1 ledger + BurnItem fields; `BurnFileNames` (idToken, prefixes, sanitizeToken 40/150, descriptiveName, stableIdSuffix, cutFileName, stem-<id>-<part>.mp3, analysis-<id>.json); "
            "`BurnSidecar` mirroring burn-setlist.mjs header order; `BurnFolder` single root resolver (filesDir/burns; SAF later); `BurnStore` (items StateFlow, burn(songs) in-process serial path, requestStop, isFresh vs rippedAt, "
            "localUrl/localUrlPreferringCut/startMs, all-4-or-nothing stems + adoptStreamedStems + stemsRemote, beat grids validated, adoptStreamedFile, removeBurns freeing shared analog audio with the LAST ref, removeAllBurns, "
            "sweepOrphanAuxFiles, usage, planEviction, reconcileOnLaunch dropping missing/poisoned <4 KB xml/html files); StorageService BURNS/STEMS categories."),
      files=m("data/burns/BurnModels.kt", "data/burns/BurnFileNames.kt", "data/burns/BurnSidecar.kt", "data/burns/BurnFolder.kt", "data/burns/BurnStore.kt", "data/burns/BurnReconciler.kt",
              "data/burns/EvictionPlanner.kt", "data/burns/BeatGridSidecar.kt", "data/storage/StorageService.kt", "di/ServicesGraph.kt")
            + t("data/burns/BurnFileNamesTest.kt", "data/burns/BurnSidecarTest.kt", "data/burns/BurnStoreTest.kt", "data/burns/BurnReconcilerTest.kt", "data/burns/EvictionPlannerTest.kt",
                "data/burns/BeatGridSidecarTest.kt", "data/burns/BurnStemsTest.kt"),
      deps=["SVC-1", "SURF-2"], est=2500, prio="P0", rank=3),

    P("SVC-3", "services", src=["XFER-1"], partial=["DL-1"],
      title="TransferCoordinator over WorkManager: background burn downloads surviving process death, persisted records, bearer policy, progress mirror, rip-reconcile periodic worker",
      files=m("data/transfers/TransferModels.kt", "data/transfers/BearerPolicy.kt", "data/transfers/TransferCoordinator.kt", "data/transfers/BurnDownloadWorker.kt", "data/transfers/RipReconcileWorker.kt",
              "data/transfers/TransferNotifications.kt", "data/burns/BurnStore.kt", "di/ServicesGraph.kt")
            + t("data/transfers/BearerPolicyTest.kt", "data/transfers/TransferCoordinatorTest.kt", "data/transfers/TransferRecordCodecTest.kt", "data/transfers/BurnDownloadWorkerTest.kt"),
      deps=["SVC-2", "SURF-2"], est=1500, prio="P0", rank=5,
      device="Doze-deferred periodic timing is only observable on hardware; the emulator uses `cmd jobscheduler run -f`."),

    P("SVC-4", "services", src=["BURN-2"],
      title="Burned-first row resolver + device/cloud PlaybackMode + collection Rip/Burn bar with Stop and progress",
      files=m("data/rips/PlayResolver.kt", "playback/sequencer/BurnedRowResolver.kt", "data/burns/BurnSettings.kt", "screens/playlists/CollectionBurnBar.kt", "screens/playlists/PlaylistDetailScreen.kt",
              "screens/playlists/PlaybackModeToggle.kt", "di/ServicesGraph.kt")
            + t("data/rips/PlayResolverBurnedFirstTest.kt", "playback/sequencer/BurnedRowResolverTest.kt", "screens/playlists/CollectionBurnBarStateTest.kt"),
      deps=["SVC-2", "SVC-3", "PB-1"], est=1400, prio="P0", rank=8,
      acc=["Device/cloud mode is surfaced by `PlaybackModeToggle` on the collection burn bar and by the sequencer's `deviceQueueUnplayable` notice (PB-1 notice slot) — the mini bar (PB-6) is not edited"]),

    P("SVC-5", "services", src=["PB-9", "DIAG-1", "DBG-1"],
      title="Diagnostics: DiagLog + NPLog lanes, shared SigV4 S3 uploader, .pdjdiagkey import, jank watchdog, Settings ▸ Debug screen",
      goal=("Decision D8. One `diag/` stack: DiagLog (ring buffer, 500-line parts, 40k session cap, 15 s / 3 s telemetry flush, immediate on error, serialized uploads latest-body-per-key, UploadStatus persisted, "
            "`[diag] status` at launch, buffered-until-key), NPLog lanes ([playback] [session] [transport] [supervisor] [deadair] [runway] [ripreq] [action] [np] [mix] [studio]) with the iOS grammar, key "
            "`diag/android-<installId8>/<stamp>-b<versionCode>[-pN].log` in `RemoteEndpoints.diagBucket` (default pocketdj-logs-623170744161, us-west-2), `net/SigV4.kt` pure signer (AWS test vectors), "
            "DiagKeyFile (.pdjdiagkey type tag, schemaVersion 1, AKIA/ASIA regex, 12-digit account, env/account pairing check) stored in SecretStore, JankWatchdog (Choreographer gap >500 ms), DebugScreen "
            "(build identity, endpoints summary, upload status, key import/remove, capture sessions export, dead-air seam) + DebugSection registry row; channel gate BuildConfig.DEBUG || DIAG_CHANNEL; FlushRegistry registration; deep-link handler for .pdjdiagkey."),
      files=m("diag/DiagLog.kt", "diag/NPLog.kt", "diag/DiagUploader.kt", "diag/DiagUploadStatus.kt", "diag/DiagKeyFile.kt", "diag/JankWatchdog.kt", "diag/DiagSettings.kt", "net/SigV4.kt",
              "screens/settings/DebugScreen.kt", "screens/settings/sections/DebugSection.kt", "data/config/RemoteEndpoints.kt", "di/ServicesGraph.kt")
            + t("diag/DiagLogTest.kt", "net/SigV4Test.kt", "diag/DiagKeyFileTest.kt", "diag/DiagUploaderTest.kt"),
      deps=["SURF-1"], est=1800, prio="P0", rank=1),

    P("SVC-6", "services", src=["STOR-1"],
      title="PlayStatsStore + StorageManager prune engine + StoragePruneWorker + Storage screen burn/stem/cap sections",
      files=m("data/stats/PlayStatsStore.kt", "data/stats/PlayStatsRecorder.kt", "data/storage/StorageManager.kt", "data/storage/StorageSettings.kt", "data/transfers/StoragePruneWorker.kt",
              "data/storage/StorageService.kt", "screens/settings/StorageScreen.kt", "di/ServicesGraph.kt")
            + t("data/stats/PlayStatsStoreTest.kt", "data/storage/StorageManagerPlanTest.kt", "data/storage/PruneWorkerGateTest.kt"),
      deps=["SVC-2", "SVC-3", "PB-5"], est=1800, prio="P1", rank=24),

    P("SVC-7", "services", src=["SYNC-1@services"],
      title="Document sync engine (CloudSyncService verbatim port) + ProfileStore + in-memory CloudDocDatabase + SyncRegistry over FeatureModule.syncEntries + reloadFromDisk seams",
      files=m("data/sync/CloudDoc.kt", "data/sync/CloudDocDatabase.kt", "data/sync/InMemoryCloudDocDatabase.kt", "data/sync/CloudSyncService.kt", "data/sync/ProfileStore.kt", "data/sync/SyncRegistry.kt",
              "data/sync/SyncSettings.kt", "data/collections/CollectionsStore.kt", "data/history/PlayHistoryStore.kt", "data/activity/CollectionActivityStore.kt",
              "screens/settings/sections/ProfileSection.kt", "di/ServicesGraph.kt")
            + t("data/sync/CloudSyncServiceTest.kt", "data/sync/ProfileStoreTest.kt", "data/sync/SyncRegistryTest.kt", "data/sync/ReloadMergeTest.kt"),
      shared=[M + "data/collections/CollectionsStore.kt, data/history/PlayHistoryStore.kt, data/activity/CollectionActivityStore.kt (one reloadFromDisk() each; activity/history merge by event id)"],
      deps=["SURF-3", "COL-2", "PB-5", "SURF-6"], est=2000, prio="P1", rank=26),

    P("SVC-8", "services", src=["SYNC-0"],
      title="Backend: pocketdj-profile-sync Lambda (S3 document store) + optional endpoint key",
      files=["scripts/lambda/profile-sync/index.mjs", "scripts/lambda/profile-sync/deploy.sh", "scripts/lambda/profile-sync/test/profile-sync.test.mjs", "config/endpoints.green.json", "docs/design/profile-sync-s3.md"],
      shared=["config/endpoints*.json (new optional key profileSyncBase)"],
      deps=[], est=500, prio="P1", rank=25,
      device="Deploy to the green account needs AWS profile llc; unit tests run against a stubbed S3 client."),

    P("SVC-9", "services", src=["SYNC-2"],
      title="S3CloudDocDatabase + enroll + link-a-device (QR/code) + onboarding stage-1 probe",
      files=m("data/sync/S3CloudDocDatabase.kt", "data/sync/ProfileSecretStore.kt", "data/sync/Enrollment.kt", "data/sync/LinkCode.kt", "data/config/RemoteEndpoints.kt",
              "screens/settings/LinkDeviceScreen.kt", "onboarding/LinkDeviceProbe.kt", "di/ServicesGraph.kt")
            + t("data/sync/S3CloudDocDatabaseTest.kt", "data/sync/LinkCodeTest.kt", "data/sync/EnrollmentTest.kt"),
      deps=["SVC-7", "SVC-8"], est=1300, prio="P1", rank=32),

    P("SVC-10", "services", partial=["CRED-1"],
      title="Synced connection credentials doc (empty-secret guard) + diag-key sync doc + X-PocketDJ-Profile header",
      goal="The sync half of CRED-1 (SecretStore itself shipped in SURF-1): `SettingsCredentialsDocument` (sorted-key deterministic encode, credentialsAreBlank, syncIfChanged — a blank install never materializes the doc, applyPulled ignores empty secrets so an accidental blank can never wipe the fleet), `DiagKeySync`, registration through ServicesGraph.syncEntries, and the X-PocketDJ-Profile header on RipServerClient + JukeboxClient when a profile id exists.",
      files=m("data/credentials/SettingsCredentialsDocument.kt", "data/credentials/CredentialsSync.kt", "data/credentials/DiagKeySync.kt", "data/rips/RipServerClient.kt", "data/jukebox/JukeboxClient.kt", "di/ServicesGraph.kt")
            + t("data/credentials/CredentialsSyncTest.kt", "data/credentials/DiagKeySyncTest.kt", "data/credentials/ProfileHeaderTest.kt"),
      shared=[M + "data/rips/RipServerClient.kt, data/jukebox/JukeboxClient.kt (header only)"],
      deps=["SVC-7", "SVC-5"], est=600, prio="P1", rank=36,
      acc=["A pulled credentials doc with an empty secret never overwrites a non-empty local secret; a blank install never creates the doc; both clients send X-PocketDJ-Profile only when enrolled"],
      ut=["CredentialsSyncTest: blank-guard both directions, deterministic encode", "DiagKeySyncTest: non-empty + changed only", "ProfileHeaderTest: header presence"],
      emu=["Enter rip token on device A (emulator), sync, wipe B's token, sync → B gets the token; blank B's token and sync → A keeps its token"]),

    P("SVC-11", "services", src=["STEM-1"], partial=["DMX-1"],
      title="Cloud stems client (stemify/stem jobs) + burned stems/beat-grids pull + Stemify action on the collection burn bar",
      files=m("data/rips/RipServerClient.kt", "data/rips/RipJobTracker.kt", "data/burns/BurnStems.kt", "data/burns/BurnStore.kt", "data/stems/StemClient.kt", "screens/playlists/CollectionBurnBar.kt")
            + t("data/burns/BurnStemsTest.kt", "data/stems/StemClientTest.kt", "data/rips/StemJobsTrackerTest.kt"),
      deps=["SVC-1", "SVC-2", "SVC-4"], est=1000, prio="P1", rank=16),

    P("SVC-12", "services", src=["CAT-1"],
      title="Catalog cache polish + green compiled-in endpoints pinned by test",
      files=m("data/catalog/CatalogService.kt", "data/catalog/CatalogRepository.kt", "data/config/RemoteEndpoints.kt", "data/config/Endpoints.kt") + t("data/config/EndpointsGreenPinTest.kt", "data/catalog/CatalogCacheTest.kt"),
      deps=[], est=400, prio="P1", rank=10),

    P("SVC-13", "services", src=["RESET-1"], partial=["SET-1"],
      title="Reset everything (FeatureModule.resetHooks orchestrator, iOS mushroom-cloud order) + account deletion",
      files=m("data/reset/AppResetService.kt", "data/reset/AccountDeletionService.kt", "screens/settings/sections/ResetSection.kt", "di/ServicesGraph.kt")
            + t("data/reset/AppResetOrderTest.kt", "data/reset/AccountDeletionTest.kt"),
      deps=["SVC-2", "SVC-7", "SVC-6", "SURF-3"], est=800, prio="P1", rank=38),

    P("SVC-14", "services", src=["BURN-5"],
      title="User-browsable burn folder via SAF (destination captured on the transfer record at enqueue)",
      files=m("data/burns/BurnFolder.kt", "data/transfers/TransferModels.kt", "data/transfers/BurnDownloadWorker.kt", "data/burns/BurnSettings.kt", "screens/settings/StorageScreen.kt")
            + t("data/burns/BurnFolderSafTest.kt", "data/transfers/DestinationCaptureTest.kt"),
      deps=["SVC-3", "SVC-6", "SVC-4"], est=800, prio="P2", rank=92,
      device="Removable media on a real device; emulator verifies the picker + internal tree URIs."),

    P("SVC-15", "services", partial=["DISC-1", "WB-1", "REC-7", "FAV-2"],
      title="Apple Music Web API client: catalog search, library playlists CRUD, favorites, artists latest release; dev + user token plumbing",
      goal="Decision D12. One `AppleMusicApi` over OkHttp + kotlinx.serialization with the developer token (MusicKitDeveloperTokenClient) and Music-User-Token (MusicKitAuth) headers, typed endpoints for catalog search (songs|albums, storefront), library playlists (list/create/add tracks/remove), favorites (rate/unrate), artists latest releases; 401/403 → NeedsUserToken, 429 backoff, paging cursors; MockWebServer tests. Consumers: BRW-15, COL-8, COL-9, COL-11, BRW-14.",
      files=m("data/applemusic/AppleMusicApi.kt", "data/applemusic/AppleMusicApiModels.kt", "data/applemusic/AppleMusicTokens.kt")
            + t("data/applemusic/AppleMusicApiTest.kt", "data/applemusic/AppleMusicApiModelsTest.kt"),
      deps=["SURF-1"], est=800, prio="P1", rank=18,
      acc=["Every endpoint used by its consumers has a MockWebServer test for success, 401 and 429; the user-token header is attached only when present"],
      ut=["AppleMusicApiTest: request shape per endpoint, error mapping, paging", "AppleMusicApiModelsTest: lenient decode of real response fixtures"],
      emu=["Catalog search returns results with the dev token on the emulator; library calls report NeedsUserToken without a signed-in MUT"],
      device="Library (write) endpoints need a real Music-User-Token from the vendored auth AAR."),
]

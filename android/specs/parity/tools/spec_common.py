"""Shared helpers + cross-area decisions + N/A list for the Android parity roadmap.

The roadmap is authored as Python data (spec_*.py), built by build_roadmap.py into
../roadmap.json, and verified by check_roadmap.py.  Keeping the authoring source on
disk means a cut session loses nothing: re-run build + check.
"""

M = "android/app/src/main/java/com/levi/pocketdj/"
T = "android/app/src/test/java/com/levi/pocketdj/"
A = "android/app/src/androidTest/java/com/levi/pocketdj/"
R = "android/app/src/main/res/"
TR = "android/app/src/test/resources/"
CPP = "android/app/src/main/cpp/pdjdsp/"
MANIFEST = "android/app/src/main/AndroidManifest.xml"
GRADLE = "android/app/build.gradle.kts"
TOML = "android/gradle/libs.versions.toml"
ARCH_DOC = "docs/ARCHITECTURE-ANDROID.md"


def m(*paths):
    return [M + p for p in paths]


def t(*paths):
    return [T + p for p in paths]


# Files that many areas historically wanted to edit.  The shell foundation package
# (SURF-1) turns each into an extension point; afterwards at most ONE package per
# wave may touch any of them (check_roadmap.py enforces this on top of plain
# per-wave disjointness).
HOT_FILES = [
    M + "MainActivity.kt",
    M + "shell/ShellNavigation.kt",
    M + "navigation/PocketDjDestination.kt",
    M + "di/AppGraph.kt",
    M + "data/settings/AppSettingsStore.kt",
    M + "screens/settings/SettingsScreen.kt",
    M + "screens/settings/SettingsSections.kt",
    MANIFEST,
    GRADLE,
    TOML,
]

AREA_GRAPH = {
    "playback": M + "di/PlaybackGraph.kt",
    "mix": M + "di/MixGraph.kt",
    "studio": M + "di/StudioGraph.kt",
    "games": M + "di/GamesGraph.kt",
    "collections": M + "di/CollectionsGraph.kt",
    "browse": M + "di/BrowseGraph.kt",
    "services": M + "di/ServicesGraph.kt",
    "surfaces": M + "di/ShellGraph.kt",
}

DECISIONS = [
    {
        "id": "D1",
        "title": "One native audio engine story: shared `audio/` core, Kotlin pull-graph on AudioTrack for Mix, Oboe sink + small C++ core for Studio",
        "decision": (
            "A single platform audio layer lives in `com.levi.pocketdj.audio` (package MIX-2): `AudioSink` interface with `AudioTrackSink` (float PCM, "
            "PERFORMANCE_MODE_LOW_LATENCY, dedicated THREAD_PRIORITY_URGENT_AUDIO render thread) and, once the NDK module exists, `OboeSink` (STU-2) — both "
            "pull the same `RenderGraph`/`PcmSource` API; ONE MediaCodec decoder (`Mp3Decoder` + generic `AudioDecoder`), ONE `OfflineRenderer` for JVM/instrumented "
            "tests, ONE `RenderClock`/`FloatRing`/`Voice`/`VoiceGroup` (four stems start on ONE render frame), ONE `AudioDiag`. "
            "Mix DSP engine = Kotlin in-process pull graph (MIX-3 DSP nodes, MIX-4 graph) rendered by `AudioTrackSink`, per-deck time/pitch via Media3 "
            "`SonicAudioProcessor` (public API, media3-common 1.6.1) — no NDK on the Mix path in v1; switching the Mix to `OboeSink` is a one-line sink swap later. "
            "Studio keeps its C++ core (`cpp/pdjdsp`: TinySoundFont SF2 voices, Signalsmith Stretch for OFFLINE stretch, ported TrackFX/MasterFX kernels, "
            "multitrack sum) behind JNI because a playable SoundFont/MIDI latency needs a native data callback; all scheduling, state and musical math stay in Kotlin. "
            "Now Playing's F4 mini-panel + Stem Lock (MIX-18) reuse `Voice` + `Handover` from the Mix graph rather than forking."
        ),
        "why": (
            "The Mix audit proved stems/handover/cue/limiter force an in-process mixer and chose Kotlin+AudioTrack (no NDK); the Studio audit proved SF2 synthesis "
            "needs Oboe. Both are right for their path, but two platform layers would duplicate decode, render-thread discipline (never allocate/lock on the callback), "
            "re-prime-after-route-change and the test renderer. One `AudioSink` contract gives both engines the same substrate and a free upgrade path."
        ),
        "areas": ["mix", "studio", "playback"],
    },
    {
        "id": "D2",
        "title": "One MediaSession, one audio owner: `SessionSwitchboard` arbiter in the playback core; Mix/Studio/games present `TransportOwner` facades",
        "decision": (
            "`PlaybackService` hosts the ONLY MediaSession (upgraded to MediaLibrarySession by SURF-8). PB-2 merges the audit's SessionSwitchboard, SessionPlayerArbiter, "
            "TransportOwner, SetGatedPlayer and FavoriteSeam into `playback/session/`: the engine that last STARTED audio owns the card; a restored-never-sounded engine "
            "is not a remote target; starting one owner pauses the other. The Mix engine does NOT get its own MediaSessionService: `MixSessionPlayer : SimpleBasePlayer` "
            "(MIX-11) implements `TransportOwner` and is handed to the session via `SessionSwitchboard.setOwner`, which also keeps the foreground service alive while the "
            "Mix renders. Apple Music rows use `AppleMusicPlayerAdapter` the same way (PB-8). Game runs ride the sequencer under a run tag (GM-3) — ExoPlayer-only rows."
        ),
        "why": "Playback, Mix and Surfaces audits each described an arbiter; the iOS 'impersonate' rule is one card ever. A second session (the Mix audit's MixService) would break lock-screen, Auto and widget parity and double the manifest/foreground surface.",
        "areas": ["playback", "mix", "surfaces", "games", "studio"],
    },
    {
        "id": "D3",
        "title": "Shell + DI extension points: `FeatureModule` + one sidecar graph per area, settings section registry, per-package settings keys",
        "decision": (
            "SURF-1 (wave 1) creates `shell/FeatureModule.kt` and eight sidecar graphs `di/{Playback,Mix,Studio,Games,Collections,Browse,Services,Shell}Graph.kt`, each "
            "implementing FeatureModule { navEntries, settingsSections, deepLinkHandlers, flushables, resetHooks, syncEntries, rowResolvers, playOutcomeListeners, "
            "periodicWork }. `AppGraph` lists the eight ONCE; `ShellNavigation`, `SettingsScreen`, `DeepLinkDispatcher`, `FlushRegistry`, `AppResetService`, "
            "`SyncRegistry`, `PlaybackController` and `WorkScheduler` consume the aggregated lists. Settings: `AppSettingsStore` becomes a generic typed store over "
            "`PrefKey<T>` objects; every later package declares its keys in its OWN `*Settings.kt` file (e.g. `data/search/SearchSettings.kt`). Result: after wave 1 "
            "no package edits MainActivity, AppGraph, AppSettingsStore, SettingsScreen or PocketDjDestination — they add files and edit only their area's sidecar."
        ),
        "why": "37 audit packages wanted AppGraph, 32 AppSettingsStore, 15 MainActivity, 15 the Manifest. With ≤6 packages per wave and a one-editor-per-hot-file rule that would have serialized the whole program; registries make the hot files write-once.",
        "areas": ["surfaces", "playback", "mix", "studio", "games", "collections", "browse", "services"],
    },
    {
        "id": "D4",
        "title": "Hot-file budget: build files, Manifest and permissions are swept once in wave 1; later edits only for NDK, a vendored AAR and background location",
        "decision": (
            "SURF-1 adds every planned dependency to the version catalog in one pass (work-runtime-ktx + work-testing, lifecycle-process, security-crypto, glance-appwidget, "
            "material3-adaptive-navigation-suite, media3-common, play-services-location, compose foundation DnD, mockwebserver) and declares in the Manifest: "
            "RECORD_AUDIO, POST_NOTIFICATIONS, FOREGROUND_SERVICE_DATA_SYNC, FOREGROUND_SERVICE_MEDIA_PLAYBACK, BLUETOOTH_CONNECT/SCAN, a FileProvider with a broad "
            "`res/xml/file_paths.xml`, an empty `res/xml/shortcuts.xml` meta-data, and `buildConfigField DIAG_CHANNEL`. Remaining Manifest editors: SURF-2 (Application "
            "class), SURF-4 (deep-link/file-open intent filters incl. the parked pocketdj://mwf route), SURF-7 (widget receiver), SURF-8 (Android Auto), COL-20 "
            "(location permissions). Remaining Gradle editors: STU-2 (externalNativeBuild/Oboe/abiFilters), BRW-17 (ShazamKit AAR). Everything else adds files."
        ),
        "why": "Each hot-file edit costs a whole wave slot and is the most frequent merge conflict in parallel agent work; declaring permissions early is harmless and FileProvider/shortcut resources can be empty placeholders.",
        "areas": ["surfaces", "studio", "browse", "collections", "services"],
    },
    {
        "id": "D5",
        "title": "ONE offline downloads/burn store (`data/burns` + `data/transfers`), WorkManager-backed, shared by Playback, Mix, Studio and Storage",
        "decision": (
            "Mix DL-1 and Services BURN-1/XFER-1 merge into SVC-2 (BurnStore core: iOS `pocketdj-burns.json` v1 ledger, byte-identical descriptive file names, sidecar, "
            "all-4-or-nothing stems `stem-<id>-<part>.mp3`, beat-grid sidecars `analysis-<id>.json`, reconcile, eviction planner, in-process serial loop) and SVC-3 "
            "(TransferCoordinator over WorkManager: records persisted BEFORE enqueue, foreground progress notification, bearer policy, .part + atomic rename, "
            "rip-reconcile periodic worker). Burns live app-private under `filesDir/burns/` behind a single `BurnFolder` root resolver; the SAF user folder is SVC-14. "
            "Mix's `MixStreamLoader` (MIX-6) adopts finished streams into the SAME store; Studio's `LocalAudioCache` (STU-3) is a thin façade over BurnStore for "
            "rip/cut/stem files; `StorageService` categories BURNS/STEMS/MIX_STREAM_CACHE/MIX_SESSIONS/STUDIO come from it."
        ),
        "why": "Two ledgers for the same mp3s would double disk use and break the iOS invariant that a burn is one file with one owner; WorkManager (not DownloadManager) because workers must write app-private storage and survive process death.",
        "areas": ["services", "mix", "studio", "playback"],
    },
    {
        "id": "D6",
        "title": "Persistence: JSON documents with iOS file + field names verbatim, one `VersionedJsonWriter`, DataStore for prefs, Keystore `SecretStore` for every secret, no Room",
        "decision": (
            "Every document (collections v7, activity, play-history, play-stats, playback-session v1, mix-decks v1, mix-sessions v2, burns v1, transfers, studio v1, "
            "scoreboard, onboarding marker, widget snapshot) keeps the iOS file name and CodingKeys so the S3 profile sync can union them across platforms; all "
            "additive-optional, `PdjJson.lenient`, atomic temp+rename. COL-2 ships the shared `data/store/VersionedJsonWriter.kt` (monotonic version, off-main, "
            "`invalidate(through:)` seam) which MIX-1, PB-4 and STU-1 reuse. Non-secret prefs stay in Preferences DataStore via `PrefKey<T>`. ALL secrets "
            "(rip token, jukebox token, Music-User-Token, aoss search creds, diag key, profile secret) live in `data/credentials/SecretStore.kt` "
            "(EncryptedSharedPreferences, one-shot migration that blanks the DataStore copies) created in SURF-1; the audits' SecretBox, DiagCredentialStore and "
            "DiagKeyStore are folded into it."
        ),
        "why": "Three audits each invented a Keystore wrapper and two invented a versioned writer; the sync engine needs one reload/invalidate seam per store, not per author.",
        "areas": ["collections", "mix", "playback", "studio", "services", "browse", "games"],
    },
    {
        "id": "D7",
        "title": "Profile sync without CloudKit: verbatim `CloudSyncService` port over `CloudDocDatabase`, backed by S3 through the first-party `pocketdj-profile-sync` Lambda; link-a-device by QR/code; owner gates become per-install opt-ins",
        "decision": (
            "SVC-7 ports the iOS whole-document LWW engine unchanged (2 s skew, `.pre-cloud` backup, watermarks, merge-on-reload, meta-probed pushDirty, onboarding push "
            "gate, 8 s launch deadline) against an in-memory database; SVC-8 ships the Lambda (S3 `profiles/<profileId>/<key>.json`, HMAC profile secret, optional "
            "remote-endpoint key `profileSyncBase` — absent ⇒ sync disabled); SVC-9 adds `S3CloudDocDatabase`, enrollment and link-a-device (QR/code) which also "
            "replaces onboarding stage 1's iCloud branch ('Use on this device' / 'Link a device'). Synced docs register through `FeatureModule.syncEntries`. "
            "Collections' same-named SYNC-1 is a different thing (source-playlist reconcile) and becomes COL-7. The iOS owner gate (iCloud userRecordID hash) is N/A: "
            "favorites two-way sync (COL-11) and the owner-seed are per-install opt-ins defaulting OFF."
        ),
        "why": "The engine is already pure over the database interface and unit-tested; only the backend changes. Keeping doc shapes identical means iOS and Android profiles merge with no migration.",
        "areas": ["services", "collections", "surfaces", "games", "browse"],
    },
    {
        "id": "D8",
        "title": "One diagnostics stack (`diag/` + `net/SigV4.kt`) in wave 2; channel gate = BuildConfig.DEBUG || DIAG_CHANNEL",
        "decision": (
            "PB-9, DIAG-1 and DBG-1 merge into SVC-5: DiagLog (ring buffer, 500-line parts, 40k cap, 15 s/3 s flush, buffered-until-key), NPLog lanes with the iOS "
            "grammar so scripts/deadair-report.py reads `android-<id8>` logs unchanged, hand-rolled SigV4 PUT over OkHttp (shared `net/SigV4.kt`, also used by online "
            "search BRW-5), `.pdjdiagkey` import (env/account pairing check), JankWatchdog, Settings ▸ Debug screen + upload status. Release builds never upload."
        ),
        "why": "Every later playback/mix/studio package logs through it, so it must exist before PB-1; three copies of SigV4 and the debug screen were specified.",
        "areas": ["services", "playback", "surfaces", "browse"],
    },
    {
        "id": "D9",
        "title": "History outcomes (SkipTracker, PlayEvent additive fields, progress events, game/mix sources) are ONE package: PB-5",
        "decision": (
            "HIST-1 (browse), PB-5 (playback) and GAMES-6 (games) specified the same contract three times. PB-5 owns `playback/outcome/SkipTracker.kt`, the PlayEvent "
            "fields `wasSkipped`, `listenedFraction`, `tzOffsetMin`, `originInstallId`, `originCollectionId` (iOS JSON keys; `carPlay`/`listeningContext` reserved, "
            "never renamed), `PlayProgress`/`PlayAdvancedAway`/`PlayStopped` events on PlayEventBus, `markSkipped`/`noteListened` max-merge, the `PlaySource.GAME`/"
            "`PlayContext.game(runTag,label)` and `PlaySource.MIX` tokens, and the `PlayOutcomeListener` registry. History UI (BRW-6), hide-skips (BRW-2), In the Pocket "
            "(GM-7), listening pockets (COL-17), play-stats (SVC-6) and the Mix bridge (MIX-16) depend on it."
        ),
        "why": "The rule must live in one place (strict <0.5 skip, high-water position, one-deep previous stash) and the recording site must stay single (the sequencer/service).",
        "areas": ["playback", "browse", "games", "collections", "services", "mix"],
    },
    {
        "id": "D10",
        "title": "Id collisions and duplicates resolved",
        "decision": (
            "SYNC-1(collections)→COL-7 source-sync; SYNC-1(services)→SVC-7 cloud docs. ONB-1(services)+ONB-1(surfaces)→SURF-3. LP-1(browse) folded into COL-16/17/18 "
            "(models+client / service+opt-in+PocketsBridge impl / History ▸ Pockets UI). DL-1→SVC-2+SVC-3; BURN-2→SVC-4. LOCK-1 + MIX-6's AudioOwnerArbiter→PB-2 "
            "(resumption provider→PB-4). PB-9+DIAG-1+DBG-1→SVC-5. HIST-1+GAMES-6→PB-5. LYR-1→BRW-4. RA-1 absorbs HIST-3's recently-added derivation→COL-12; HIST-3 keeps "
            "the collection timeline→BRW-7. IO-1+SET-2 codecs→COL-14; IO-2+SET-2 UI→COL-15. SET-1 registry→SURF-1, SET-1 rows→SURF-6, SET-1 reset→SVC-13 "
            "(with RESET-1). SRCH-1 SecretBox + diag credential stores→SecretStore (SURF-1). GAMES-4's AddToCollectionSheet params→COL-4. GAMES-5 owns "
            "`data/pockets/PocketsModels.kt`; COL-16 extends it. DMX-1's StemClient→SVC-11. EXPL-1 owns IndexSong.dateAdded/streaming links; RA-1 consumes. "
            "The Apple Music Web API client (search, library playlists, favorites, artists) specified inside DISC-1, WB-1, REC-7 and FAV-2 is split out as SVC-15. "
            "Studio's RipsModels additive fields and Mix's stems/beat-grid manifest fields are owned by SVC-1."
        ),
        "why": "Every non-duplicate package is kept and every fold is recorded in source_ids so nothing in the audits is lost silently.",
        "areas": ["playback", "mix", "studio", "games", "collections", "browse", "services", "surfaces"],
    },
    {
        "id": "D11",
        "title": "Playback core first: sequencer owns the queue, ExoPlayer holds a 1–2 row window, zero-dead-air discipline before any surface",
        "decision": (
            "PB-1 (SetlistSequencer, per-row resolve ladder, `RowResolverRegistry`, `playUrl` seam for jukebox Tune-In, `appendRows(runTag)` for games) lands in wave 3, "
            "PB-2 (session transport + arbiter) wave 4, PB-3 (runway/watchdogs/stall hop/cascade breaker/rip window/live backstop/supervisor/DeadAirMeter) and PB-6 "
            "(Now Playing deck + mini bar) wave 5. Android never fires passive stream-through rips; rip-on-demand inside a run is explicit per row, gated by the "
            "rip-ahead window (playing + next 10) with /rip-cancel on eviction; interactive ▶ waits ≤20 s then returns StillRipping (SVC-1). Pause discrimination "
            "comes from Media3 change reasons, never timing heuristics. The 30 s preview rung never appears inside a sequencer run."
        ),
        "why": "The task orders foundations → playback/Now Playing → P0 parity; the iOS dead-air program is the app's core guarantee and every surface (lock screen, Auto, widgets, games, jukebox) drives the sequencer.",
        "areas": ["playback", "services", "surfaces", "games"],
    },
    {
        "id": "D12",
        "title": "Apple Music on Android: vendored MusicKit AARs for sign-in + DRM full-track (device-only), one REST client for everything else",
        "decision": (
            "SVC-15 `data/applemusic/AppleMusicApi.kt` wraps the Apple Music REST API with the developer token Android already mints plus the Music-User-Token from the "
            "vendored auth AAR: catalog search (Discover, BRW-15), library playlists CRUD (write-back COL-8, playlist sync COL-9), favorites (COL-11), artists/latest "
            "releases (BRW-14). Full-track playback stays on the vendored mediaplayback AAR via `AppleMusicPlayerAdapter` (PB-8) and is device-only; 30 s previews are "
            "the emulator path. rip-server and jukebox HTTP APIs are unchanged."
        ),
        "why": "Four packages each specified a partial REST client; MusicKit-for-Android has no search/library API worth vendoring; iOS itself does write-back over the Web API.",
        "areas": ["services", "browse", "collections", "playback"],
    },
    {
        "id": "D13",
        "title": "Catalog stays CloudFront offline-first; compiled-in endpoints = green account; remote-endpoint config may add keys only",
        "decision": "SVC-12 pins `config/endpoints.green.json` by JVM test (blue account deleted 2026-10-15), keeps disk-cache-first + conditional refresh, and adds the optional `profileSyncBase`/`diagBucket` keys read at request time so an account move never needs a release.",
        "why": "Locked decision + the AWS migration memory; every network package reads RemoteEndpoints at call time.",
        "areas": ["services", "browse", "playback"],
    },
    {
        "id": "D14",
        "title": "Verification doctrine per package: JVM parity fixtures copied verbatim from iOS, emulator AVD `pocketdj` drive, explicit device-only list, test COUNT must move",
        "decision": "Every package carries unit_tests (JVM, iOS fixtures under src/test/resources), emulator_steps (headless AVD pocketdj, API 36, `-no-audio`: transport/state verified through diag heartbeat lines and OfflineRenderer probes) and a device_only string. Acceptance for every package includes 'the JVM test count increased by the package's new tests' (the XcodeGen zero-tests trap applies to Gradle too) and 'docs/ARCHITECTURE-ANDROID.md status ledger row updated'.",
        "why": "Memory: exit 0 with zero tests run has shipped broken builds before; the living doc is the program's source of truth.",
        "areas": ["playback", "mix", "studio", "games", "collections", "browse", "services", "surfaces"],
    },
    {
        "id": "D15",
        "title": "Games placement and game-run playback",
        "decision": "Games is the 7th destination registered through the nav registry (compact width: labels on the selected item only); engines live in the GamesGraph sidecar; game runs append ExoPlayer-only rows (manifest streams, 30 s previews for appleMusicId songs) to the sequencer under a run tag and never the native AM full-track engine; MwF ships without push (4 s poll is the source of truth); In the Pocket runs time-only until COL-19/20 ship the location engine.",
        "why": "Keeps queue-index ownership in the sequencer and matches the Games audit's hard-won rules.",
        "areas": ["games", "playback", "surfaces", "collections"],
    },
]

NA_ON_ANDROID = [
    {"feature": "CloudKit whole-document LWW sync, `reloadFromDisk` via CloudKit, iCloud credential sync, iCloud owner gate (userRecordID hash)", "reason": "Locked: NO CloudKit. Replaced by the S3 profile-sync Lambda (D7); owner gate becomes a per-install opt-in; document shapes unchanged so iOS and Android profiles still merge."},
    {"feature": "Apple play-count baseline (PlayCountService / AMPlayBaselineStore)", "reason": "Needs MusicKit library play counts, unavailable to the Android SDK; 'Plays' on Android = local PlayHistoryStore + PlayStatsStore counts only."},
    {"feature": "Passive stream-through rip on Apple Music play + lazy edition rip", "reason": "Android has no catalog-owner identity; specs/playback.md §3 rules rip fires only on explicit ▶. Rip-on-demand inside a run stays explicit and window-gated."},
    {"feature": "AM-sync 3-strike removal confirmation", "reason": "Lives in the iMac indexer (pending-removals.json); clients only see the confirmed catalog."},
    {"feature": "FoundationModels LLM tie-break in SongDuplicateJudge; on-device 'Create Pocket' intent", "reason": "No on-device Apple Foundation Models; deterministic tiers only."},
    {"feature": "On-device speech transcription for Demux lyrics", "reason": "Android SpeechRecognizer is mic-only; Demux shows the cloud faster-whisper sidecar (equal to iOS default gate-off)."},
    {"feature": "CLVisit-based listening places", "reason": "No visit API; ported pure ListeningPlaceEngine is fed by a fused low-power dwell detector (COL-19/20), default OFF."},
    {"feature": "APNs push for Music with Friends (+ NotificationRouter)", "reason": "Broker speaks APNs only; FCM would need Firebase in app + broker change. The 4 s poll is the source of truth on iOS too."},
    {"feature": "CarPlay, tvOS, visionOS, macOS shells (TVRootView, TV Mix, two-deck CarPlay Mix, Buffering… detail text)", "reason": "Android Auto (SURF-8/9) is the CarPlay analogue; no Android TV/XR target in the locked decisions."},
    {"feature": "Multi-window ⌘N, keyboard shortcuts (⌘1–⌘7, ⌘B/H/P/J, ⇧⌘R/A), macOS toolbar/right-click traps, focus cursor, shadow buttons", "reason": "Desktop/iPad affordances; Android keeps resizeableActivity for split-screen only."},
    {"feature": "App Intents / Siri / Spotlight donations (IntentServices)", "reason": "Mapped instead to Assistant MEDIA_PLAY_FROM_SEARCH + static/dynamic shortcuts via ShellActions (SURF-5); no Spotlight analogue."},
    {"feature": "WidgetKit App Group snapshot + Live Activities", "reason": "Glance widgets fed by a file-backed snapshot with the iOS key names (SURF-7)."},
    {"feature": "Security-scoped bookmarks for user folders", "reason": "SAF persistable tree URIs (SVC-14, Studio folders) with the same 'unreachable ⇒ skip' semantics."},
    {"feature": "AirPlay external-playback guard (allowsExternalPlayback=false)", "reason": "No AirPlay; Cast is out of scope."},
    {"feature": "Background URLSession download analogue", "reason": "WorkManager CoroutineWorkers with foreground progress (D5)."},
    {"feature": "AVAudioUnitTimePitch quality on extreme stretch", "reason": "Media3 Sonic is a notch below beyond ±25 %; Auto-DJ glide ≤10 % and Sync ≈ ±15 % are clean. Recorded as resolved open question #1 in ARCHITECTURE-ANDROID.md."},
    {"feature": "Loop files as .caf", "reason": "Studio loops are LPCM .wav on Android (documented divergence)."},
    {"feature": "TestFlight receipt as the diag channel gate", "reason": "BuildConfig.DEBUG || DIAG_CHANNEL internal flag; release builds never upload."},
    {"feature": "XCUITest fixture seams (PDJ_USE_FIXTURE, PDJ_SEED_*)", "reason": "Stores take injectable File paths for JVM tests; debug-only intent-extra seeds replace PDJ_SEED_* for emulator drives."},
    {"feature": "Star map / constellations", "reason": "PWA-only feature; no iOS parity gap."},
    {"feature": "Explicit-system owner-only edition rips", "reason": "Edition choice is client-side (BRW-3); rips of a missing edition are explicit ▶ only."},
]

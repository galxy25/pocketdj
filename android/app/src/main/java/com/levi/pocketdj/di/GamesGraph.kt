package com.levi.pocketdj.di

import android.content.Intent
import com.levi.pocketdj.data.games.GameScoreboardStore
import com.levi.pocketdj.data.games.GamesPrefs
import com.levi.pocketdj.data.games.friends.MusicWithFriendsStore
import com.levi.pocketdj.data.games.friends.MwFClient
import com.levi.pocketdj.data.games.friends.MwFHost
import com.levi.pocketdj.data.games.friends.MwFJoinSecret
import com.levi.pocketdj.data.games.friends.MwFKeyValue
import com.levi.pocketdj.data.games.friends.MwFQueueSink
import com.levi.pocketdj.data.games.friends.MwFSessionFile
import com.levi.pocketdj.playback.RunItem
import com.levi.pocketdj.playback.sequencer.QueueItem
import com.levi.pocketdj.shell.DeepLinkHandler
import com.levi.pocketdj.shell.FeatureModule
import com.levi.pocketdj.shell.ResetHook
import com.levi.pocketdj.shell.SyncEntry
import com.levi.pocketdj.data.catalog.IndexAlbum
import com.levi.pocketdj.data.catalog.IndexSong
import com.levi.pocketdj.data.collections.AddTarget
import com.levi.pocketdj.data.config.EndpointKey
import com.levi.pocketdj.data.config.RemoteEndpoints
import com.levi.pocketdj.data.games.inthepocket.InThePocketAudio
import com.levi.pocketdj.data.games.inthepocket.InThePocketRoundsClient
import com.levi.pocketdj.data.games.inthepocket.InThePocketScorer
import com.levi.pocketdj.data.games.inthepocket.InThePocketStore
import com.levi.pocketdj.data.pockets.ListeningPocketsResults
import com.levi.pocketdj.data.pockets.NoPocketsBridge
import com.levi.pocketdj.data.pockets.PocketsBridge
import com.levi.pocketdj.data.pockets.PocketsCredentials
import kotlinx.coroutines.delay
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.asStateFlow
import com.levi.pocketdj.data.games.puzzle.CollectorsPuzzleEngine
import com.levi.pocketdj.data.games.puzzle.CollectorsPuzzleEnv
import com.levi.pocketdj.data.games.puzzle.PuzzleDecisionStore
import com.levi.pocketdj.data.games.puzzle.PuzzleSettingsPersistence
import com.levi.pocketdj.data.history.PlayEvent
import com.levi.pocketdj.data.history.PlayHistoryStore
import com.levi.pocketdj.data.rips.RipManifestEntry
import com.levi.pocketdj.playback.GameRunPlayer
import com.levi.pocketdj.playback.GamePreviewResolver
import com.levi.pocketdj.playback.GamePreviewRowResolver
import com.levi.pocketdj.playback.SequencerGameRunPlayer
import java.io.File
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.SupervisorJob
import kotlinx.coroutines.launch

/**
 * Sidecar graph for the games area (decision D3). GM-1 contributes the scoreboard store
 * (`pocketdj-game-scores.json`, union-synced), its "Reset everything" hook and the debug
 * `-e pdj.seedGames true` fixture seed. Later game packages add their lazies here.
 */
class GamesGraph(private val app: AppGraph) : FeatureModule {
    override val area: String = "games"

    val scoreboard: GameScoreboardStore by lazy {
        GameScoreboardStore(File(app.appContext.filesDir, GamesPrefs.SCOREBOARD_FILE))
    }

    /** Main-thread scope for engine mutations (iOS @MainActor equivalent); survives screen pops. */
    private val mainScope = CoroutineScope(SupervisorJob() + Dispatchers.Main.immediate)

    /** The Gem Collector decision log (`pocketdj-puzzle-decisions.json`, the recs training signal). */
    val puzzleDecisions: PuzzleDecisionStore by lazy {
        PuzzleDecisionStore(File(app.appContext.filesDir, PUZZLE_DECISIONS_FILE), mainScope)
    }

    private val previewResolver: GamePreviewResolver by lazy {
        GamePreviewResolver(
            localPlayable = { id -> env.ripManifest().containsKey(id) || id in env.burnedIds() },
            appleMusicId = { id -> app.catalogRepository.state.value.catalog?.songsById?.get(id)?.appleMusicId },
            previewUrl = { amId -> app.appleMusicPreviewResolver.previewUrl(amId) },
            canPlayFullTrack = { app.playbackController.canPlayFullTrackWarming() },
        )
    }

    /** The audio surface the timed games drive: the shared sequencer under a run tag. */
    val gameRunPlayer: GameRunPlayer by lazy {
        // Game rows that no rip/burn rung claimed ride the full-track Apple Music rung when capable, else cached 30 s AM previews (also the fallback if AM fails to start).
        runCatching { app.playbackGraph.rowSourceResolvers.register(GamePreviewRowResolver(previewResolver)) }
        app.playbackController.gamePreviewUrl = { id -> previewResolver.urlFor(id) }
        SequencerGameRunPlayer(app.playbackGraph.sequencer, previewResolver, app.appScope)
    }

    private val env: CollectorsPuzzleEnv = object : CollectorsPuzzleEnv {
        private val catalog get() = app.catalogRepository.state.value.catalog
        override fun songs(): List<IndexSong> = catalog?.songs.orEmpty()
        override fun albumsById(): Map<String, IndexAlbum> = catalog?.albumsById.orEmpty()
        override fun favoriteIds(): Set<String> = app.collectionsGraph.favorites.favoriteIds
        override fun playCounts(): Map<String, Int> =
            PlayHistoryStore.get(app.appContext).events.groupingBy { it.songId }.eachCount()
        override fun memberIds(collectionId: String): List<String> =
            if (collectionId.startsWith("pkt_")) app.collections.songIdsForPocket(collectionId)
            else app.collections.songIdsForPlaylist(collectionId)
        override fun collectionExists(collectionId: String): Boolean =
            app.collections.pocket(collectionId) != null || app.collections.playlist(collectionId) != null
        override fun collectionName(collectionId: String): String? =
            app.collections.pocket(collectionId)?.name ?: app.collections.playlist(collectionId)?.name
        override fun addSong(songId: String, target: AddTarget) = app.collections.addSong(songId, target)
        override fun stillContains(songId: String, target: AddTarget): Boolean = when (target.kind) {
            AddTarget.Kind.POCKET -> app.collections.pocket(target.id)?.songIds?.contains(songId) ?: false
            AddTarget.Kind.PLAYLIST -> app.collections.playlistContains(target.id, songId)
        }
        override fun ripManifest(): Map<String, RipManifestEntry> = app.ripsRepository.manifest.value
        override fun burnedIds(): Set<String> = runCatching {
            app.servicesGraph.burnStore.items.value.filterValues {
                it.state == com.levi.pocketdj.data.burns.BurnState.READY
            }.keys
        }.getOrDefault(emptySet())
        override fun lastPlayedMs(): Map<String, Double> {
            val out = HashMap<String, Double>()
            for (e in PlayHistoryStore.get(app.appContext).events) {
                if (e.playedAt > (out[e.songId] ?: 0.0)) out[e.songId] = e.playedAt
            }
            return out
        }
        override fun playHistory(): List<PlayEvent> = PlayHistoryStore.get(app.appContext).events
        override fun allCollectionMemberships(): List<List<String>> =
            app.collections.pockets.map { app.collections.songIdsForPocket(it.id) } +
                app.collections.playlists.map { app.collections.songIdsForPlaylist(it.id) }
    }

    /** Last-used round settings (iOS `pdj.puzzle.settings.v1`), in a tiny SharedPreferences file. */
    private val settingsPersistence = object : PuzzleSettingsPersistence {
        private val prefs get() = app.appContext.getSharedPreferences("pdj-puzzle", android.content.Context.MODE_PRIVATE)
        override fun load(): String? = runCatching { prefs.getString(PUZZLE_SETTINGS_KEY, null) }.getOrNull()
        override fun save(json: String) {
            runCatching { prefs.edit().putString(PUZZLE_SETTINGS_KEY, json).apply() }
        }
    }

    /** The app-scoped Gem Collector engine (a running round survives tab switches). */
    val puzzleEngine: CollectorsPuzzleEngine by lazy {
        CollectorsPuzzleEngine(
            env = env,
            player = gameRunPlayer,
            scoreboard = scoreboard,
            decisions = puzzleDecisions,
            persistence = settingsPersistence,
            scope = mainScope,
        )
    }

    // ---- In the Pocket (GM-7) ----

    /** Real-service seam state: bridge + opt-in arrive asynchronously from CollectionsGraph.startListeningPockets(). */
    private val bridgeHolder = PocketsServiceHolder()

    /**
     * The real listening-pockets bridge, assigned by CollectionsGraph.startListeningPockets() (debug and
     * release alike; there is no stub path). Null until then: screens show a loading state.
     */
    var servicesBridge: PocketsBridge?
        get() = bridgeHolder.bridge.value
        set(value) {
            bridgeHolder.bridge.value = value
            // The store registered its rounds provider on whatever bridge existed at construction;
            // the real service needs it too.
            value?.roundsProvider = { installId -> inThePocket.uploadWires(installId) }
        }

    /** Observable mirror of [servicesBridge]: a screen opened before the async wiring recomposes onto it. */
    val servicesBridgeFlow: StateFlow<PocketsBridge?> get() = bridgeHolder.bridge

    /** Never null: [NoPocketsBridge] (disabled, never networks) until the real bridge is wired. */
    val pocketsBridge: PocketsBridge
        get() = servicesBridge ?: NoPocketsBridge

    /** The real Settings-backed handler, assigned asynchronously by CollectionsGraph.startListeningPockets(). */
    var servicesOptIn: com.levi.pocketdj.screens.games.PocketsOptIn?
        get() = bridgeHolder.optInTarget
        set(value) { bridgeHolder.setOptIn(value) }

    /** Stable proxy: screens capture THIS once; a choice made before the real handler exists is replayed onto it. */
    val pocketsOptIn: com.levi.pocketdj.screens.games.PocketsOptIn get() = bridgeHolder.optIn

    /** Rounds upload half (acks in `pocketdj-in-the-pocket-sync.json`). */
    val roundsClient: InThePocketRoundsClient by lazy {
        InThePocketRoundsClient(
            http = app.httpClient,
            baseUrl = { RemoteEndpoints.url(EndpointKey.LISTENING_POCKETS_BASE) },
            syncFile = File(app.appContext.filesDir, ROUNDS_SYNC_FILE),
            deviceId = { runCatching { app.settings.ensureInstallId() }.getOrNull() },
        )
    }

    private val roundsUploadJob = java.util.concurrent.atomic.AtomicReference<kotlinx.coroutines.Job?>(null)

    /** 5 s debounce, then upload finished rounds (gated on the bridge's privacy switch). */
    private fun scheduleRoundsUpload() {
        val bridge = pocketsBridge
        // A real service that uploads rounds inside its own flush (after plays) owns the timing.
        if (!bridge.isEnabled.value || bridge.flushesRounds) return
        val job = app.appScope.launch(Dispatchers.IO) {
            delay(5_000)
            val creds = bridge.credentials() ?: return@launch
            runCatching { roundsClient.flush(creds, inThePocket.uploadWires(bridge.installId), bridge.installId) }
        }
        roundsUploadJob.getAndSet(job)?.cancel()
    }

    /** The app-scoped In the Pocket store (a running round survives tab switches). */
    val inThePocket: InThePocketStore by lazy {
        InThePocketStore(
            history = PlayHistoryStore.get(app.appContext),
            scoreboard = scoreboard,
            player = gameRunPlayer,
            file = File(app.appContext.filesDir, InThePocketStore.FILE_NAME),
            bridgeProvider = { pocketsBridge },
            scope = app.appScope,
        ).also { st ->
            st.appVersion = runCatching {
                app.appContext.packageManager.getPackageInfo(app.appContext.packageName, 0).versionName
            }.getOrNull()
            st.catalogSnapshot = {
                val c = app.catalogRepository.state.value.catalog
                (c?.songsById ?: emptyMap()) to (c?.albumsById ?: emptyMap())
            }
            st.audioAvailability = {
                InThePocketAudio(
                    ripIds = app.ripsRepository.manifest.value.keys,
                    burnedIds = env.burnedIds(),
                    canStreamAppleMusic = runCatching { app.settings.current().hasAppleMusic }.getOrDefault(false),
                )
            }
            st.collectionsInput = {
                // Runs inside the build dispatcher (off the UI thread); iOS ListeningPocketsCollections caps.
                val sources = app.collections.pockets.map { Triple(it.id, it.name, app.collections.songIdsForPocket(it.id)) } +
                    app.collections.playlists.map { Triple(it.id, it.name, app.collections.songIdsForPlaylist(it.id)) }
                        .filter { it.third.size <= SONG_CAP } // iOS drops oversized SOURCE playlists
                capCollections(sources)
            }
            st.onRoundsChanged = { pocketsBridge.flushSoon(); scheduleRoundsUpload() }
        }
    }

    // ---- Music with Friends (GM-9) ----

    private val mwfKeyValue = object : MwFKeyValue {
        private val prefs get() = app.appContext.getSharedPreferences("pdj-mwf", android.content.Context.MODE_PRIVATE)
        override fun getString(key: String): String? = runCatching { prefs.getString(key, null) }.getOrNull()
        override fun putString(key: String, value: String?) {
            runCatching { prefs.edit().apply { if (value == null) remove(key) else putString(key, value) }.apply() }
        }
    }

    /** Per-install re-join credential (never the broadcast install id). */
    val mwfJoinSecret: MwFJoinSecret by lazy { MwFJoinSecret(mwfKeyValue) }

    val mwfClient: MwFClient by lazy {
        MwFClient(http = app.httpClient, json = app.json, configProvider = {
            val current = app.settings.current()
            MwFClient.Config(current.jukeboxServerUrl, current.jukeboxToken, app.settings.ensureInstallId())
        })
    }

    private val mwfHost = object : MwFHost {
        private val catalog get() = app.catalogRepository.state.value.catalog
        override fun songs(): List<IndexSong> = catalog?.songs.orEmpty()
        override fun songExists(songId: String): Boolean = catalog?.songsById?.containsKey(songId) == true
        override fun songIdForAppleMusicId(appleMusicId: String): String? =
            catalog?.songs?.firstOrNull { it.appleMusicId == appleMusicId }?.id
        override fun profileName(): String = runCatching { app.servicesGraph.profile.name }.getOrDefault("")
        override fun pocketSongIds(pocketId: String): List<String> = app.collections.songIdsForPocket(pocketId)
        override val queue: MwFQueueSink = object : MwFQueueSink {
            private val seq get() = app.playbackGraph.sequencer
            override val runningSourceTag: String? get() = seq.state.value.sourceSetlistId
            override val isRunning: Boolean get() = seq.state.value.isRunning
            override fun append(item: RunItem) {
                mainScope.launch { seq.appendToQueue(listOf(item.toQueueItem())) }
            }
            override fun play(item: RunItem) {
                mainScope.launch { seq.play(listOf(item.toQueueItem())) }
            }
            private fun RunItem.toQueueItem() = QueueItem(id = songId, title = title, artist = artist, lengthMs = lengthMs)
        }
        override fun createPocket(name: String, songIds: List<String>, description: String?): String =
            app.collections.createPocket(name, songIds, description).id
        override fun pocketExists(pocketId: String): Boolean = app.collections.pocket(pocketId) != null
        override fun addSongToPocket(songId: String, pocketId: String) =
            app.collections.addSongToPocket(songId, pocketId)
    }

    /** App-scoped Music with Friends store (sessions persisted to `pocketdj-mwf-sessions.json`). */
    val friends: MusicWithFriendsStore by lazy {
        MusicWithFriendsStore(
            client = mwfClient,
            sessionFile = MwFSessionFile(File(app.appContext.filesDir, MwFSessionFile.FILE_NAME)),
            kv = mwfKeyValue,
            joinSecret = mwfJoinSecret,
            scoreboard = scoreboard,
            host = mwfHost,
            clientId = { app.settings.ensureInstallId() },
        ).also { it.loadPersisted() }
    }

    init {
        // Warm the store off the main thread so the first Games-tab composition never does disk IO.
        app.appScope.launch(Dispatchers.IO) { runCatching { scoreboard } }
        app.appScope.launch(Dispatchers.IO) { runCatching { friends } }
        // The decision log decodes up to 20k rows on construction: never on the first Gem Collector composition.
        app.appScope.launch(Dispatchers.IO) { runCatching { puzzleDecisions } }
        // A round that was playing when the process went away keeps being tracked.
        app.appScope.launch(Dispatchers.IO) { runCatching { inThePocket.resumeTrackingIfNeeded() } }
    }

    override val resetHooks: List<ResetHook> = listOf(
        ResetHook { scoreboard.clear() },
        // Final review: the per-song decision log (and last-used target collections) must not survive Delete account.
        ResetHook {
            puzzleDecisions.clear()
            runCatching { app.appContext.getSharedPreferences("pdj-puzzle", android.content.Context.MODE_PRIVATE).edit().clear().apply() }
        },
        ResetHook { inThePocket.clearLocal() },
        ResetHook { friends.eraseAll(); mwfJoinSecret.reset() },
    )

    override val syncEntries: List<SyncEntry> =
        listOf(
            SyncEntry(
                GamesPrefs.SCOREBOARD_SYNC_KEY,
                GamesPrefs.SCOREBOARD_FILE,
                onPulled = { scoreboard.reloadFromDisk() },
            ),
            // iOS: cloudSync "puzzle-decisions" (the recs training signal); pull merges by id.
            SyncEntry(
                PUZZLE_DECISIONS_SYNC_KEY,
                PUZZLE_DECISIONS_FILE,
                onPulled = { puzzleDecisions.reloadFromDisk() },
            ),
        )

    /** GM-10: pocketdj://mwf/<id> + https /mwf/<id>/ land on Games (known id pushes, unknown opens Join). */
    val mwfDeepLinks: com.levi.pocketdj.data.games.friends.MwFDeepLinkHandler by lazy {
        com.levi.pocketdj.data.games.friends.MwFDeepLinkHandler(
            openLink = { friends.handleOpenedLink(it) },
            postRoute = com.levi.pocketdj.shell.NavRequestBus::post,
        )
    }

    override val deepLinkHandlers: List<DeepLinkHandler> by lazy { buildDeepLinkHandlers() }

    private fun buildDeepLinkHandlers(): List<DeepLinkHandler> {
        // The dispatcher (ShellGraph) parses/gates links and calls this seam; claim it now so a link
        // parked before the Games area existed is replayed.
        runCatching {
            val shell = app.shellGraph
            mwfDeepLinks.install(shell.deepLinkSeams) { shell.deepLinks.takePendingMwf() }
        }
        return listOf(
        DeepLinkHandler { intent ->
            // Debug alias of CollectionsGraph's `pdj.pocketsEnable`: real Settings writes, no stub.
            if (isDebuggable() && intent.hasExtra(POCKETS_STUB_EXTRA)) {
                val on = parsePocketsEnable(intent.extras?.get(POCKETS_STUB_EXTRA))
                app.appScope.launch(Dispatchers.IO) {
                    runCatching { app.settings.set(com.levi.pocketdj.data.pockets.PocketsSettings.LISTENING_POCKETS_ANSWERED, true) }
                    runCatching { app.settings.set(com.levi.pocketdj.data.pockets.PocketsSettings.LISTENING_POCKETS_ENABLED, on) }
                }
            }
            if (isDebuggable() && wantsSeed(intent)) {
                app.appScope.launch(Dispatchers.IO) { runCatching { scoreboard.seedFixture(replaceExisting = wantsFixture(intent)) } }
            }
            false // never consumes the intent
        },
        )
    }

    companion object {
        // iOS ListeningPocketsCollections caps.
        const val COLLECTION_CAP = 500
        const val SONG_CAP = 5_000
        const val TOTAL_SONG_CAP = 100_000

        /**
         * Mirror of `ListeningPocketsCollections.flattened` (oversized playlists are dropped by the caller):
         * at most [COLLECTION_CAP] collections, [SONG_CAP] songs each, [TOTAL_SONG_CAP] overall.
         */
        internal fun capCollections(
            sources: List<Triple<String, String, List<String>>>,
        ): List<InThePocketScorer.CollectionInfo> {
            var budget = TOTAL_SONG_CAP
            val out = ArrayList<InThePocketScorer.CollectionInfo>()
            for ((id, name, songs) in sources.take(COLLECTION_CAP)) {
                val take = minOf(songs.size, SONG_CAP, maxOf(0, budget))
                budget -= take
                out += InThePocketScorer.CollectionInfo(id, name.ifEmpty { null }, songs.take(take).toSet())
            }
            return out
        }

        /** Shared parse for the debug pockets-enable extras: Boolean true, or the strings "true"/"1". */
        internal fun parsePocketsEnable(v: Any?): Boolean = when (v) {
            is Boolean -> v
            is String -> v == "true" || v == "1"
            else -> false
        }

        const val ROUNDS_SYNC_FILE = "pocketdj-in-the-pocket-sync.json"
        const val POCKETS_STUB_EXTRA = "pdj.pocketsStub"
        const val PUZZLE_DECISIONS_FILE = "pocketdj-puzzle-decisions.json"
        const val PUZZLE_DECISIONS_SYNC_KEY = "puzzle-decisions"
        const val PUZZLE_SETTINGS_KEY = "pdj.puzzle.settings.v1"
    }

    private fun wantsSeed(intent: Intent): Boolean =
        intent.getBooleanExtra(GamesPrefs.SEED_EXTRA, false) ||
            intent.getStringExtra(GamesPrefs.SEED_EXTRA) == "true"

    private fun wantsFixture(intent: Intent): Boolean =
        intent.getBooleanExtra(GamesPrefs.USE_FIXTURE_EXTRA, false) ||
            intent.getStringExtra(GamesPrefs.USE_FIXTURE_EXTRA) == "true"

    private fun isDebuggable(): Boolean =
        (app.appContext.applicationInfo.flags and android.content.pm.ApplicationInfo.FLAG_DEBUGGABLE) != 0
}

/**
 * The async-wired pockets seam, pure so it is JVM-testable: an observable bridge (null = still loading)
 * and a stable [PocketsOptIn] proxy that buffers a choice made before the real handler is assigned.
 */
class PocketsServiceHolder {
    val bridge = MutableStateFlow<PocketsBridge?>(null)

    @Volatile var optInTarget: com.levi.pocketdj.screens.games.PocketsOptIn? = null
        private set
    private var pendingChoice: Boolean? = null
    private val lock = Any()
    /** Observable mirror of the target's flag (false until wired): a collector sees a later-wired target. */
    private val recsMirror = MutableStateFlow(false)
    private val recsScope = kotlinx.coroutines.CoroutineScope(kotlinx.coroutines.SupervisorJob() + kotlinx.coroutines.Dispatchers.Unconfined)
    private var recsJob: kotlinx.coroutines.Job? = null

    val optIn: com.levi.pocketdj.screens.games.PocketsOptIn = object : com.levi.pocketdj.screens.games.PocketsOptIn {
        override val recommendationsEnabled: StateFlow<Boolean> get() = recsMirror.asStateFlow()
        override fun choose(on: Boolean) {
            val target = synchronized(lock) {
                optInTarget ?: run { pendingChoice = on; null }
            }
            target?.choose(on)
        }
    }

    fun setOptIn(value: com.levi.pocketdj.screens.games.PocketsOptIn?) {
        val replay = synchronized(lock) {
            optInTarget = value
            if (value != null) pendingChoice.also { pendingChoice = null } else null
        }
        recsJob?.cancel()
        recsJob = if (value == null) null.also { recsMirror.value = false } else recsScope.launch {
            value.recommendationsEnabled.collect { recsMirror.value = it }
        }
        if (replay != null) value?.choose(replay)
    }
}

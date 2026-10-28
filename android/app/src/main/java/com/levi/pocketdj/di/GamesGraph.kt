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
        )
    }

    /** The audio surface the timed games drive: the shared sequencer under a run tag. */
    val gameRunPlayer: GameRunPlayer by lazy {
        // Game rows that no rip/burn rung claimed ride as cached 30 s AM previews (ExoPlayer only).
        runCatching { app.playbackGraph.rowSourceResolvers.register(GamePreviewRowResolver(previewResolver)) }
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

    /** Debug stub gate (`-e pdj.pocketsStub true`): enabled + empty results, never networks. */
    private val stubEnabled = MutableStateFlow(false)

    private val debugBridge = object : PocketsBridge {
        override val isEnabled: StateFlow<Boolean> = stubEnabled.asStateFlow()
        override val results: StateFlow<ListeningPocketsResults?> = MutableStateFlow(ListeningPocketsResults.EMPTY)
        override suspend fun refreshIfStale() = Unit
        override fun flushSoon() = Unit
        override var roundsProvider: ((String) -> List<com.levi.pocketdj.data.games.inthepocket.InThePocketRoundWire>)? = null
        override suspend fun credentials(): PocketsCredentials? = null
        override val installId: String get() = PlayHistoryStore.get(app.appContext).installId
    }

    /**
     * The listening-pockets service seam. The services wave assigns a real bridge here BEFORE the
     * first [inThePocket] access; until then it is [NoPocketsBridge] (debug builds: a stub that the
     * `pdj.pocketsStub` extra turns on).
     */
    @Volatile var servicesBridge: PocketsBridge? = null
        set(value) {
            field = value
            // The store registered its rounds provider on whatever bridge existed at construction;
            // the real service needs it too.
            value?.roundsProvider = { installId -> inThePocket.uploadWires(installId) }
        }
    val pocketsBridge: PocketsBridge
        get() = servicesBridge ?: if (isDebuggable()) debugBridge else NoPocketsBridge

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
        override fun profileName(): String = ""
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
        // A round that was playing when the process went away keeps being tracked.
        app.appScope.launch(Dispatchers.IO) { runCatching { inThePocket.resumeTrackingIfNeeded() } }
    }

    override val resetHooks: List<ResetHook> = listOf(
        ResetHook { scoreboard.clear() },
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

    override val deepLinkHandlers: List<DeepLinkHandler> = listOf(
        DeepLinkHandler { intent ->
            if (isDebuggable() && (intent.getBooleanExtra(POCKETS_STUB_EXTRA, false) ||
                    intent.getStringExtra(POCKETS_STUB_EXTRA) == "true")
            ) {
                stubEnabled.value = true
            }
            if (isDebuggable() && wantsSeed(intent)) {
                app.appScope.launch(Dispatchers.IO) { runCatching { scoreboard.seedFixture(replaceExisting = wantsFixture(intent)) } }
            }
            false // never consumes the intent
        },
    )

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

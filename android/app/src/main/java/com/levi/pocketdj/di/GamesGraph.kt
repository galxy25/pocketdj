package com.levi.pocketdj.di

import android.content.Intent
import com.levi.pocketdj.data.games.GameScoreboardStore
import com.levi.pocketdj.data.games.GamesPrefs
import com.levi.pocketdj.shell.DeepLinkHandler
import com.levi.pocketdj.shell.FeatureModule
import com.levi.pocketdj.shell.ResetHook
import com.levi.pocketdj.shell.SyncEntry
import com.levi.pocketdj.data.catalog.IndexAlbum
import com.levi.pocketdj.data.catalog.IndexSong
import com.levi.pocketdj.data.collections.AddTarget
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

    init {
        // Warm the store off the main thread so the first Games-tab composition never does disk IO.
        app.appScope.launch(Dispatchers.IO) { runCatching { scoreboard } }
    }

    override val resetHooks: List<ResetHook> = listOf(ResetHook { scoreboard.clear() })

    override val syncEntries: List<SyncEntry> =
        listOf(
            SyncEntry(
                GamesPrefs.SCOREBOARD_SYNC_KEY,
                GamesPrefs.SCOREBOARD_FILE,
                onPulled = { scoreboard.reloadFromDisk() },
            ),
        )

    override val deepLinkHandlers: List<DeepLinkHandler> = listOf(
        DeepLinkHandler { intent ->
            if (isDebuggable() && wantsSeed(intent)) {
                app.appScope.launch(Dispatchers.IO) { runCatching { scoreboard.seedFixture(replaceExisting = wantsFixture(intent)) } }
            }
            false // never consumes the intent
        },
    )

    companion object {
        const val PUZZLE_DECISIONS_FILE = "pocketdj-puzzle-decisions.json"
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

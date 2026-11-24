package com.levi.pocketdj.data.pockets.wheel

import com.levi.pocketdj.data.PdjJson
import com.levi.pocketdj.data.catalog.IndexAlbum
import com.levi.pocketdj.data.catalog.IndexSong
import com.levi.pocketdj.data.collections.CollectionFlattener
import com.levi.pocketdj.data.edition.SongVariant
import com.levi.pocketdj.data.history.PlayEvent
import com.levi.pocketdj.data.pockets.ListeningPocketsCollections
import com.levi.pocketdj.screens.browse.Genre
import kotlinx.coroutines.CoroutineDispatcher
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.ExperimentalCoroutinesApi
import kotlinx.coroutines.FlowPreview
import kotlinx.coroutines.Job
import kotlinx.coroutines.flow.Flow
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.asStateFlow
import kotlinx.coroutines.flow.collectLatest
import kotlinx.coroutines.flow.debounce
import kotlinx.coroutines.launch
import kotlinx.coroutines.sync.Mutex
import kotlinx.coroutines.sync.withLock
import kotlinx.coroutines.withContext
import java.io.File
import java.util.concurrent.atomic.AtomicInteger

/**
 * The app-scoped, memoised Pocket Wheel (iOS `PocketMomentCache`, section 1.6 "Cost"): rebuilt OFF the main
 * thread when play history changes (debounced 5 s), persisted as a device-local cache
 * (`pocketdj-pocket-wheel-cache.json`, never synced) so the wheel paints instantly at launch, and folded into
 * the synced palette after every build. Views read [snapshot] only; nothing is derived in a composable.
 */
class PocketMomentCache(
    private val file: File,
    val palette: PocketPaletteStore,
    private val scope: CoroutineScope,
    /** Where the engine runs (never main). */
    private val buildDispatcher: CoroutineDispatcher = Dispatchers.Default,
    /** Where the cache file and the palette are written. */
    private val ioDispatcher: CoroutineDispatcher = Dispatchers.IO,
    var debounceMs: Long = DEBOUNCE_MS,
    /** The engine (a seam so a test can observe the thread it runs on). */
    private val engine: (PocketMomentEngine.Input) -> PocketWheelSnapshot = PocketMomentEngine::build,
) {
    private val _snapshot = MutableStateFlow(PocketWheelSnapshot())
    val snapshot: StateFlow<PocketWheelSnapshot> = _snapshot.asStateFlow()

    private val _building = MutableStateFlow(false)
    val isBuilding: StateFlow<Boolean> = _building.asStateFlow()

    /** Bumped whenever [snapshot] changes (view recompute key). */
    @Volatile var revision: Int = 0
        private set

    // ---- Seams (closures so tests need no app graph). All default to empty. ----
    var historyRevision: () -> Int = { 0 }
    var historyEvents: () -> List<PlayEvent> = { emptyList() }
    var catalogSnapshot: () -> Pair<Map<String, IndexSong>, Map<String, IndexAlbum>> = { emptyMap<String, IndexSong>() to emptyMap() }
    var collectionsInput: () -> ListeningPocketsCollections.Input = { ListeningPocketsCollections.Input() }
    var favoriteIds: () -> Set<String> = { emptySet() }
    var setlistToPlaylist: () -> Map<String, String> = { emptyMap() }
    var timbreVectors: suspend () -> Map<String, Map<String, Double>> = { emptyMap() }
    var cloudPatterns: () -> List<PocketMomentEngine.CloudPatternRef> = { emptyList() }
    /** Ids of collections that exist right now; null = unknown (catalog not loaded), nothing is freed. */
    var liveCollectionIds: () -> Set<String>? = { null }
    var nowMs: () -> Double = { System.currentTimeMillis().toDouble() }

    /** The app's automatic rebuilds. Off in hosts that drive their own builds. */
    @Volatile var autoRebuild: Boolean = true

    /** A seeded demo wheel must not be rebuilt away from under a screenshot. */
    @Volatile var pinnedForDemo: Boolean = false
        private set

    private val buildMutex = Mutex()
    private val fileLock = Any()
    /** Bumped by [clearLocal] so a build that was in flight when the user cleared can never resurrect the wheel. */
    private val generation = AtomicInteger(0)
    @Volatile private var builtRevision = -1
    private var watcher: Job? = null

    init {
        // Paint instantly from the cache, but ALWAYS rebuild once this launch: the history revision is a
        // per-process counter, so a stored revision proves nothing now.
        readCache()?.let { _snapshot.value = it }
    }

    /**
     * Follow the history revision flow: each change schedules a rebuild after [debounceMs] of quiet; a newer
     * change cancels a rebuild still in flight. Idempotent.
     */
    @OptIn(FlowPreview::class, ExperimentalCoroutinesApi::class)
    fun attach(revisions: Flow<Int>) {
        if (watcher?.isActive == true) return
        watcher = scope.launch {
            revisions.debounce { debounceMs }.collectLatest { rev ->
                if (autoRebuild && !pinnedForDemo && rev != builtRevision) rebuildNow()
            }
        }
    }

    /** Build now (off-main), adopt, fold into the palette, persist. */
    suspend fun rebuildNow() {
        buildMutex.withLock {
            val gen = generation.get()
            _building.value = true
            try {
                val rev = historyRevision()
                val events = historyEvents()
                val (songs, albums) = catalogSnapshot()
                val colls = collectionsInput()
                val favs = favoriteIds()
                val setlists = setlistToPlaylist()
                val patterns = cloudPatterns()
                val now = nowMs()
                val vectors = timbreVectors()
                val snap = withContext(buildDispatcher) {
                    engine(makeInput(events, songs, albums, colls, favs, setlists, vectors, patterns, now, rev))
                }
                if (gen == generation.get()) withContext(ioDispatcher) { adoptIf(snap, gen) }
            } finally {
                _building.value = false
            }
        }
    }

    /** Adopt a built snapshot (also the seed/test seam). */
    fun adopt(snap: PocketWheelSnapshot) = adoptIf(snap, generation.get())

    private fun adoptIf(snap: PocketWheelSnapshot, gen: Int) {
        synchronized(fileLock) {
            if (gen != generation.get()) return
            val live = liveCollectionIds()
            val deleted = live?.let { l ->
                palette.entries.keys.filterTo(HashSet()) { it !in l && it != PocketWheelIds.FAVORITES }
            } ?: emptySet()
            palette.assign(snap.dominanceOrder, deleted, snap.builtAtMs)
            builtRevision = snap.historyRevision
            if (snap == _snapshot.value) return
            _snapshot.value = snap
            revision++
            // An empty wheel (history just deleted) leaves no cache behind: nothing to paint at next launch.
            if (snap.isEmpty) runCatching { file.delete() } else writeCache(snap)
        }
    }

    /** Pin a deterministic demo wheel (debug seam): auto rebuilds stop. */
    fun seedDemo(snap: PocketWheelSnapshot) { adopt(snap); pinnedForDemo = true }

    /** "Delete history" / account deletion: drop the wheel, the cache file and any pending or in-flight build. */
    fun clearLocal() {
        synchronized(fileLock) {
            generation.incrementAndGet()
            _snapshot.value = PocketWheelSnapshot()
            builtRevision = -1
            revision++
            pinnedForDemo = false
            runCatching { file.delete() }
            runCatching { File(file.parentFile, file.name + ".tmp").delete() }
        }
    }

    private fun readCache(): PocketWheelSnapshot? = runCatching {
        if (!file.exists()) return null
        PdjJson.lenient.decodeFromString(PocketWheelSnapshot.serializer(), file.readText())
    }.getOrNull()

    private fun writeCache(snap: PocketWheelSnapshot) {
        runCatching {
            val bytes = PdjJson.lenient.encodeToString(PocketWheelSnapshot.serializer(), snap).toByteArray()
            val tmp = File(file.parentFile, file.name + ".tmp")
            tmp.writeBytes(bytes)
            if (!tmp.renameTo(file)) { file.writeBytes(bytes); tmp.delete() }
        }
    }

    companion object {
        const val FILE_NAME = "pocketdj-pocket-wheel-cache.json"
        const val DEBOUNCE_MS = 5_000L

        /**
         * Off-main: catalog + collections + history -> the engine's input. Only songs in the history are
         * converted (the catalog is ~100k rows; the wheel needs the played slice). Favorites join as the
         * `fav_songs` pseudo-collection.
         */
        fun makeInput(
            events: List<PlayEvent>,
            songs: Map<String, IndexSong>,
            albums: Map<String, IndexAlbum>,
            collections: ListeningPocketsCollections.Input,
            favorites: Set<String>,
            setlistToPlaylist: Map<String, String>,
            timbre: Map<String, Map<String, Double>>,
            cloudPatterns: List<PocketMomentEngine.CloudPatternRef>,
            nowMs: Double,
            revision: Int,
        ): PocketMomentEngine.Input {
            val flat = CollectionFlattener.flatten(collections.source)
            val adds = CollectionFlattener.addTimes(flat, collections.activity, collections.source.pockets, collections.source.albumTracks)
            val infos = flat.mapTo(ArrayList()) {
                PocketMomentEngine.CollectionInfo(it.id, it.name, it.songIds.toSet(), adds[it.id] ?: emptyMap())
            }
            if (favorites.isNotEmpty()) {
                infos += PocketMomentEngine.CollectionInfo(PocketWheelIds.FAVORITES, PocketWheelIds.FAVORITES_NAME, favorites)
            }
            val genreByAlbum = HashMap<String, String?>()
            val info = HashMap<String, PocketMomentEngine.SongInfo>()
            for (e in events) {
                val id = SongVariant.baseId(e.songId)
                if (id in info) continue
                val s = songs[id] ?: continue
                var genre: String? = null
                s.albumId?.let { aid ->
                    genre = if (aid in genreByAlbum) genreByAlbum[aid] else {
                        val cat = Genre.category(albums[aid]?.genre)
                        (if (cat == Genre.OTHER) null else cat.lowercase()).also { genreByAlbum[aid] = it }
                    }
                }
                info[id] = PocketMomentEngine.SongInfo(s.artist, genre, s.bpm, s.year, timbre[id])
            }
            return PocketMomentEngine.Input(
                events = events,
                collections = infos,
                songs = info,
                setlistToPlaylist = setlistToPlaylist,
                extraNames = mapOf(PocketWheelIds.FAVORITES to PocketWheelIds.FAVORITES_NAME),
                librarySize = songs.size,
                nowMs = nowMs,
                historyRevision = revision,
                cloudPatterns = cloudPatterns,
            )
        }
    }
}

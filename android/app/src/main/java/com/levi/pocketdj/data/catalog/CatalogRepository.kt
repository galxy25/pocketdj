package com.levi.pocketdj.data.catalog

import com.levi.pocketdj.data.settings.AppSettingsStore
import com.levi.pocketdj.data.settings.SourceConfig
import java.util.concurrent.atomic.AtomicBoolean
import java.util.concurrent.atomic.AtomicInteger
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.distinctUntilChanged
import kotlinx.coroutines.flow.map
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.asStateFlow
import kotlinx.coroutines.flow.update
import kotlinx.coroutines.launch
import kotlinx.coroutines.sync.withLock
import kotlinx.coroutines.withContext

/**
 * App-level catalog flow — the Android mirror of iOS `AppModel.loadIfNeeded`
 * (specs/catalog.md §6):
 *
 * 1. Seed from the disk cache first, no network wait — render instantly; a
 *    loading state shows only on a true first launch (nothing cached).
 * 2. Then a conditional refresh runs detached (never on the caller's path).
 * 3. Refresh is non-destructive: a failed/offline refresh can never blank an
 *    already-rendered catalog. A source that fails with no cache is skipped;
 *    the whole load fails only when EVERY source failed.
 * 4. Single-flight: one load/refresh at a time.
 */
class CatalogRepository(
    private val service: CatalogService,
    private val settings: AppSettingsStore,
    private val scope: CoroutineScope,
) {
    enum class Phase { Idle, Loading, Ready, Failed }

    data class CatalogState(
        val catalog: MergedCatalog? = null,
        val phase: Phase = Phase.Idle,
        val isRefreshing: Boolean = false,
        /** Transient refresh error; never blanks a rendered catalog. */
        val error: String? = null,
    )

    private val _state = MutableStateFlow(CatalogState())
    val state: StateFlow<CatalogState> = _state.asStateFlow()

    /**
     * Catalog-only view: emits only when the [MergedCatalog] instance changes, so
     * collectors don't recompose on isRefreshing flips of an unchanged (304) refresh.
     */
    val catalogFlow: kotlinx.coroutines.flow.Flow<MergedCatalog?> =
        _state.map { it.catalog }.distinctUntilChanged { a, b -> a === b }

    /** Test seam: number of refreshInternal passes that have fully finished. */
    private val _refreshCompletions = AtomicInteger(0)
    val refreshCompletions: Int get() = _refreshCompletions.get()

    private fun timing(msg: String) {
        runCatching { android.util.Log.i("CatalogTiming", msg) }
    }

    /**
     * Merge-order seam for later phases: synthetic local sources (iOS
     * "Discover"/"Imported") are appended AFTER all real sources so a real
     * source always shadows a provisional twin. Empty on Android P1.
     */
    @Volatile
    var syntheticDocuments: () -> List<IndexJson> = { emptyList() }

    /**
     * Provisional "Discover" source (DISC-2): resolved against the REAL documents of THIS merge so a real
     * row carrying the same appleMusicId supersedes the provisional twin (excluded, never duplicated).
     * Its document is appended after every real source and BEFORE [syntheticDocuments]. Null = none.
     */
    @Volatile
    var provisionalSources: ((real: List<IndexJson>) -> com.levi.pocketdj.data.discover.ProvisionalSource.Result)? = null

    /**
     * Fired (off the merge path, after the catalog published) with the (provisional -> indexed) song id pairs
     * a merge superseded - the app prunes the provisional store and remaps collection references.
     */
    @Volatile
    var onSupersede: ((List<Pair<String, String>>) -> Unit)? = null

    /** Real docs + provisional + synthetic, in merge order; reports supersedes through [onSupersede]. */
    private fun withProvisional(real: List<IndexJson>): Pair<List<IndexJson>, com.levi.pocketdj.data.discover.ProvisionalSource.Result?> {
        val prov = provisionalSources?.let { runCatching { it(real) }.getOrNull() }
        return (real + prov?.documents.orEmpty() + syntheticDocuments()) to prov
    }

    private fun notifySupersede(prov: com.levi.pocketdj.data.discover.ProvisionalSource.Result?) {
        val pairs = prov?.supersededSongs.orEmpty()
        val albums = prov?.supersededAlbums.orEmpty()
        if (pairs.isEmpty() && albums.isEmpty()) return
        runCatching { onSupersede?.invoke(pairs) }
        // Albums have nothing to remap (collections reference SONG ids): prune only.
        runCatching { onAlbumsSuperseded?.invoke(albums) }
    }

    /** Provisional ALBUM supersedes (provisional album id -> indexed album id); prune-only. */
    @Volatile
    var onAlbumsSuperseded: ((List<Pair<String, String>>) -> Unit)? = null

    private val inFlight = AtomicBoolean(false)
    private val seeded = AtomicBoolean(false)

    /** A refresh was requested while one was in flight — run again after. */
    private val refreshQueued = AtomicBoolean(false)

    /**
     * Last successfully-loaded document per source URL. The non-destructive
     * guard for PARTIAL failures: when one source's fetch fails (and its disk
     * cache is gone/corrupt), its last-good document substitutes in the merge so
     * a failed refresh never shrinks an already-rendered catalog. Only touched
     * from the single-flight load coroutine.
     */
    private val lastGoodBySource = HashMap<String, IndexJson>()

    /** Real (non-provisional) documents behind the last publish - the no-fetch local re-merge input. */
    @Volatile private var lastRealDocs: List<IndexJson> = emptyList()

    private val publishLock = kotlinx.coroutines.sync.Mutex()

    /**
     * Local re-merge (no network): last-good real docs + provisional + synthetic. Used when a LOCAL store
     * (Discover adds, Imported songs) changed so the row shows up at once instead of after N source reloads.
     */
    fun remergeLocal() {
        scope.launch {
            publishLock.withLock {
                val (inputs, prov) = withContext(Dispatchers.IO) { withProvisional(lastRealDocs) }
                if (inputs.isEmpty()) return@withLock
                if (_state.value.catalog != null && sameInputs(lastMergedInputs, inputs)) return@withLock
                val mergedCatalog = withContext(Dispatchers.Default) {
                    mergeCount++
                    MergedCatalog.merge(inputs)
                }
                lastMergedInputs = inputs
                _state.update { it.copy(catalog = mergedCatalog, phase = Phase.Ready) }
                notifySupersede(prov)
            }
        }
    }

    /** Apple Music name->artist-id join rows of the last real documents (BRW-14 ownership + release feed). */
    fun indexArtists(): List<IndexArtist> {
        val docs = lastRealDocs
        val memo = artistsMemo
        if (memo != null && memo.first === docs) return memo.second
        val flat = docs.flatMap { it.artists.orEmpty() }
        artistsMemo = docs to flat
        return flat
    }

    /** [indexArtists] result memoised on the identity of the docs list (callers can memo on the result's identity). */
    @Volatile private var artistsMemo: Pair<List<IndexJson>, List<IndexArtist>>? = null

    /** Exact documents (by identity) behind the currently-published catalog. */
    private var lastMergedInputs: List<IndexJson>? = null

    /** Test seam: number of [MergedCatalog.merge] calls made. */
    @Volatile
    var mergeCount = 0
        private set

    private fun sameInputs(a: List<IndexJson>?, b: List<IndexJson>): Boolean =
        a != null && a.size == b.size && a.indices.all { a[it] === b[it] }

    /** Seed from cache (once) then refresh — call at app launch. */
    fun loadIfNeeded() {
        if (!inFlight.compareAndSet(false, true)) return
        scope.launch {
            try {
                if (!seeded.getAndSet(true)) seedFromCache()
                refreshInternal()
            } finally {
                inFlight.set(false)
            }
            runQueuedRefresh()
        }
    }

    /**
     * Manual "Reload catalog": refreshes in place, never resets to loading.
     * A call during an in-flight load is QUEUED, not dropped — Settings calls
     * this right after a source toggle/add, and the in-flight refresh captured
     * the OLD source list.
     */
    fun refresh() {
        if (!inFlight.compareAndSet(false, true)) {
            refreshQueued.set(true)
            return
        }
        scope.launch {
            try {
                refreshInternal()
            } finally {
                inFlight.set(false)
            }
            runQueuedRefresh()
        }
    }

    private fun runQueuedRefresh() {
        if (refreshQueued.getAndSet(false)) refresh()
    }

    private suspend fun enabledSources(): List<SourceConfig> =
        settings.current().sources.filter { it.enabled }

    private suspend fun seedFromCache() {
        val sources = enabledSources()
        val t0 = System.nanoTime()
        val cached = withContext(Dispatchers.IO) {
            sources.mapNotNull { source ->
                service.cachedIndexOrNull(source.url)?.also { lastGoodBySource[source.url] = it }
            }
        }
        if (cached.isEmpty()) {
            _state.update { it.copy(phase = Phase.Loading) }
            return
        }
        lastRealDocs = cached
        val prov = publishLock.withLock {
            val (inputs, prov) = withContext(Dispatchers.IO) { withProvisional(cached) }
            val merged = withContext(Dispatchers.Default) {
                mergeCount++
                MergedCatalog.merge(inputs)
            }
            lastMergedInputs = inputs
            _state.update { it.copy(catalog = merged, phase = Phase.Ready, error = null) }
            prov
        }
        notifySupersede(prov)
        timing("seed ready in ${(System.nanoTime() - t0) / 1_000_000} ms (${cached.size} sources)")
    }

    private suspend fun refreshInternal() {
        val sources = enabledSources()
        val t0 = System.nanoTime()
        var merged = false
        _state.update { it.copy(isRefreshing = true) }
        try {
            val loaded = ArrayList<IndexJson>(sources.size)
            var lastError: String? = null
            for (source in sources) {
                runCatching { service.load(source.url, lastGoodBySource[source.url]) }
                    .onSuccess {
                        lastGoodBySource[source.url] = it.index
                        loaded.add(it.index)
                    }
                    .onFailure { error ->
                        lastError = error.message ?: "Couldn't load ${source.name}"
                        // Partial-failure guard: substitute the source's last-good
                        // document (service.load already fell back to disk; this
                        // covers a cleared/corrupt cache) so an already-rendered
                        // source never vanishes from the merged catalog.
                        lastGoodBySource[source.url]?.let(loaded::add)
                    }
            }
            if (loaded.isEmpty()) {
                // No real source: local rows (Discover / Imported) still merge on their own.
                val localOnly = publishLock.withLock {
                    lastRealDocs = emptyList()
                    val (inputs, prov) = withContext(Dispatchers.IO) { withProvisional(emptyList()) }
                    if (inputs.isEmpty()) return@withLock null
                    val mergedCatalog = withContext(Dispatchers.Default) {
                        mergeCount++
                        MergedCatalog.merge(inputs)
                    }
                    lastMergedInputs = inputs
                    _state.update { it.copy(catalog = mergedCatalog, phase = Phase.Ready, error = lastError) }
                    prov
                }
                if (localOnly != null) { merged = true; notifySupersede(localOnly); return }
                // Every source failed — surface a failure only when nothing was
                // ever rendered; otherwise keep the catalog and note the error.
                _state.update { current ->
                    if (current.catalog == null) {
                        current.copy(phase = Phase.Failed, error = lastError ?: "Couldn't load any source")
                    } else {
                        current.copy(error = lastError)
                    }
                }
                return
            }
            lastRealDocs = loaded
            val prov = publishLock.withLock {
                val (inputs, prov) = withContext(Dispatchers.IO) { withProvisional(loaded) }
                if (_state.value.catalog != null && sameInputs(lastMergedInputs, inputs)) {
                    // Every source unchanged (304 / failure on seed): skip the derived rebuild.
                    _state.update { it.copy(phase = Phase.Ready, error = lastError) }
                    return@withLock prov
                }
                val mergedCatalog = withContext(Dispatchers.Default) {
                    mergeCount++
                    MergedCatalog.merge(inputs)
                }
                merged = true
                lastMergedInputs = inputs
                _state.update {
                    it.copy(catalog = mergedCatalog, phase = Phase.Ready, error = lastError)
                }
                prov
            }
            notifySupersede(prov)
        } finally {
            _state.update { it.copy(isRefreshing = false) }
            timing("refresh complete in ${(System.nanoTime() - t0) / 1_000_000} ms (merged=$merged)")
            _refreshCompletions.incrementAndGet()
        }
    }
}

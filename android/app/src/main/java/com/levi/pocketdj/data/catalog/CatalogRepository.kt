package com.levi.pocketdj.data.catalog

import com.levi.pocketdj.data.settings.AppSettingsStore
import com.levi.pocketdj.data.settings.SourceConfig
import java.util.concurrent.atomic.AtomicBoolean
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.asStateFlow
import kotlinx.coroutines.flow.update
import kotlinx.coroutines.launch
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
     * Merge-order seam for later phases: synthetic local sources (iOS
     * "Discover"/"Imported") are appended AFTER all real sources so a real
     * source always shadows a provisional twin. Empty on Android P1.
     */
    @Volatile
    var syntheticDocuments: () -> List<IndexJson> = { emptyList() }

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
        val cached = withContext(Dispatchers.IO) {
            sources.mapNotNull { source ->
                service.cachedIndexOrNull(source.url)?.also { lastGoodBySource[source.url] = it }
            }
        }
        if (cached.isEmpty()) {
            _state.update { it.copy(phase = Phase.Loading) }
            return
        }
        val merged = withContext(Dispatchers.Default) {
            MergedCatalog.merge(cached + syntheticDocuments())
        }
        _state.update { it.copy(catalog = merged, phase = Phase.Ready, error = null) }
    }

    private suspend fun refreshInternal() {
        val sources = enabledSources()
        _state.update { it.copy(isRefreshing = true) }
        try {
            val loaded = ArrayList<IndexJson>(sources.size)
            var lastError: String? = null
            for (source in sources) {
                runCatching { service.load(source.url) }
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
            val merged = withContext(Dispatchers.Default) {
                MergedCatalog.merge(loaded + syntheticDocuments())
            }
            _state.update {
                it.copy(catalog = merged, phase = Phase.Ready, error = lastError)
            }
        } finally {
            _state.update { it.copy(isRefreshing = false) }
        }
    }
}

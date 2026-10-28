package com.levi.pocketdj.data.search

import com.levi.pocketdj.net.SigV4
import com.levi.pocketdj.screens.browse.BrowseKind
import com.levi.pocketdj.screens.browse.Clause
import com.levi.pocketdj.screens.browse.SortKey
import kotlinx.coroutines.CancellationException
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Job
import kotlinx.coroutines.delay
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.launch

/** Snapshot of the online results (what the UI renders). */
data class OnlineSearchUi(
    val state: OnlineSearchModel.State = OnlineSearchModel.State.Idle,
    /** Deduped hits in server order. */
    val hits: List<SearchHit> = emptyList(),
    /** Exact total reported by OpenSearch for the current query+filters+kind. */
    val total: Int = 0,
    /** True while a NEXT-page fetch is in flight (the first page uses [state]). */
    val isLoadingPage: Boolean = false,
    /** Raw hit count loaded so far = the `from` offset of the next page. */
    val loadedCount: Int = 0,
    /** Bumps on every reset so the UI can reset scroll / paging triggers. */
    val generation: Int = 0,
) {
    val hasMore: Boolean
        get() = loadedCount < total && loadedCount < SearchService.MAX_RESULT_WINDOW
}

/**
 * Drives online (OpenSearch) search: debounced query -> [Searching] -> deduped hits. Port of
 * iOS `OnlineSearchModel`. Hit -> row mapping lives in the UI layer (needs the catalog).
 *
 * Invariants (hard-won on iOS): reset on any query/kind/clauses/sort change; the offset is the
 * RAW hit count (so de-dupe can never desync paging); a stale page (from != loadedCount, or a
 * newer generation) is dropped; a transient page error keeps the loaded rows; the window caps
 * at 10 000.
 */
class OnlineSearchModel(
    private val service: Searching,
    private val scope: CoroutineScope,
    val pageSize: Int = 50,
    private val debounceMs: Long = 300,
) {

    /** State with an optional failure message. */
    sealed interface State {
        data object Idle : State
        data object Loading : State
        data object Loaded : State
        data class Failed(val message: String) : State
    }

    private val _ui = MutableStateFlow(OnlineSearchUi())
    val ui: StateFlow<OnlineSearchUi> = _ui

    private class Ctx(
        val query: String, val kind: BrowseKind, val clauses: List<Clause>,
        val sortKeys: List<SortKey>, val creds: SigV4.Creds,
    )

    private var ctx: Ctx? = null
    private val seen = HashSet<String>()
    private var job: Job? = null
    private var generation = 0

    /**
     * Always RESETS, then loads page 1 after the debounce. Call on every query / kind /
     * clauses / SORT change. [creds] null -> failed state with the Settings hint.
     */
    fun searchDebounced(
        query: String, kind: BrowseKind, clauses: List<Clause> = emptyList(),
        sortKeys: List<SortKey> = emptyList(), creds: SigV4.Creds?,
    ) {
        job?.cancel()
        reset()
        if (creds == null) {
            _ui.value = _ui.value.copy(state = State.Failed(SearchSettings.MISSING_CREDS_MESSAGE))
            return
        }
        ctx = Ctx(query, kind, clauses, sortKeys, creds)
        // Pending, not "Loaded + empty": the UI must not flash "No matches" during the debounce.
        _ui.value = _ui.value.copy(state = State.Loading)
        job = scope.launch {
            delay(debounceMs)
            loadFirstPage()
        }
    }

    /** Non-debounced reset + first page (deterministic for tests). */
    suspend fun startSearch(
        query: String, kind: BrowseKind, clauses: List<Clause> = emptyList(),
        sortKeys: List<SortKey> = emptyList(), creds: SigV4.Creds,
    ) {
        job?.cancel()
        reset()
        ctx = Ctx(query, kind, clauses, sortKeys, creds)
        loadFirstPage()
    }

    fun cancel() {
        job?.cancel()
        job = null
        reset()
        _ui.value = _ui.value.copy(state = State.Idle)
    }

    private fun reset() {
        generation++
        seen.clear()
        _ui.value = OnlineSearchUi(state = _ui.value.state, generation = generation)
    }

    private suspend fun loadFirstPage() {
        val c = ctx ?: return
        val gen = generation
        _ui.value = _ui.value.copy(state = State.Loading)
        try {
            val page = service.search(c.query, c.kind, c.clauses, c.sortKeys, c.creds, 0, pageSize)
            if (gen != generation) return
            _ui.value = _ui.value.copy(total = page.total)
            append(page.hits)
            _ui.value = _ui.value.copy(state = State.Loaded)
        } catch (e: CancellationException) {
            throw e
        } catch (e: Exception) {
            if (gen != generation) return
            reset()
            _ui.value = _ui.value.copy(state = State.Failed(e.message ?: "Search failed"))
        }
    }

    /** Fetch + APPEND the next page. Safe to call freely from the last row's appearance. */
    suspend fun loadMore() {
        val s = _ui.value
        val c = ctx ?: return
        if (!s.hasMore || s.isLoadingPage || s.state != State.Loaded) return
        val gen = generation
        val from = s.loadedCount
        _ui.value = s.copy(isLoadingPage = true)
        try {
            val page = service.search(c.query, c.kind, c.clauses, c.sortKeys, c.creds, from, pageSize)
            // Query/filters/sort changed mid-flight (reset zeroed the offset): drop the page.
            if (gen != generation || from != _ui.value.loadedCount) return
            _ui.value = _ui.value.copy(total = page.total)
            append(page.hits)
        } catch (e: CancellationException) {
            throw e
        } catch (_: Exception) {
            // Keep what we have; a transient page error must not wipe loaded rows.
        } finally {
            if (gen == generation) _ui.value = _ui.value.copy(isLoadingPage = false)
        }
    }

    /** Advance the offset by the RAW count, append only unseen ids. */
    private fun append(hits: List<SearchHit>) {
        val cur = _ui.value
        val fresh = hits.filter { seen.add(it.id) }
        _ui.value = cur.copy(hits = cur.hits + fresh, loadedCount = cur.loadedCount + hits.size)
    }
}

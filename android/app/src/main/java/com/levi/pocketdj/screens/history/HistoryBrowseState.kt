package com.levi.pocketdj.screens.history

import com.levi.pocketdj.data.history.HistorySnapshot
import com.levi.pocketdj.data.settings.BrowseSortKeyDoc
import com.levi.pocketdj.screens.browse.BrowseEngine
import com.levi.pocketdj.screens.browse.BrowseKind
import com.levi.pocketdj.screens.browse.Clause
import com.levi.pocketdj.screens.browse.Fields
import com.levi.pocketdj.screens.browse.SongRow
import com.levi.pocketdj.screens.browse.SortField
import com.levi.pocketdj.screens.browse.SortKey
import com.levi.pocketdj.screens.browse.toClause
import com.levi.pocketdj.screens.browse.toDoc
import kotlinx.coroutines.CoroutineDispatcher
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.delay
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.asStateFlow
import kotlinx.coroutines.flow.update
import kotlinx.coroutines.withContext

/** Everything the History results depend on EXCEPT the event log / catalog (those are bases). */
internal data class HistoryInputs(
    /** TRANSIENT — never persisted. */
    val query: String = "",
    val clauses: List<Clause> = emptyList(),
    val sortKeys: List<SortKey> = DEFAULT_SORT,
    /** TRANSIENT; applied while building the base, so part of the base key. */
    val hideSkips: Boolean = false,
    /** Bumped by the play-count store when a clause/sort reads plays. */
    val playCountsRevision: Int = 0,
    /** Bumped by an explicit submit so the recompute effect re-fires with an unchanged signature. */
    val submitNonce: Int = 0,
) {
    /** Does a clause or sort key read play counts (memo-key / count-snapshot gate)? */
    val usesPlayCounts: Boolean
        get() = sortKeys.any { it.field == SortField.PLAY_COUNT } ||
            clauses.any { !it.isIncomplete && it.field == "playCount" }

    /** Deterministic signature of the inputs (clause VALUES, never ids; see BrowseEngine.resultsKey). */
    fun signature(): String =
        BrowseEngine.resultsKey(0L, BrowseKind.SONGS, query, clauses, sortKeys, playCountsRevision) +
            "|hs=$hideSkips"

    /** Glyph/count of active History constraints (clauses + Hide skips). */
    val activeCount: Int get() = clauses.count { !it.isIncomplete } + if (hideSkips) 1 else 0

    companion object {
        /** History defaults to most-recently-played first. */
        val DEFAULT_SORT: List<SortKey> = listOf(SortKey(SortField.LAST_PLAYED_AT, ascending = false))
    }
}

/** One published result set: the engine output plus the base that can resolve each row's PlayRef. */
internal class HistoryResults(val rows: List<SongRow>, private val base: HistoryBase) {
    fun refOf(row: SongRow): PlayRef? = base.refOf(row)

    /** The unfiltered base rows (drives the filter sheet's option lists). */
    val allRows: List<SongRow> get() = base.rows

    companion object {
        val EMPTY = HistoryResults(emptyList(), HistoryBase.EMPTY)
    }
}

/**
 * History's browse state: its own persisted filter/sort (key `historySnapshotJson`), a transient
 * query, and the iOS `BrowseState.refreshExternal` pipeline over an externally supplied base
 * (the play-event rows). The three load-bearing guards are ported verbatim:
 *
 *  1. DEBOUNCE BEFORE BASE BUILD — a burst of keystrokes coalesces before the O(events) build.
 *  2. SUPERSEDE CHECK — the inputs are snapshotted before the await; if they moved while we
 *     slept / filtered, the publish is abandoned (the run that moved them owns the publish).
 *     Otherwise `displayKey` would be stamped with the OLD signature over the NEW rows.
 *  3. NEVER STICKY-EMPTY — an empty base is never memoized, and with no base bound nothing is
 *     published or stamped, so the next run recomputes for real.
 *
 * [invalidateDisplayKey] (explicit submit) drops BOTH memos. Paging is keyed by [pagingKey],
 * which excludes the catalog identity so a catalog refresh never resets a scrolled-in budget.
 */
internal class HistoryBrowseState(
    private val debounceMs: Long = QUERY_DEBOUNCE_MS,
    private val filterDispatcher: CoroutineDispatcher = Dispatchers.Default,
    /** When true, [refreshExternal] publishes nothing until the persisted snapshot has been applied. */
    private val requireRestore: Boolean = false,
) {
    private val _inputs = MutableStateFlow(HistoryInputs())
    val inputs: StateFlow<HistoryInputs> = _inputs.asStateFlow()

    private val _results = MutableStateFlow(HistoryResults.EMPTY)
    val results: StateFlow<HistoryResults> = _results.asStateFlow()

    /** Signature the published [results] were computed for (the "already current" memo). */
    @Volatile var displayKey: String? = null
        private set

    /** Host-bound base builder. Null until the host binds it (guard 3). */
    @Volatile var externalBase: (() -> HistoryBase)? = null

    private class BaseCache(val key: String, val base: HistoryBase)

    @Volatile private var baseCache: BaseCache? = null

    /** Play counts for a `playCount` clause/sort (empty unless the host supplies them). */
    @Volatile var playCounts: Map<String, Int> = emptyMap()

    /** True once the persisted snapshot has been applied (a flush before this must not clobber it). */
    private val _restored = MutableStateFlow(false)
    val restoredFlow: StateFlow<Boolean> = _restored.asStateFlow()
    val restored: Boolean get() = _restored.value

    // ---- inputs -----------------------------------------------------------------------------

    fun update(transform: (HistoryInputs) -> HistoryInputs) = _inputs.update(transform)

    fun setQuery(q: String) = update { it.copy(query = q) }
    fun setClauses(c: List<Clause>) = update { it.copy(clauses = c) }
    fun setSortKeys(k: List<SortKey>) = update { it.copy(sortKeys = k) }
    fun setHideSkips(v: Boolean) = update { it.copy(hideSkips = v) }

    /** Clear All: clauses + Hide skips (sort is its own sheet's Clear all). */
    fun clearFilters() = update { it.copy(clauses = emptyList(), hideSkips = false) }

    // ---- the refreshExternal pipeline ---------------------------------------------------------

    suspend fun refreshExternal(signature: String, baseKey: String) {
        if (requireRestore && !_restored.value) return // hydrating: defaults must not publish
        if (displayKey == signature) return
        val before = _inputs.value
        val sigBefore = before.signature()
        // Guard 1: debounce an active query FIRST.
        if (before.query.isNotEmpty()) {
            delay(debounceMs)
            // Guard 2 (post-sleep): the inputs moved -> the run that moved them owns the publish.
            if (_inputs.value.signature() != sigBefore) return
        }
        val base: HistoryBase
        val cached = baseCache
        if (cached != null && cached.key == baseKey) {
            base = cached.base
        } else {
            val build = externalBase ?: return // guard 3: nothing bound -> publish/stamp nothing
            base = withContext(filterDispatcher) { build() }
            // Guard 3: never memoize an EMPTY base (an empty answer costs nothing to rebuild).
            if (base.rows.isNotEmpty()) baseCache = BaseCache(baseKey, base)
        }
        val inputs = _inputs.value
        val counts = playCounts
        val sorted = withContext(filterDispatcher) {
            BrowseEngine.filterSort(
                base = base.rows,
                searchKeys = base.keys,
                query = inputs.query,
                clauses = inputs.clauses,
                sortKeys = inputs.sortKeys,
                playCounts = counts,
            )
        }
        // Guard 2 (publish point): the pair (results, displayKey) is only written when they agree.
        if (_inputs.value.signature() != sigBefore) return
        _results.value = HistoryResults(sorted, base)
        displayKey = signature
    }

    /**
     * Explicit submit: drop the "already current" memo AND the base memo so the next
     * [refreshExternal] recomputes even when the signature is unchanged.
     */
    fun invalidateDisplayKey() {
        displayKey = null
        baseCache = null
    }

    /** Explicit submit (IME Search): invalidate both memos AND re-fire the recompute effect. */
    fun submit() {
        invalidateDisplayKey()
        update { it.copy(submitNonce = it.submitNonce + 1) }
    }

    // ---- paging ---------------------------------------------------------------------------------

    /**
     * What makes the RESULT SET different: event-log revision + inputs + count. Deliberately
     * EXCLUDES the catalog identity — a catalog load bumps the recompute signature but must not
     * strand a scrolled-in budget back at page one. The count catches a catalog load that
     * changes which rows pass a catalog-derived filter.
     */
    fun pagingKey(historyRevision: Int, resultCount: Int): String =
        "$historyRevision|${_inputs.value.signature()}|$resultCount"

    // ---- persistence ----------------------------------------------------------------------------

    fun toSnapshot(): HistorySnapshot {
        val i = _inputs.value
        return HistorySnapshot(
            clauses = i.clauses.map(Clause::toDoc),
            sortKeys = i.sortKeys.map { BrowseSortKeyDoc(it.field.id, it.ascending) },
        )
    }

    /** Mark hydration finished without applying anything (load failed). */
    fun markRestored() { _restored.value = true }

    /** Apply a persisted snapshot; an empty sort falls to the History default (most recent first). */
    fun restore(snapshot: HistorySnapshot) {
        val sort = snapshot.sortKeys
            .mapNotNull { doc -> SortField.byId[doc.field]?.let { SortKey(it, doc.ascending) } }
            .ifEmpty { HistoryInputs.DEFAULT_SORT }
        val clauses = snapshot.clauses.mapNotNull { it.toClause() }
            .filter { Fields.byId.containsKey(it.field) }
        // Apply only while the user hasn't touched filter/sort during the async hydrate.
        update {
            if (it.clauses.isEmpty() && it.sortKeys == HistoryInputs.DEFAULT_SORT) {
                it.copy(clauses = clauses, sortKeys = sort)
            } else it
        }
        _restored.value = true
    }

    companion object {
        const val QUERY_DEBOUNCE_MS = 180L
    }
}

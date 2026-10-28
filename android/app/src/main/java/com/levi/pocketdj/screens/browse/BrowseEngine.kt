package com.levi.pocketdj.screens.browse

import java.util.concurrent.atomic.AtomicInteger
import kotlinx.serialization.json.JsonArray
import kotlinx.serialization.json.JsonNull
import kotlinx.serialization.json.JsonObject
import kotlinx.serialization.json.JsonPrimitive

/**
 * The one pure browse pipeline — base rows → text query → filter clauses →
 * multi-key sort (iOS `BrowseState.computeSorted`). Reused by Browse, History,
 * collections and the queue builder; no Android types, safe off the main thread.
 */
object BrowseEngine {

    /** Count of mismatched parallel-array calls (the should-never path); testable. */
    val mismatchCount = AtomicInteger(0)

    /** Loud-in-debug hook for the mismatch fault; replaced in tests. */
    @Volatile
    var mismatchReporter: (String) -> Unit = { msg ->
        runCatching { android.util.Log.w("BrowseEngine", msg) }
    }

    /**
     * @param searchKeys folded haystacks PARALLEL to [base]. A mismatched size used
     * to drop the query and return everything ("typing does nothing"); it now
     * honours the query against each row's own name/artist and reports a fault.
     */
    fun <T : BrowseRow> filterSort(
        base: List<T>,
        searchKeys: List<String>,
        query: String,
        clauses: List<Clause>,
        sortKeys: List<SortKey>,
        playCounts: Map<String, Int> = emptyMap(),
    ): List<T> {
        // Strip newlines so a query can't match across field boundaries (§4.1).
        val q = Fmt.fold(query.replace("\n", ""))
        var items = base
        if (q.isNotEmpty()) {
            if (base.size == searchKeys.size) {
                items = base.filterIndexed { i, _ -> searchKeys[i].contains(q) }
            } else {
                mismatchCount.incrementAndGet()
                mismatchReporter("searchKeys ${searchKeys.size} must parallel base ${base.size} — falling back to per-row matching")
                items = base.filter { matchesFolded(it, q) }
            }
        }
        return BrowseSort.sorted(FilterEngine.apply(items, clauses, playCounts), sortKeys, playCounts)
    }

    /** Per-row fallback: fold the row's own name/artist; [q] is pre-folded. */
    fun matchesFolded(row: BrowseRow, q: String): Boolean =
        listOf("name", "artist").any { id ->
            val v = Fields.value(row, id)
            v is FieldValue.Str && Fmt.fold(v.v).contains(q)
        }

    /**
     * Deterministic memo signature of everything the results depend on EXCEPT
     * the read-time membership/favorite layers. Built from clause VALUES (never
     * ids), complete clauses only, JSON-encoded with alphabetically ordered
     * object keys so a title containing `,` or `|` can't collide two different
     * inputs. [catalogIdentity] is the catalog revision/identity; the play-count
     * revision folds in only while a clause or sort key reads play counts.
     */
    fun resultsKey(
        catalogIdentity: Long,
        kind: BrowseKind,
        query: String,
        clauses: List<Clause>,
        sortKeys: List<SortKey>,
        playCountsRevision: Int,
    ): String {
        val complete = clauses.filter { !it.isIncomplete }
        val usesPlayCounts = sortKeys.any { it.field == SortField.PLAY_COUNT } ||
            complete.any { it.field == "playCount" }
        val clauseArr = JsonArray(
            complete.map { c ->
                JsonObject(
                    linkedMapOf(
                        "f" to JsonPrimitive(c.field),
                        "mn" to (c.min?.let(::JsonPrimitive) ?: JsonNull),
                        "mx" to (c.max?.let(::JsonPrimitive) ?: JsonNull),
                        "o" to JsonPrimitive(c.op.id),
                        "v" to JsonPrimitive(c.value),
                        "vs" to JsonArray(c.values.sorted().map(::JsonPrimitive)),
                    ),
                )
            },
        )
        val sortArr = JsonArray(
            sortKeys.map {
                JsonObject(
                    linkedMapOf(
                        "d" to JsonPrimitive(if (it.ascending) "asc" else "desc"),
                        "f" to JsonPrimitive(it.field.id),
                    ),
                )
            },
        )
        return JsonObject(
            linkedMapOf(
                "c" to clauseArr,
                "k" to JsonPrimitive(kind.name.lowercase()),
                "pc" to JsonPrimitive(if (usesPlayCounts) playCountsRevision else -1),
                "q" to JsonPrimitive(query),
                "rev" to JsonPrimitive(catalogIdentity),
                "s" to sortArr,
            ),
        ).toString()
    }
}

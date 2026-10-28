package com.levi.pocketdj.data.search

import com.levi.pocketdj.net.SigV4
import com.levi.pocketdj.screens.browse.BrowseKind
import com.levi.pocketdj.screens.browse.Clause
import com.levi.pocketdj.screens.browse.SortField
import com.levi.pocketdj.screens.browse.SortKey
import java.io.IOException
import kotlinx.coroutines.CompletableDeferred
import kotlinx.coroutines.CoroutineStart
import kotlinx.coroutines.async
import kotlinx.coroutines.runBlocking
import kotlinx.coroutines.test.TestScope
import kotlinx.coroutines.test.advanceTimeBy
import kotlinx.coroutines.test.runTest
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

private data class Call(val query: String, val kind: BrowseKind?, val sort: List<SortKey>, val from: Int, val size: Int)

private class Stub(var handler: suspend (Call) -> SearchResults) : Searching {
    val calls = mutableListOf<Call>()
    override suspend fun search(
        query: String, kind: BrowseKind?, clauses: List<Clause>, sortKeys: List<SortKey>,
        creds: SigV4.Creds, from: Int, size: Int,
    ): SearchResults {
        val c = Call(query, kind, sortKeys, from, size)
        calls += c
        return handler(c)
    }
}

private fun hits(range: IntRange) = range.map { SearchHit(id = "s$it", type = "song", title = "T$it") }

class OnlineSearchModelTest {
    private val creds = SigV4.Creds("k", "s")

    private fun model(stub: Searching, scope: kotlinx.coroutines.CoroutineScope = TestScope(), size: Int = 50) =
        OnlineSearchModel(stub, scope, pageSize = size)

    @Test fun firstPageLoadsAndExposesExactTotal() = runBlocking {
        val stub = Stub { SearchResults(hits(0 until 50), 120) }
        val m = model(stub)
        m.startSearch("q", BrowseKind.SONGS, creds = creds)
        val ui = m.ui.value
        assertEquals(OnlineSearchModel.State.Loaded, ui.state)
        assertEquals(50, ui.hits.size); assertEquals(120, ui.total); assertEquals(50, ui.loadedCount)
        assertTrue(ui.hasMore)
        assertEquals(Call("q", BrowseKind.SONGS, emptyList(), 0, 50), stub.calls.single())
    }

    @Test fun loadMoreAppendsFromLoadedCountUntilTotal() = runBlocking {
        val stub = Stub { c -> SearchResults(hits(c.from until minOf(c.from + 50, 120)), 120) }
        val m = model(stub)
        m.startSearch("q", BrowseKind.SONGS, creds = creds)
        m.loadMore(); m.loadMore()
        assertEquals(listOf(0, 50, 100), stub.calls.map { it.from })
        assertEquals(120, m.ui.value.hits.size)
        assertFalse(m.ui.value.hasMore)
        m.loadMore() // no-op: nothing more
        assertEquals(3, stub.calls.size)
    }

    @Test fun offsetAdvancesByRawCountEvenWhenDedupeDropsRows() = runBlocking {
        // Page 2 repeats ids s40..s49 (already seen): offset must still advance by 50.
        val stub = Stub { c ->
            if (c.from == 0) SearchResults(hits(0 until 50), 200) else SearchResults(hits(40 until 90), 200)
        }
        val m = model(stub)
        m.startSearch("q", BrowseKind.SONGS, creds = creds)
        m.loadMore()
        val ui = m.ui.value
        assertEquals(100, ui.loadedCount)
        assertEquals(90, ui.hits.size)
        assertEquals(90, ui.hits.map { it.id }.toSet().size)
        m.loadMore()
        assertEquals(100, stub.calls.last().from)
    }

    @Test fun windowCapsAtTenThousand() = runBlocking {
        val stub = Stub { c -> SearchResults(hits(c.from until c.from + 50), 50_000) }
        val m = model(stub)
        m.startSearch("q", BrowseKind.SONGS, creds = creds)
        repeat(300) { m.loadMore() }
        assertEquals(10_000, m.ui.value.loadedCount)
        assertFalse(m.ui.value.hasMore)
        assertEquals(10_000 / 50, stub.calls.size)
    }

    @Test fun loadMoreIsGuardedWhileAPageIsInFlight() = runBlocking {
        val gate = CompletableDeferred<Unit>()
        val stub = Stub { c ->
            if (c.from > 0) gate.await()
            SearchResults(hits(c.from until c.from + 50), 500)
        }
        val m = model(stub)
        m.startSearch("q", BrowseKind.SONGS, creds = creds)
        val first = async(start = CoroutineStart.UNDISPATCHED) { m.loadMore() }
        assertTrue(m.ui.value.isLoadingPage)
        m.loadMore() // guarded no-op
        assertEquals(2, stub.calls.size)
        gate.complete(Unit)
        first.await()
        assertFalse(m.ui.value.isLoadingPage)
        assertEquals(100, m.ui.value.loadedCount)
    }

    @Test fun stalePageIsDroppedWhenSearchResetsMidFlight() = runBlocking {
        val gate = CompletableDeferred<Unit>()
        val stub = Stub { c ->
            if (c.from > 0) gate.await()
            SearchResults(hits(c.from until c.from + 50).map { it.copy(id = "${c.query}${it.id}") }, 500)
        }
        val m = model(stub)
        m.startSearch("old", BrowseKind.SONGS, creds = creds)
        val stale = async(start = CoroutineStart.UNDISPATCHED) { m.loadMore() }
        m.startSearch("new", BrowseKind.SONGS, creds = creds) // reset + fresh page 1 (50 rows)
        gate.complete(Unit)
        stale.await()
        val ui = m.ui.value
        assertEquals(50, ui.loadedCount)
        assertTrue(ui.hits.all { it.id.startsWith("new") })
    }

    @Test fun sortChangeResetsAndReloadsPageOneWithNewSort() = runBlocking {
        val stub = Stub { c -> SearchResults(hits(c.from until c.from + 50), 500) }
        val m = model(stub)
        m.startSearch("q", BrowseKind.SONGS, creds = creds)
        m.loadMore()
        assertEquals(100, m.ui.value.loadedCount)
        val sort = listOf(SortKey(SortField.BPM, false))
        m.startSearch("q", BrowseKind.SONGS, sortKeys = sort, creds = creds)
        assertEquals(50, m.ui.value.loadedCount)
        assertEquals(Call("q", BrowseKind.SONGS, sort, 0, 50), stub.calls.last())
        m.loadMore()
        assertEquals(sort, stub.calls.last().sort) // the SAME sort on every page
    }

    @Test fun firstPageFailureClearsRowsAndReportsMessage() = runBlocking {
        val stub = Stub { throw SearchFailedException(403, "Search failed (403): denied") }
        val m = model(stub)
        m.startSearch("q", BrowseKind.SONGS, creds = creds)
        val ui = m.ui.value
        assertEquals(OnlineSearchModel.State.Failed("Search failed (403): denied"), ui.state)
        assertTrue(ui.hits.isEmpty()); assertEquals(0, ui.total)
    }

    @Test fun transientPageErrorKeepsLoadedRows() = runBlocking {
        val stub = Stub { c -> if (c.from == 0) SearchResults(hits(0 until 50), 500) else throw IOException("flaky") }
        val m = model(stub)
        m.startSearch("q", BrowseKind.SONGS, creds = creds)
        m.loadMore()
        val ui = m.ui.value
        assertEquals(OnlineSearchModel.State.Loaded, ui.state)
        assertEquals(50, ui.hits.size); assertEquals(50, ui.loadedCount)
        assertFalse(ui.isLoadingPage)
    }

    @Test fun missingCredsFailsWithSettingsHintAndNeverSearches() = runTest {
        val stub = Stub { SearchResults(emptyList(), 0) }
        val m = model(stub, this)
        m.searchDebounced("q", BrowseKind.SONGS, creds = null)
        assertEquals(
            OnlineSearchModel.State.Failed("Add OpenSearch credentials in Settings to search online."),
            m.ui.value.state,
        )
        advanceTimeBy(1000)
        assertTrue(stub.calls.isEmpty())
    }

    @Test fun debouncePendingShowsLoadingNotEmptyLoaded() = runTest {
        val stub = Stub { SearchResults(hits(0 until 3), 3) }
        val m = model(stub, this)
        m.searchDebounced("m", BrowseKind.SONGS, creds = creds)
        assertEquals(OnlineSearchModel.State.Loading, m.ui.value.state)
        advanceTimeBy(1000)
        assertEquals(OnlineSearchModel.State.Loaded, m.ui.value.state)
    }

    @Test fun debounceCollapsesRapidQueriesIntoOneSearch() = runTest {
        val stub = Stub { SearchResults(hits(0 until 3), 3) }
        val m = model(stub, this)
        m.searchDebounced("m", BrowseKind.SONGS, creds = creds)
        advanceTimeBy(100)
        m.searchDebounced("mi", BrowseKind.SONGS, creds = creds)
        advanceTimeBy(299)
        assertTrue(stub.calls.isEmpty())
        advanceTimeBy(2)
        assertEquals(listOf("mi"), stub.calls.map { it.query })
        assertEquals(OnlineSearchModel.State.Loaded, m.ui.value.state)
    }

    @Test fun cancelResetsToIdle() = runBlocking {
        val m = model(Stub { SearchResults(hits(0 until 5), 5) })
        m.startSearch("q", BrowseKind.SONGS, creds = creds)
        m.cancel()
        assertEquals(OnlineSearchModel.State.Idle, m.ui.value.state)
        assertTrue(m.ui.value.hits.isEmpty())
    }
}

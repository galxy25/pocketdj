package com.levi.pocketdj.screens.history

import com.levi.pocketdj.data.catalog.MergedCatalog
import com.levi.pocketdj.data.history.HistorySettings
import com.levi.pocketdj.data.history.HistorySnapshot
import com.levi.pocketdj.data.history.PlayEvent
import com.levi.pocketdj.data.settings.ClauseDoc
import com.levi.pocketdj.screens.browse.Clause
import com.levi.pocketdj.screens.browse.FilterOp
import com.levi.pocketdj.screens.browse.SortField
import com.levi.pocketdj.screens.browse.SortKey
import kotlinx.coroutines.ExperimentalCoroutinesApi
import kotlinx.coroutines.test.StandardTestDispatcher
import kotlinx.coroutines.test.advanceTimeBy
import kotlinx.coroutines.test.advanceUntilIdle
import kotlinx.coroutines.test.runCurrent
import kotlinx.coroutines.test.runTest
import kotlinx.coroutines.launch
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNotEquals
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test

@OptIn(ExperimentalCoroutinesApi::class)
class HistoryBrowseStateTest {

    private fun events(vararg at: Double) =
        at.mapIndexed { i, t -> PlayEvent(id = "e$i", songId = "s$i", playedAt = t, title = "Song $i", artist = "Art") }

    private fun base(evs: List<PlayEvent>, hideSkips: Boolean = false) =
        buildItems(evs, MergedCatalog.EMPTY, hideSkips, playCountOf = { 1 })

    private fun newState(disp: kotlinx.coroutines.CoroutineDispatcher) =
        HistoryBrowseState(debounceMs = 180, filterDispatcher = disp)

    @Test
    fun defaultSort_isLastPlayedDesc_andPublishesStampedKey() = runTest {
        val s = newState(StandardTestDispatcher(testScheduler))
        s.externalBase = { base(events(1_000.0, 3_000.0, 2_000.0)) }
        s.refreshExternal("sig", "base")
        assertEquals(listOf("e1", "e2", "e0"), s.results.value.rows.map { s.results.value.refOf(it)!!.eventId })
        assertEquals("sig", s.displayKey)
        assertEquals(HistoryInputs.DEFAULT_SORT, s.inputs.value.sortKeys)
    }

    @Test
    fun sortAscending_reversesTimeline() = runTest {
        val s = newState(StandardTestDispatcher(testScheduler))
        s.externalBase = { base(events(1_000.0, 3_000.0, 2_000.0)) }
        s.setSortKeys(listOf(SortKey(SortField.LAST_PLAYED_AT, ascending = true)))
        s.refreshExternal("sig", "base")
        assertEquals(listOf("e0", "e2", "e1"), s.results.value.rows.map { s.results.value.refOf(it)!!.eventId })
    }

    @Test
    fun lastPlayedBetween_filtersRows() = runTest {
        val s = newState(StandardTestDispatcher(testScheduler))
        s.externalBase = { base(events(1_000.0, 3_000.0, 2_000.0)) }
        s.setClauses(listOf(Clause("lastPlayedAt", FilterOp.BETWEEN, min = 1_500.0, max = 2_500.0)))
        s.refreshExternal("sig", "base")
        assertEquals(listOf("e2"), s.results.value.rows.map { s.results.value.refOf(it)!!.eventId })
    }

    @Test
    fun supersede_duringDebounce_abandonsPublish() = runTest {
        val s = newState(StandardTestDispatcher(testScheduler))
        var builds = 0
        s.externalBase = { builds++; base(events(1.0, 2.0)) }
        s.setQuery("song")
        val job = launch { s.refreshExternal("sig-song", "base") }
        runCurrent()
        // The user keeps typing while the debounce sleeps: the inputs moved.
        s.setQuery("song 1")
        advanceTimeBy(500)
        job.join()
        assertEquals("no base built for an abandoned run", 0, builds)
        assertNull("displayKey must NOT be stamped with the stale signature", s.displayKey)
        assertTrue(s.results.value.rows.isEmpty())
    }

    @Test
    fun supersede_duringFilter_abandonsPublish() = runTest {
        val s = newState(StandardTestDispatcher(testScheduler))
        // Empty query -> no debounce; the inputs move DURING the base build / filter window.
        s.externalBase = {
            s.setClauses(listOf(Clause("lastPlayedAt", FilterOp.BETWEEN, min = 0.0, max = 1.0)))
            base(events(1.0, 2.0))
        }
        s.refreshExternal("sig", "base")
        assertNull(s.displayKey)
        assertTrue(s.results.value.rows.isEmpty())
    }

    @Test
    fun emptyBase_isNeverMemoized_nonEmptyIs() = runTest {
        val s = newState(StandardTestDispatcher(testScheduler))
        var builds = 0
        var evs = emptyList<PlayEvent>()
        s.externalBase = { builds++; base(evs) }
        s.refreshExternal("sig1", "base")
        s.refreshExternal("sig2", "base") // same baseKey, empty answer last time -> must rebuild
        assertEquals(2, builds)

        evs = events(1.0)
        s.refreshExternal("sig3", "base")
        assertEquals(3, builds)
        assertEquals(1, s.results.value.rows.size)
        s.refreshExternal("sig4", "base") // now memoized under the same baseKey
        assertEquals(3, builds)
    }

    @Test
    fun noBaseBound_publishesAndStampsNothing_thenRecovers() = runTest {
        val s = newState(StandardTestDispatcher(testScheduler))
        s.refreshExternal("sig", "base")
        assertNull(s.displayKey)
        assertTrue(s.results.value.rows.isEmpty())
        s.externalBase = { base(events(1.0)) }
        s.refreshExternal("sig", "base") // the SAME signature must now compute for real
        assertEquals("sig", s.displayKey)
        assertEquals(1, s.results.value.rows.size)
    }

    @Test
    fun alreadyCurrentSignature_shortCircuits_untilInvalidated() = runTest {
        val s = newState(StandardTestDispatcher(testScheduler))
        var builds = 0
        s.externalBase = { builds++; base(events(1.0)) }
        s.refreshExternal("sig", "base")
        s.refreshExternal("sig", "base")
        assertEquals(1, builds)

        s.invalidateDisplayKey() // explicit submit drops BOTH memos
        assertNull(s.displayKey)
        s.refreshExternal("sig", "base")
        assertEquals("invalidate must also drop the base memo", 2, builds)
        assertEquals("sig", s.displayKey)
    }

    @Test
    fun submit_bumpsNonce_soTheEffectRefires_withUnchangedSignature() {
        val s = newState(StandardTestDispatcher())
        val sigBefore = s.inputs.value.signature()
        val nonceBefore = s.inputs.value.submitNonce
        s.submit()
        assertEquals(sigBefore, s.inputs.value.signature())
        assertEquals(nonceBefore + 1, s.inputs.value.submitNonce)
    }

    @Test
    fun query_isTransient_andNotInSnapshot() {
        val s = newState(StandardTestDispatcher())
        s.setQuery("secret")
        s.setHideSkips(true)
        val raw = HistorySettings.encode(s.toSnapshot())
        assertFalse(raw.contains("secret"))
        assertFalse(raw.contains("hideSkips"))
    }

    @Test
    fun pagingKey_changesWithInputsAndLog_butNeverWithCatalog() {
        val s = newState(StandardTestDispatcher())
        val k = s.pagingKey(historyRevision = 4, resultCount = 10)
        assertEquals("same revision/inputs/count -> same key (catalog identity is not an input)", k, s.pagingKey(4, 10))
        assertNotEquals(k, s.pagingKey(5, 10))
        assertNotEquals(k, s.pagingKey(4, 11))
        s.setHideSkips(true)
        assertNotEquals(k, s.pagingKey(4, 10))
    }

    @Test
    fun hideSkips_isPartOfSignature() {
        val a = HistoryInputs()
        assertNotEquals(a.signature(), a.copy(hideSkips = true).signature())
        assertEquals(1, a.copy(hideSkips = true).activeCount)
    }

    @Test
    fun snapshot_roundTrips_clausesAndSort() {
        val s = newState(StandardTestDispatcher())
        s.setClauses(listOf(Clause("lastPlayedAt", FilterOp.BETWEEN, min = 10.0, max = 20.0)))
        s.setSortKeys(listOf(SortKey(SortField.NAME, ascending = true)))
        val raw = HistorySettings.encode(s.toSnapshot())

        val s2 = newState(StandardTestDispatcher())
        assertFalse(s2.restored)
        s2.restore(HistorySettings.decode(raw))
        assertTrue(s2.restored)
        val c = s2.inputs.value.clauses.single()
        assertEquals("lastPlayedAt", c.field)
        assertEquals(FilterOp.BETWEEN, c.op)
        assertEquals(10.0, c.min!!, 0.0)
        assertEquals(20.0, c.max!!, 0.0)
        assertEquals(listOf(SortKey(SortField.NAME, true)), s2.inputs.value.sortKeys)
    }

    @Test
    fun restore_corruptDoc_emptySort_andUnknownFields_fallToSafeDefaults() {
        assertEquals(HistorySnapshot(), HistorySettings.decode("{not json"))
        assertEquals(HistorySnapshot(), HistorySettings.decode(""))
        val s = newState(StandardTestDispatcher())
        s.restore(
            HistorySnapshot(
                clauses = listOf(ClauseDoc(field = "futureField", op = "eq", value = "x")),
            ),
        )
        assertTrue("unknown clause field dropped", s.inputs.value.clauses.isEmpty())
        assertEquals("empty sort -> most recent first", HistoryInputs.DEFAULT_SORT, s.inputs.value.sortKeys)
    }

    @Test
    fun query_filtersRows_afterDebounce() = runTest {
        val s = newState(StandardTestDispatcher(testScheduler))
        s.externalBase = { base(events(1.0, 2.0, 3.0)) }
        s.setQuery("song 1")
        val job = launch { s.refreshExternal("sig", "base") }
        advanceUntilIdle()
        job.join()
        assertEquals(listOf("e1"), s.results.value.rows.map { s.results.value.refOf(it)!!.eventId })
    }
}

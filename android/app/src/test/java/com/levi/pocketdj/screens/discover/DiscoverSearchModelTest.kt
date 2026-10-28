package com.levi.pocketdj.screens.discover

import kotlinx.coroutines.ExperimentalCoroutinesApi
import kotlinx.coroutines.test.TestScope
import kotlinx.coroutines.test.advanceTimeBy
import kotlinx.coroutines.test.advanceUntilIdle
import kotlinx.coroutines.test.runCurrent
import kotlinx.coroutines.test.runTest
import com.levi.pocketdj.data.rips.RipServerClient
import org.junit.Assert.assertEquals
import org.junit.Assert.assertTrue
import org.junit.Test

@OptIn(ExperimentalCoroutinesApi::class)
class DiscoverSearchModelTest {
    private fun h(id: String, artist: String = "A") =
        DiscoverHit(appleMusicId = id, title = "t$id", artist = artist, songId = "amrec_$id")

    private fun runner(
        scope: kotlinx.coroutines.CoroutineScope,
        rest: suspend (String) -> DiscoverRestResult<DiscoverHit> = { DiscoverRestResult(emptyList(), true) },
        server: suspend (String) -> List<DiscoverHit> = { emptyList() },
        configured: Boolean = true,
        onTerm: (String) -> Unit = {},
    ) = DiscoverQueryRunner(
        scope = scope,
        rest = { onTerm(it); rest(it) },
        server = server,
        serverConfigured = { configured },
        merge = DiscoverMerge::mergeSongs,
        refine = DiscoverMerge::refineSongs,
    )

    @Test fun blankQuery_staysIdle() = runTest {
        val r = runner(this)
        r.searchDebounced("  ", "")
        assertEquals(DiscoverState.Idle, r.ui.value.state)
    }

    @Test fun loadingIsSynchronous_andDebounceCoalescesBurst() = runTest {
        val terms = mutableListOf<String>()
        val r = runner(this, rest = { DiscoverRestResult(listOf(h("1")), true) }, onTerm = { terms += it })
        r.searchDebounced("d")
        assertEquals(DiscoverState.Loading, r.ui.value.state) // before the debounce elapses
        advanceTimeBy(200); r.searchDebounced("da")
        advanceTimeBy(200); r.searchDebounced("daf")
        advanceTimeBy(399)
        runCurrent()
        assertTrue(terms.isEmpty())
        advanceTimeBy(2)
        advanceUntilIdle()
        assertEquals(listOf("daf"), terms)
        assertEquals(DiscoverState.Loaded, r.ui.value.state)
        assertEquals(listOf("1"), r.ui.value.hits.map { it.appleMusicId })
    }

    @Test fun immediateSubmit_skipsDebounce() = runTest {
        val r = runner(this, rest = { DiscoverRestResult(listOf(h("1")), true) })
        r.searchDebounced("x", immediate = true)
        runCurrent()
        assertEquals(DiscoverState.Loaded, r.ui.value.state)
    }

    @Test fun mergesBothSources_andRefineNarrows() = runTest {
        val r = runner(
            this,
            rest = { DiscoverRestResult(listOf(h("1", "Daft Punk"), h("2", "Other")), true) },
            server = { listOf(h("3", "Daft Punk"), h("2", "Other")) },
        )
        r.run("one more", "daft")
        assertEquals(listOf("1", "3"), r.ui.value.hits.map { it.appleMusicId })
    }

    @Test fun serverFailure_withRestHits_keepsHitsAndShowsNotice() = runTest {
        val r = runner(
            this,
            rest = { DiscoverRestResult(listOf(h("1")), true) },
            server = { throw RipServerClient.RipServerException(401, "x") },
        )
        r.run("q", "")
        assertEquals(DiscoverState.Loaded, r.ui.value.state)
        assertEquals(1, r.ui.value.hits.size)
        assertTrue(r.ui.value.notice!!.contains("rejected"))
    }

    @Test fun serverFailure_nothingElse_isDiscoverUnavailable() = runTest {
        val r = runner(this, server = { throw java.io.IOException("down") })
        r.run("q", "")
        val s = r.ui.value.state as DiscoverState.Unavailable
        assertTrue(s.message.contains("unreachable"))
        assertEquals("Discover unavailable", DiscoverQueryRunner.UNAVAILABLE)
    }

    @Test fun noServer_andRestUnavailable_isNoSources() = runTest {
        val r = runner(this, rest = { DiscoverRestResult(emptyList(), false) }, configured = false)
        r.run("q", "")
        assertEquals(DiscoverState.NoSources, r.ui.value.state)
    }

    @Test fun noServer_butRestAvailable_isLoadedEvenWhenEmpty() = runTest {
        val r = runner(this, configured = false)
        r.run("q", "")
        assertEquals(DiscoverState.Loaded, r.ui.value.state)
        assertTrue(r.ui.value.hits.isEmpty())
    }

    @Test fun restThrowing_degradesToServerOnly() = runTest {
        val r = runner(this, rest = { error("no token") }, server = { listOf(h("5")) })
        r.run("q", "")
        assertEquals(listOf("5"), r.ui.value.hits.map { it.appleMusicId })
    }

    @Test fun cancel_clearsToIdle() = runTest {
        val r = runner(this, rest = { DiscoverRestResult(listOf(h("1")), true) })
        r.run("q", "")
        r.cancel()
        assertEquals(DiscoverUi<DiscoverHit>(), r.ui.value)
    }

    @Test fun failureMessages() {
        assertEquals("Search failed (500).", DiscoverQueryRunner.failureMessage(RipServerClient.RipServerException(500, "x")))
    }
}

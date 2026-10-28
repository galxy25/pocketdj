package com.levi.pocketdj.screens.playlists

import com.levi.pocketdj.data.burns.BurnItem
import com.levi.pocketdj.data.burns.BurnProgress
import com.levi.pocketdj.data.burns.BurnResult
import com.levi.pocketdj.data.burns.BurnSong
import com.levi.pocketdj.data.burns.BurnState
import com.levi.pocketdj.data.rips.BatchRipResult
import com.levi.pocketdj.data.rips.RipJob
import com.levi.pocketdj.playback.PlaybackMode
import java.util.concurrent.atomic.AtomicBoolean
import kotlinx.coroutines.CompletableDeferred
import kotlinx.coroutines.ExperimentalCoroutinesApi
import kotlinx.coroutines.test.StandardTestDispatcher
import kotlinx.coroutines.test.TestScope
import kotlinx.coroutines.test.advanceUntilIdle
import kotlinx.coroutines.test.runTest
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test

@OptIn(ExperimentalCoroutinesApi::class)
class CollectionBurnBarStateTest {
    @Test fun burnSummaryPartialSuccess() {
        val r = BurnResult(burned = 3, notRipped = 2, failed = 1, total = 6, stemmedSongs = 2, beatGridded = 1)
        assertEquals(
            "Burned 3 of 6 · 2 with stems · 1 with beat grids · 2 not yet ripped · 1 failed · prepared one at a time",
            CollectionBurnReducer.burnSummary(r, hasServer = true),
        )
        assertEquals(
            "Burned 3 of 6 · 2 with stems · 1 with beat grids · 2 not yet ripped · 1 failed",
            CollectionBurnReducer.burnSummary(r, hasServer = false),
        )
    }

    @Test fun burnSummaryStoppedAndOutOfSpaceAndFolder() {
        val r = BurnResult(burned = 1, notRipped = 4, total = 5, outOfSpace = true, stopped = true)
        assertEquals("Burned 1 of 5 · 4 not yet ripped · out of space — stopped early · stopped", CollectionBurnReducer.burnSummary(r, true))
        assertTrue(CollectionBurnReducer.burnSummary(BurnResult(total = 3, folderUnavailable = true), true).startsWith("Couldn’t write"))
        assertFalse(CollectionBurnReducer.shouldRipMissing(r, true))
        assertFalse(CollectionBurnReducer.canRefreshAfterBurn(r))
        assertTrue(CollectionBurnReducer.shouldRipMissing(BurnResult(notRipped = 1, total = 1), true))
        assertFalse(CollectionBurnReducer.shouldRipMissing(BurnResult(notRipped = 1, total = 1), false))
    }

    @Test fun ripSummary() {
        assertEquals("Nothing to rip.", CollectionBurnReducer.ripSummary(BatchRipResult()))
        assertEquals(
            "2 already ripped · 4 enqueued — completes over time · 1 unrippable · prepared one at a time",
            CollectionBurnReducer.ripSummary(BatchRipResult(ready = 2, queued = 3, inflight = 1, unknown = 1)),
        )
    }

    @Test fun ripProgressLabels() {
        assertEquals("ripping — 3 of 12 done", CollectionBurnReducer.ripProgressLabel(3, 12))
        assertNull(CollectionBurnReducer.ripProgressLabel(12, 12))
        assertEquals("Ripped 12 of 12", CollectionBurnReducer.ripProgressSummary(12, 12))
    }

    @Test fun pill() {
        assertNull(CollectionBurnReducer.pillFraction(null))
        assertNull(CollectionBurnReducer.pillFraction(BurnProgress(0, 0, "")))
        assertEquals(0.25f, CollectionBurnReducer.pillFraction(BurnProgress(1, 4, "Burning"))!!, 0f)
        assertEquals("Burning 1/4", CollectionBurnReducer.pillText(BurnProgress(1, 4, "Burning")))
    }

    private fun item(state: BurnState, error: String?) = BurnItem(
        songId = "s", title = "t", artist = "a", audioFileName = "f", sidecarFileName = "f.txt",
        source = "digital", state = state, error = error,
    )

    @Test fun rowNotes() {
        assertEquals("not ripped — Rip first", CollectionBurnReducer.rowNote(item(BurnState.ERROR, "not ripped — Rip first"), null))
        assertNull(CollectionBurnReducer.rowNote(item(BurnState.ERROR, "disk full"), null))
        assertNull(CollectionBurnReducer.rowNote(item(BurnState.READY, null), null))
        assertEquals("Ripping\u2026", CollectionBurnReducer.rowNote(null, RipJob(phase = "ripping")))
        assertEquals("Queued\u2026", CollectionBurnReducer.rowNote(null, RipJob(phase = "queued")))
        assertNull(CollectionBurnReducer.rowNote(null, RipJob(phase = "error")))
        // Once the song is in the manifest the stale ledger error is suppressed.
        assertNull(CollectionBurnReducer.rowNote(item(BurnState.ERROR, "not ripped — Rip first"), null, manifestHit = true))
        assertEquals(
            "not ripped — Rip first",
            CollectionBurnReducer.rowNote(item(BurnState.ERROR, "not ripped — Rip first"), RipJob(phase = "queued")),
        )
    }

    @Test fun modeToggleFlips() {
        assertEquals(PlaybackMode.DEVICE, PlaybackMode.CLOUD.toggled())
        assertEquals(PlaybackMode.CLOUD, PlaybackMode.DEVICE.toggled())
    }

    // ---- controller state machine ------------------------------------------------------------

    private fun TestScope.controller(
        burn: suspend (List<BurnSong>) -> BurnResult = { BurnResult(burned = it.size, total = it.size) },
        rip: suspend (List<String>) -> BatchRipResult = { BatchRipResult() },
        ripped: MutableSet<String> = mutableSetOf(),
        stopFlag: AtomicBoolean = AtomicBoolean(false),
        canceled: MutableList<String> = mutableListOf(),
    ) = CollectionBurnController(
        scope = this, burn = burn, requestStopBurn = { stopFlag.set(true) },
        ripCollection = rip, cancelRips = { canceled.addAll(it) },
        isRipped = { it in ripped }, refreshManifest = {}, hasServer = { true },
        tuples = { ids -> ids.map { BurnSong(it, it, "x") } },
        pollIntervalMs = 10, maxTicks = 5,
    )

    @Test fun burnLifecycleProducesSummary() = runTest(StandardTestDispatcher()) {
        val gate = CompletableDeferred<Unit>()
        val c = controller(burn = { gate.await(); BurnResult(burned = 2, total = 2) })
        c.burn(listOf("a", "b"))
        advanceUntilIdle()
        assertTrue(c.state.value.working); assertTrue(c.state.value.showStop)
        assertNull(c.burn(listOf("a"))) // re-entry blocked while working
        gate.complete(Unit); advanceUntilIdle()
        val s = c.state.value
        assertFalse(s.working); assertTrue(s.showSummary); assertEquals("Burned 2 of 2", s.summary); assertFalse(s.showStop)
    }

    @Test fun burnAutoRipsMissingThenSummaryReportsNotRipped() = runTest(StandardTestDispatcher()) {
        val ripCalls = mutableListOf<List<String>>()
        val c = controller(
            burn = { BurnResult(burned = 1, notRipped = 1, total = 2) },
            rip = { ripCalls += it; BatchRipResult() },
            ripped = mutableSetOf("a"),
        )
        c.burn(listOf("a", "b")); advanceUntilIdle()
        assertEquals(listOf(listOf("b")), ripCalls)
        assertTrue(c.state.value.summary!!.contains("1 not yet ripped"))
        assertTrue(c.state.value.canRefresh)
    }

    @Test fun stopDuringBurnSignalsStoreAndShowsStoppedSummary() = runTest(StandardTestDispatcher()) {
        val flag = AtomicBoolean(false)
        val gate = CompletableDeferred<Unit>()
        // Like BurnStore: stop is cooperative; the loop notices the flag and returns a partial result.
        val c = controller(burn = { gate.await(); BurnResult(burned = 1, total = 3, stopped = flag.get()) }, stopFlag = flag)
        c.burn(listOf("a")); advanceUntilIdle()
        c.stop(); gate.complete(Unit); advanceUntilIdle()
        assertTrue(flag.get())
        assertFalse(c.state.value.working)
        assertTrue(c.state.value.showSummary)
        assertTrue(c.state.value.summary!!.contains("stopped"))
    }

    @Test fun burnCancelledByScopeResetsWorking() = runTest(StandardTestDispatcher()) {
        val gate = CompletableDeferred<Unit>()
        val c = controller(burn = { gate.await(); BurnResult(total = 1) })
        val job = c.burn(listOf("a"))!!; advanceUntilIdle()
        job.cancel(); advanceUntilIdle()
        assertFalse(c.state.value.working)
        assertNull(c.state.value.inFlightOp)
    }

    @Test fun ripPollsUntilAllRippedThenStops() = runTest(StandardTestDispatcher()) {
        val ripped = mutableSetOf<String>()
        val c = controller(rip = { BatchRipResult(queued = 2, total = 2) }, ripped = ripped)
        c.rip(listOf("a", "b")); testScheduler.runCurrent()
        assertTrue(c.state.value.ripInProgress)
        assertEquals("ripping — 0 of 2 done", c.state.value.ripProgress)
        ripped += "a"; ripped += "b"
        testScheduler.advanceTimeBy(11); testScheduler.runCurrent()
        assertFalse(c.state.value.ripInProgress)
        assertEquals("Ripped 2 of 2", c.state.value.summary)
    }

    @Test fun stopRipCancelsServerJobsAndPoll() = runTest(StandardTestDispatcher()) {
        val canceled = mutableListOf<String>()
        val c = controller(rip = { BatchRipResult(queued = 2, total = 2) }, canceled = canceled)
        c.rip(listOf("a", "b")); testScheduler.runCurrent()
        assertTrue(c.state.value.ripInProgress)
        c.stop(); testScheduler.runCurrent()
        assertEquals(listOf("a", "b"), canceled)
        assertFalse(c.state.value.ripInProgress)
        assertFalse(c.state.value.showStop)
    }
}

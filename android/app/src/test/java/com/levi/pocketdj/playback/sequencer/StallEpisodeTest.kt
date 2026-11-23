package com.levi.pocketdj.playback.sequencer

import com.levi.pocketdj.playback.PlaybackMode
import kotlin.random.Random
import kotlinx.coroutines.ExperimentalCoroutinesApi
import kotlinx.coroutines.test.TestScope
import kotlinx.coroutines.test.advanceTimeBy
import kotlinx.coroutines.test.currentTime
import kotlinx.coroutines.test.runCurrent
import kotlinx.coroutines.test.runTest
import org.junit.Assert.assertEquals
import org.junit.Assert.assertTrue
import org.junit.Test

/** iOS 532ac59f: consecutive hops never go back to an abandoned row; the episode ends on audio / user / stop. */
@OptIn(ExperimentalCoroutinesApi::class)
class StallEpisodeTest {
    private class H(val t: TestScope, val playable: Set<String>) {
        val port = FakePlayerPort()
        val logs = mutableListOf<String>()
        val registry = RowResolverRegistry(
            // every row resolves via the slow rip path (never reaches first audio on its own), yet a manifest hit
            // counts as "instant" for the hop - exactly the two-stalled-manifest-rows ping-pong.
            initial = listOf(MapResolver("rip", Rung.RIP_ON_DEMAND, playable.associateWith { RipOnDemandSource(it) })),
            manifestHit = { it in playable },
            ripServerConfigured = { true },
        )
        val seq = SetlistSequencer(
            scope = t.backgroundScope, port = port, registry = registry,
            modeProvider = { PlaybackMode.CLOUD }, random = Random(1),
            log = { logs += it }, clockMs = { t.currentTime },
        ).also { it.rowStartsInstantly = { r -> r.id in playable } }
        val order get() = seq.state.value.queue.map { it.id }
        val abandonedLogs get() = logs.filter { it.contains("stall episode end") }
        fun start(vararg ids: String) { seq.play(rows(*ids), null); t.runCurrent() }
    }

    @Test
    fun aStalls_hopB_bStalls_hopC_neverBackToA_queueOrderKeepsStalledBehind() = runTest {
        val h = H(this, setOf("a", "b", "c", "d"))
        h.start("a", "b", "c", "d")
        advanceTimeBy(6_100); runCurrent()
        assertEquals(listOf("b", "a", "c", "d"), h.order)
        advanceTimeBy(6_100); runCurrent()
        assertEquals("b stalls: C, never the abandoned A", listOf("c", "b", "a", "d"), h.order)
        advanceTimeBy(6_100); runCurrent()
        assertEquals(listOf("d", "c", "b", "a"), h.order)
        assertEquals(listOf("a", "b", "c", "d"), h.port.loadedIds)
    }

    @Test
    fun noEligibleTarget_currentRowKeepsBuffering_noRestartLoop() = runTest {
        val h = H(this, setOf("a", "b"))
        h.start("a", "b")
        advanceTimeBy(6_100); runCurrent()
        assertEquals(listOf("b", "a"), h.order)
        advanceTimeBy(60_000); runCurrent()
        assertEquals("b keeps buffering", "b", h.seq.currentSongId)
        assertEquals(listOf("a", "b"), h.port.loadedIds)
        assertEquals(listOf("b", "a"), h.order)
    }

    @Test
    fun firstAudioEndsTheEpisode_andClearsTheSet() = runTest {
        val h = H(this, setOf("a", "b", "c"))
        h.start("a", "b", "c")
        advanceTimeBy(6_100); runCurrent()
        h.seq.onFirstAudio("b")
        assertEquals(listOf("stall episode end reason=first-audio abandoned=1"), h.abandonedLogs.map { it.removePrefix("[playback] ") })
        // a fresh episode may hop to a again
        h.seq.skipNext(); runCurrent() // user transport; now on a (b, a, c -> a)
        assertEquals("a", h.seq.currentSongId)
    }

    @Test
    fun userTransportEndsTheEpisode() = runTest {
        val h = H(this, setOf("a", "b", "c"))
        h.start("a", "b", "c")
        advanceTimeBy(6_100); runCurrent()
        h.seq.skipNext(); runCurrent()
        assertTrue(h.logs.any { it.endsWith("stall episode end reason=user abandoned=1") })
        assertEquals("a", h.seq.currentSongId) // [b, a, c] -> skip lands on a
        advanceTimeBy(6_100); runCurrent()
        assertEquals("fresh episode: a stalls -> c (b is behind the cursor)", listOf("b", "c", "a"), h.order)
    }

    @Test
    fun stopEndsTheEpisode_noLogWhenNoHopHappened() = runTest {
        val h = H(this, setOf("a", "b"))
        h.start("a", "b")
        h.seq.stop(); runCurrent()
        assertTrue("no hop -> nothing to log", h.abandonedLogs.isEmpty())
        val h2 = H(this, setOf("a", "b"))
        h2.start("a", "b")
        advanceTimeBy(6_100); runCurrent()
        h2.seq.stop(); runCurrent()
        assertTrue(h2.logs.any { it.endsWith("stall episode end reason=stop abandoned=1") })
    }
}

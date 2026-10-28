package com.levi.pocketdj.playback.sequencer

import com.levi.pocketdj.playback.am.EndReason
import com.levi.pocketdj.playback.health.AutoAdvanceCascadeBreaker
import kotlinx.coroutines.ExperimentalCoroutinesApi
import kotlinx.coroutines.test.TestScope
import kotlinx.coroutines.test.runTest
import org.junit.Assert.assertEquals
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test

@OptIn(ExperimentalCoroutinesApi::class)
class AppleMusicRowTest {
    private fun TestScope.harness(canPlay: Boolean = true, vararg playable: String) = SequencerHarness(
        this, backgroundScope, playable.toSet(),
        extra = listOf(AppleMusicRowResolver(appleMusicIdFor = { "am_${it.id}" }, canPlayFullTrack = { canPlay })),
    )

    // ---- resolver ----

    @Test fun resolver_hit_isAppleMusicSourceWithBackendLabel() = runTest {
        val r = AppleMusicRowResolver({ "123" }, { true })
        val s = r.resolve(QueueItem("a"), ResolveContext(com.levi.pocketdj.playback.PlaybackMode.CLOUD, true, false))
        assertEquals(AppleMusicSource("123", "a"), s)
        assertEquals("appleMusic", s!!.backend)
        assertEquals(Rung.APPLE_MUSIC, r.rung)
    }

    @Test fun resolver_emulator_cannotPlayFullTrack_fallsThrough() = runTest {
        val r = AppleMusicRowResolver({ "123" }, { false })
        assertNull(r.resolve(QueueItem("a"), ResolveContext(com.levi.pocketdj.playback.PlaybackMode.CLOUD, true, false)))
    }

    @Test fun resolver_noAppleMusicId_fallsThrough() = runTest {
        val r = AppleMusicRowResolver({ null }, { true })
        assertNull(r.resolve(QueueItem("a"), ResolveContext(com.levi.pocketdj.playback.PlaybackMode.CLOUD, true, false)))
    }

    @Test fun resolver_defersWhenRipStartsNow_unlessAppleSourced() = runTest {
        val ctx = ResolveContext(com.levi.pocketdj.playback.PlaybackMode.CLOUD, true, ripStartsNow = true)
        assertNull(AppleMusicRowResolver({ "1" }, { true }).resolve(QueueItem("a"), ctx))
        assertEquals(
            AppleMusicSource("1", "a"),
            AppleMusicRowResolver({ "1" }, { true }, isAppleMusicSourced = { true }).resolve(QueueItem("a"), ctx),
        )
    }

    @Test fun ladder_rungOrder_manifestBeatsAppleMusic_appleBeatsRipOnDemand() {
        assertTrue(Rung.MANIFEST.order < Rung.APPLE_MUSIC.order)
        assertTrue(Rung.APPLE_MUSIC.order < Rung.RIP_ON_DEMAND.order)
    }

    @Test fun deviceMode_neverConsultsAppleMusicRung() = runTest {
        val h = harness(true)
        h.mode = com.levi.pocketdj.playback.PlaybackMode.DEVICE
        h.seq.play(rows("a"))
        h.settle()
        assertTrue(h.port.loads.none { it.source is AppleMusicSource })
    }

    // ---- sequencer verdict handling ----

    @Test fun amRow_loadsAsAppleMusicSource_andLogsBackend() = runTest {
        val h = harness(true)
        h.seq.play(rows("a"))
        h.settle()
        assertEquals(AppleMusicSource("am_a", "a"), h.port.loads.single().source)
        assertTrue(h.logs.any { it.contains("backend=appleMusic") })
    }

    @Test fun systemSkip_advances_evenUnderRepeatOne() = runTest {
        val h = harness(true)
        h.seq.play(rows("a", "b"))
        h.seq.setRepeatMode(RepeatMode.ONE)
        h.settle()
        h.seq.handleAppleMusicEnded("a", EndReason.SYSTEM_SKIP)
        h.settle()
        assertEquals(listOf("a", "b"), h.port.loadedIds)
        assertEquals(1, h.index)
    }

    @Test fun neverStarted_advances_neverReplays_underRepeatOne() = runTest {
        val h = harness(true)
        h.seq.play(rows("a", "b"))
        h.seq.setRepeatMode(RepeatMode.ONE)
        h.settle()
        h.seq.handleAppleMusicEnded("a", EndReason.NEVER_STARTED)
        h.settle()
        assertEquals(listOf("a", "b"), h.port.loadedIds)
        assertTrue(h.logs.any { it.contains("AM never started") })
    }

    @Test fun natural_underRepeatOne_replaysTheSong() = runTest {
        val h = harness(true)
        h.seq.play(rows("a", "b"))
        h.seq.setRepeatMode(RepeatMode.ONE)
        h.settle()
        h.seq.handleAppleMusicEnded("a", EndReason.NATURAL)
        h.settle()
        // Replayed in place (the production port declines for AM and the sequencer then reloads).
        assertEquals(listOf("a"), h.port.replays)
        assertEquals(0, h.index)
    }

    @Test fun natural_advancesToNext() = runTest {
        val h = harness(true)
        h.seq.play(rows("a", "b"))
        h.settle()
        h.seq.handleAppleMusicEnded("a", EndReason.NATURAL)
        h.settle()
        assertEquals(listOf("a", "b"), h.port.loadedIds)
    }

    @Test fun staleRow_endIsIgnored() = runTest {
        val h = harness(true)
        h.seq.play(rows("a", "b"))
        h.settle()
        h.seq.handleAppleMusicEnded("zzz", EndReason.SYSTEM_SKIP)
        h.settle()
        assertEquals(listOf("a"), h.port.loadedIds)
    }

    @Test fun restarted_stepsBack() = runTest {
        val h = harness(true)
        h.seq.play(rows("a", "b", "c"))
        h.settle()
        h.seq.skipNext()
        h.settle()
        assertEquals(1, h.index)
        h.seq.handleAppleMusicRestarted("b")
        h.settle()
        assertEquals(0, h.index)
        assertEquals("a", h.port.loadedIds.last())
    }

    @Test fun interrupted_holdsWithNotice_resumedClearsIt() = runTest {
        val h = harness(true)
        h.seq.play(rows("a", "b"))
        h.settle()
        h.seq.noteAppleMusicInterrupted("a")
        h.settle()
        assertEquals(AutoAdvanceCascadeBreaker.APPLE_MUSIC_NOTICE, h.seq.state.value.playbackNotice)
        assertEquals(0, h.index)
        assertEquals(listOf("a"), h.port.loadedIds) // nothing advanced
        h.seq.noteAppleMusicResumed("a")
        assertNull(h.seq.state.value.playbackNotice)
    }
}

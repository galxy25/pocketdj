package com.levi.pocketdj.studio.demux

import com.levi.pocketdj.audio.core.OfflineRenderer
import com.levi.pocketdj.audio.core.SyntheticPcmSource
import java.io.File
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.SupervisorJob
import org.junit.After
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test

class StemPlayerSyncTest {
    private val scope = CoroutineScope(SupervisorJob() + Dispatchers.Default)
    private val names = listOf("vocals", "drums", "bass", "other")
    private var player: VoiceGroupStemPlayer? = null
    private var sink: OfflineRenderer? = null

    @After fun tearDown() { player?.stop(); scope.coroutineContext[kotlinx.coroutines.Job]?.cancel() }

    /** Four stems that are constant levels 0.1/0.2/0.3/0.4 so a mix reveals exactly which are audible. */
    private fun load(total: Long = 200_000): VoiceGroupStemPlayer {
        val levels = mapOf("vocals" to 0.1f, "drums" to 0.2f, "bass" to 0.3f, "other" to 0.4f)
        val p = VoiceGroupStemPlayer(
            sinkFactory = { OfflineRenderer().also { sink = it } },
            openSource = { f -> val lv = levels.getValue(f.name); SyntheticPcmSource(total = total) { _, _ -> lv } },
            scope = scope,
        )
        p.load("k#stems", names.associateWith { File(it) })
        player = p
        return p
    }

    private fun waitFor(what: String, cond: () -> Boolean) {
        val end = System.currentTimeMillis() + 5_000
        while (!cond() && System.currentTimeMillis() < end) Thread.sleep(5)
        assertTrue(what, cond())
    }

    /** Render until the mix goes non-zero (all voices started on one frame); returns the settled mix level. */
    private fun firstAudible(): Float {
        val r = sink!!
        repeat(1000) {
            val out = r.renderFrames(512)
            val i = OfflineRenderer.firstNonZeroFrame(out)
            if (i >= 0) {
                // gain ramps are linear across one block: read the settled level a few blocks later
                val later = r.renderFrames(4096)
                return later[later.size - 2]
            }
            Thread.sleep(2)
        }
        error("never audible")
    }

    @Test fun mixStateRules() {
        val m = StemMixState()
        assertTrue(names.all { m.isAudible(it) })
        m.toggleMute("drums"); assertFalse(m.isAudible("drums")); assertTrue(m.isAudible("bass"))
        m.solo("bass"); assertTrue(m.isAudible("bass")); assertFalse(m.isAudible("vocals")); assertFalse(m.isAudible("drums"))
        m.solo("bass"); assertNull(m.soloed); assertFalse("mute set survives solo clear", m.isAudible("drums"))
        m.solo("vocals"); m.toggleMute("other")
        assertNull("muting clears solo", m.soloed); assertTrue(m.isAudible("vocals")); assertFalse(m.isAudible("other"))
        m.reset(); assertTrue(names.all { m.isAudible(it) })
    }

    @Test fun allFourStemsStartOnOneFrameAndSumTogether() {
        val p = load()
        assertEquals(200_000.0 / 44_100, p.durationSec, 1e-6)
        p.togglePlayPause()
        waitFor("playing") { p.isPlaying }
        // 0.1+0.2+0.3+0.4: every stem sounds from the very first audible frame (no stem lags the others).
        assertEquals(1.0f, firstAudible(), 1e-4f)
    }

    @Test fun soloLeavesOnlyThatStemAudible() {
        val p = load()
        p.solo("bass")
        waitFor("playing") { p.isPlaying }
        assertEquals("soloed bass only", 0.3f, firstAudible(), 1e-4f)
        assertEquals("bass", p.soloed)
        assertTrue(p.isAudible("bass")); assertFalse(p.isAudible("vocals"))
    }

    @Test fun muteDropsOneStemFromTheMix() {
        val p = load()
        p.toggleMute("drums")
        p.togglePlayPause()
        waitFor("playing") { p.isPlaying }
        assertEquals(0.8f, firstAudible(), 1e-4f)
    }

    @Test fun pausedSeekMovesThePositionAndPlaybackStartsThere() {
        val p = load()
        p.seek(1.0)
        assertEquals(1.0, p.currentTimeSec, 1e-6)
        p.seek(999.0)
        assertEquals("clamped to duration", p.durationSec, p.currentTimeSec, 1e-6)
    }

    @Test fun repeatLoadOfTheSameIdIsANoOpAndStopClears() {
        val p = load()
        val before = p.version.value
        p.load("k#stems", names.associateWith { File(it) })
        assertEquals(before, p.version.value)
        p.stop()
        assertFalse(p.isPlaying); assertEquals(0.0, p.durationSec, 0.0)
    }

    @Test fun unopenableStemsLoadNothing() {
        val p = VoiceGroupStemPlayer({ OfflineRenderer() }, { null }, scope)
        p.load("x", mapOf("vocals" to File("a")))
        assertEquals(0.0, p.durationSec, 0.0)
        p.togglePlayPause()
        assertFalse(p.isPlaying)
    }
}

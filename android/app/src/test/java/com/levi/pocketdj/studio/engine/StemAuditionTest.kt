package com.levi.pocketdj.studio.engine

import com.levi.pocketdj.audio.core.OfflineRenderer
import com.levi.pocketdj.audio.core.SyntheticPcmSource
import com.levi.pocketdj.studio.demux.StemMixState
import com.levi.pocketdj.studio.demux.StemPlayer
import com.levi.pocketdj.studio.demux.VoiceGroupStemPlayer
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.SupervisorJob
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow
import org.junit.After
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test
import java.io.File

/** Q118: the stem-carve sheet auditions the chosen stems through a synced stem player (iOS parity). */
class StemAuditionTest {
    private class FakeMix : MixAudition {
        override var isPlaying = false
        var pos = 0.0
        val log = mutableListOf<String>()
        override fun play() { isPlaying = true; log += "play" }
        override fun pause() { isPlaying = false; log += "pause" }
        override fun seek(sec: Double) { pos = sec; log += "seek $sec" }
        override fun playheadSec() = pos
    }

    private class FakeStems(var loadOk: Boolean = true) : StemPlayer {
        override val version: StateFlow<Int> = MutableStateFlow(0)
        override var isPlaying = false
        override var currentTimeSec = 0.0
        override var durationSec = 0.0
        private val m = StemMixState()
        override val soloed: String? get() = m.soloed
        override fun isAudible(name: String) = m.isAudible(name)
        var loads = 0; var loadedFiles: Map<String, File> = emptyMap()
        override fun load(id: String, files: Map<String, File>): Boolean {
            loads++; if (!loadOk) return false
            loadedFiles = files; durationSec = 100.0; m.reset(); return true
        }
        override fun togglePlayPause() { isPlaying = !isPlaying }
        override fun seek(sec: Double) { currentTimeSec = sec }
        override fun solo(name: String) = m.solo(name)
        override fun toggleMute(name: String) = m.toggleMute(name)
        override fun stop() { isPlaying = false; durationSec = 0.0; currentTimeSec = 0.0; m.reset() }
    }

    private val four = StemCarve.STEMS.associateWith { File("$it.mp3") }

    @Test fun enteringStemModeCarriesPositionAndPlayStateAndOnlyOnePlayerSounds() {
        val mix = FakeMix(); val stems = FakeStems(); val a = StemAudition(mix, stems)
        mix.play(); mix.pos = 12.5
        assertTrue(a.enterStems("s1", four, setOf("drums", "bass")))
        assertTrue(a.auditioningStems)
        assertFalse("full mix paused", mix.isPlaying)
        assertTrue("stems continue playing", stems.isPlaying)
        assertEquals(12.5, stems.currentTimeSec, 0.0)
        assertEquals(12.5, a.playheadSec(), 0.0)
        assertEquals(StemCarve.STEMS, stems.loadedFiles.keys.toList())
        assertTrue(stems.isAudible("drums") && stems.isAudible("bass"))
        assertFalse(stems.isAudible("vocals") || stems.isAudible("other"))
    }

    @Test fun chipsLiveMuteTheStemPlayer() {
        val stems = FakeStems(); val a = StemAudition(FakeMix(), stems)
        a.enterStems("s1", four, StemCarve.allEnabled())
        assertTrue(StemCarve.STEMS.all { stems.isAudible(it) })
        a.applyMutes(setOf("vocals"))
        assertEquals(listOf("vocals"), StemCarve.STEMS.filter { stems.isAudible(it) })
        a.applyMutes(setOf("vocals", "other"))
        assertEquals(listOf("vocals", "other"), StemCarve.STEMS.filter { stems.isAudible(it) })
    }

    @Test fun transportRoutesToTheAudibleEngine() {
        val mix = FakeMix(); val stems = FakeStems(); val a = StemAudition(mix, stems)
        a.toggle(); assertTrue(mix.isPlaying); a.toggle(); assertFalse(mix.isPlaying)
        a.seek(3.0); assertEquals(3.0, mix.pos, 0.0)
        a.enterStems("s1", four, StemCarve.allEnabled())
        mix.log.clear()
        a.toggle(); assertTrue(stems.isPlaying); assertTrue("mix untouched", mix.log.isEmpty())
        a.seek(7.0); assertEquals(7.0, stems.currentTimeSec, 0.0); assertEquals(3.0, mix.pos, 0.0)
        assertTrue(a.isPlaying)
    }

    @Test fun exitingHandsThePositionBackAndReleasesTheStems() {
        val mix = FakeMix(); val stems = FakeStems(); val a = StemAudition(mix, stems)
        a.enterStems("s1", four, StemCarve.allEnabled())
        a.toggle(); a.seek(40.0)
        a.exitStems()
        assertFalse(a.auditioningStems)
        assertFalse(stems.isPlaying); assertEquals(0.0, stems.durationSec, 0.0)
        assertEquals(40.0, mix.pos, 0.0); assertTrue(mix.isPlaying)
    }

    @Test fun incompleteOrUnopenableSetsKeepTheFullMixAudition() {
        val mix = FakeMix(); val a = StemAudition(mix, FakeStems())
        mix.play()
        assertFalse(a.enterStems("s1", four - "bass", StemCarve.allEnabled()))
        assertTrue("full mix resumes", mix.isPlaying); assertFalse(a.auditioningStems)
        val b = StemAudition(mix, FakeStems(loadOk = false))
        assertFalse(b.enterStems("s1", four, StemCarve.allEnabled()))
        assertTrue(mix.isPlaying); assertFalse(b.auditioningStems)
        assertTrue(StemAudition.caption(false).contains("full mix"))
        assertTrue(StemAudition.caption(true).contains("what gets cut"))
    }

    @Test fun aStemPlayerStoppedBehindTheSheetReloadsOnTheNextTransport() {
        val stems = FakeStems(); val a = StemAudition(FakeMix(), stems)
        a.enterStems("s1", four, setOf("drums"))
        stems.stop() // app backgrounded
        a.toggle()
        assertEquals(2, stems.loads)
        assertTrue(stems.isPlaying)
        assertEquals("mutes re-applied after the reload", listOf("drums"), StemCarve.STEMS.filter { stems.isAudible(it) })
    }

    // ---- the real synced player: what you hear is exactly the chosen stems ----

    private val scope = CoroutineScope(SupervisorJob() + Dispatchers.Default)
    private var real: VoiceGroupStemPlayer? = null
    @After fun tearDown() { real?.stop(); scope.coroutineContext[kotlinx.coroutines.Job]?.cancel() }

    @Test fun syncedStemAuditionSoundsOnlyTheEnabledChips() {
        var sink: OfflineRenderer? = null
        val levels = mapOf("vocals" to 0.1f, "drums" to 0.2f, "bass" to 0.3f, "other" to 0.4f)
        val p = VoiceGroupStemPlayer(
            sinkFactory = { OfflineRenderer().also { sink = it } },
            openSource = { f -> val lv = levels.getValue(f.nameWithoutExtension); SyntheticPcmSource(total = 200_000) { _, _ -> lv } },
            scope = scope,
        ).also { real = it }
        val mix = FakeMix().apply { isPlaying = true; pos = 1.0 }
        val a = StemAudition(mix, p)
        assertTrue(a.enterStems("song", four, setOf("drums", "other")))
        val end = System.currentTimeMillis() + 5_000
        while (!p.isPlaying && System.currentTimeMillis() < end) Thread.sleep(5)
        assertTrue(p.isPlaying)
        var level = 0f
        for (i in 0 until 1000) {
            val out = sink!!.renderFrames(512)
            if (OfflineRenderer.firstNonZeroFrame(out) >= 0) { val later = sink!!.renderFrames(4096); level = later[later.size - 2]; break }
            Thread.sleep(2)
        }
        assertEquals("drums 0.2 + other 0.4", 0.6f, level, 1e-4f)
    }
}

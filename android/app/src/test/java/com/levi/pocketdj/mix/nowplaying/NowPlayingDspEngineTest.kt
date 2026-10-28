package com.levi.pocketdj.mix.nowplaying

import com.levi.pocketdj.audio.core.OfflineRenderer
import com.levi.pocketdj.audio.core.PcmSource
import com.levi.pocketdj.audio.core.SyntheticPcmSource
import com.levi.pocketdj.audio.core.Voice
import com.levi.pocketdj.mix.engine.MixSourceOpener
import com.levi.pocketdj.mix.engine.StemHandover
import com.levi.pocketdj.mix.engine.VoiceRunner
import com.levi.pocketdj.mix.model.Effect
import kotlinx.coroutines.ExperimentalCoroutinesApi
import kotlinx.coroutines.test.StandardTestDispatcher
import kotlinx.coroutines.test.TestScope
import kotlinx.coroutines.test.runCurrent
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNotNull
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test
import java.io.File

@OptIn(ExperimentalCoroutinesApi::class)
class NowPlayingDspEngineTest {
    private val sr = 44_100

    /** Offline harness: the sink renders on demand, decoder pumping is interleaved per block, ticks every block. */
    private class Rig(val songSeconds: Int = 10) {
        val sr = 44_100
        val scope = TestScope(StandardTestDispatcher())
        val voices = ArrayList<Voice>()
        var sink: OfflineRenderer? = null
        val parts = LinkedHashMap<String, File>()
        var obtainable = false
        var fetchCalls = 0
        var fetchResult: suspend () -> Boolean = { false }
        var refuse = false
        val stemSource = object : DspStemSource {
            override fun localParts(songId: String): Map<String, File> = parts.toMap()
            override fun obtainable(songId: String) = obtainable
            override suspend fun fetch(songId: String, parts: List<String>): Boolean { fetchCalls++; return fetchResult() }
        }
        val opener = MixSourceOpener { f ->
            if (refuse) null
            else {
                val freq = if (f.name.startsWith("stem")) 440.0 else 440.0   // coherent: stems sum to the main level
                val amp = if (f.name.startsWith("stem")) 0.125f else 0.5f
                val total = sr.toLong() * songSeconds
                SyntheticPcmSource.tone(freq, total, sr, amp) as PcmSource
            }
        }
        val engine = NowPlayingDspEngine(
            sinkFactory = { OfflineRenderer(sr, 512).also { sink = it } },
            opener = opener,
            runner = VoiceRunner { v -> voices += v; AutoCloseable { voices.remove(v) } },
            stemSource = stemSource, scope = scope,
        )

        fun addAllParts() { for (n in listOf("vocals", "drums", "bass", "other")) parts[n] = File("stem-$n.mp3") }

        fun pump() {
            var guard = 0
            do { var any = false; for (v in voices.toList()) while (v.pump()) any = true; guard++ } while (any && guard < 100)
        }

        /** Render [frames] frames, ticking the engine every block. */
        fun render(frames: Int): FloatArray {
            val out = FloatArray(frames * 2)
            var done = 0
            while (done < frames) {
                pump()
                val n = minOf(512, frames - done)
                val b = sink!!.renderFrames(n)
                System.arraycopy(b, 0, out, done * 2, n * 2)
                done += n
                engine.tick()
                scope.testScheduler.runCurrent()
            }
            return out
        }

        fun peak(buf: FloatArray, from: Int, to: Int): Float {
            var p = 0f
            for (i in from * 2 until to * 2) p = maxOf(p, kotlin.math.abs(buf[i]))
            return p
        }
    }

    private val file = File("song.mp3")

    // ---------------------------------------------------------------- engage / disengage state machine

    @Test fun engageThenDisengageReportsThePositionReached() {
        val r = Rig()
        assertFalse(r.engine.isEngaged)
        assertNull("disengage when idle is a no-op", r.engine.disengage())
        assertTrue(r.engine.engage(file, 0, 0, atSeconds = 2.0, play = true))
        r.engine.bindSong("s1")
        assertTrue(r.engine.isEngaged); assertTrue(r.engine.isPlaying)
        assertEquals(2.0, r.engine.currentTimeSec, 0.02)
        r.render(sr)   // one second of audio
        val pos = r.engine.disengage()
        assertNotNull(pos)
        assertEquals(3.0, pos!!, 0.15)
        assertFalse(r.engine.isEngaged); assertFalse(r.engine.isPlaying)
        assertNull(r.engine.engagedSongId)
        assertNull("second disengage is a no-op", r.engine.disengage())
        assertTrue("voices released", r.voices.isEmpty())
    }

    @Test fun anUndecodableFileIsRefusedAndNothingIsEngaged() {
        val r = Rig(); r.refuse = true
        assertFalse(r.engine.engage(file, 0, 0, 0.0, true))
        assertFalse(r.engine.isEngaged)
    }

    @Test fun engagingAgainReplacesTheCurrentTrack() {
        val r = Rig()
        r.engine.engage(file, 0, 0, 1.0, true); r.engine.bindSong("a")
        r.engine.engage(file, 0, 0, 4.0, true); r.engine.bindSong("b")
        assertEquals("b", r.engine.engagedSongId)
        assertEquals(4.0, r.engine.currentTimeSec, 0.02)
        assertEquals("only the new track's voice is pumped", 1, r.voices.size)
    }

    @Test fun audioStartsOnceAndFlowsFromTheHandOffPosition() {
        val r = Rig()
        var started = 0
        r.engine.onAudioStarted = { started++ }
        r.engine.engage(file, 0, 0, 1.0, true); r.engine.bindSong("s")
        val out = r.render(sr / 2)
        assertEquals(1, started)
        assertTrue("audible within the first blocks", r.peak(out, 0, 4096) > 0.2f)
        assertTrue(r.engine.hasStarted)
    }

    @Test fun pauseHoldsThePositionAndPlayResumes() {
        val r = Rig()
        r.engine.engage(file, 0, 0, 0.0, true); r.engine.bindSong("s")
        r.render(sr / 2)
        r.engine.pause()
        assertFalse(r.engine.isPlaying)
        val held = r.engine.currentTimeSec
        val silent = r.render(sr / 4)
        assertEquals(held, r.engine.currentTimeSec, 0.001)
        assertEquals(0f, r.peak(silent, 1024, sr / 4), 1e-3f)
        r.engine.play()
        r.render(sr / 2)
        assertTrue(r.engine.currentTimeSec > held + 0.3)
    }

    @Test fun onReachedEndFiresOnceAtTheEndOfTheSongWindow() {
        val r = Rig()
        var ended = 0
        r.engine.onReachedEnd = { ended++ }
        // a 300 ms window starting 1 s into the file, engaged near its end
        r.engine.engage(file, startMs = 1000, lengthMs = 300, atSeconds = 0.1, play = true); r.engine.bindSong("s")
        assertEquals(0.3, r.engine.durationSec, 0.002)
        r.render(sr)   // well past the window
        assertEquals(1, ended)
        r.render(sr / 2)
        assertEquals("fires once per engage", 1, ended)
        assertFalse(r.engine.isPlaying)
    }

    @Test fun windowedTracksReportTimeRelativeToTheirStart() {
        val r = Rig()
        r.engine.engage(file, startMs = 2000, lengthMs = 5000, atSeconds = 1.5, play = false); r.engine.bindSong("s")
        assertEquals(1.5, r.engine.currentTimeSec, 0.01)
    }

    // ---------------------------------------------------------------- controls

    @Test fun tempoControlChangesTheAdvanceRate() {
        val r = Rig()
        r.engine.engage(file, 0, 0, 0.0, true); r.engine.bindSong("s")
        r.render(sr / 2)
        val t0 = r.engine.currentTimeSec
        r.engine.setRate(2.0)
        r.render(sr / 4)          // let the stretcher settle
        val t1 = r.engine.currentTimeSec
        r.render(sr)
        val advanced = r.engine.currentTimeSec - t1
        assertEquals("1 s of output at 2x advances ~2 s of song", 2.0, advanced, 0.15)
        assertTrue(t1 > t0)
        assertEquals(2.0, r.engine.rate, 0.0)
    }

    @Test fun controlsClampAndReset() {
        val r = Rig()
        r.engine.setRate(9.0); r.engine.setPitch(-40.0); r.engine.setVolume(5.0)
        assertEquals(2.0, r.engine.rate, 0.0); assertEquals(-12.0, r.engine.pitch, 0.0); assertEquals(2.0, r.engine.volume, 0.0)
        r.engine.setEffect(Effect.REVERB, true); r.engine.setEffectStrength(Effect.REVERB, 0.8)
        assertTrue(r.engine.isEnabled(Effect.REVERB)); assertEquals(0.8, r.engine.strength(Effect.REVERB), 1e-9)
        r.engine.applyCarriedStemControls(setOf("bass"), mapOf("vocals" to 0.3))
        r.engine.resetControls()
        assertEquals(1.0, r.engine.rate, 0.0); assertEquals(0.0, r.engine.pitch, 0.0); assertEquals(1.0, r.engine.volume, 0.0)
        assertFalse(r.engine.isEnabled(Effect.REVERB))
        assertTrue(r.engine.mutedStems.isEmpty()); assertTrue(r.engine.stemVolumes.isEmpty()); assertFalse(r.engine.stemMode)
    }

    @Test fun gainBoostIsAudible() {
        val r = Rig()
        r.engine.engage(file, 0, 0, 0.0, true); r.engine.bindSong("s")
        val base = r.peak(r.render(sr / 2), sr / 4, sr / 2)
        r.engine.setVolume(0.25)
        r.render(sr / 4)
        val quiet = r.peak(r.render(sr / 4), 0, sr / 4)
        assertTrue("0.25 gain is quieter ($quiet vs $base)", quiet < base * 0.5f)
    }

    @Test fun userStemChangesNotifyButCarriedOnesDoNot() {
        val r = Rig()
        var user = 0
        r.engine.onUserStemChange = { user++ }
        r.engine.applyCarriedStemControls(setOf("drums"), mapOf("vocals" to 0.5))
        assertEquals(0, user)
        r.engine.setStemMuted("bass", true)
        r.engine.setStemVolume("vocals", 0.2)
        assertEquals(2, user)
        assertEquals(setOf("drums", "bass"), r.engine.mutedStems)
        r.engine.setStemMuted("nonsense", true)
        assertEquals("unknown parts are ignored", 2, user)
    }

    // ---------------------------------------------------------------- stems handover

    @Test fun stemsOnDiskHandOverWithoutAGap() {
        val r = Rig(); r.addAllParts()
        var onAir: String? = null
        r.engine.onStemsOnAir = { onAir = it }
        r.engine.engage(file, 0, 0, 0.0, true); r.engine.bindSong("s")
        val before = r.render(sr / 2)
        assertTrue(r.engine.setStemMode(true))
        assertEquals(StemHandover.TO_STEMS, r.engine.stemHandover)
        val during = r.render(sr)   // the fade and a bit of stems
        assertTrue("stems on air", r.engine.stemsOnAir)
        assertNull(r.engine.stemHandover)
        assertEquals("s", onAir)
        // coherent main/stems: the level is continuous and there is never a dead block
        val level = r.peak(before, sr / 4, sr / 2)
        var minBlock = Float.MAX_VALUE
        for (b in 0 until sr / 512) minBlock = minOf(minBlock, r.peak(during, b * 512, b * 512 + 512))
        assertTrue("no dead air across the hand-over (min block peak $minBlock)", minBlock > level * 0.5f)
        assertEquals(level, r.peak(during, sr / 2, sr), level * 0.2f)
    }

    @Test fun stemsOffHandsBackToTheFullMix() {
        val r = Rig(); r.addAllParts()
        r.engine.engage(file, 0, 0, 0.0, true); r.engine.bindSong("s")
        r.render(sr / 4)
        r.engine.setStemMode(true); r.render(sr)
        assertTrue(r.engine.stemsOnAir)
        r.engine.setStemMode(false)
        assertEquals(StemHandover.TO_FULL_MIX, r.engine.stemHandover)
        val out = r.render(sr)
        assertFalse(r.engine.stemsOnAir); assertNull(r.engine.stemHandover)
        assertTrue("full mix audible after hand-back", r.peak(out, sr / 2, sr) > 0.2f)
    }

    @Test fun mutingAStemSilencesItsShareOfTheMix() {
        val r = Rig(); r.addAllParts()
        r.engine.engage(file, 0, 0, 0.0, true); r.engine.bindSong("s")
        r.engine.setStemMode(true); r.render(sr)
        val full = r.peak(r.render(sr / 4), 0, sr / 4)
        r.engine.setStemMuted("vocals", true); r.engine.setStemMuted("drums", true)
        r.render(sr / 8)
        val half = r.peak(r.render(sr / 4), 0, sr / 4)
        assertEquals("two of four equal stems muted halves the level", full / 2, half, full * 0.1f)
    }

    @Test fun stemsWithNothingObtainableRefuseAndStayOnTheFullMix() {
        val r = Rig()
        r.engine.engage(file, 0, 0, 0.0, true); r.engine.bindSong("s")
        assertFalse(r.engine.setStemMode(true))
        assertFalse(r.engine.stemMode); assertNull(r.engine.stemHandover)
        assertTrue(r.render(sr / 4).let { r.peak(it, 1024, sr / 4) } > 0.2f)
    }

    @Test fun pendingHandoverCompletesWhenThePartsLand() {
        val r = Rig(); r.obtainable = true
        val gate = kotlinx.coroutines.CompletableDeferred<Boolean>()
        r.fetchResult = { gate.await() }
        r.engine.engage(file, 0, 0, 0.0, true); r.engine.bindSong("s")
        assertTrue(r.engine.setStemMode(true))
        r.render(sr / 2)
        assertEquals("full mix plays on while stems load", StemHandover.TO_STEMS, r.engine.stemHandover)
        assertTrue(r.engine.stemsLoading); assertFalse(r.engine.stemsOnAir)
        r.addAllParts()                       // the fetch landed
        gate.complete(true)
        r.render(sr)
        assertTrue(r.engine.stemsOnAir); assertNull(r.engine.stemHandover)
    }

    @Test fun partialSetOnAirWithMutedPartsMissing() {
        val r = Rig(); r.obtainable = true
        r.engine.applyCarriedStemControls(setOf("bass", "other"), emptyMap())
        r.parts["vocals"] = File("stem-v.mp3"); r.parts["drums"] = File("stem-d.mp3")
        r.engine.engage(file, 0, 0, 0.0, true); r.engine.bindSong("s")
        assertTrue(r.engine.requestStemModeForLock(true))
        r.render(sr)
        assertTrue("enabled parts present -> on air without the muted ones", r.engine.stemsOnAir)
    }

    @Test fun aFailedFetchGivesUpAndStaysOnTheFullMix() {
        val r = Rig(); r.obtainable = true      // fetch returns false
        r.engine.engage(file, 0, 0, 0.0, true); r.engine.bindSong("s")
        assertTrue(r.engine.setStemMode(true))
        r.render(sr / 4)
        assertFalse(r.engine.stemMode); assertNull(r.engine.stemHandover); assertFalse(r.engine.stemsOnAir)
    }

    @Test fun aStaleFetchCompletionAfterDisengageTouchesNothing() {
        val r = Rig(); r.obtainable = true
        val gate = kotlinx.coroutines.CompletableDeferred<Boolean>()
        r.fetchResult = { gate.await() }
        r.engine.engage(file, 0, 0, 0.0, true); r.engine.bindSong("s")
        r.engine.setStemMode(true)
        r.scope.testScheduler.runCurrent()
        r.engine.disengage()                  // stop() fires completions: the generation moved on
        gate.complete(true)
        r.scope.testScheduler.runCurrent()
        assertFalse(r.engine.isEngaged); assertNull(r.engine.stemHandover)
        assertEquals(1, r.fetchCalls)
    }

    @Test fun trackChangeResetClearsAPendingHandover() {
        val r = Rig(); r.obtainable = true
        r.engine.engage(file, 0, 0, 0.0, true); r.engine.bindSong("s")
        r.engine.setStemMode(true)
        assertNotNull(r.engine.stemHandover)
        r.engine.disengage(); r.engine.resetControls()
        assertNull(r.engine.stemHandover); assertFalse(r.engine.stemMode)
    }
}

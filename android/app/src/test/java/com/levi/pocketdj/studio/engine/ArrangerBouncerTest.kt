package com.levi.pocketdj.studio.engine

import com.levi.pocketdj.audio.core.PcmBuffer
import com.levi.pocketdj.studio.model.StudioArrangement
import com.levi.pocketdj.studio.model.StudioArrangementArtifact
import com.levi.pocketdj.studio.model.StudioChannelStrip
import com.levi.pocketdj.studio.model.StudioClip
import com.levi.pocketdj.studio.model.StudioGrid
import com.levi.pocketdj.studio.model.StudioMasterFX
import com.levi.pocketdj.studio.model.StudioTrack
import com.levi.pocketdj.studio.store.TestEnv
import com.levi.pocketdj.studio.store.TrimGap
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.runBlocking
import org.junit.After
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNotNull
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Rule
import org.junit.Test
import org.junit.rules.TemporaryFolder
import java.io.File

private const val RATE = 44_100

private fun constPcm(frames: Int, v: Float) = PcmBuffer(RATE, 2, FloatArray(frames * 2) { v })

/** Loader whose transform is a nearest-sample resample (rate 2 halves the window) so Beat Match lengths are checkable. */
private class FakeLoader(val files: Map<String, PcmBuffer>) : MultitrackClipLoader {
    override suspend fun decode(fileName: String): PcmBuffer? = files[fileName]
    override suspend fun transform(source: PcmBuffer, from: Long, frames: Long, rate: Double, pitchCents: Double): PcmBuffer? {
        val n = Math.round(frames / rate).toInt()
        val out = FloatArray(n * 2)
        for (i in 0 until n) {
            val s = (from + (i * rate).toLong()).toInt().coerceAtMost(source.frames - 1)
            out[2 * i] = source.samples[2 * s]; out[2 * i + 1] = source.samples[2 * s + 1]
        }
        return PcmBuffer(RATE, 2, out)
    }
}

class ArrangerBouncerTest {
    @get:Rule val tmp = TemporaryFolder()
    private val scope = CoroutineScope(Dispatchers.Default)
    @After fun tearDown() { scope.coroutineContext[kotlinx.coroutines.Job]?.cancel() }

    private fun clip(id: String, file: String, start: Int = 0, dur: Int = 1000, fs: Int = 0, grid: StudioGrid? = null) =
        StudioClip(id, id, file, startMs = start, durationMs = dur, fileStartMs = fs, grid = grid)

    private fun track(id: String, vararg clips: StudioClip, gainDb: Double = 0.0, pan: Double = 0.0, muted: Boolean = false,
                      soloed: Boolean = false, strip: StudioChannelStrip = StudioChannelStrip()) =
        StudioTrack(id, id, clips.toList(), gainDb = gainDb, pan = pan, muted = muted, soloed = soloed, strip = strip)

    private val files = mapOf("a" to constPcm(RATE, 0.1f), "b" to constPcm(RATE, 0.2f), "hot" to constPcm(RATE, 0.8f))
    private fun bouncer(files: Map<String, PcmBuffer> = this.files) = ArrangerBouncer(FakeLoader(files), writeM4a = { _, f -> f.writeText("m4a") })

    @Test fun bounceEqualsWhatTheLivePlayerRenders() = runBlocking {
        val tracks = listOf(
            track("t1", clip("c1", "a"), gainDb = -3.0, pan = -0.5),
            track("t2", clip("c2", "b", start = 250, dur = 500), gainDb = 2.0, pan = 0.7),
        )
        val fx = StudioMasterFX(driveEnabled = true, driveAmount = 0.3, masterGainDb = -2.0)
        val arr = StudioArrangement("A", "A", tracks, bpm = 120.0, masterFX = fx)
        val sinks = mutableListOf<FakeSink>()
        val player = MultitrackPlayer(FakeLoader(files), { FakeSink().also { sinks += it } }, scope)
        assertTrue(player.play(arr))
        val live = sinks[0].pull(RATE)
        player.stop()
        val bounced = bouncer().mixdown(tracks, fx, 120.0, false)!!
        assertEquals(RATE, bounced.frames)
        // Same planner + same render context => identical samples (the live limiter is transparent below 1.0).
        for (i in 0 until live.size) assertEquals("sample $i", live[i], bounced.samples[i], 1e-5f)
    }

    @Test fun masterFxIsBakedIntoTheBounce() = runBlocking {
        // Two overlapping hot tracks sum to 1.6: dry normalizes to exactly 1.0; Drive soft-clips below it.
        val tracks = listOf(track("t1", clip("c1", "hot")), track("t2", clip("c2", "hot")))
        val dry = bouncer().mixdown(tracks)!!
        assertEquals(1.0f, ArrangerBouncer.peak(dry.samples), 1e-6f)
        val driven = bouncer().mixdown(tracks, StudioMasterFX(driveEnabled = true, driveAmount = 0.8))!!
        val dp = ArrangerBouncer.peak(driven.samples)
        assertTrue("driven peak $dp must be soft-clipped under the dry peak", dp < 1.0f)
        assertTrue(dp > 0.1f)
    }

    @Test fun staleFreezeFlagNeverSilencesABounce() = runBlocking {
        val out = bouncer().mixdown(listOf(track("t1", clip("c1", "a"))), StudioMasterFX(freezeEnabled = true))!!
        assertEquals(0.1f, out.samples[0], 1e-6f)
    }

    @Test fun stripEqIsBakedPerTrack() = runBlocking {
        val neutral = bouncer().mixdown(listOf(track("t1", clip("c1", "a"))))!!
        val boosted = bouncer().mixdown(listOf(track("t1", clip("c1", "a"), strip = StudioChannelStrip(eqLowDb = 12.0, reverb = 0.6))))!!
        var diff = 0f
        for (i in neutral.samples.indices) diff = maxOf(diff, Math.abs(neutral.samples[i] - boosted.samples[i]))
        assertTrue("strip FX must change the audio (diff=$diff)", diff > 1e-3f)
    }

    @Test fun muteAndSoloDoNotAffectABounceButGainDoes() = runBlocking {
        val muted = track("t1", clip("c1", "a"), muted = true)
        val soloOther = track("t2", clip("c2", "b"), soloed = true)
        val out = bouncer().mixdown(listOf(muted, soloOther))!!
        assertEquals(0.3f, out.samples[0], 1e-5f)         // 0.1 muted-track still counted + 0.2 soloed
        val quiet = bouncer().mixdown(listOf(track("t1", clip("c1", "a"), gainDb = -6.0)))!!
        assertEquals(0.1f * Math.pow(10.0, -6 / 20.0).toFloat(), quiet.samples[0], 1e-5f)
        // Gain is clamped to +6 dB like the live path.
        val loud = bouncer().mixdown(listOf(track("t1", clip("c1", "a"), gainDb = 40.0)))!!
        assertEquals(0.1f * Math.pow(10.0, 6 / 20.0).toFloat(), loud.samples[0], 1e-5f)
    }

    @Test fun trimmedTailBounceIsSilentInTheGapAndWindowsTheSameFile() = runBlocking {
        // Source: a ramp so each frame is identifiable. Clip is 400 ms; cut 100..200 ms.
        val frames = RATE
        val ramp = PcmBuffer(RATE, 2, FloatArray(frames * 2) { (it / 2) / frames.toFloat() * 0.5f })
        val trimmed = TrimGap.trimGap(listOf(clip("c1", "ramp", start = 0, dur = 400)), 100, 200)
        assertEquals(2, trimmed.size)
        assertEquals(trimmed[0].fileName, trimmed[1].fileName)
        assertEquals(200, trimmed[1].fileStartMs)
        val out = bouncer(mapOf("ramp" to ramp)).mixdown(listOf(track("t1", *trimmed.toTypedArray())))!!
        fun ms(m: Int) = (m * RATE / 1000)
        assertEquals(0.5f * ms(50) / frames, out.samples[2 * ms(50)], 1e-6f)         // head intact
        for (f in ms(100) until ms(200)) assertEquals(0f, out.samples[2 * f], 0f)   // the gap is silent
        assertEquals(0.5f * ms(250) / frames, out.samples[2 * ms(250)], 1e-6f)      // tail = file @ 250 ms (slid window)
        assertEquals(ms(400), out.frames)
    }

    @Test fun beatMatchWarpsLengthAndSnapsStarts() = runBlocking {
        // 90 bpm clip into a 120 bpm master: rate 4/3 => a 3 s source plays in 2.25 s.
        val src = constPcm(3 * RATE, 0.25f)
        val g = StudioGrid(bpm = 90.0)
        val t = track("t1", clip("c1", "x", start = 700, dur = 3000, grid = g))   // 700 ms snaps to the nearest 500 ms beat => 500
        val on = bouncer(mapOf("x" to src)).mixdown(listOf(t), bpm = 120.0, beatMatch = true)!!
        val start = 500 * RATE / 1000
        assertEquals(start + Math.round(3 * RATE / (4.0 / 3.0)).toInt(), on.frames)
        assertEquals(0f, on.samples[2 * (start - 1)], 0f)
        assertEquals(0.25f, on.samples[2 * start], 1e-6f)
        val off = bouncer(mapOf("x" to src)).mixdown(listOf(t), bpm = 120.0, beatMatch = false)!!
        assertEquals(700 * RATE / 1000 + 3 * RATE, off.frames)       // no warp, no snap
    }

    @Test fun nothingToBounceAndMissingFilesGiveNull() = runBlocking {
        assertNull(bouncer().mixdown(emptyList()))
        assertNull(bouncer().mixdown(listOf(track("t1"))))                                  // no clips
        assertNull(bouncer().mixdown(listOf(track("t1", clip("c1", "missing")))))          // unreadable
        val partial = bouncer().mixdown(listOf(track("t1", clip("c1", "missing")), track("t2", clip("c2", "a"))))!!
        assertEquals(0.1f, partial.samples[0], 1e-6f)                                       // the readable one still bounces
    }

    @Test fun normalizeOnlyWhenClipping() {
        val quiet = floatArrayOf(0.5f, -0.25f); ArrangerBouncer.normalizeIfClipping(quiet)
        assertEquals(0.5f, quiet[0], 0f)
        val hot = floatArrayOf(2f, -1f); ArrangerBouncer.normalizeIfClipping(hot)
        assertEquals(1f, hot[0], 1e-6f); assertEquals(-0.5f, hot[1], 1e-6f)
    }

    @Test fun bounceArtifactWritesADatedFileAndFilesOnlyAnArtifact() = runBlocking {
        val env = TestEnv(tmp.newFolder("studio"))
        val store = env.store()
        val a = store.createArrangement("A"); val t = store.addTrack(a.id)!!
        val arr = StudioArrangement(a.id, "A", listOf(track("t1", clip("c1", "a"))), bpm = 120.0)
        val dir = env.roots.arrangementsDir()
        val art = bouncer().bounceArtifact(arr, arr.tracks, dir, store, "2026-10-28 10-00-00", now = 42.0)!!
        assertEquals("bounce-2026-10-28 10-00-00.m4a", art.fileName)
        assertEquals(StudioArrangementArtifact.Kind.BOUNCE, art.kind)
        assertEquals(1000, art.durationMs)
        assertTrue(File(dir, art.fileName).exists())
        assertEquals(listOf(art.id), store.artifacts(a.id, StudioArrangementArtifact.Kind.BOUNCE).map { it.id })
        // Artifact-only: no track/clip was added to the arrangement.
        assertEquals(1, store.arrangement(a.id)!!.tracks.size)
        assertTrue(store.arrangement(a.id)!!.tracks[0].clips.isEmpty())
        assertEquals(t.id, store.arrangement(a.id)!!.tracks[0].id)
        // No leftover temp file.
        assertFalse(dir.listFiles()!!.any { it.name.startsWith(".bounce-") })
        // Nothing resolvable => nothing written, no artifact.
        val none = bouncer(emptyMap()).bounceArtifact(arr, arr.tracks, dir, store, "x")
        assertNull(none); assertFalse(File(dir, "bounce-x.m4a").exists())
        assertNotNull(store.artifacts(a.id, StudioArrangementArtifact.Kind.BOUNCE).singleOrNull())
    }

    @Test fun encodeFailureLeavesNoFileAndNoArtifact() = runBlocking {
        val env = TestEnv(tmp.newFolder("studio2"))
        val store = env.store()
        val a = store.createArrangement("A")
        val arr = StudioArrangement(a.id, "A", listOf(track("t1", clip("c1", "a"))))
        val failing = ArrangerBouncer(FakeLoader(files), writeM4a = { _, f -> f.writeText("partial"); error("encoder died") })
        val dir = env.roots.arrangementsDir()
        assertNull(failing.bounceArtifact(arr, arr.tracks, dir, store, "s"))
        assertTrue(store.artifacts(a.id, StudioArrangementArtifact.Kind.BOUNCE).isEmpty())
        assertTrue(dir.listFiles().orEmpty().none { it.name.contains("bounce") })
    }
}

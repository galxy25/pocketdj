package com.levi.pocketdj.studio.engine

import com.levi.pocketdj.audio.core.AudioSink
import com.levi.pocketdj.audio.core.BlockRenderer
import com.levi.pocketdj.audio.core.PcmBuffer
import com.levi.pocketdj.audio.core.RenderClock
import com.levi.pocketdj.studio.audio.ResampleStretcher
import com.levi.pocketdj.studio.audio.StudioCodec
import com.levi.pocketdj.studio.audio.StudioRender
import com.levi.pocketdj.studio.model.LoopBeats
import com.levi.pocketdj.studio.model.StudioGrid
import com.levi.pocketdj.studio.model.StudioLoop
import com.levi.pocketdj.studio.model.StudioSample
import com.levi.pocketdj.studio.store.StudioFamily
import com.levi.pocketdj.studio.store.TestEnv
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.async
import kotlinx.coroutines.runBlocking
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNotNull
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Assert.fail
import org.junit.Rule
import org.junit.Test
import org.junit.rules.TemporaryFolder
import java.io.File

class LoopAuditionTest {
    @get:Rule val tmp = TemporaryFolder()

    // ---- LoopMath ----

    @Test fun lengthIsSumOfRealIntervalsWithADriftingGrid() {
        val g = StudioGrid(120.0, 0, listOf(0, 510, 1000, 1480, 2010, 2500, 3000))
        // 4 beats from the first beat = beat[4] - beat[0], NOT 4 x 500.
        assertEquals(2010, LoopMath.lengthMs(0, LoopBeats.FOUR, g))
        // starting on the second beat: 510 -> 2500 (beat index 1 + 4 = 5)
        assertEquals(2500 - 510, LoopMath.lengthMs(510, LoopBeats.FOUR, g))
    }

    @Test fun fractionalBeatsInterpolateBetweenRealBeats() {
        val g = StudioGrid(120.0, 0, listOf(0, 600, 1000))
        assertEquals(300, LoopMath.lengthMs(0, LoopBeats.HALF, g))
    }

    @Test fun constantGridLengthIsBeatsTimes60000OverBpm() {
        val g = StudioGrid(120.0)
        assertEquals(2000, LoopMath.lengthMs(0, LoopBeats.FOUR, g))
        assertEquals(250, LoopMath.lengthMs(0, LoopBeats.HALF, g))
        assertEquals(16000, LoopMath.lengthMs(0, LoopBeats.THIRTY_TWO, g))
        // 93 BPM is not a whole ms: 4 beats = 2580.645... rounds to 2581
        assertEquals(2581, LoopMath.lengthMs(0, LoopBeats.FOUR, StudioGrid(93.0)))
    }

    @Test fun framesAreRoundedMsTimes44Point1() {
        assertEquals(88_200L, LoopMath.frames(2000))
        assertEquals(11_025L, LoopMath.frames(250))
        assertEquals(54_419L, LoopMath.frames(1234))   // 54419.4
        assertEquals(113_822L, LoopMath.frames(2581))  // 113822.1
    }

    @Test fun noGridMeansNoWindow() {
        assertNull(LoopMath.window(0, LoopBeats.FOUR, StudioGrid(0.0)))
    }

    @Test fun anchorStepsAlongRealAndConstantGrids() {
        val real = StudioGrid(120.0, 0, listOf(0, 510, 1000, 1480))
        assertEquals(510, LoopMath.stepAnchor(null, +1, real))
        assertEquals(1000, LoopMath.stepAnchor(510, +1, real))
        assertEquals(510, LoopMath.stepAnchor(1000, -1, real))
        assertFalse(LoopMath.canStepBack(null, real))
        assertTrue(LoopMath.canStepBack(510, real))
        val constant = StudioGrid(120.0, 100)
        assertEquals(100, LoopMath.snappedAnchor(null, constant))
        assertEquals(600, LoopMath.stepAnchor(null, +1, constant))
        assertNull(LoopMath.previousBeat(100, constant))   // never before the phase anchor
        assertEquals(100, LoopMath.previousBeat(600, constant))
    }

    @Test fun stepBackRefusedAtFirstBeatKeepsAnchor() {
        val constant = StudioGrid(120.0, 0)
        assertEquals(null, LoopMath.stepAnchor(null, -1, constant))
        assertEquals(0, LoopMath.stepAnchor(0, -1, constant))
    }

    @Test fun forwardStepStopsBeforePureSilence() {
        val g = StudioGrid(120.0)
        assertTrue(LoopMath.canStepForward(null, g, 2000))   // next beat 500 < 2000
        assertFalse(LoopMath.canStepForward(1500, g, 2000))  // next beat 2000 >= 2000
    }

    @Test fun previousBeatPastTheMeasuredGridWalksTheExtension() {
        val g = StudioGrid(120.0, 0, listOf(0, 500, 1000))
        assertEquals(1000, LoopMath.previousBeat(1500, g))
        assertEquals(1200, LoopMath.previousBeat(1700, g))   // one step back on the extension
        assertEquals(1000, LoopMath.previousBeat(1100, g))   // clamped to the last real beat
        assertEquals(1500, LoopMath.previousBeat(2000, g))
    }

    @Test fun overhangDetected() {
        val g = StudioGrid(120.0)
        val w = LoopMath.window(0, LoopBeats.FOUR, g)!!
        assertTrue(LoopMath.overhangs(w, 1500))
        assertFalse(LoopMath.overhangs(w, 2000))
    }

    @Test fun conformTruncatesAndZeroPadsToTheAuthoritativeFrames() {
        val src = PcmBuffer(44_100, 2, FloatArray(200) { 0.5f })   // 100 frames
        val trimmed = LoopMath.conform(src, 60)!!
        assertEquals(60, trimmed.frames)
        val padded = LoopMath.conform(src, 130)!!
        assertEquals(130, padded.frames)
        assertEquals(0.5f, padded.samples[199], 0f)
        assertEquals(0f, padded.samples[200], 0f)
        assertEquals(100, LoopMath.conform(src, 0)!!.frames)       // legacy record: as decoded
    }

    @Test fun copy() {
        assertEquals("Kick · 4 beats", LoopMath.defaultName("Kick", LoopBeats.FOUR))
        assertEquals("Kick · 1 beat", LoopMath.defaultName("Kick", LoopBeats.ONE))
        assertEquals("Sample · ½ beats", LoopMath.defaultName("", LoopBeats.HALF))
        assertEquals("250 ms", LoopMath.lengthLabel(250))
        assertEquals("1:05", LoopMath.lengthLabel(65_000))
        val l = StudioLoop("lp_1", "L", "smp_1", beats = LoopBeats.FOUR, bpm = 120.04, lengthMs = 2000, frames = 88200, fileName = "x")
        assertEquals("4 beats · 120.0 BPM · 2000 ms", LoopMath.rowSubtitle(l))
        assertTrue(LoopMath.deleteMessage(0) == "This deletes the loop’s audio file.")
        assertTrue(LoopMath.deleteMessage(1).endsWith("1 sequencer row targeting it will go silent."))
        assertTrue(LoopMath.deleteMessage(3).contains("3 sequencer rows"))
    }

    // ---- LoopAudition (looping) ----

    private class FakeSink : AudioSink {
        override val sampleRate = 44_100
        override val clock = RenderClock(44_100)
        override val underruns = 0L
        override var isRendering = false
        override var onRoutingChanged: ((Boolean) -> Unit)? = null
        var renderer: BlockRenderer? = null
        override fun start(renderer: BlockRenderer) { this.renderer = renderer; isRendering = true }
        override fun stop() { isRendering = false }
        override fun release() {}
        override fun latencyFrames() = 0
    }

    @Test fun auditionLoopsExactlyTheAuthoritativeFramesWithNoSeam() = runBlocking {
        val loopFrames = 1000
        // the decoded container is LONGER than the authoritative count (an encoder pad)
        val decoded = PcmBuffer(44_100, 2, FloatArray(1024 * 2) { (it / 2) / 1024f })
        val sink = FakeSink()
        val a = LoopAudition({ sink }, { decoded })
        assertTrue(a.play("lp_x", File("loop.wav"), loopFrames.toLong()))
        assertEquals("lp_x", a.playingId.value)
        assertEquals(loopFrames.toLong(), a.loopedFrames)
        // pull several blocks that straddle the wrap point
        val total = 2 * loopFrames + 37
        val out = FloatArray(total * 2)
        var done = 0
        while (done < total) {
            val n = minOf(333, total - done)
            val blk = FloatArray(n * 2)
            sink.renderer!!.render(blk, n)
            System.arraycopy(blk, 0, out, done * 2, n * 2)
            done += n
        }
        for (i in 0 until total) assertEquals("frame $i", ((i % loopFrames) / 1024f), out[i * 2], 1e-6f)
    }

    // ---- ANS-STU-3: session claim + transient-loss park/resume ----

    private fun parkRig(events: MutableList<String>): Triple<LoopAudition, FakeSink, MutableList<String>> {
        val sink = FakeSink()
        val decoded = PcmBuffer(44_100, 2, FloatArray(200 * 2) { 0.5f })
        val a = LoopAudition({ sink }, { decoded }, focus = { events += "focus"; true }, focusRelease = { events += "release" })
        a.onAudible = { events += "audible=$it" }
        a.onUserTransport = { events += "user" }
        return Triple(a, sink, events)
    }

    @Test fun audibleCallbackClaimsOnStartAndResignsOnStop() = runBlocking {
        val ev = mutableListOf<String>()
        val (a, _, _) = parkRig(ev)
        assertTrue(a.play("lp_a", File("a.wav"), 200))
        assertTrue(a.isAudible)
        assertTrue("audible=true" in ev)
        a.stop()
        assertFalse(a.isAudible)
        assertEquals("audible=false", ev.last { it.startsWith("audible") })
    }

    @Test fun transientLossParksKeepingFocusAndGainResumesTheSameLoop() = runBlocking {
        val ev = mutableListOf<String>()
        val (a, sink, _) = parkRig(ev)
        a.play("lp_a", File("a.wav"), 200)
        ev.clear()
        assertTrue(a.parkForInterruption())
        assertFalse(a.isAudible)
        assertFalse(sink.isRendering)
        assertEquals("lp_a", a.parked!!.id)
        assertFalse("focus must be HELD while parked, else AUDIOFOCUS_GAIN never arrives", "release" in ev)
        assertFalse("a park KEEPS session ownership (card + foreground service survive the call)", "audible=false" in ev)
        assertTrue(a.resumeFromInterruption())
        assertEquals("lp_a", a.playingId.value)
        assertTrue(sink.isRendering)
        assertNull(a.parked)
        assertEquals(200L, a.loopedFrames)
    }

    @Test fun userStopWhileParkedResignsTheSession() = runBlocking {
        val ev = mutableListOf<String>()
        val (a, _, _) = parkRig(ev)
        a.play("lp_a", File("a.wav"), 200)
        a.parkForInterruption(); ev.clear()
        a.stop("focus-loss")
        assertTrue("audible=false" in ev)
    }

    @Test fun secondTransientLossDuringResumeDecodeRepartsInsteadOfSounding() = runBlocking {
        val ev = mutableListOf<String>()
        val sink = FakeSink()
        val gate = kotlinx.coroutines.CompletableDeferred<Unit>()
        var slow = false
        val decoded = PcmBuffer(44_100, 2, FloatArray(400) { 0.5f })
        val a = LoopAudition({ sink }, { if (slow) gate.await(); decoded }, focus = { true }, focusRelease = { ev += "release" })
        a.play("lp_a", File("a.wav"), 200)
        a.parkForInterruption()
        slow = true
        val resume = async(Dispatchers.Default) { a.resumeFromInterruption() }
        while (a.arming.value == null) kotlinx.coroutines.yield()
        assertTrue("resume in flight counts as audible so the coordinator re-parks it", a.isAudible)
        assertTrue(a.parkForInterruption())
        assertEquals("lp_a", a.parked!!.id)
        gate.complete(Unit); resume.await()
        assertNull("the late decode must not start sounding mid-interruption", a.playingId.value)
        assertFalse(sink.isRendering)
        assertEquals("lp_a", a.parked!!.id)
        assertFalse("focus stays held for the next gain", "release" in ev)
    }

    @Test fun loopBStartedWhileLoopAPlaysKeepsPlayingWhenTheGatedNowPlayingPauseIsSkipped() = runBlocking {
        // Wired like StudioGraph: the NP pause (gated by shouldPauseNowPlayingForStudio) reaches the session owner = the studio port.
        val sink = FakeSink()
        lateinit var a: LoopAudition
        val board = com.levi.pocketdj.playback.session.SessionSwitchboard(log = {})
        val session = object : com.levi.pocketdj.playback.session.TransportOwner {
            override val engine = "studio"
            override val sessionPlayer: androidx.media3.common.Player get() = throw UnsupportedOperationException()
            override val hasSounded = true
            override fun pauseForHandoff() { a.stop("superseded") }
        }
        val decoded = PcmBuffer(44_100, 2, FloatArray(400) { 0.5f })
        a = LoopAudition({ sink }, { decoded }, focus = {
            if (shouldPauseNowPlayingForStudio(board.current?.engine)) session.pauseForHandoff()   // = port.remoteStop in prod
            true
        })
        a.onAudible = { on -> if (on) board.setOwner(session) else board.resign(session) }
        assertTrue(a.play("lp_a", File("a.wav"), 200))
        assertEquals("studio", board.current?.engine)
        assertTrue(a.play("lp_b", File("b.wav"), 200))
        assertEquals("lp_b", a.playingId.value); assertTrue(sink.isRendering)
        assertTrue(a.play("lp_b", File("b.wav"), 200))   // re-tap
        assertEquals("lp_b", a.playingId.value); assertTrue(sink.isRendering)
    }

    @Test fun nowPlayingPauseIsSkippedOnlyWhileStudioOwnsTheSession() {
        assertFalse(shouldPauseNowPlayingForStudio("studio"))
        assertTrue(shouldPauseNowPlayingForStudio(null))
        assertTrue(shouldPauseNowPlayingForStudio("exo"))
        assertTrue(shouldPauseNowPlayingForStudio("am"))
    }

    @Test fun nowPlayingPauseIsSkippedWhenNothingIsPlaying() {
        // Emulator-found: a pause sent for an already-paused Now Playing landed on the Studio session and killed the loop.
        assertFalse(shouldPauseNowPlayingForStudio(null, nowPlayingIsPlaying = false))
        assertTrue(shouldPauseNowPlayingForStudio(null, nowPlayingIsPlaying = true))
    }

    @Test fun userStopWhileParkedClearsThePendingResumeAndReleasesFocus() = runBlocking {
        val ev = mutableListOf<String>()
        val (a, sink, _) = parkRig(ev)
        a.play("lp_a", File("a.wav"), 200)
        a.parkForInterruption(); ev.clear()
        a.stop()
        assertNull(a.parked)
        assertTrue("release" in ev); assertTrue("user" in ev)
        assertFalse(a.resumeFromInterruption())
        assertFalse(sink.isRendering)
    }

    @Test fun permanentLossStopsAndClears() = runBlocking {
        val ev = mutableListOf<String>()
        val (a, _, _) = parkRig(ev)
        a.play("lp_a", File("a.wav"), 200)
        a.parkForInterruption()
        a.stop("focus-loss")                      // AUDIOFOCUS_LOSS after the transient
        assertNull(a.parked); assertFalse(a.isAudible)
        assertFalse(a.resumeFromInterruption())
    }

    @Test fun parkWhileSilentIsANoOp() {
        val (a, _, _) = parkRig(mutableListOf())
        assertFalse(a.parkForInterruption())
        assertNull(a.parked)
    }

    @Test fun userPlayWhileParkedSupersedesTheParkedLoop() = runBlocking {
        val ev = mutableListOf<String>()
        val (a, _, _) = parkRig(ev)
        a.play("lp_a", File("a.wav"), 200)
        a.parkForInterruption()
        assertTrue(a.play("lp_b", File("b.wav"), 200))
        assertNull(a.parked)
        assertEquals("lp_b", a.playingId.value)
        assertFalse(a.resumeFromInterruption())
    }

    @Test fun auditionPadsAShortFileToTheAuthoritativeFrames() = runBlocking {
        val decoded = PcmBuffer(44_100, 2, FloatArray(100 * 2) { 1f })
        val sink = FakeSink()
        val a = LoopAudition({ sink }, { decoded })
        assertTrue(a.play("lp_x", File("loop.wav"), 150))
        assertEquals(150L, a.loopedFrames)
        val blk = FloatArray(150 * 2)
        sink.renderer!!.render(blk, 150)
        assertEquals(1f, blk[2 * 99], 0f)
        assertEquals(0f, blk[2 * 100], 0f)   // silence tail keeps the seam on the musical boundary
    }

    @Test fun throwingDecoderIsAnUnreadableRefusalNotACrash() = runBlocking {
        val a = LoopAudition({ FakeSink() }, { throw java.io.IOException("truncated") })
        assertFalse(a.play("lp_x", File("bad.wav"), 10))
        assertEquals("unreadable", a.lastRefusal)
        assertNull(a.playingId.value)
        assertNull(a.arming.value)
    }

    @Test fun stopDuringDecodeCancelsThePendingPlay() = runBlocking {
        val gate = kotlinx.coroutines.CompletableDeferred<PcmBuffer>()
        val sink = FakeSink()
        val a = LoopAudition({ sink }, { gate.await() })
        val r = async(Dispatchers.Default) { a.play("lp_x", File("x.wav"), 10) }
        while (a.arming.value == null) kotlinx.coroutines.yield()
        assertEquals("lp_x", a.arming.value)
        a.stop()
        gate.complete(PcmBuffer(44_100, 2, FloatArray(20)))
        assertFalse(r.await())
        assertNull(a.playingId.value)
        assertFalse(sink.isRendering)
    }

    @Test fun sinkThatFailsToOpenRefusesAndReleasesFocus() = runBlocking {
        var released = 0
        val dead = object : AudioSink by FakeSink() {
            override val isRendering = false
            override fun start(renderer: BlockRenderer) {}
        }
        val a = LoopAudition({ dead }, { PcmBuffer(44_100, 2, FloatArray(20)) }, focusRelease = { released++ })
        assertFalse(a.play("lp_x", File("x.wav"), 10))
        assertNull(a.playingId.value)
        assertEquals("output-unavailable", a.lastRefusal)
        assertEquals(1, released)
    }

    @Test fun switchingLoopsKeepsTheSinkRunning() = runBlocking {
        val sink = FakeSink()
        val a = LoopAudition({ sink }, { PcmBuffer(44_100, 2, FloatArray(20)) })
        assertTrue(a.play("a", File("a.wav"), 10))
        assertTrue(a.play("b", File("b.wav"), 10))
        assertEquals("b", a.playingId.value)
        assertTrue(sink.isRendering)
    }

    @Test fun refusesWhileMicCapturesOrFileUnreadableAndStopSilences() = runBlocking {
        val sink = FakeSink()
        var released = 0
        val a = LoopAudition({ sink }, { null }, focusRelease = { released++ })
        assertFalse(a.play("lp_x", File("gone.wav"), 10))
        assertEquals("unreadable", a.lastRefusal)
        assertNull(a.playingId.value)
        val b = LoopAudition({ sink }, { PcmBuffer(44_100, 2, FloatArray(20)) }, focusRelease = { released++ })
        assertTrue(b.play("lp_y", File("x.wav"), 10))
        assertTrue(sink.isRendering)
        b.stop()
        assertNull(b.playingId.value)
        assertFalse(sink.isRendering)
        assertEquals(1, released)
        val noFocus = LoopAudition({ sink }, { PcmBuffer(44_100, 2, FloatArray(20)) }, focus = { false })
        assertFalse(noFocus.play("lp_z", File("x.wav"), 10))
        assertEquals("no-focus", noFocus.lastRefusal)
    }

    // ---- LoopFactory + store: self-contained loops ----

    private class Codec(val src: PcmBuffer) : StudioCodec {
        var wav: PcmBuffer? = null
        override fun decode(path: String) = src
        override fun decodeNativeRate(path: String) = src
        override fun isProtected(path: String) = false
        override fun writeM4a(pcm: PcmBuffer, file: File) { file.writeText("m4a") }
        override fun writeWav(pcm: PcmBuffer, file: File) { wav = pcm; file.writeText("wav") }
    }

    @Test fun savedLoopRecordsRendererTruthAndSurvivesParentDeletion() = runBlocking {
        val env = TestEnv(tmp.newFolder())
        val store = env.store()
        val codec = Codec(PcmBuffer(44_100, 2, FloatArray(44_100 * 4 * 2) { 0.25f }))   // 4 s
        val render = StudioRender(codec, ResampleStretcher, Dispatchers.Unconfined) { }
        val smpFile = env.write(StudioFamily.SAMPLES, "smp_a")
        val sample = store.addSample(StudioSample("smp_a", "Kick", smpFile, durationMs = 4000, grid = StudioGrid(120.0)))
        val factory = LoopFactory(env.roots, store, render, { env.appFile(StudioFamily.SAMPLES, it.fileName) }, File(tmp.root, "preview.wav"), now = { 9.0 })

        val loop = factory.save(sample, 0, LoopBeats.FOUR, null)
        assertEquals("Kick · 4 beats", loop.name)
        assertEquals(88_200L, loop.frames)
        assertEquals(2000, loop.lengthMs)
        assertEquals(88_200, codec.wav!!.frames)
        assertEquals(120.0, loop.bpm, 1e-6)
        assertNotNull(store.loop(loop.id))

        // parent deleted: the loop record and its file stay and still resolve for playback
        assertTrue(store.deleteSample("smp_a"))
        assertFalse(store.sampleExists("smp_a"))
        assertNotNull(store.loop(loop.id))
        val playable = store.localUrlForPlayback(loop.id)
        assertNotNull(playable)
        assertTrue(playable!!.ref.file!!.isFile)
    }

    @Test fun previewUsesARealRenderOutsideTheFamilyFoldersAndSaveRefusesGridless() = runBlocking {
        val env = TestEnv(tmp.newFolder())
        val store = env.store()
        val codec = Codec(PcmBuffer(44_100, 2, FloatArray(44_100 * 4 * 2) { 0.25f }))
        val render = StudioRender(codec, ResampleStretcher, Dispatchers.Unconfined) { }
        val smpFile = env.write(StudioFamily.SAMPLES, "smp_a")
        val sample = store.addSample(StudioSample("smp_a", "Kick", smpFile, durationMs = 4000, grid = StudioGrid(120.0)))
        val preview = File(tmp.root, "cache/studio-loop-preview.wav")
        val factory = LoopFactory(env.roots, store, render, { env.appFile(StudioFamily.SAMPLES, it.fileName) }, preview)
        val (syn, file) = factory.preview(sample)
        assertEquals(LoopMath.PREVIEW_ID, syn.id)
        assertEquals(88_200L, syn.frames)
        assertTrue(file.isFile)
        assertTrue(store.loops(null).isEmpty())   // a preview is never filed

        val gridless = sample.copy(grid = null)
        try { factory.save(gridless, 0, LoopBeats.FOUR, null); fail() } catch (e: LoopException) { assertEquals(LoopFailure.NoGrid, e.failure) }
    }

    private suspend fun LoopFactory.preview(s: StudioSample) = renderPreview(s, 0, LoopBeats.FOUR)

    @Test fun engineLogsStartAndStopReasons() = runBlocking {
        captureAudioDiag { lines ->
            val a = LoopAudition({ FakeSink() }, { PcmBuffer(44_100, 2, FloatArray(200)) })
            assertTrue(a.play("lp_x", File("loop.wav"), 100))
            assertTrue(lines.any { it.startsWith("audio.play owner=studio.loop reason=user-play") })
            a.stop("focus-loss")
            assertTrue(lines.any { it == "audio.stop owner=studio.loop reason=focus-loss" })
        }
    }
}

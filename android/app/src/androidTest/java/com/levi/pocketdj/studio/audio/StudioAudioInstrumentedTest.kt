package com.levi.pocketdj.studio.audio

import android.content.Context
import android.media.AudioManager
import androidx.test.ext.junit.runners.AndroidJUnit4
import androidx.test.platform.app.InstrumentationRegistry
import com.levi.pocketdj.audio.core.AacEncoder
import com.levi.pocketdj.audio.core.AudioDecoder
import com.levi.pocketdj.audio.core.AudioTrackSink
import com.levi.pocketdj.audio.core.PcmBuffer
import com.levi.pocketdj.studio.dsp.MasterFxKernel
import com.levi.pocketdj.studio.dsp.MasterFxParams
import com.levi.pocketdj.studio.dsp.TrackFxKernel
import com.levi.pocketdj.studio.dsp.TrackFxParams
import com.levi.pocketdj.studio.model.LoopBeats
import com.levi.pocketdj.studio.model.StudioGrid
import com.levi.pocketdj.studio.model.StudioSampleEdit
import kotlinx.coroutines.runBlocking
import org.junit.Assert.assertEquals
import org.junit.Assert.assertTrue
import org.junit.Test
import org.junit.runner.RunWith
import java.io.File
import kotlin.math.PI
import kotlin.math.abs
import kotlin.math.sin

/**
 * STU-2 emulator smoke (run by the integrator on the 'pocketdj' AVD; NOT run in the JVM suite):
 * encode a tone to m4a, decode it back, render a loop .wav + a sample m4a through the REAL codecs and
 * native stretcher, pull a second through [RenderGraph] and play it on [AudioTrackSink]; and hold the
 * native C++ kernels to the Kotlin mirrors within 1e-5.
 */
@RunWith(AndroidJUnit4::class)
class StudioAudioInstrumentedTest {
    private val ctx: Context get() = InstrumentationRegistry.getInstrumentation().targetContext

    private fun tone(frames: Int) = PcmBuffer(44_100, 2, FloatArray(frames * 2) { (0.4 * sin(2 * PI * 441.0 * (it / 2) / 44_100)).toFloat() })

    @Test fun nativeLibraryLoadsAndKernelsMatchKotlinMirrors() {
        assertTrue("libpdjdsp must load on the emulator ABI", NativeDsp.available)
        val n = 2048
        fun input() = arrayOf(FloatArray(n).also { it[0] = 1f }, FloatArray(n).also { it[0] = 0.5f })
        val p = TrackFxParams(eqLowDb = 6.0, eqMidDb = -4.0, eqHighDb = 3.0, reverb = 0.5, delay = 0.4, chorus = 0.5, bpm = 1500.0)
        val k = TrackFxKernel(44_100.0, 2).also { it.update(p) }
        val nat = NativeTrackFx(44_100.0).also { it.update(p) }
        val a = input(); val b = input()
        k.process(a, n); nat.process(b, n)
        for (c in 0..1) for (i in 0 until n) assertEquals("track c=$c i=$i", a[c][i].toDouble(), b[c][i].toDouble(), 1e-5)
        nat.close()
        val mp = MasterFxParams(phaser = true, ringMod = true, brazil = true, drive = true, masterGain = 0.8)
        val mk = MasterFxKernel(44_100.0, 2).also { it.update(mp) }
        val mn = NativeMasterFx(44_100.0).also { it.update(mp) }
        val x = arrayOf(FloatArray(n) { (0.5 * sin(it * 0.05)).toFloat() }, FloatArray(n) { (0.3 * sin(it * 0.03)).toFloat() })
        val y = arrayOf(x[0].copyOf(), x[1].copyOf())
        mk.process(x, n, 0.0); mn.process(y, n, 0.0)
        for (c in 0..1) for (i in 0 until n) assertEquals("master c=$c i=$i", x[c][i].toDouble(), y[c][i].toDouble(), 1e-5)
        mn.close()
    }

    @Test fun nativeStretchHitsExactFramesAndKeepsPitch() {
        val out = NativeStretcher.stretch(tone(44_100), 22_050, 0.0)
        assertEquals(22_050, out.frames)
        var zc = 0
        for (i in 5000 until 15000) if ((out.samples[2 * i] < 0) != (out.samples[2 * (i + 1)] < 0)) zc++
        assertTrue("441 Hz survives a 2x speed-up (zc=$zc)", abs(zc - 200) <= 6)
    }

    @Test fun decodeEncodeRenderLoopAndPlayOneSecond() = runBlocking {
        val dir = File(ctx.cacheDir, "stu2").apply { deleteRecursively(); mkdirs() }
        val m4a = File(dir, "tone.m4a")
        AacEncoder.encode(tone(2 * 44_100), m4a, AacEncoder.Container.M4A, 192_000)
        val decoded = AudioDecoder.decode(m4a.path)!!
        assertTrue(StudioAudio.isCanonical(decoded))
        assertTrue("decoded 2 s tone within 60 ms (AAC priming/padding): ${decoded.seconds}", abs(decoded.seconds - 2.0) < 0.06)

        val render = StudioRender()
        val loopFile = File(dir, "loop.wav")
        val loop = render.renderLoop(StudioSampleEdit.NEUTRAL, m4a.path, 0, LoopBeats.TWO, StudioGrid(bpm = 120.0), loopFile)
        assertEquals(44_100L, loop.frames)
        assertTrue(loopFile.length() >= 44_100L * 2 * 4)

        val sample = render.renderSample(StudioSampleEdit(rate = 1.5, reverbWet = 0.3), m4a.path, File(dir, "sample.m4a"))
        assertTrue(sample.frames >= 29_400L)

        val g = RenderGraph()
        g.addTrack("t", PcmClipSource(AudioDecoder.decode(loopFile.path)!!, loop = true))
        val am = ctx.getSystemService(Context.AUDIO_SERVICE) as AudioManager
        val sink = AudioTrackSink(am)
        sink.start(g)
        Thread.sleep(1000)
        assertTrue("rendering for ~1 s", sink.isRendering && sink.clock.now() > 20_000)
        sink.stop()
    }
}

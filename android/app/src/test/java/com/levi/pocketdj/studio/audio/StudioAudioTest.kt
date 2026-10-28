package com.levi.pocketdj.studio.audio

import com.levi.pocketdj.audio.core.PcmBuffer
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNotNull
import org.junit.Assert.assertNull
import org.junit.Assert.assertSame
import org.junit.Assert.assertTrue
import org.junit.Test
import kotlin.math.PI
import kotlin.math.sin

class StudioAudioTest {
    private fun tone(frames: Int, rate: Int = 44_100, ch: Int = 2, hz: Double = 441.0, amp: Float = 0.5f) =
        PcmBuffer(rate, ch, FloatArray(frames * ch) { (amp * sin(2 * PI * hz * (it / ch) / rate)).toFloat() })

    @Test fun gainDbMath() {
        assertEquals(1f, StudioAudio.gainMultiplier(0.0), 1e-6f)
        assertEquals(0.5012f, StudioAudio.gainMultiplier(-6.0), 1e-3f)
        assertEquals(3.981f, StudioAudio.gainMultiplier(12.0), 1e-3f)
        assertEquals(0.001f, StudioAudio.gainMultiplier(-60.0), 1e-6f)
        // clamped to the sample-edit domain: a hand-edited document can't drive an absurd multiplier
        assertEquals(StudioAudio.gainMultiplier(12.0), StudioAudio.gainMultiplier(99.0), 0f)
        assertEquals(StudioAudio.gainMultiplier(-60.0), StudioAudio.gainMultiplier(-500.0), 0f)
    }

    @Test fun trimmedOrPaddedHitsTheExactFrameCount() {
        val b = tone(1000)
        assertSame(b, StudioAudio.trimmedOrPadded(b, 1000))
        val shorter = StudioAudio.trimmedOrPadded(b, 600)!!
        assertEquals(600, shorter.frames)
        assertEquals(b.samples[598], shorter.samples[598], 0f) // content preserved from frame 0
        val longer = StudioAudio.trimmedOrPadded(b, 1500)!!
        assertEquals(1500, longer.frames)
        for (i in 2000 until longer.samples.size) assertEquals("padding must be explicit silence", 0f, longer.samples[i], 0f)
        assertEquals(b.samples[1999], longer.samples[1999], 0f)
        assertNull(StudioAudio.trimmedOrPadded(b, 0))
        assertNull(StudioAudio.trimmedOrPadded(b, -5))
    }

    @Test fun canonicalConversionOf48kMonoKeepsDurationWithin1ms() {
        val mono48 = tone(48_000, rate = 48_000, ch = 1) // exactly 1 s
        val c = mono48.toCanonical()
        assertTrue(StudioAudio.isCanonical(c))
        assertEquals(44_100, c.frames) // 1 s -> 44100 frames
        assertTrue("duration ${c.seconds}", kotlin.math.abs(c.seconds - 1.0) <= 0.001)
        // mono is duplicated to both channels
        assertEquals(c.samples[2000], c.samples[2001], 0f)
        // an odd-length source rounds DOWN to whole frames (still within 1 ms)
        val odd = tone(48_123, rate = 48_000, ch = 1).toCanonical()
        assertTrue(kotlin.math.abs(odd.seconds - 48_123 / 48_000.0) <= 0.001)
    }

    @Test fun isCanonicalRequires44k1Stereo() {
        assertTrue(StudioAudio.isCanonical(tone(10)))
        assertFalse(StudioAudio.isCanonical(tone(10, rate = 48_000)))
        assertFalse(StudioAudio.isCanonical(tone(10, ch = 1)))
    }

    @Test fun frameMath() {
        assertEquals(44_100L, StudioAudio.msToFrames(1000, 44_100.0))
        assertEquals(0L, StudioAudio.msToFrames(-5, 44_100.0))
        assertEquals(22_050L, StudioAudio.nominalSampleFrames(44_100, 44_100.0, 2.0))
        assertEquals(44_101L, StudioAudio.nominalSampleFrames(44_100, 44_100.0, 0.99999)) // ceil never undershoots
        assertEquals(44_100L, StudioAudio.nominalSampleFrames(48_000, 48_000.0, 1.0)) // a 48k window lands on canonical frames
        assertEquals(88_200L, StudioAudio.exactLoopFrames(2000, 1.0))
        assertEquals(44_100L, StudioAudio.exactLoopFrames(2000, 2.0))
        assertEquals(132_300L, StudioAudio.exactLoopFrames(2000, 2.0 / 3.0))
        assertEquals(132_300L, StudioAudio.tailCapFrames)
    }

    @Test fun isBelowFloorDetectsTailDecay() {
        val loud = FloatArray(1024) { 0.01f } // -40 dBFS
        val quiet = FloatArray(1024) { 0.0005f } // ~-66 dBFS
        assertFalse(StudioAudio.isBelowFloor(loud, 0, 1024))
        assertTrue(StudioAudio.isBelowFloor(quiet, 0, 1024))
        assertTrue(StudioAudio.isBelowFloor(FloatArray(8), 0, 0)) // empty counts as silence
        assertEquals(-40.0, StudioAudio.rmsDb(loud, 0, 1024), 0.01)
        assertEquals(Double.NEGATIVE_INFINITY, StudioAudio.rmsDb(FloatArray(4), 0, 4), 0.0)
        // the window start offset is honoured
        val mixed = loud + quiet
        assertTrue(StudioAudio.isBelowFloor(mixed, 1024, 1024))
        assertFalse(StudioAudio.isBelowFloor(mixed, 0, 1024))
    }

    @Test fun sliceNeverPads() {
        val b = tone(100)
        assertEquals(40, StudioAudio.slice(b, 10, 40)!!.frames)
        assertNull(StudioAudio.slice(b, 90, 20))
        assertNull(StudioAudio.slice(b, -1, 5))
        assertNull(StudioAudio.slice(b, 0, 0))
    }

    @Test fun mixPcmSumsToLongestAndHardClamps() {
        val a = PcmBuffer(44_100, 2, FloatArray(8) { 0.8f })
        val b = PcmBuffer(44_100, 2, FloatArray(12) { 0.7f })
        val m = StudioAudio.mixPcm(listOf(a, b))
        assertEquals(6, m.frames)
        assertEquals(1f, m.samples[0], 0f)   // 1.5 clamped
        assertEquals(0.7f, m.samples[10], 1e-6f) // only b reaches the tail
        assertEquals(m.samples.size, StudioRender.mixPCM(listOf(a, b)).samples.size)
    }

    @Test fun addIntoSumsOverTheOverlapOnly() {
        val acc = FloatArray(6) { 1f }
        StudioAudio.addInto(acc, PcmBuffer(44_100, 2, floatArrayOf(0.5f, 0.5f, 0.5f, 0.5f)))
        assertEquals(listOf(1.5f, 1.5f, 1.5f, 1.5f, 1f, 1f), acc.toList())
    }

    @Test fun relabelKeepsSamplesAndStampsCanonicalRate() {
        val raw = tone(48_000, rate = 48_000)
        val r = StudioAudio.relabeled(raw)
        assertEquals(44_100, r.sampleRate)
        assertEquals(48_000, r.frames) // same frames, ~8.8% longer when played at 44.1k
        assertEquals(raw.samples[100], r.samples[100], 0f)
        assertEquals(2, StudioAudio.relabeled(tone(10, rate = 22_050, ch = 1)).channels)
    }

    @Test fun emulatorDetectionAndBackendChoice() {
        assertTrue(StudioOutputs.looksLikeEmulator("generic_x86_64/sdk_gphone64", "ranchu", "sdk_gphone64_x86_64"))
        assertTrue(StudioOutputs.looksLikeEmulator(null, "goldfish", null))
        assertFalse(StudioOutputs.looksLikeEmulator("google/husky/husky:15/AP4A", "husky", "husky"))
        assertEquals(StudioOutputs.Backend.OBOE, StudioOutputs.chooseBackend(nativeAvailable = true, isEmulator = false))
        assertEquals(StudioOutputs.Backend.AUDIO_TRACK, StudioOutputs.chooseBackend(nativeAvailable = true, isEmulator = true))
        assertEquals(StudioOutputs.Backend.AUDIO_TRACK, StudioOutputs.chooseBackend(nativeAvailable = false, isEmulator = false))
    }

    @Test fun nativeLibraryAbsentOnTheJvmFallsBackCleanly() {
        assertFalse(NativeDsp.available)
        val fx = NativeDsp.trackFx()
        assertNotNull(fx)
        assertTrue(fx is com.levi.pocketdj.studio.dsp.TrackFxKernel)
        // NativeStretcher degrades to the resampler: still EXACT length
        val out = NativeStretcher.stretch(tone(1000), 777, 0.0)
        assertEquals(777, out.frames)
    }
}

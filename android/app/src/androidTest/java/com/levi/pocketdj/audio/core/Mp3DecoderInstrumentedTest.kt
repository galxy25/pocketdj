package com.levi.pocketdj.audio.core

import androidx.test.ext.junit.runners.AndroidJUnit4
import org.junit.Assert.assertEquals
import org.junit.Assert.assertTrue
import org.junit.Test
import org.junit.runner.RunWith
import kotlin.math.abs

/** Runs on the emulator (headless -no-audio is fine: decode only). Fixtures are shared with the JVM tests. */
@RunWith(AndroidJUnit4::class)
class Mp3DecoderInstrumentedTest {
    private fun bytes(name: String) = javaClass.classLoader!!.getResourceAsStream("mix/$name")!!.readBytes()

    private fun decodeAll(d: Mp3Decoder, max: Int = 200_000): FloatArray {
        d.seek(0)
        val ch = d.channels
        val out = FloatArray(max * ch)
        var n = 0
        val buf = FloatArray(4096 * ch)
        while (n < max) {
            val r = d.read(buf, minOf(4096, max - n))
            if (r <= 0) break
            System.arraycopy(buf, 0, out, n * ch, r * ch)
            n += r
        }
        return out.copyOf(n * ch)
    }

    @Test fun decodesTaggedFixtureToItsKnownLengthAndFirstSoundWithin2ms() {
        val d = Mp3Decoder(ArrayByteSource(bytes("tagged-lame-2s.mp3")))
        val total = d.totalFrames
        val pcm = decodeAll(d)
        val ch = d.channels
        assertEquals(total.toDouble(), (pcm.size / ch).toDouble(), 2048.0)
        // the fixture is a 440 Hz sine starting at phase 0 -> sound begins at file frame 0 (+ first half-cycle ramp)
        var first = -1
        for (i in 0 until pcm.size / ch) if (abs(pcm[i * ch]) > 0.01f) { first = i; break }
        assertTrue("first audible frame $first", first in 0..(0.002 * d.sampleRate).toInt() + 50)
        d.close()
    }

    @Test fun seekMidFileLandsOnTheSameSamplesAsLinearDecode() {
        val d = Mp3Decoder(ArrayByteSource(bytes("tagged-lame-2s.mp3")))
        val all = decodeAll(d)
        val ch = d.channels
        d.seek(40_000)
        val buf = FloatArray(1024 * ch)
        val r = d.read(buf, 1024)
        assertEquals(1024, r)
        for (i in 0 until 1024) assertEquals(all[(40_000 + i) * ch], buf[i * ch], 0.02f)
        d.close()
    }

    @Test fun untaggedFixtureDecodesWithPrimingApplied() {
        val d = Mp3Decoder(ArrayByteSource(bytes("untagged-lame-2s.mp3")))
        val pcm = decodeAll(d)
        assertEquals(2.0, pcm.size / d.channels / d.sampleRate.toDouble(), 0.06)
        d.close()
    }
}

package com.levi.pocketdj.audio.core

import androidx.test.ext.junit.runners.AndroidJUnit4
import org.junit.Assert.assertEquals
import org.junit.Assert.assertNotNull
import org.junit.Test
import org.junit.runner.RunWith
import java.io.File

@RunWith(AndroidJUnit4::class)
class AudioDecoderInstrumentedTest {
    @Test fun decodesMp3AndWavToCanonicalStereo44k() {
        val dir = androidx.test.platform.app.InstrumentationRegistry.getInstrumentation().targetContext.cacheDir
        val mp3 = File(dir, "t.mp3").also { it.writeBytes(javaClass.classLoader!!.getResourceAsStream("mix/tagged-lame-2s.mp3")!!.readBytes()) }
        val a = AudioDecoder.decode(mp3.path)
        assertNotNull(a)
        assertEquals(2, a!!.channels); assertEquals(44_100, a.sampleRate)
        assertEquals(2.0, a.seconds, 0.1)

        val wav = File(dir, "t.wav")
        WavWriter.write(wav, PcmBuffer(22_050, 1, FloatArray(22_050) { if (it % 50 < 25) 0.3f else -0.3f }))
        val b = AudioDecoder.decode(wav.path)!!
        assertEquals(2, b.channels); assertEquals(44_100, b.sampleRate)
        assertEquals(1.0, b.seconds, 0.05)
    }

    @Test fun aacRoundTripThroughEncoderAndDecoder() {
        val dir = androidx.test.platform.app.InstrumentationRegistry.getInstrumentation().targetContext.cacheDir
        val pcm = PcmBuffer(44_100, 2, FloatArray(44_100 * 2) { (0.4 * Math.sin(it / 2 * 2 * Math.PI * 440 / 44_100)).toFloat() })
        val out = File(dir, "t.m4a")
        AacEncoder.encode(pcm, out, AacEncoder.Container.M4A)
        val back = AudioDecoder.decode(out.path)!!
        assertEquals(1.0, back.seconds, 0.15)
    }
}

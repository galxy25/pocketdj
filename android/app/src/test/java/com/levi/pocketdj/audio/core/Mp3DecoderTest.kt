package com.levi.pocketdj.audio.core

import org.junit.Assert.assertEquals
import org.junit.Test

/** JVM-checkable parts of [Mp3Decoder] (the codec itself is covered by the instrumented test). */
class Mp3DecoderTest {
    private fun fixture(name: String) = ArrayByteSource(javaClass.classLoader!!.getResourceAsStream("mix/$name")!!.readBytes())

    @Test fun freshDecoderReportsTheFilesFormatBeforeAnyRead() {
        val mono = Mp3Decoder(fixture("mono-22k-1s.mp3"))
        assertEquals(22_050, mono.sampleRate); assertEquals(1, mono.channels)
        val st = Mp3Decoder(fixture("tagged-lame-2s.mp3"))
        assertEquals(44_100, st.sampleRate); assertEquals(2, st.channels)
    }

    @Test fun voiceWrapsAMonoNon44kMp3InAConversionSoLengthIsInSinkFrames() {
        val v = Voice(Mp3Decoder(fixture("mono-22k-1s.mp3")))
        // ~1 s of 22.05k mono is ~44.1k sink frames; without the wrap it would report ~22k source frames
        assertEquals(44_100.0, v.totalFrames.toDouble(), 3_000.0)
    }

    @Test fun discardDropsOnlyTheEncoderDelayBecauseTheCodecTrimsItsOwnDecoderDelay() {
        assertEquals(576L, Mp3Decoder.discardFor(0, 576, 0, 1152))
        assertEquals(40_000L + 576 - 33 * 1152, Mp3Decoder.discardFor(40_000, 576, 33, 1152))
        assertEquals(0L, Mp3Decoder.discardFor(0, 0, 5, 1152))
    }
}

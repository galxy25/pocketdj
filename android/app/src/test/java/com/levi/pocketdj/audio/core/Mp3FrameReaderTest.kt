package com.levi.pocketdj.audio.core

import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNotNull
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test

class Mp3FrameReaderTest {
    private fun fixture(name: String): ByteArray =
        checkNotNull(javaClass.classLoader!!.getResourceAsStream("mix/$name")) { "missing $name" }.readBytes()

    private val tagged by lazy { fixture("tagged-lame-2s.mp3") }
    private val untagged by lazy { fixture("untagged-lame-2s.mp3") }

    @Test fun headerParseMatchesKnownFrames() {
        val h = Mp3Header.parse(0xFF, 0xFB, 0x90, 0x64)!! // 128 kbps / 44.1k / joint stereo, no pad
        assertEquals(1, h.mpegVersion); assertEquals(128_000, h.bitrate); assertEquals(44_100, h.sampleRate)
        assertEquals(2, h.channels); assertEquals(417, h.frameBytes); assertEquals(1152, h.samplesPerFrame)
        assertEquals(32, h.sideInfoBytes)
        assertNull(Mp3Header.parse(0xFF, 0xFB, 0xF0, 0)) // bitrate index 15
        assertNull(Mp3Header.parse(0xFF, 0xFD, 0x90, 0)) // layer II
        val v2 = Mp3Header.parse(0xFF, 0xF3, 0x90, 0xC4)!! // MPEG-2 L3 mono
        assertEquals(2, v2.mpegVersion); assertEquals(576, v2.samplesPerFrame); assertEquals(1, v2.channels)
        assertEquals(22_050, v2.sampleRate)
    }

    @Test fun taggedFileReportsXingFrameCountAndEncoderDelay() {
        val r = Mp3FrameReader(ArrayByteSource(tagged))
        assertTrue(r.open())
        val tag = r.tag!!
        assertEquals("Xing", tag.kind)
        assertEquals(78L, tag.frameCount)
        assertEquals(576, tag.encoderDelay)
        assertEquals(576, r.encoderDelay)
        assertEquals(576 + 529, r.startSkip)
        assertEquals(44_100, r.sampleRate); assertEquals(2, r.channels)
        val endPad = tag.endPadding!!
        assertEquals(78L * 1152 - 1105 - maxOf(0, endPad - 529), r.totalFrames(complete = true))
        // ~2 s of tone
        assertEquals(2.0, r.totalFrames(true) / 44_100.0, 0.05)
    }

    @Test fun untaggedFileUsesThe576PrimingRuleAndNeedsCompletionForLength() {
        val r = Mp3FrameReader(ArrayByteSource(untagged))
        assertTrue(r.open())
        assertNull(r.tag)
        assertEquals(576, r.encoderDelay)
        assertEquals(0L, r.audioStart)
        assertEquals(-1L, r.totalFrames(complete = false))
        val total = r.totalFrames(complete = true)
        assertEquals(2.0, total / 44_100.0, 0.05)
        val frames = r.presentFrames(untagged.size.toLong())
        assertEquals(frames * 1152 - 1105, total)
    }

    @Test fun truncatedTaggedFileStillReportsFullLengthAndPlayableStaysBehindTheFrontier() {
        val fullTotal = Mp3FrameReader(ArrayByteSource(tagged)).apply { open() }.totalFrames(true)
        val cut = tagged.size / 2
        val src = ArrayByteSource(tagged, cut)
        val r = Mp3FrameReader(src)
        assertTrue(r.open())
        assertEquals(fullTotal, r.totalFrames(complete = false))
        val present = r.presentFrames(cut.toLong())
        assertTrue(present in 1..77)
        val playable = r.playableFrames(cut.toLong())
        val margin = (1.5 * 44_100).toLong()
        assertEquals(maxOf(0L, present * 1152 - r.startSkip - margin), playable)
        // with ~1 s of the 2 s file present the 1.5 s torn-frame margin leaves nothing safe yet
        assertEquals(0L, playable)
        // the whole file past the margin: complete => full length
        assertEquals(fullTotal, Mp3FrameReader(ArrayByteSource(tagged)).apply { open() }.playableFrames(tagged.size.toLong(), complete = true))
    }

    @Test fun growingFileOpensOnlyOnceHeaderBytesArrive() {
        val src = ArrayByteSource(tagged, 3)
        val r = Mp3FrameReader(src)
        assertFalse(r.open())
        assertFalse(r.isOpen)
        src.valid = tagged.size
        assertTrue(r.open())
        assertEquals(78L, r.tag!!.frameCount)
    }

    @Test fun playableFramesIsMonotonicAsBytesArrive() {
        val src = ArrayByteSource(tagged, 2000)
        val r = Mp3FrameReader(src)
        r.open()
        var last = -1L
        for (b in 2000..tagged.size step 500) {
            src.valid = b
            val p = r.playableFrames(b.toLong())
            assertTrue(p >= last)
            last = p
        }
    }

    @Test fun frameIndexAndSampleMappingRoundTrip() {
        val r = Mp3FrameReader(ArrayByteSource(tagged)).also { it.open() }
        assertEquals(0L, r.frameIndexForSample(0))
        assertEquals(1L, r.frameIndexForSample(1152 - 1105)) // sample 47 is where frame 1 begins
        assertEquals(-1105L, r.sampleForFrameIndex(0))
        assertEquals(47L, r.sampleForFrameIndex(1))
    }

    @Test fun framesAreAddressableAndAudioStartsAfterTheXingFrame() {
        val r = Mp3FrameReader(ArrayByteSource(tagged)).also { it.open() }
        r.presentFrames(tagged.size.toLong())
        val buf = ByteArray(Mp3FrameReader.MAX_FRAME_BYTES)
        val n = r.readFrame(0, buf)
        assertTrue(n > 0)
        assertNotNull(Mp3Header.parse(buf[0].toInt(), buf[1].toInt(), buf[2].toInt(), buf[3].toInt()))
        assertEquals(r.audioStart, r.frameOffset(0))
        assertEquals(-1, r.readFrame(100_000, buf))
        assertTrue(r.audioStart > 0) // ID3v2 + Xing frame skipped
    }
}

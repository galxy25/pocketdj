package com.levi.pocketdj.mix.stream

import com.levi.pocketdj.mix.engine.StreamRules
import com.levi.pocketdj.mix.stream.GrowingFileSchedule.LengthClaim
import java.io.File
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNotNull
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test

/** Port of iOS `GrowingFileScheduleTests` / `NPMixGrowingFileTests` section 1 (the pure tables) + the length-claim sniffer. */
class GrowingFileScheduleTest {
    private val sr = 44_100.0

    @Test fun bytesPerSecondTrustsOnlyADeclaredLength() {
        // 12 s whose file is 384 KB => 32 KB/s.
        assertEquals(32_000.0, GrowingFileSchedule.bytesPerSecond(529_200, 44_100.0, 384_000, LengthClaim.FrameCount)!!, 1.0)
        assertEquals(32_000.0, GrowingFileSchedule.bytesPerSecond(529_200, 44_100.0, 384_000, LengthClaim.Container)!!, 1.0)
        // Headerless / TLEN-only / undecided: the decoder's length is an estimate - never a rate.
        for (c in listOf(LengthClaim.Absent, LengthClaim.Undetermined, LengthClaim.Tlen(12_000))) {
            assertNull("$c", GrowingFileSchedule.bytesPerSecond(529_200, 44_100.0, 384_000, c))
        }
        // A trusted length that could not cover expectedBytes at 320 kbps (~41 KB/s) is not the song's.
        assertNull(GrowingFileSchedule.bytesPerSecond(44_100 * 5, 44_100.0, 384_000, LengthClaim.FrameCount))
        // No Content-Length: the house rate.
        assertEquals(com.levi.pocketdj.mix.model.MixMath.BYTES_PER_PLAYBACK_SECOND,
            GrowingFileSchedule.bytesPerSecond(529_200, 44_100.0, null, LengthClaim.FrameCount)!!, 0.0)
        assertNull(GrowingFileSchedule.bytesPerSecond(0, 44_100.0, 1000, LengthClaim.FrameCount))
        assertFalse(GrowingFileSchedule.attachableWhilePartial(LengthClaim.Absent))
        assertFalse(GrowingFileSchedule.attachableWhilePartial(LengthClaim.Tlen(1)))
        assertFalse(GrowingFileSchedule.attachableWhilePartial(LengthClaim.Undetermined))
        assertTrue(GrowingFileSchedule.attachableWhilePartial(LengthClaim.FrameCount))
        assertTrue(GrowingFileSchedule.attachableWhilePartial(LengthClaim.Container))
    }

    @Test fun frontierIsBytesMinusMarginCappedAtTheWindow() {
        assertEquals((3.5 * sr).toLong(), GrowingFileSchedule.frontier(160_000, false, 32_000.0, sr, 0, 529_200))
        assertEquals("never past the window's end", 529_200L, GrowingFileSchedule.frontier(10_000_000, false, 32_000.0, sr, 0, 529_200))
        assertEquals("complete => the whole window", 529_200L, GrowingFileSchedule.frontier(1, true, 32_000.0, sr, 0, 529_200))
        assertEquals("headerless (null rate) => nothing", 1000L, GrowingFileSchedule.frontier(160_000, false, null, sr, 1000, 529_200))
        assertEquals("under the margin => the window start", 500L, GrowingFileSchedule.frontier(1_000, false, 32_000.0, sr, 500, 529_200))
    }

    @Test fun canStartNeedsRunwayPastThePlayheadOrTheWindowEnd() {
        assertTrue(GrowingFileSchedule.canStart(0, (2 * sr).toLong(), 529_200, false, 2.0, sr))
        assertFalse(GrowingFileSchedule.canStart(0, (1.9 * sr).toLong(), 529_200, false, 2.0, sr))
        assertTrue("the tail is all there", GrowingFileSchedule.canStart((11 * sr).toLong(), 529_200, 529_200, false, 4.0, sr))
        assertFalse("the frontier must be PAST the playhead", GrowingFileSchedule.canStart((5 * sr).toLong(), (5 * sr).toLong(), 529_200, false, 0.0, sr))
        assertTrue(GrowingFileSchedule.canStart(529_200, 0, 529_200, true, 4.0, sr))
        assertEquals(2.0, GrowingFileSchedule.runwayNeeded(resuming = false), 0.0)
        assertEquals(4.0, GrowingFileSchedule.runwayNeeded(resuming = true), 0.0)
    }

    @Test fun appendIsSmallWhileTheRunwayIsShortAndBigOnceComfortable() {
        fun f(sec: Double) = (sec * sr).toLong()
        assertTrue(GrowingFileSchedule.shouldAppend(f(3.0), f(4.1), f(2.0), sr, false))
        assertFalse(GrowingFileSchedule.shouldAppend(f(3.0), f(3.5), f(2.0), sr, false))
        assertFalse("comfortable runway waits for a 15 s chunk", GrowingFileSchedule.shouldAppend(f(20.0), f(30.0), f(2.0), sr, false))
        assertTrue(GrowingFileSchedule.shouldAppend(f(20.0), f(36.0), f(2.0), sr, false))
        assertTrue("complete appends at once", GrowingFileSchedule.shouldAppend(f(3.0), f(3.1), 0, sr, true))
        assertFalse("nothing new", GrowingFileSchedule.shouldAppend(f(3.0), f(3.0), 0, sr, true))
    }

    @Test fun underrunIsTheEndOfWhatIsScheduledNotTheEndOfTheSong() {
        assertTrue(GrowingFileSchedule.underrun(4.96, 5.0, 12.0))
        assertFalse(GrowingFileSchedule.underrun(4.5, 5.0, 12.0))
        assertFalse("the real end is no underrun", GrowingFileSchedule.underrun(11.99, 12.0, 12.0))
    }

    @Test fun windowCutsAnAnalogSideSliceAndFlagsAnEmptyOne() {
        val w = GrowingFileSchedule.window(44_100L * 600, sr, 60_000, 180_000)
        assertEquals(60L * 44_100, w.first); assertEquals(180L * 44_100, w.second)
        assertTrue(GrowingFileSchedule.window(1_000, sr, 60_000, null).second <= 0)
        assertEquals(44_100L * 540, GrowingFileSchedule.window(44_100L * 600, sr, 60_000, null).second)
    }

    @Test fun coveredFileSecondsEstimatesFromTheByteFraction() {
        assertEquals(4.5, GrowingFileSchedule.coveredFileSeconds(50, 100, false, 12.0)!!, 1e-9)
        assertEquals(12.0, GrowingFileSchedule.coveredFileSeconds(1, null, true, 12.0)!!, 0.0)
        assertNull(GrowingFileSchedule.coveredFileSeconds(50, null, false, 12.0))
        assertNull(GrowingFileSchedule.coveredFileSeconds(50, 100, false, null))
    }

    @Test fun mixStreamRulesForwardToTheSharedSchedule() {
        assertEquals(GrowingFileSchedule.START_RUNWAY, StreamRules.START_RUNWAY, 0.0)
        assertEquals(GrowingFileSchedule.RESUME_RUNWAY, StreamRules.RESUME_RUNWAY, 0.0)
        assertEquals(1.0, StreamRules.appendChunk(3.0), 0.0)
        assertEquals(15.0, StreamRules.appendChunk(12.0), 0.0)
        assertTrue(StreamRules.canResume(false, (2 * sr).toLong(), 0, 529_200, 44_100, playing = false))
        assertFalse("playing needs the bigger resume cushion", StreamRules.canResume(false, (2 * sr).toLong(), 0, 529_200, 44_100, playing = true))
        assertTrue(StreamRules.shouldHold(5.0, 12.0, 4.97))
        assertFalse(StreamRules.shouldHold(12.0, 12.0, 11.99))
    }

    // ---------------------------------------------------------------- length claim (synthetic mp3 bytes)

    /** MPEG-1 L3, 128 kbps, 44.1 kHz, joint stereo: 417-byte frames. */
    private val frameLen = 417
    private fun frame(fill: Byte = 0): ByteArray = ByteArray(frameLen) { fill }.also {
        it[0] = 0xFF.toByte(); it[1] = 0xFB.toByte(); it[2] = 0x90.toByte(); it[3] = 0x44
    }
    private fun withXing(tag: String = "Xing", frames: Int = 500): ByteArray = frame().also {
        val o = 4 + 32
        tag.forEachIndexed { i, c -> it[o + i] = c.code.toByte() }
        it[o + 7] = 1                                                // flags: frames present
        it[o + 8] = (frames shr 24).toByte(); it[o + 9] = (frames shr 16).toByte()
        it[o + 10] = (frames shr 8).toByte(); it[o + 11] = frames.toByte()
    }
    private fun withVbri(frames: Int = 500): ByteArray = frame().also {
        val o = 36
        "VBRI".forEachIndexed { i, c -> it[o + i] = c.code.toByte() }
        it[o + 17] = frames.toByte(); it[o + 16] = (frames shr 8).toByte()
    }
    /** An ID3v2.3 tag carrying only a TLEN frame. */
    private fun id3Tlen(ms: Int): ByteArray {
        val body = "0$ms".toByteArray(Charsets.ISO_8859_1)                     // encoding byte 0x30?? use real 0
        body[0] = 0
        val frame = "TLEN".toByteArray() + byteArrayOf(0, 0, 0, body.size.toByte(), 0, 0) + body
        val size = frame.size
        return "ID3".toByteArray() + byteArrayOf(3, 0, 0, 0, 0, ((size shr 7) and 0x7F).toByte(), (size and 0x7F).toByte()) + frame
    }

    @Test fun xingInfoAndVbriDeclareTheFullLength() {
        assertEquals(LengthClaim.FrameCount, GrowingFileSchedule.lengthClaim(withXing("Xing") + frame()))
        assertEquals(LengthClaim.FrameCount, GrowingFileSchedule.lengthClaim(withXing("Info") + frame()))
        assertEquals(LengthClaim.FrameCount, GrowingFileSchedule.lengthClaim(withVbri() + frame()))
        assertEquals("a zero frame count declares nothing", LengthClaim.Absent,
            GrowingFileSchedule.lengthClaim(withXing("Xing", frames = 0) + frame() + ByteArray(20_000)))
    }

    @Test fun aHeaderlessFileIsAbsentAndATlenAloneIsNotTrusted() {
        val raw = frame() + frame() + frame()
        assertEquals(LengthClaim.Absent, GrowingFileSchedule.lengthClaim(raw))
        val c = GrowingFileSchedule.lengthClaim(id3Tlen(12_000) + raw)
        assertTrue("TLEN-only is reported but never makes the file attachable", c is LengthClaim.Tlen && c.ms == 12_000)
        assertFalse(GrowingFileSchedule.attachableWhilePartial(c))
    }

    @Test fun tooFewBytesIsUndeterminedNeverAVerdict() {
        assertEquals(LengthClaim.Undetermined, GrowingFileSchedule.lengthClaim(ByteArray(0)))
        assertEquals(LengthClaim.Undetermined, GrowingFileSchedule.lengthClaim(frame().copyOf(100)))
        assertEquals("the first frame is here but the next is not: cannot verify", LengthClaim.Undetermined,
            GrowingFileSchedule.lengthClaim(withXing()))
        val tag = id3Tlen(5000)
        assertEquals("a partial ID3 tag", LengthClaim.Undetermined, GrowingFileSchedule.lengthClaim(tag.copyOf(tag.size - 3)))
        assertEquals(LengthClaim.Undetermined, GrowingFileSchedule.lengthClaim("ID".toByteArray()))
    }

    @Test fun aStrayFrameSyncIsNotAFrameTheNextOneMustFollow() {
        val junk = ByteArray(40) { 0 }.also { it[10] = 0xFF.toByte(); it[11] = 0xFB.toByte(); it[12] = 0x90.toByte(); it[13] = 0x44 }
        assertEquals(LengthClaim.FrameCount, GrowingFileSchedule.lengthClaim(junk + withXing() + frame()))
    }

    @Test fun anNonMp3FileTrustsItsContainerAndAFileSniffMatchesTheBytes() {
        val dir = File(System.getProperty("java.io.tmpdir"), "gfs-${System.nanoTime()}").also { it.mkdirs() }
        try {
            val m4a = File(dir, "a.m4a").also { it.writeBytes(ByteArray(10)) }
            assertEquals(LengthClaim.Container, GrowingFileSchedule.lengthClaim(m4a))
            val x = File(dir, "x.mp3").also { it.writeBytes(withXing() + frame()) }
            assertEquals(LengthClaim.FrameCount, GrowingFileSchedule.lengthClaim(x))
            val h = File(dir, "h.mp3").also { it.writeBytes(frame() + frame() + frame()) }
            assertEquals(LengthClaim.Absent, GrowingFileSchedule.lengthClaim(h))
            assertEquals("unreadable => undetermined, not a verdict", LengthClaim.Undetermined,
                GrowingFileSchedule.lengthClaim(File(dir, "missing.mp3")))
            val part = File(dir, "p.mp3").also { it.writeBytes(frame().copyOf(50)) }
            assertNotNull(GrowingFileSchedule.lengthClaim(part))
            assertEquals(LengthClaim.Undetermined, GrowingFileSchedule.lengthClaim(part))
        } finally { dir.deleteRecursively() }
    }
}

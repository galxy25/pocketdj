package com.levi.pocketdj.mix.stream

import com.levi.pocketdj.mix.model.MixMath
import java.io.File
import java.io.RandomAccessFile
import kotlin.math.max
import kotlin.math.min

/**
 * GROWING-FILE SCHEDULING (port of iOS `GrowingFileSchedule`): the decisions every engine that plays a file
 * WHILE IT DOWNLOADS needs, shared by the Mix decks ([com.levi.pocketdj.mix.engine.StreamDecks]) and the Now
 * Playing DSP (`NowPlayingDspEngine.engageStreaming`) so they attach, hold, resume, append and detect an
 * underrun the SAME way. Pure functions; no engine state.
 *
 * The model (a LAME mp3 written progressively by [MixStreamLoader]'s sink):
 *  - the schedulable FRONTIER is bytes -> seconds at the file's byte rate (learned at attach) minus a
 *    torn-frame margin, never past the song window's end;
 *  - the playhead is never scheduled past the frontier: at the frontier it HOLDS (stall -> wait, not
 *    silence / crash / skip) and resumes once there is runway again.
 */
object GrowingFileSchedule {
    /** Seconds of runway past the playhead needed to START a held playhead (first audio)... */
    const val START_RUNWAY = 2.0
    /** ...and to RESUME after an underrun / a seek past the frontier (a bigger cushion: no hold/play flapping). */
    const val RESUME_RUNWAY = 4.0
    /** Bytes counted as present can include a torn trailing mp3 frame: the last stretch before the byte frontier is never scheduled. */
    const val FRONTIER_MARGIN = MixMath.STREAM_FRONTIER_MARGIN
    /** An on-air voice holds this close to the end of what it has scheduled. */
    const val UNDERRUN_LEAD = 0.05
    /** Bytes scanned past the ID3 tag(s) for the first MPEG frame (padding / junk tolerated). */
    const val SNIFF_SCAN = 16 * 1024
    /** The mp3 max bitrate (320 kbps incl. framing) in bytes per second: a length that cannot cover [expectedBytes] at it is not the song's. */
    private const val MAX_MP3_BYTES_PER_SECOND = 41_000.0

    // ------------------------------------------------------------------ length claim

    /** What a growing file's leading bytes say about its length. */
    sealed interface LengthClaim {
        /** An Xing / Info / VBRI frame (non-zero frame count) in the first MPEG frame: trusted. */
        data object FrameCount : LengthClaim
        /** No frame-count header, only an ID3v2 TLEN (ms): NOT trusted (the decoder's length is an estimate). */
        data class Tlen(val ms: Int) : LengthClaim
        /** The first MPEG frame is here (and verified) and declares nothing: HEADERLESS. */
        data object Absent : LengthClaim
        /** Not enough bytes yet to verify the first frame: sniff again later (never a verdict). */
        data object Undetermined : LengthClaim
        /** Not an mp3: the container's length decides. */
        data object Container : LengthClaim
    }

    /**
     * Bytes of file per second of audio for a growing mp3 - or null: don't attach until the download
     * completes (its frame -> byte map is unknowable mid-flight).
     *
     * The decoder's open length is trusted only on the sniffed claim: [LengthClaim.FrameCount] /
     * [LengthClaim.Container]. A trusted length must ALSO be plausible: one that couldn't cover
     * [expectedBytes] at 320 kbps is not the song's. No Content-Length: the house rate.
     */
    fun bytesPerSecond(totalFrames: Long, sampleRate: Double, expectedBytes: Long?, claim: LengthClaim): Double? {
        if (!(sampleRate > 0) || totalFrames <= 0) return null
        val seconds = totalFrames.toDouble() / sampleRate
        when (claim) {
            LengthClaim.Absent, LengthClaim.Undetermined, is LengthClaim.Tlen -> return null
            LengthClaim.FrameCount, LengthClaim.Container -> {}
        }
        if (expectedBytes == null || expectedBytes <= 0) return MixMath.BYTES_PER_PLAYBACK_SECOND
        if (seconds < expectedBytes.toDouble() / MAX_MP3_BYTES_PER_SECOND) return null
        return expectedBytes.toDouble() / seconds
    }

    /** May a PARTIAL file with this [claim] be attached on its length estimate? Only a declared length. */
    fun attachableWhilePartial(claim: LengthClaim): Boolean =
        claim == LengthClaim.FrameCount || claim == LengthClaim.Container

    /** Sniff [file]'s length claim: reads only the ID3v2 tag(s) and the first frames. */
    fun lengthClaim(file: File): LengthClaim {
        if (!file.name.lowercase().endsWith(".mp3")) return LengthClaim.Container
        return try {
            RandomAccessFile(file, "r").use { raf ->
                val first = 64 * 1024
                var buf = ByteArray(min(raf.length(), first.toLong()).toInt())
                raf.readFully(buf)
                val tag = id3Span(buf)
                // A big tag (cover art) pushes the first frame past the first read: read on to it.
                if (buf.size == first && tag.end + SNIFF_SCAN > first) {
                    val want = min(tag.end.toLong() + SNIFF_SCAN, raf.length()).coerceAtMost(32L * 1024 * 1024 + first)
                    if (want > buf.size) {
                        val more = ByteArray((want - buf.size).toInt())
                        raf.seek(buf.size.toLong()); raf.readFully(more)
                        buf += more
                    }
                }
                lengthClaim(buf)
            }
        } catch (_: Exception) { LengthClaim.Undetermined }
    }

    /** Pure: the length claim of a (possibly partial) mp3 whose leading bytes are [b]. */
    fun lengthClaim(b: ByteArray): LengthClaim {
        val tag = id3Span(b)
        if (!tag.complete) return LengthClaim.Undetermined
        val limit = min(b.size, tag.end + SNIFF_SCAN)
        var i = tag.end
        while (i + 4 <= limit) {
            val f = MpegFrame.parse(b, i)
            if (f == null) { i++; continue }
            // A stray 0xFFE bit pattern isn't a frame: the NEXT frame must follow exactly.
            val next = i + f.length
            if (next + 4 > b.size) return LengthClaim.Undetermined
            val g = MpegFrame.parse(b, next)
            if (g == null || g.version != f.version || g.sampleRate != f.sampleRate) { i++; continue }
            if (xingFrames(b, i, f) > 0 || vbriFrames(b, i) > 0) return LengthClaim.FrameCount
            val ms = tag.tlenMs
            if (ms != null && ms > 0) return LengthClaim.Tlen(ms)
            return LengthClaim.Absent
        }
        // No verified frame in what's here: undetermined while the scan window is still filling.
        return if (b.size < tag.end + SNIFF_SCAN) LengthClaim.Undetermined else LengthClaim.Absent
    }

    data class Id3Span(val end: Int, val complete: Boolean, val tlenMs: Int?)

    /** The leading ID3v2 tag(s): where audio may start, whether the whole tag is present yet, and its TLEN (ms). */
    fun id3Span(b: ByteArray): Id3Span {
        val magic = byteArrayOf(0x49, 0x44, 0x33)
        var at = 0
        var tlen: Int? = null
        repeat(4) {                                                           // tags can be stacked
            val avail = b.size - at
            if (avail < 10) {
                // Too short to read a tag header: undecided only while what's here could still be one.
                val n = min(3, avail)
                val couldBeTag = (0 until n).all { b[at + it] == magic[it] }
                return Id3Span(at, !couldBeTag, tlen)
            }
            if (b[at] != magic[0] || b[at + 1] != magic[1] || b[at + 2] != magic[2]) return Id3Span(at, true, tlen)
            val major = b[at + 3].toInt() and 0xFF
            val flags = b[at + 5].toInt() and 0xFF
            val size4 = (6..9).map { b[at + it].toInt() and 0xFF }
            if (major < 2 || major > 4 || !size4.all { it < 0x80 }) return Id3Span(at, true, tlen)   // not a tag
            val size = size4.fold(0) { a, x -> (a shl 7) or x }
            val end = at + 10 + size + (if (major == 4 && flags and 0x10 != 0) 10 else 0)
            if (end > b.size) return Id3Span(end, false, tlen)
            if (tlen == null && flags and 0x80 == 0) {                        // not unsynchronised
                val ext = extendedHeaderSize(b, at, major, flags)
                tlen = id3Tlen(b, at + 10 + ext, at + 10 + size, major)
            }
            at = end
        }
        return Id3Span(at, true, tlen)
    }

    private fun extendedHeaderSize(b: ByteArray, at: Int, major: Int, flags: Int): Int {
        if (major < 3 || flags and 0x40 == 0 || at + 14 > b.size) return 0
        val raw = (10..13).map { b[at + it].toInt() and 0xFF }
        return if (major == 4) raw.fold(0) { a, x -> (a shl 7) or (x and 0x7F) }      // v2.4: includes itself
        else raw.fold(0) { a, x -> (a shl 8) or x } + 4                                 // v2.3: excludes its size field
    }

    private fun id3Tlen(b: ByteArray, from: Int, to: Int, major: Int): Int? {
        val idLen = if (major == 2) 3 else 4
        val sizeLen = idLen
        val hdr = if (major == 2) 6 else 10
        val want = (if (major == 2) "TLE" else "TLEN").toByteArray(Charsets.ISO_8859_1)
        val end = min(to, b.size)
        var i = max(0, from)
        while (i + hdr <= end) {
            if (b[i].toInt() == 0) return null                                              // padding
            var size = 0
            for (k in 0 until sizeLen) size = (size shl (if (major == 4) 7 else 8)) or (b[i + idLen + k].toInt() and 0xFF)
            if (size <= 0 || i + hdr + size > end) return null
            if (b.copyOfRange(i, i + idLen).contentEquals(want) && size > 1) {
                val digits = (i + hdr + 1 until i + hdr + size).map { b[it].toInt() and 0xFF }.filter { it in 0x30..0x39 }
                if (digits.isEmpty() || digits.size > 10) return null
                return digits.map { it.toChar() }.joinToString("").toLongOrNull()?.takeIf { it <= Int.MAX_VALUE }?.toInt()
            }
            i += hdr + size
        }
        return null
    }

    /** A Layer III MPEG audio frame header. */
    class MpegFrame private constructor(val version: Int, val mono: Boolean, val sampleRate: Int, val length: Int) {
        companion object {
            private val MPEG1 = intArrayOf(0, 32, 40, 48, 56, 64, 80, 96, 112, 128, 160, 192, 224, 256, 320)
            private val MPEG2 = intArrayOf(0, 8, 16, 24, 32, 40, 48, 56, 64, 80, 96, 112, 128, 144, 160)
            private val RATES = intArrayOf(44_100, 48_000, 32_000)

            fun parse(b: ByteArray, i: Int): MpegFrame? {
                if (i < 0 || i + 4 > b.size) return null
                val b0 = b[i].toInt() and 0xFF; val b1 = b[i + 1].toInt() and 0xFF
                val b2 = b[i + 2].toInt() and 0xFF; val b3 = b[i + 3].toInt() and 0xFF
                if (b0 != 0xFF || b1 and 0xE0 != 0xE0) return null
                val version = (b1 shr 3) and 3
                val layer = (b1 shr 1) and 3
                val brIdx = b2 shr 4
                val srIdx = (b2 shr 2) and 3
                val pad = (b2 shr 1) and 1
                if (version == 1 || layer != 1 || brIdx == 0 || brIdx == 15 || srIdx == 3) return null
                val sr = RATES[srIdx] shr (if (version == 3) 0 else if (version == 2) 1 else 2)
                val kbps = (if (version == 3) MPEG1 else MPEG2)[brIdx]
                val len = (if (version == 3) 144 else 72) * kbps * 1000 / sr + pad
                return MpegFrame(version, (b3 shr 6) == 3, sr, len)
            }
        }
    }

    private fun u32(b: ByteArray, i: Int): Long {
        if (i < 0 || i + 4 > b.size) return 0
        return ((b[i].toLong() and 0xFF) shl 24) or ((b[i + 1].toLong() and 0xFF) shl 16) or
            ((b[i + 2].toLong() and 0xFF) shl 8) or (b[i + 3].toLong() and 0xFF)
    }

    private fun tagAt(b: ByteArray, o: Int, s: String): Boolean =
        o >= 0 && o + s.length <= b.size && s.indices.all { b[o + it] == s[it].code.toByte() }

    /** The Xing/Info frame count declared in the first frame (0 = none / not declared). */
    private fun xingFrames(b: ByteArray, frameStart: Int, f: MpegFrame): Long {
        val side = if (f.version == 3) (if (f.mono) 17 else 32) else (if (f.mono) 9 else 17)
        val o = frameStart + 4 + side
        if (o + 12 > b.size) return 0
        if (!tagAt(b, o, "Xing") && !tagAt(b, o, "Info")) return 0
        if (u32(b, o + 4) and 0x1L == 0L) return 0                                 // frames field present
        return u32(b, o + 8)
    }

    /** The VBRI (Fraunhofer) frame count - its tag always sits 32 bytes past the frame header. */
    private fun vbriFrames(b: ByteArray, frameStart: Int): Long {
        val o = frameStart + 36
        if (o + 18 > b.size || !tagAt(b, o, "VBRI")) return 0
        return u32(b, o + 14)
    }

    // ------------------------------------------------------------------ frontier

    /** The last FILE frame safe to schedule given [bytes] downloaded (torn-frame margin applied; null rate = [startFrame]). */
    fun playableFrames(bytes: Long, bytesPerSecond: Double?, sampleRate: Double, startFrame: Long): Long =
        MixMath.streamPlayableFrames(bytes, bytesPerSecond, sampleRate, startFrame)

    /** The schedulable frontier (file frames): the whole window once complete, else the byte frontier capped at the window's end. */
    fun frontier(bytes: Long, complete: Boolean, bytesPerSecond: Double?, sampleRate: Double, start: Long, fullEnd: Long): Long {
        if (complete) return fullEnd
        return min(fullEnd, playableFrames(bytes, bytesPerSecond, sampleRate, start))
    }

    /** Seconds of runway needed to START (first audio) or RESUME. */
    fun runwayNeeded(resuming: Boolean): Double = if (resuming) RESUME_RUNWAY else START_RUNWAY

    /**
     * May a HELD playhead at [position] (file frames) start now? A complete file: always. Otherwise the
     * frontier must be PAST the playhead by [runway] seconds - or reach the window's end, whichever first.
     */
    fun canStart(position: Long, frontier: Long, fullEnd: Long, complete: Boolean, runway: Double, sampleRate: Double): Boolean {
        if (complete) return true
        val need = min(fullEnd, position + (max(0.0, runway) * sampleRate).toLong())
        return frontier > position && frontier >= need
    }

    /** Append granularity: small while the runway is short, big once comfortable (every pending append pins work). */
    fun appendChunkSeconds(runway: Double): Double = if (runway < 10) 1.0 else 15.0

    /** Should an on-air voice scheduled up to [scheduledEnd] get the next stretch (to [frontier]) now? */
    fun shouldAppend(scheduledEnd: Long, frontier: Long, playFrame: Long, sampleRate: Double, complete: Boolean): Boolean {
        if (frontier <= scheduledEnd || !(sampleRate > 0)) return false
        if (complete) return true
        val runway = (scheduledEnd - playFrame).toDouble() / sampleRate
        return (frontier - scheduledEnd).toDouble() / sampleRate >= appendChunkSeconds(runway)
    }

    /**
     * An on-air voice reached the end of what it could schedule while more of the song is still to come
     * (seconds, song-relative): hold there instead of running on over silence.
     */
    fun underrun(position: Double, scheduledEnd: Double, duration: Double): Boolean =
        scheduledEnd < duration - UNDERRUN_LEAD && position >= scheduledEnd - UNDERRUN_LEAD

    /**
     * The song's window inside the file: [startMs] into it (an analog album side; null for a per-song file),
     * [windowMs] long (null = to the file's end). count <= 0 = nothing in the window.
     */
    fun window(fileLength: Long, sampleRate: Double, startMs: Int?, windowMs: Int?): Pair<Long, Long> {
        val start = min(max(0L, ((startMs ?: 0) / 1000.0 * sampleRate).toLong()), fileLength)
        val count = windowMs?.let { min(fileLength - start, max(0L, (it / 1000.0 * sampleRate).toLong())) } ?: (fileLength - start)
        return start to count
    }

    /** Seconds of the FILE (from its 0:00) the bytes cover, estimated from the byte fraction (no file open). */
    fun coveredFileSeconds(bytes: Long, expectedBytes: Long?, complete: Boolean, fileDurationSeconds: Double?): Double? {
        val dur = fileDurationSeconds ?: return null
        if (!(dur > 0)) return null
        if (complete) return dur
        val expected = expectedBytes ?: return null
        if (expected <= 0) return null
        return max(0.0, bytes.toDouble() / expected * dur - FRONTIER_MARGIN)
    }
}

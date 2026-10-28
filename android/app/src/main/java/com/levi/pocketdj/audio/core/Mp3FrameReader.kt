package com.levi.pocketdj.audio.core

import java.io.File
import java.io.RandomAccessFile

/** Random-access bytes of a possibly growing file. */
interface ByteSource {
    /** Bytes currently present. */
    val length: Long
    fun read(pos: Long, dst: ByteArray, off: Int, len: Int): Int
    fun close() {}
}

class ArrayByteSource(private val bytes: ByteArray, validLength: Int = bytes.size) : ByteSource {
    @Volatile var valid: Int = validLength
    override val length: Long get() = valid.toLong()
    override fun read(pos: Long, dst: ByteArray, off: Int, len: Int): Int {
        if (pos >= valid) return -1
        val n = minOf(len.toLong(), valid - pos).toInt()
        System.arraycopy(bytes, pos.toInt(), dst, off, n)
        return n
    }
}

class FileByteSource(file: File) : ByteSource {
    private val raf = RandomAccessFile(file, "r")
    private val file = file
    override val length: Long get() = file.length()
    @Synchronized override fun read(pos: Long, dst: ByteArray, off: Int, len: Int): Int {
        raf.seek(pos)
        return raf.read(dst, off, len)
    }
    override fun close() = raf.close()
}

/** A parsed MPEG audio Layer III frame header. */
data class Mp3Header(
    val mpegVersion: Int, // 1, 2 (MPEG-2) or 25 (MPEG-2.5)
    val bitrate: Int,     // bits/s
    val sampleRate: Int,
    val channels: Int,
    val padding: Boolean,
    val crcProtected: Boolean,
) {
    val samplesPerFrame: Int get() = if (mpegVersion == 1) 1152 else 576
    val frameBytes: Int get() =
        (if (mpegVersion == 1) 144 * bitrate / sampleRate else 72 * bitrate / sampleRate) + (if (padding) 1 else 0)

    /** Side-info size (bytes after the 4-byte header, plus CRC). */
    val sideInfoBytes: Int get() =
        (if (mpegVersion == 1) (if (channels == 1) 17 else 32) else (if (channels == 1) 9 else 17)) + (if (crcProtected) 2 else 0)

    companion object {
        private val BR_V1 = intArrayOf(0, 32, 40, 48, 56, 64, 80, 96, 112, 128, 160, 192, 224, 256, 320, 0)
        private val BR_V2 = intArrayOf(0, 8, 16, 24, 32, 40, 48, 56, 64, 80, 96, 112, 128, 144, 160, 0)
        private val SR_V1 = intArrayOf(44100, 48000, 32000, 0)

        fun parse(b0: Int, b1: Int, b2: Int, b3: Int): Mp3Header? {
            val h = ((b0 and 0xFF) shl 24) or ((b1 and 0xFF) shl 16) or ((b2 and 0xFF) shl 8) or (b3 and 0xFF)
            if ((h ushr 21) and 0x7FF != 0x7FF) return null
            val verBits = (h ushr 19) and 3
            val layerBits = (h ushr 17) and 3
            if (verBits == 1 || layerBits != 1) return null // reserved version / not Layer III
            val brIdx = (h ushr 12) and 0xF
            val srIdx = (h ushr 10) and 3
            if (brIdx == 0 || brIdx == 15 || srIdx == 3) return null
            val version = when (verBits) { 3 -> 1; 2 -> 2; else -> 25 }
            val sr = SR_V1[srIdx] / (when (version) { 1 -> 1; 2 -> 2; else -> 4 })
            val br = (if (version == 1) BR_V1[brIdx] else BR_V2[brIdx]) * 1000
            return Mp3Header(version, br, sr, if (((h ushr 6) and 3) == 3) 1 else 2,
                ((h ushr 9) and 1) == 1, ((h ushr 16) and 1) == 0)
        }
    }
}

/** Xing / Info / VBRI (+ LAME extension) metadata from the first frame. */
data class Mp3Tag(
    val kind: String,           // "Xing", "Info" or "VBRI"
    val frameCount: Long?,      // audio frames (the tag frame itself excluded)
    val byteCount: Long?,
    val encoderDelay: Int?,     // LAME tag, samples
    val endPadding: Int?,       // LAME tag, samples
)

/**
 * Synchronous MPEG-1/2 Layer III frame walker for (growing) mp3 files.
 *
 * Provides what the decoder and the stream math need: the first audio frame (ID3v2 and the
 * Xing/Info/VBRI frame skipped), exact frame count + LAME delay when tagged, the 576-sample
 * priming rule for untagged LAME files, frame index <-> sample mapping and
 * [playableFrames] for a byte frontier. Single-threaded (owned by the decoder thread).
 *
 * Sample mapping: output sample `s` of the file lives at decoder-timeline `s + startSkip`, where
 * `startSkip = encoderDelay + 529` (529 = MPEG decoder delay), and `encoderDelay` is the LAME
 * header value, else 576 for untagged files (iOS: untagged stems decode 576 late vs tagged mixes).
 */
class Mp3FrameReader(private val src: ByteSource) {
    var header: Mp3Header? = null; private set
    var tag: Mp3Tag? = null; private set
    var audioStart: Long = 0; private set
    val isOpen: Boolean get() = header != null

    val sampleRate: Int get() = header?.sampleRate ?: 0
    val channels: Int get() = header?.channels ?: 0
    val samplesPerFrame: Int get() = header?.samplesPerFrame ?: 1152
    val encoderDelay: Int get() = tag?.encoderDelay ?: UNTAGGED_PRIMING
    val startSkip: Int get() = encoderDelay + DECODER_DELAY

    private var offsets = LongArray(1024)
    private var walked = 0
    private var walkPos = 0L
    private val hdr = ByteArray(4)
    private val probe = ByteArray(1024)

    /** Parse the head of the file. False when not enough bytes have arrived yet (retry later). */
    fun open(): Boolean {
        if (isOpen) return true
        var p = 0L
        if (read(0, 10) == 10 && probe[0] == 'I'.code.toByte() && probe[1] == 'D'.code.toByte() && probe[2] == '3'.code.toByte()) {
            val size = ((probe[6].toInt() and 0x7F) shl 21) or ((probe[7].toInt() and 0x7F) shl 14) or
                ((probe[8].toInt() and 0x7F) shl 7) or (probe[9].toInt() and 0x7F)
            p = 10L + size + (if ((probe[5].toInt() and 0x10) != 0) 10 else 0)
        }
        val limit = p + SYNC_SEARCH
        while (p < limit) {
            if (read(p, 4) < 4) return false
            val h = Mp3Header.parse(probe[0].toInt(), probe[1].toInt(), probe[2].toInt(), probe[3].toInt())
            if (h != null && confirms(p, h)) {
                header = h
                val t = parseTag(p, h)
                tag = t
                audioStart = if (t != null) p + h.frameBytes else p
                walkPos = audioStart
                return true
            }
            p++
        }
        return false
    }

    private fun confirms(p: Long, h: Mp3Header): Boolean {
        val next = p + h.frameBytes
        if (src.length < next + 4) return src.length >= p + h.frameBytes // not enough to verify: accept a full frame
        if (read(next, 4) < 4) return false
        val n = Mp3Header.parse(probe[0].toInt(), probe[1].toInt(), probe[2].toInt(), probe[3].toInt())
        return n != null && n.sampleRate == h.sampleRate && n.mpegVersion == h.mpegVersion
    }

    private fun parseTag(p: Long, h: Mp3Header): Mp3Tag? {
        val n = minOf(h.frameBytes, probe.size)
        if (read(p, n) < n) return null
        fun s(off: Int, str: String) = off + str.length <= n && String(probe, off, str.length, Charsets.ISO_8859_1) == str
        fun u32(off: Int): Long = ((probe[off].toLong() and 0xFF) shl 24) or ((probe[off + 1].toLong() and 0xFF) shl 16) or
            ((probe[off + 2].toLong() and 0xFF) shl 8) or (probe[off + 3].toLong() and 0xFF)
        val vbri = 4 + 32
        if (s(vbri, "VBRI")) return Mp3Tag("VBRI", u32(vbri + 14), u32(vbri + 10), null, null)
        val x = 4 + h.sideInfoBytes
        val kind = when { s(x, "Xing") -> "Xing"; s(x, "Info") -> "Info"; else -> return null }
        val flags = u32(x + 4).toInt()
        var o = x + 8
        var frames: Long? = null; var bytes: Long? = null
        if (flags and 1 != 0) { frames = u32(o); o += 4 }
        if (flags and 2 != 0) { bytes = u32(o); o += 4 }
        if (flags and 4 != 0) o += 100
        if (flags and 8 != 0) o += 4
        var delay: Int? = null; var pad: Int? = null
        // LAME extension: 9-byte encoder id, then delay/padding as 2x12 bits at +21
        if (o + 24 <= n && (s(o, "LAME") || s(o, "Lavf") || s(o, "Lavc") || s(o, "GOGO"))) {
            val b0 = probe[o + 21].toInt() and 0xFF; val b1 = probe[o + 22].toInt() and 0xFF; val b2 = probe[o + 23].toInt() and 0xFF
            delay = (b0 shl 4) or (b1 ushr 4)
            pad = ((b1 and 0xF) shl 8) or b2
        }
        return Mp3Tag(kind, frames, bytes, delay, pad)
    }

    /**
     * Exact playable length in samples: tagged => from the frame count (so a truncated copy
     * still reports the FULL length, like AVAudioFile); untagged => only known once the file
     * is [complete] (walks to the end), else -1.
     */
    fun totalFrames(complete: Boolean): Long {
        val h = header ?: return -1
        val t = tag
        val count = t?.frameCount
        if (count != null) {
            val endPad = maxOf(0, (t.endPadding ?: 0) - DECODER_DELAY)
            return maxOf(0L, count * h.samplesPerFrame - startSkip - endPad)
        }
        if (!complete) return -1
        val present = presentFrames(src.length)
        return maxOf(0L, present * h.samplesPerFrame - startSkip)
    }

    /**
     * Length estimate for an UNTAGGED partial file from the full download size (CBR): audio bytes / frame
     * bytes * samplesPerFrame. -1 when unknown. (iOS AVAudioFile estimates a partial CBR file the same way.)
     */
    fun estimateTotalFrames(expectedBytes: Long?): Long {
        val h = header ?: return -1
        val total = expectedBytes ?: return -1
        val audioBytes = total - audioStart
        if (audioBytes <= 0 || h.frameBytes <= 0) return -1
        return maxOf(0L, audioBytes / h.frameBytes * h.samplesPerFrame - startSkip)
    }

    /** Audio frames fully contained in the first [bytes] bytes of the file. */
    fun presentFrames(bytes: Long): Long {
        val h = header ?: return 0
        val limit = minOf(bytes, src.length)
        while (true) {
            if (walkPos + 4 > limit) break
            if (read(walkPos, 4) < 4) break
            val fh = Mp3Header.parse(probe[0].toInt(), probe[1].toInt(), probe[2].toInt(), probe[3].toInt())
            if (fh == null || fh.sampleRate != h.sampleRate) {
                // resync (padding / trailing tag): scan a bounded window, else stop
                var found = false
                var q = walkPos + 1
                val scanEnd = minOf(limit - 4, walkPos + RESYNC_SEARCH)
                while (q <= scanEnd) {
                    if (read(q, 4) == 4) {
                        val c = Mp3Header.parse(probe[0].toInt(), probe[1].toInt(), probe[2].toInt(), probe[3].toInt())
                        if (c != null && c.sampleRate == h.sampleRate) { walkPos = q; found = true; break }
                    }
                    q++
                }
                if (!found) break
                continue
            }
            if (walkPos + fh.frameBytes > limit) break
            if (walked == offsets.size) offsets = offsets.copyOf(walked * 2)
            offsets[walked++] = walkPos
            walkPos += fh.frameBytes
        }
        return walked.toLong()
    }

    /** Sample frames safe to schedule with [bytesFrontier] bytes downloaded (torn-frame margin applied). */
    fun playableFrames(bytesFrontier: Long, marginSeconds: Double = STREAM_MARGIN_SECONDS, complete: Boolean = false): Long {
        val h = header ?: return 0
        val total = totalFrames(complete)
        val present = presentFrames(bytesFrontier)
        val raw = present * h.samplesPerFrame - startSkip
        if (complete && total >= 0 && bytesFrontier >= src.length) return total
        val playable = maxOf(0L, raw - (marginSeconds * h.sampleRate).toLong())
        return if (total >= 0) minOf(playable, total) else playable
    }

    /** Frame index holding output sample [sample]. */
    fun frameIndexForSample(sample: Long): Long = (sample + startSkip) / samplesPerFrame

    /** Output-sample of the first sample decoded from frame [index] (can be negative: priming). */
    fun sampleForFrameIndex(index: Long): Long = index * samplesPerFrame - startSkip

    /** Byte offset of audio frame [index] (walks as far as present bytes allow); -1 if not present. */
    fun frameOffset(index: Long): Long {
        if (index >= walked) presentFrames(src.length)
        return if (index in 0 until walked) offsets[index.toInt()] else -1
    }

    /** Copy frame [index] into [dst]; returns its byte length or -1 if not fully present. */
    fun readFrame(index: Long, dst: ByteArray): Int {
        val off = frameOffset(index)
        if (off < 0) return -1
        if (read(off, 4) < 4) return -1
        val fh = Mp3Header.parse(probe[0].toInt(), probe[1].toInt(), probe[2].toInt(), probe[3].toInt()) ?: return -1
        val n = fh.frameBytes
        if (n > dst.size) return -1
        var got = 0
        while (got < n) {
            val r = src.read(off + got, dst, got, n - got)
            if (r <= 0) return -1
            got += r
        }
        return n
    }

    private fun read(pos: Long, len: Int): Int {
        var got = 0
        while (got < len) {
            val r = src.read(pos + got, probe, got, len - got)
            if (r <= 0) break
            got += r
        }
        return got
    }

    companion object {
        const val DECODER_DELAY = 529
        const val UNTAGGED_PRIMING = 576
        const val STREAM_MARGIN_SECONDS = 1.5 // == MixMath.STREAM_FRONTIER_MARGIN
        private const val SYNC_SEARCH = 65_536
        private const val RESYNC_SEARCH = 4096
        const val MAX_FRAME_BYTES = 1441
    }
}

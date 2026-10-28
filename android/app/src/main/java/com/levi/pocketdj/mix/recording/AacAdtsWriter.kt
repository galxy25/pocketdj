package com.levi.pocketdj.mix.recording

import android.media.MediaCodec
import android.media.MediaCodecInfo
import android.media.MediaFormat
import com.levi.pocketdj.audio.core.AacEncoder
import java.io.File
import java.io.FileOutputStream
import java.util.concurrent.atomic.AtomicBoolean

/** What [MixRecorder] needs from a take writer (a fake in JVM tests). */
interface TakeWriter {
    /** Seconds of media actually handed to the encoder (the content clock). */
    val appendedSeconds: Double
    /** Fired at most once, from the writer thread, when the writer dies permanently. */
    var onWriterFailure: (() -> Unit)?
    val failed: Boolean
    fun start()
    /** Drain what is queued, finalize, close. Idempotent. */
    fun stop()
}

/**
 * Streams the house tap into a raw ADTS AAC-LC file on its own thread. Every encoded frame is
 * written with its 7-byte header and flushed, so a kill mid-take leaves a file that decodes up to
 * the last whole frame (no moov box to lose). Failure (disk full, folder gone, codec error) latches
 * [failed], fires [onWriterFailure] exactly once, and stops the thread.
 */
class AacAdtsWriter(
    private val file: File,
    private val tap: RecordingTapSink,
    private val sampleRate: Int = 44_100,
    private val bitrate: Int = 128_000,
) : TakeWriter {
    override var onWriterFailure: (() -> Unit)? = null
    @Volatile override var failed = false; private set
    @Volatile private var framesAppended = 0L
    override val appendedSeconds: Double get() = framesAppended.toDouble() / sampleRate

    private val stopRequested = AtomicBoolean(false)
    private val failureFired = AtomicBoolean(false)
    private var thread: Thread? = null

    private var codec: MediaCodec? = null
    private var out: FileOutputStream? = null

    /** Opens the file and starts the encoder synchronously; throws on any failure (nothing is left open). */
    override fun start() {
        try {
            out = FileOutputStream(file)
            val fmt = MediaFormat.createAudioFormat(MediaFormat.MIMETYPE_AUDIO_AAC, sampleRate, tap.channels).apply {
                setInteger(MediaFormat.KEY_AAC_PROFILE, MediaCodecInfo.CodecProfileLevel.AACObjectLC)
                setInteger(MediaFormat.KEY_BIT_RATE, bitrate)
                setInteger(MediaFormat.KEY_MAX_INPUT_SIZE, 65_536)
            }
            val c = MediaCodec.createEncoderByType(MediaFormat.MIMETYPE_AUDIO_AAC)
            codec = c
            c.configure(fmt, null, null, MediaCodec.CONFIGURE_FLAG_ENCODE)
            c.start()
        } catch (e: Throwable) {
            runCatching { codec?.release() }; runCatching { out?.close() }
            codec = null; out = null
            throw e
        }
        val t = Thread({ run() }, "pdj-mix-aac")
        thread = t
        t.start()
    }

    override fun stop() {
        stopRequested.set(true)
        thread?.let { runCatching { it.join(5_000) } }
        thread = null
    }

    private fun fail() {
        failed = true
        if (failureFired.compareAndSet(false, true)) onWriterFailure?.invoke()
    }

    private fun run() {
        val c = codec ?: return
        val out = out ?: return
        try {
            val info = MediaCodec.BufferInfo()
            val scratch = FloatArray(8192)
            var inEos = false
            var outEos = false
            var inFrames = 0L
            while (!outEos) {
                if (!inEos) {
                    val ii = c.dequeueInputBuffer(5_000)
                    if (ii >= 0) {
                        val buf = c.getInputBuffer(ii)!!
                        buf.clear()
                        val maxFloats = minOf(scratch.size, buf.capacity() / 2)
                        val got = tap.drain(scratch, maxFloats)
                        val ts = inFrames * 1_000_000L / sampleRate
                        if (got <= 0) {
                            if (stopRequested.get()) {
                                c.queueInputBuffer(ii, 0, 0, ts, MediaCodec.BUFFER_FLAG_END_OF_STREAM); inEos = true
                            } else {
                                c.queueInputBuffer(ii, 0, 0, ts, 0)
                                try { Thread.sleep(10) } catch (_: InterruptedException) {}
                            }
                        } else {
                            val bytes = toPcm16(scratch, got)
                            buf.put(bytes)
                            c.queueInputBuffer(ii, 0, bytes.size, ts, 0)
                            val f = got / tap.channels
                            inFrames += f
                            framesAppended = inFrames
                        }
                    }
                }
                val oi = c.dequeueOutputBuffer(info, 5_000)
                if (oi >= 0) {
                    val data = c.getOutputBuffer(oi)!!
                    val config = info.flags and MediaCodec.BUFFER_FLAG_CODEC_CONFIG != 0
                    if (info.size > 0 && !config) {
                        data.position(info.offset).limit(info.offset + info.size)
                        val raw = ByteArray(info.size); data.get(raw)
                        out.write(AacEncoder.adtsHeader(raw.size, sampleRate, tap.channels))
                        out.write(raw)
                        out.flush()
                    }
                    c.releaseOutputBuffer(oi, false)
                    if (info.flags and MediaCodec.BUFFER_FLAG_END_OF_STREAM != 0) outEos = true
                }
            }
        } catch (_: Throwable) {
            fail()
        } finally {
            runCatching { c.stop() }; runCatching { c.release() }
            runCatching { out.close() }
        }
    }

    /** Linear below 0.9, then a tanh knee into +-1: two hot decks round off instead of hard-clipping. */
    private fun softClip(x: Float): Float {
        val a = kotlin.math.abs(x)
        if (a <= 0.9f) return x
        val y = 0.9f + 0.1f * kotlin.math.tanh((a - 0.9f) / 0.1f)
        return if (x < 0) -y else y
    }

    private fun toPcm16(src: FloatArray, n: Int): ByteArray {
        val b = ByteArray(n * 2)
        for (i in 0 until n) {
            val s = (softClip(src[i]) * 32767f).toInt()
            b[i * 2] = (s and 0xFF).toByte()
            b[i * 2 + 1] = ((s shr 8) and 0xFF).toByte()
        }
        return b
    }
}

/** Pure ADTS stream inspection (orphan recovery duration without a decoder). */
object AdtsScan {
    private val RATES = intArrayOf(96000, 88200, 64000, 48000, 44100, 32000, 24000, 22050, 16000, 12000, 11025, 8000, 7350)
    const val SAMPLES_PER_FRAME = 1024

    /** Whole frames and the sample rate of the first frame; frames=0 for an unreadable/empty stream. */
    data class Result(val frames: Int, val sampleRate: Int) {
        val durationMs: Int get() = if (sampleRate > 0) (frames.toLong() * SAMPLES_PER_FRAME * 1000 / sampleRate).toInt() else 0
    }

    /** Streams the file (never loads it whole): read each 7-byte header, then skip the frame body. */
    fun scan(file: File): Result = try {
        java.io.RandomAccessFile(file, "r").use { raf ->
            val total = raf.length()
            val hdr = ByteArray(7)
            var pos = 0L; var frames = 0; var rate = 0
            while (pos + 7 <= total) {
                raf.seek(pos); raf.readFully(hdr)
                val len = frameLength(hdr) ?: break
                if (pos + len > total) break
                if (frames == 0) rate = RATES[(hdr[2].toInt() shr 2) and 0xF]
                frames++; pos += len
            }
            Result(frames, rate)
        }
    } catch (_: Throwable) { Result(0, 0) }

    private fun frameLength(b: ByteArray): Int? {
        val b0 = b[0].toInt() and 0xFF; val b1 = b[1].toInt() and 0xFF
        if (b0 != 0xFF || (b1 and 0xF0) != 0xF0) return null
        val idx = (b[2].toInt() shr 2) and 0xF
        val len = ((b[3].toInt() and 3) shl 11) or ((b[4].toInt() and 0xFF) shl 3) or ((b[5].toInt() and 0xFF) shr 5)
        return if (len < 7 || idx >= RATES.size) null else len
    }

    fun scan(bytes: ByteArray): Result {
        var pos = 0; var frames = 0; var rate = 0
        while (pos + 7 <= bytes.size) {
            val b0 = bytes[pos].toInt() and 0xFF; val b1 = bytes[pos + 1].toInt() and 0xFF
            if (b0 != 0xFF || (b1 and 0xF0) != 0xF0) break
            val idx = (bytes[pos + 2].toInt() shr 2) and 0xF
            val len = ((bytes[pos + 3].toInt() and 3) shl 11) or ((bytes[pos + 4].toInt() and 0xFF) shl 3) or
                ((bytes[pos + 5].toInt() and 0xFF) shr 5)
            if (len < 7 || idx >= RATES.size || pos + len > bytes.size) break // truncated tail frame is ignored
            if (frames == 0) rate = RATES[idx]
            frames++; pos += len
        }
        return Result(frames, rate)
    }
}

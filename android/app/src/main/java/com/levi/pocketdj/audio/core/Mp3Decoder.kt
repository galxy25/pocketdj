package com.levi.pocketdj.audio.core

import android.media.MediaCodec
import android.media.MediaFormat
import java.io.File

/**
 * MediaCodec (`audio/mpeg`, synchronous mode) mp3 decoder over a growing file, as a [PcmSource].
 *
 * Raw frames come from [Mp3FrameReader] (so a partial file is fine: only frames fully present
 * are fed). Seek = flush, restart [WARMUP_FRAMES] earlier (bit reservoir), then decode-and-discard
 * `sample + startSkip - startFrame * samplesPerFrame` samples. Output is canonical float; the
 * channel count follows the file (mono files are upmixed by the Voice).
 *
 * Device-verified only (instrumented test); the frame/skip math it relies on is JVM-tested in
 * [Mp3FrameReader].
 */
class Mp3Decoder(
    private val bytes: ByteSource,
    private var complete: Boolean = true,
) : PcmSource {
    constructor(file: File, complete: Boolean = true) : this(FileByteSource(file), complete)

    private val reader = Mp3FrameReader(bytes)
    private var codec: MediaCodec? = null
    private val info by lazy { MediaCodec.BufferInfo() }
    private val frameBuf = ByteArray(Mp3FrameReader.MAX_FRAME_BYTES + 16)

    private var nextFrame = 0L
    private var discard = 0L
    private var position = 0L
    private var inputEos = false
    private var outputEos = false
    private var pcm = FloatArray(0)
    private var byteScratch = ByteArray(0)
    private var pcmPos = 0
    private var pcmLen = 0 // floats
    private var outChannels = 2
    private var outRate = 44_100
    private var pendingSeek: Long = 0

    // Parse the header on demand: a Voice reads these exactly once at construction to decide
    // whether to wrap us in a ConvertedSource, so they must be the FILE's values, not defaults.
    override val sampleRate: Int get() = if (ensureOpen()) reader.sampleRate else outRate
    // The layout [read] hands out is ALWAYS reader.channels (fill() remaps the codec's layout).
    override val channels: Int get() = if (ensureOpen()) reader.channels else outChannels
    override val isComplete: Boolean get() = complete
    override val totalFrames: Long get() = if (ensureOpen()) reader.totalFrames(complete) else -1
    override val availableFrames: Long get() = if (ensureOpen()) reader.playableFrames(bytes.length, complete = complete) else 0

    /** The writer finished appending: the frontier is now the whole file. */
    fun markComplete() { complete = true }

    private fun ensureOpen(): Boolean = reader.open()

    private fun startCodec() {
        val h = reader.header ?: return
        val fmt = MediaFormat.createAudioFormat(MediaFormat.MIMETYPE_AUDIO_MPEG, h.sampleRate, h.channels)
        val c = MediaCodec.createDecoderByType(MediaFormat.MIMETYPE_AUDIO_MPEG)
        c.configure(fmt, null, null, 0)
        c.start()
        codec = c
        outRate = h.sampleRate; outChannels = h.channels
    }

    override fun seek(frame: Long) {
        pendingSeek = frame.coerceAtLeast(0)
        position = pendingSeek
        applySeek()
    }

    private fun applySeek() {
        if (!ensureOpen()) return
        if (codec == null) startCodec() else codec?.flush()
        val target = reader.frameIndexForSample(position)
        val first = maxOf(0L, target - WARMUP_FRAMES)
        nextFrame = first
        discard = discardFor(position, reader.encoderDelay, first, reader.samplesPerFrame)
        inputEos = false; outputEos = false; pcmPos = 0; pcmLen = 0
    }

    override fun read(dst: FloatArray, frames: Int): Int {
        if (!ensureOpen()) return 0
        if (codec == null) applySeek()
        val ch = channels
        var produced = 0
        while (produced < frames) {
            if (pcmPos >= pcmLen) {
                val r = fill()
                if (r < 0) return if (produced == 0) -1 else produced
                if (r == 0) break
            }
            var availFrames = (pcmLen - pcmPos) / ch
            if (discard > 0) {
                val d = minOf(discard, availFrames.toLong()).toInt()
                pcmPos += d * ch; discard -= d; availFrames -= d
                continue
            }
            val total = totalFrames
            if (total in 0..position) return if (produced == 0) -1 else produced
            val n = minOf(frames - produced, availFrames, if (total >= 0) (total - position).toInt() else Int.MAX_VALUE)
            System.arraycopy(pcm, pcmPos, dst, produced * ch, n * ch)
            pcmPos += n * ch; produced += n; position += n
        }
        return produced
    }

    /** Decode one more output buffer into [pcm]; 1 = got data, 0 = nothing available now, -1 = end. */
    private fun fill(): Int {
        val c = codec ?: return 0
        var idle = 0
        while (true) {
            val oi = c.dequeueOutputBuffer(info, 0)
            when {
                oi >= 0 -> {
                    val out = c.getOutputBuffer(oi)!!
                    var n = info.size / 2
                    if (pcm.size < n) pcm = FloatArray(n)
                    if (byteScratch.size < info.size) byteScratch = ByteArray(info.size)
                    out.position(info.offset); out.get(byteScratch, 0, info.size)
                    PcmBuffer.fromPcm16(byteScratch, info.size, pcm, 0)
                    n = remap(n)
                    pcmPos = 0; pcmLen = n
                    val eos = info.flags and MediaCodec.BUFFER_FLAG_END_OF_STREAM != 0
                    c.releaseOutputBuffer(oi, false)
                    if (eos) outputEos = true
                    if (n > 0) return 1
                    if (eos) return -1
                }
                oi == MediaCodec.INFO_OUTPUT_FORMAT_CHANGED -> {
                    val f = c.outputFormat
                    outChannels = f.getInteger(MediaFormat.KEY_CHANNEL_COUNT)
                    outRate = f.getInteger(MediaFormat.KEY_SAMPLE_RATE)
                }
                else -> {
                    if (outputEos) return -1
                    if (!feed(c)) { if (++idle > 1) return 0 } else idle = 0
                }
            }
        }
    }

    /** Convert [n] floats in [pcm] from the codec's channel layout to the file's; returns the new float count. */
    private fun remap(n: Int): Int {
        val tgt = reader.channels
        val src = outChannels
        if (src == tgt || src < 1) return n
        val frames = n / src
        val need = frames * tgt
        if (tgt == 1) {
            for (i in 0 until frames) {
                var a = 0f
                for (c in 0 until src) a += pcm[i * src + c]
                pcm[i] = a / src
            }
        } else {
            if (pcm.size < need) pcm = pcm.copyOf(need)
            for (i in frames - 1 downTo 0) for (c in tgt - 1 downTo 0) pcm[i * tgt + c] = pcm[i * src + minOf(c, src - 1)]
        }
        return need
    }

    /** Queue one frame (or EOS). False when nothing could be queued. */
    private fun feed(c: MediaCodec): Boolean {
        if (inputEos) return false
        val ii = c.dequeueInputBuffer(2_000)
        if (ii < 0) return false
        val n = reader.readFrame(nextFrame, frameBuf)
        if (n < 0) {
            if (complete) {
                c.queueInputBuffer(ii, 0, 0, 0, MediaCodec.BUFFER_FLAG_END_OF_STREAM)
                inputEos = true
                return true
            }
            c.queueInputBuffer(ii, 0, 0, 0, 0) // nothing yet (growing file)
            return false
        }
        val buf = c.getInputBuffer(ii)!!
        buf.clear(); buf.put(frameBuf, 0, n)
        c.queueInputBuffer(ii, 0, n, nextFrame * 26_122L, 0)
        nextFrame++
        return true
    }

    override fun close() {
        runCatching { codec?.stop() }
        runCatching { codec?.release() }
        codec = null
        bytes.close()
    }

    companion object {
        // 12 frames: the emulator's software MP3 decoder emits ~8 frames (8825 samples) of silence after
        // every start/flush, so a short warm-up leaves a gap after a seek (found by the wave-3 instrumented run).
        private const val WARMUP_FRAMES = 12L

        /**
         * Android's MP3 codecs (C2SoftMp3Dec / SoftMP3) already drop the 529-sample decoder delay
         * from the first output after start AND after every flush, so only the encoder delay (plus
         * the intra-frame offset) is left to discard. Flip if a device codec is found to keep it.
         */
        const val CODEC_TRIMS_DECODER_DELAY = true

        /** Samples to drop from the codec output after (re)starting at frame [firstFrame] to land on file sample [position]. */
        internal fun discardFor(position: Long, encoderDelay: Int, firstFrame: Long, samplesPerFrame: Int): Long {
            val skip = encoderDelay + if (CODEC_TRIMS_DECODER_DELAY) 0 else Mp3FrameReader.DECODER_DELAY
            return maxOf(0L, position + skip - firstFrame * samplesPerFrame)
        }
    }
}

package com.levi.pocketdj.audio.core

import android.media.MediaCodec
import android.media.MediaCodecInfo
import android.media.MediaFormat
import android.media.MediaMuxer
import java.io.File
import java.io.FileOutputStream

/** Sink for interleaved float PCM produced block by block (a streaming encoder, or a test double). [close] finalizes. */
interface PcmChunkWriter {
    /** [frames] interleaved frames from the start of [samples]; the array may be reused by the caller afterwards. */
    fun write(samples: FloatArray, frames: Int)
    fun close()
}

/** MediaCodec AAC-LC encoder: `.m4a` (MediaMuxer) or raw ADTS stream. */
object AacEncoder {
    enum class Container { M4A, ADTS }

    /** 7-byte ADTS header for an AAC-LC frame with [payloadBytes] of raw AAC. */
    fun adtsHeader(payloadBytes: Int, sampleRate: Int, channels: Int): ByteArray {
        val freqIdx = ADTS_RATES.indexOf(sampleRate).also { require(it >= 0) { "unsupported rate $sampleRate" } }
        val len = payloadBytes + 7
        val h = ByteArray(7)
        h[0] = 0xFF.toByte()
        h[1] = 0xF1.toByte() // MPEG-4, layer 0, no CRC
        h[2] = ((1 shl 6) or (freqIdx shl 2) or (channels shr 2)).toByte() // profile = AAC-LC (object type 2 - 1)
        h[3] = (((channels and 3) shl 6) or (len shr 11)).toByte()
        h[4] = ((len shr 3) and 0xFF).toByte()
        h[5] = (((len and 7) shl 5) or 0x1F).toByte()
        h[6] = 0xFC.toByte()
        return h
    }

    /** One-shot encode of an in-memory buffer (delegates to the streaming [Stream]). */
    fun encode(pcm: PcmBuffer, out: File, container: Container = Container.M4A, bitrate: Int = 128_000) {
        val s = Stream(out, pcm.sampleRate, pcm.channels, container, bitrate)
        try {
            var pos = 0
            while (pos < pcm.frames) {
                val n = minOf(WRITE_CHUNK_FRAMES, pcm.frames - pos)
                s.write(if (pos == 0 && n == pcm.frames) pcm.samples else pcm.samples.copyOfRange(pos * pcm.channels, (pos + n) * pcm.channels), n)
                pos += n
            }
            s.close()
        } catch (t: Throwable) { s.abort(); throw t }
    }

    /** Frames handed to the encoder per [encode] write (bounds transient arrays). */
    const val WRITE_CHUNK_FRAMES = 16_384

    /**
     * Streaming MediaCodec AAC-LC encoder: [write] interleaved blocks as they are produced, [close] flushes EOS and
     * finalizes the container. Never holds more than one codec input buffer of PCM, so encoding a long master is O(1) heap.
     */
    class Stream(
        out: File, private val sampleRate: Int, private val channels: Int,
        container: Container = Container.M4A, bitrate: Int = 128_000,
    ) : PcmChunkWriter {
        private val codec: MediaCodec
        private var muxer: MediaMuxer? = null
        private var track = -1
        private var adts: FileOutputStream? = null
        private val info = MediaCodec.BufferInfo()
        private var framePos = 0L
        private var inEos = false
        private var outEos = false
        private var released = false

        init {
            val fmt = MediaFormat.createAudioFormat(MediaFormat.MIMETYPE_AUDIO_AAC, sampleRate, channels).apply {
                setInteger(MediaFormat.KEY_AAC_PROFILE, MediaCodecInfo.CodecProfileLevel.AACObjectLC)
                setInteger(MediaFormat.KEY_BIT_RATE, bitrate)
                setInteger(MediaFormat.KEY_MAX_INPUT_SIZE, 65_536)
            }
            codec = MediaCodec.createEncoderByType(MediaFormat.MIMETYPE_AUDIO_AAC)
            try {
                codec.configure(fmt, null, null, MediaCodec.CONFIGURE_FLAG_ENCODE)
                codec.start()
                if (container == Container.M4A) muxer = MediaMuxer(out.path, MediaMuxer.OutputFormat.MUXER_OUTPUT_MPEG_4)
                else adts = FileOutputStream(out)
            } catch (t: Throwable) { release(); throw t }
        }

        override fun write(samples: FloatArray, frames: Int) {
            var done = 0
            while (done < frames) {
                val ii = codec.dequeueInputBuffer(if (drain(0)) 0 else 5_000)
                if (ii < 0) continue
                val buf = codec.getInputBuffer(ii)!!
                buf.clear()
                val n = minOf(buf.capacity() / (2 * channels), frames - done)
                val bytes = WavWriter.samplesToBytes(samples, done * channels, n * channels, WavWriter.Format.PCM16)
                buf.put(bytes)
                codec.queueInputBuffer(ii, 0, bytes.size, framePos * 1_000_000L / sampleRate, 0)
                framePos += n; done += n
            }
            drain(0)
        }

        /** EOS + drain + finalize the container. */
        override fun close() {
            if (released) return
            try {
                while (!inEos) {
                    val ii = codec.dequeueInputBuffer(5_000)
                    if (ii >= 0) { codec.queueInputBuffer(ii, 0, 0, framePos * 1_000_000L / sampleRate, MediaCodec.BUFFER_FLAG_END_OF_STREAM); inEos = true }
                    else drain(0)
                }
                while (!outEos) drain(5_000)
            } finally {
                runCatching { muxer?.stop() }
                release()
            }
        }

        /** Drop the encoder without finalizing (failure path); the caller deletes the partial file. */
        fun abort() = release()

        /** Pull available output; true if anything was consumed (so the caller need not block on input). */
        private fun drain(timeoutUs: Long): Boolean {
            var any = false
            var t = timeoutUs
            while (!outEos) {
                val oi = codec.dequeueOutputBuffer(info, t)
                t = 0
                if (oi == MediaCodec.INFO_OUTPUT_FORMAT_CHANGED) {
                    muxer?.let { track = it.addTrack(codec.outputFormat); it.start() }
                    any = true
                } else if (oi >= 0) {
                    val data = codec.getOutputBuffer(oi)!!
                    val config = info.flags and MediaCodec.BUFFER_FLAG_CODEC_CONFIG != 0
                    if (info.size > 0 && !config) {
                        data.position(info.offset).limit(info.offset + info.size)
                        val m = muxer
                        if (m != null) m.writeSampleData(track, data, info)
                        else {
                            val raw = ByteArray(info.size); data.get(raw)
                            adts!!.write(adtsHeader(raw.size, sampleRate, channels)); adts!!.write(raw)
                        }
                    }
                    codec.releaseOutputBuffer(oi, false)
                    if (info.flags and MediaCodec.BUFFER_FLAG_END_OF_STREAM != 0) outEos = true
                    any = true
                } else break
            }
            return any
        }

        private fun release() {
            if (released) return
            released = true
            runCatching { codec.stop() }; runCatching { codec.release() }
            runCatching { muxer?.release() }; runCatching { adts?.close() }
        }
    }

    private val ADTS_RATES = listOf(96000, 88200, 64000, 48000, 44100, 32000, 24000, 22050, 16000, 12000, 11025, 8000, 7350)
}

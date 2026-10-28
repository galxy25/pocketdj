package com.levi.pocketdj.audio.core

import android.media.MediaCodec
import android.media.MediaExtractor
import android.media.MediaFormat
import java.nio.ByteOrder

/**
 * Generic whole-file decode (MediaExtractor + MediaCodec) to canonical 44.1 kHz stereo Float32
 * for m4a / wav / mp3 — Studio's decoder (sample import, Demux, arranger clips). Mix streaming
 * decks use [Mp3Decoder] instead.
 */
object AudioDecoder {
    /** Decode [path]; [maxSeconds] caps the length (0 = whole file). Returns null if no audio track. */
    fun decode(path: String, rate: Int = PcmBuffer.CANONICAL_RATE, maxSeconds: Double = 0.0): PcmBuffer? {
        val ex = MediaExtractor()
        try {
            ex.setDataSource(path)
            val idx = (0 until ex.trackCount).firstOrNull {
                ex.getTrackFormat(it).getString(MediaFormat.KEY_MIME)?.startsWith("audio/") == true
            } ?: return null
            ex.selectTrack(idx)
            val fmt = ex.getTrackFormat(idx)
            val mime = fmt.getString(MediaFormat.KEY_MIME)!!
            val codec = MediaCodec.createDecoderByType(mime)
            codec.configure(fmt, null, null, 0)
            codec.start()
            try {
                return pump(ex, codec, fmt, rate, maxSeconds)
            } finally {
                runCatching { codec.stop() }; runCatching { codec.release() }
            }
        } finally {
            ex.release()
        }
    }

    private fun pump(ex: MediaExtractor, codec: MediaCodec, fmt: MediaFormat, rate: Int, maxSeconds: Double): PcmBuffer {
        var ch = fmt.getInteger(MediaFormat.KEY_CHANNEL_COUNT)
        var sr = fmt.getInteger(MediaFormat.KEY_SAMPLE_RATE)
        var floatOut = false
        var acc = FloatArray(sr * ch * 4)
        var len = 0
        val info = MediaCodec.BufferInfo()
        var inEos = false
        var outEos = false
        while (!outEos) {
            if (!inEos) {
                val ii = codec.dequeueInputBuffer(5_000)
                if (ii >= 0) {
                    val buf = codec.getInputBuffer(ii)!!
                    val n = ex.readSampleData(buf, 0)
                    if (n < 0) { codec.queueInputBuffer(ii, 0, 0, 0, MediaCodec.BUFFER_FLAG_END_OF_STREAM); inEos = true }
                    else { codec.queueInputBuffer(ii, 0, n, ex.sampleTime, 0); ex.advance() }
                }
            }
            val oi = codec.dequeueOutputBuffer(info, 5_000)
            if (oi >= 0) {
                val out = codec.getOutputBuffer(oi)!!
                out.position(info.offset).limit(info.offset + info.size)
                out.order(ByteOrder.nativeOrder())
                val n = if (floatOut) info.size / 4 else info.size / 2
                if (len + n > acc.size) acc = acc.copyOf(maxOf(acc.size * 2, len + n))
                if (floatOut) out.asFloatBuffer().get(acc, len, n)
                else { val sb = out.asShortBuffer(); for (i in 0 until n) acc[len + i] = sb.get() / 32768f }
                len += n
                codec.releaseOutputBuffer(oi, false)
                if (info.flags and MediaCodec.BUFFER_FLAG_END_OF_STREAM != 0) outEos = true
                if (maxSeconds > 0 && len / ch >= maxSeconds * sr) outEos = true
            } else if (oi == MediaCodec.INFO_OUTPUT_FORMAT_CHANGED) {
                val f = codec.outputFormat
                ch = f.getInteger(MediaFormat.KEY_CHANNEL_COUNT)
                sr = f.getInteger(MediaFormat.KEY_SAMPLE_RATE)
                floatOut = f.containsKey(MediaFormat.KEY_PCM_ENCODING) &&
                    f.getInteger(MediaFormat.KEY_PCM_ENCODING) == android.media.AudioFormat.ENCODING_PCM_FLOAT
            }
        }
        return PcmBuffer(sr, ch, acc.copyOf(len)).toCanonical(rate)
    }
}

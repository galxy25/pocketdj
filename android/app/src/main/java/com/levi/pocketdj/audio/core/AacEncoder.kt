package com.levi.pocketdj.audio.core

import android.media.MediaCodec
import android.media.MediaCodecInfo
import android.media.MediaFormat
import android.media.MediaMuxer
import java.io.File
import java.io.FileOutputStream

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

    fun encode(pcm: PcmBuffer, out: File, container: Container = Container.M4A, bitrate: Int = 128_000) {
        val fmt = MediaFormat.createAudioFormat(MediaFormat.MIMETYPE_AUDIO_AAC, pcm.sampleRate, pcm.channels).apply {
            setInteger(MediaFormat.KEY_AAC_PROFILE, MediaCodecInfo.CodecProfileLevel.AACObjectLC)
            setInteger(MediaFormat.KEY_BIT_RATE, bitrate)
            setInteger(MediaFormat.KEY_MAX_INPUT_SIZE, 65_536)
        }
        val codec = MediaCodec.createEncoderByType(MediaFormat.MIMETYPE_AUDIO_AAC)
        codec.configure(fmt, null, null, MediaCodec.CONFIGURE_FLAG_ENCODE)
        codec.start()
        var muxer: MediaMuxer? = null
        var track = -1
        var adts: FileOutputStream? = null
        if (container == Container.M4A) muxer = MediaMuxer(out.path, MediaMuxer.OutputFormat.MUXER_OUTPUT_MPEG_4)
        else adts = FileOutputStream(out)
        try {
            val info = MediaCodec.BufferInfo()
            var framePos = 0
            var inEos = false
            var outEos = false
            while (!outEos) {
                if (!inEos) {
                    val ii = codec.dequeueInputBuffer(5_000)
                    if (ii >= 0) {
                        val buf = codec.getInputBuffer(ii)!!
                        buf.clear()
                        val capFrames = buf.capacity() / (2 * pcm.channels)
                        val n = minOf(capFrames, pcm.frames - framePos)
                        val ts = framePos * 1_000_000L / pcm.sampleRate
                        if (n <= 0) { codec.queueInputBuffer(ii, 0, 0, ts, MediaCodec.BUFFER_FLAG_END_OF_STREAM); inEos = true }
                        else {
                            val bytes = WavWriter.samplesToBytes(pcm.samples, framePos * pcm.channels, n * pcm.channels, WavWriter.Format.PCM16)
                            buf.put(bytes)
                            codec.queueInputBuffer(ii, 0, bytes.size, ts, 0)
                            framePos += n
                        }
                    }
                }
                val oi = codec.dequeueOutputBuffer(info, 5_000)
                if (oi == MediaCodec.INFO_OUTPUT_FORMAT_CHANGED) {
                    if (muxer != null) { track = muxer.addTrack(codec.outputFormat); muxer.start() }
                } else if (oi >= 0) {
                    val data = codec.getOutputBuffer(oi)!!
                    val config = info.flags and MediaCodec.BUFFER_FLAG_CODEC_CONFIG != 0
                    if (info.size > 0 && !config) {
                        data.position(info.offset).limit(info.offset + info.size)
                        if (muxer != null) muxer.writeSampleData(track, data, info)
                        else {
                            val raw = ByteArray(info.size); data.get(raw)
                            adts!!.write(adtsHeader(raw.size, pcm.sampleRate, pcm.channels)); adts.write(raw)
                        }
                    }
                    codec.releaseOutputBuffer(oi, false)
                    if (info.flags and MediaCodec.BUFFER_FLAG_END_OF_STREAM != 0) outEos = true
                }
            }
        } finally {
            runCatching { codec.stop() }; runCatching { codec.release() }
            runCatching { muxer?.stop() }; runCatching { muxer?.release() }
            runCatching { adts?.close() }
        }
    }

    private val ADTS_RATES = listOf(96000, 88200, 64000, 48000, 44100, 32000, 24000, 22050, 16000, 12000, 11025, 8000, 7350)
}

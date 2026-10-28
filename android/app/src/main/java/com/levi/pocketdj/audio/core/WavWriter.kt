package com.levi.pocketdj.audio.core

import java.io.File
import java.io.RandomAccessFile
import java.nio.ByteBuffer
import java.nio.ByteOrder

/** RIFF/WAVE writer: 16-bit PCM or 32-bit float, one-shot [encode] or [Streaming] (header patched on close). */
object WavWriter {
    enum class Format(val tag: Int, val bits: Int) { PCM16(1, 16), FLOAT32(3, 32) }

    fun header(sampleRate: Int, channels: Int, format: Format, dataBytes: Long): ByteArray {
        val bb = ByteBuffer.allocate(44).order(ByteOrder.LITTLE_ENDIAN)
        val blockAlign = channels * format.bits / 8
        bb.put("RIFF".toByteArray()).putInt((36 + dataBytes).coerceAtMost(0xFFFF_FFFFL).toInt())
        bb.put("WAVE".toByteArray()).put("fmt ".toByteArray()).putInt(16)
        bb.putShort(format.tag.toShort()).putShort(channels.toShort()).putInt(sampleRate)
        bb.putInt(sampleRate * blockAlign).putShort(blockAlign.toShort()).putShort(format.bits.toShort())
        bb.put("data".toByteArray()).putInt(dataBytes.coerceAtMost(0xFFFF_FFFFL).toInt())
        return bb.array()
    }

    fun samplesToBytes(samples: FloatArray, off: Int, n: Int, format: Format): ByteArray {
        val bb = ByteBuffer.allocate(n * format.bits / 8).order(ByteOrder.LITTLE_ENDIAN)
        for (i in off until off + n) {
            val s = samples[i]
            when (format) {
                Format.FLOAT32 -> bb.putFloat(s)
                Format.PCM16 -> bb.putShort(Math.round(s.coerceIn(-1f, 1f) * 32767f).toShort())
            }
        }
        return bb.array()
    }

    fun encode(pcm: PcmBuffer, format: Format = Format.PCM16): ByteArray {
        val data = samplesToBytes(pcm.samples, 0, pcm.samples.size, format)
        return header(pcm.sampleRate, pcm.channels, format, data.size.toLong()) + data
    }

    fun write(file: File, pcm: PcmBuffer, format: Format = Format.PCM16) = file.writeBytes(encode(pcm, format))

    /** Append blocks as they render (recording tap); sizes are patched in [close]. */
    class Streaming(file: File, private val sampleRate: Int, private val channels: Int, private val format: Format = Format.PCM16) {
        private val raf = RandomAccessFile(file, "rw").also { it.setLength(0); it.write(header(sampleRate, channels, format, 0)) }
        var dataBytes = 0L; private set

        fun append(samples: FloatArray, off: Int, n: Int) {
            val b = samplesToBytes(samples, off, n, format)
            raf.write(b); dataBytes += b.size
        }

        fun close() {
            raf.seek(0); raf.write(header(sampleRate, channels, format, dataBytes)); raf.close()
        }
    }

    /** Parsed header for tests / validation; null if not a RIFF WAVE. */
    data class Info(val format: Int, val channels: Int, val sampleRate: Int, val bits: Int, val dataBytes: Long)

    fun parse(bytes: ByteArray): Info? {
        if (bytes.size < 44 || String(bytes, 0, 4) != "RIFF" || String(bytes, 8, 4) != "WAVE") return null
        val bb = ByteBuffer.wrap(bytes).order(ByteOrder.LITTLE_ENDIAN)
        return Info(bb.getShort(20).toInt(), bb.getShort(22).toInt(), bb.getInt(24), bb.getShort(34).toInt(),
            bb.getInt(40).toLong() and 0xFFFF_FFFFL)
    }
}

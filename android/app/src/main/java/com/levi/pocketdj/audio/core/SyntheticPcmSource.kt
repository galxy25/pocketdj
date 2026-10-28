package com.levi.pocketdj.audio.core

import kotlin.math.PI
import kotlin.math.sin

/**
 * Deterministic in-memory source for JVM tests. [available] is the readable frontier (growing
 * file); [forceIncomplete] keeps `isComplete` false even once everything is available.
 */
class SyntheticPcmSource(
    override val sampleRate: Int = 44_100,
    override val channels: Int = 2,
    private val total: Long,
    initialAvailable: Long = total,
    private val generator: (frame: Long, channel: Int) -> Float,
) : PcmSource {
    @Volatile var available: Long = initialAvailable
    @Volatile var forceIncomplete = false
    @Volatile var position = 0L; private set
    @Volatile var seekCount = 0; private set

    override val totalFrames: Long get() = total
    override val availableFrames: Long get() = minOf(available, total)
    override val isComplete: Boolean get() = !forceIncomplete && available >= total

    override fun seek(frame: Long) { position = frame.coerceIn(0, total); seekCount++ }

    override fun read(dst: FloatArray, frames: Int): Int {
        if (position >= total) return -1
        val n = minOf(frames.toLong(), availableFrames - position).toInt()
        if (n <= 0) return 0
        for (i in 0 until n) for (c in 0 until channels) dst[i * channels + c] = generator(position + i, c)
        position += n
        return n
    }

    companion object {
        /** Sample value encodes its own frame index: (frame+1) * 1e-6 (exact enough below ~500k). */
        fun counter(total: Long, available: Long = total, sampleRate: Int = 44_100, channels: Int = 2) =
            SyntheticPcmSource(sampleRate, channels, total, available) { f, _ -> (f + 1) * 1e-6f }

        /** Decode the counter back to a frame index. */
        fun frameOf(sample: Float): Long = Math.round(sample / 1e-6f).toLong() - 1

        fun tone(freq: Double, total: Long, sampleRate: Int = 44_100, amp: Float = 0.5f) =
            SyntheticPcmSource(sampleRate, 2, total) { f, _ -> (amp * sin(2 * PI * freq * f / sampleRate)).toFloat() }

        /** Silence with a single full-scale click on every frame in [clicks]. */
        fun clicks(total: Long, clicks: Set<Long>) =
            SyntheticPcmSource(44_100, 2, total) { f, _ -> if (f in clicks) 1f else 0f }
    }
}

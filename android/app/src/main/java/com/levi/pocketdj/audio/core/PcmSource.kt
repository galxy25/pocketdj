package com.levi.pocketdj.audio.core

/**
 * A seekable, possibly GROWING stream of PCM frames (file frames, i.e. after priming/delay
 * trimming). Called from ONE decoder thread; never from the render thread.
 */
interface PcmSource {
    val sampleRate: Int
    val channels: Int

    /** Total playable frames, or -1 when not yet known (headerless growing file). */
    val totalFrames: Long

    /** True once no more bytes will arrive (file complete). */
    val isComplete: Boolean

    /** Frames that can be read right now without waiting (growing-file frontier). */
    val availableFrames: Long

    fun seek(frame: Long)

    /**
     * Read up to [frames] interleaved frames into [dst]. Returns frames read; 0 when nothing is
     * available YET (growing); -1 at the true end.
     */
    fun read(dst: FloatArray, frames: Int): Int

    fun close() {}
}

/**
 * Adapts any source to the Voice's canonical shape: stereo at [targetRate]. Mono is upmixed by
 * duplication; a rate mismatch is bridged by linear interpolation (fallback only: decoders should
 * already deliver the sink rate).
 */
class ConvertedSource(private val src: PcmSource, override val sampleRate: Int) : PcmSource {
    override val channels: Int = 2
    private val ch = src.channels
    private val ratio = src.sampleRate.toDouble() / sampleRate
    override val totalFrames: Long get() = src.totalFrames.let { if (it < 0) it else (it / ratio).toLong() }
    override val isComplete: Boolean get() = src.isComplete
    override val availableFrames: Long get() = (src.availableFrames / ratio).toLong()

    private val inBuf = FloatArray(IN_FRAMES * ch)
    private var inCount = 0
    private var inIndex = 0
    private var frac = 0.0
    private var srcEnded = false
    private val direct = src.sampleRate == sampleRate

    override fun seek(frame: Long) {
        src.seek(Math.round(frame * ratio))
        inCount = 0; inIndex = 0; frac = 0.0; srcEnded = false
    }

    override fun read(dst: FloatArray, frames: Int): Int {
        var produced = 0
        while (produced < frames) {
            if (inIndex + (if (direct) 0 else 1) >= inCount) {
                // keep the not-yet-consumed tail frame (needed as the lerp's left sample)
                if (!direct && inCount > 0 && inIndex < inCount) {
                    System.arraycopy(inBuf, inIndex * ch, inBuf, 0, ch)
                    inCount = 1
                } else inCount = 0
                inIndex = 0
                if (srcEnded) return if (produced == 0) -1 else produced // EOF is sticky: every later call is -1 too
                val want = IN_FRAMES - inCount
                val tmp = if (inCount == 0) inBuf else scratch(want)
                val r = src.read(tmp, want)
                if (r < 0) { srcEnded = true; continue }
                if (r == 0) break
                if (tmp !== inBuf) System.arraycopy(tmp, 0, inBuf, inCount * ch, r * ch)
                inCount += r
                if (!direct && inCount < 2) continue
            }
            if (direct) {
                put(dst, produced, inBuf, inIndex, inBuf, inIndex, 0f)
                inIndex++
            } else {
                put(dst, produced, inBuf, inIndex, inBuf, inIndex + 1, frac.toFloat())
                frac += ratio
                while (frac >= 1.0) { frac -= 1.0; inIndex++ }
            }
            produced++
        }
        return produced
    }

    private var scratchBuf = FloatArray(0)
    private fun scratch(frames: Int): FloatArray {
        if (scratchBuf.size < frames * ch) scratchBuf = FloatArray(frames * ch)
        return scratchBuf
    }

    private fun put(dst: FloatArray, outFrame: Int, a: FloatArray, ai: Int, b: FloatArray, bi: Int, f: Float) {
        val l0 = a[ai * ch]; val l1 = b[bi * ch]
        val r0 = if (ch > 1) a[ai * ch + 1] else l0
        val r1 = if (ch > 1) b[bi * ch + 1] else l1
        dst[outFrame * 2] = l0 + (l1 - l0) * f
        dst[outFrame * 2 + 1] = r0 + (r1 - r0) * f
    }

    override fun close() = src.close()

    private companion object { const val IN_FRAMES = 2048 }
}

package com.levi.pocketdj.audio.core

/**
 * Chunked twin of [PcmBuffer.resampled] (linear). Carries the last few input frames across [process] calls so that
 * feeding a stream in ANY chunking and then calling [finish] yields the exact same output frames as the one-shot
 * resample (same double position math, same end clamp, same `ceil(frames * rate / sampleRate)` length).
 * Memory is O(chunk): a bake never holds the whole capture.
 *
 * [sink] receives interleaved output blocks; the array is REUSED, so consume (copy/encode) before returning.
 */
class StreamingResampler(private val inRate: Int, private val outRate: Int, private val channels: Int = 2) {
    private val passthrough = inRate == outRate
    private val ratio = inRate.toDouble() / outRate
    private var carry = FloatArray(0)      // retained input frames (interleaved), starting at absolute frame [carryBase]
    private var carryBase = 0L
    private var totalIn = 0L
    private var nextOut = 0L
    private var out = FloatArray(OUT_FRAMES * channels)
    private var finished = false

    /** Total frames emitted so far. */
    val framesOut: Long get() = if (passthrough) totalIn else nextOut

    fun process(input: FloatArray, inFrames: Int, sink: (FloatArray, Int) -> Unit) {
        check(!finished) { "finished" }
        if (inFrames <= 0) return
        if (passthrough) { totalIn += inFrames; sink(input, inFrames); return }
        // work = carry ++ input
        val carryFrames = carry.size / channels
        val work = FloatArray(carry.size + inFrames * channels)
        System.arraycopy(carry, 0, work, 0, carry.size)
        System.arraycopy(input, 0, work, carry.size, inFrames * channels)
        totalIn += inFrames
        // An output frame i needs input i0 and i0+1 (i1 = min(i0+1, last)); only emit while i0+1 < totalIn (no clamp yet).
        emit(work, carryFrames + inFrames, sink, final = false)
        val keepFrom = minOf((nextOut * ratio).toLong(), totalIn)   // earliest input frame a future output can touch
        retain(work, keepFrom, carryFrames + inFrames)
    }

    /** Flush the end-clamped tail frames (the one-shot's clamp at the last input frame). */
    fun finish(sink: (FloatArray, Int) -> Unit) {
        if (finished) return
        finished = true
        if (passthrough || totalIn == 0L) return
        val carryFrames = carry.size / channels
        emit(carry, carryFrames, sink, final = true)
    }

    private fun emit(work: FloatArray, workFrames: Int, sink: (FloatArray, Int) -> Unit, final: Boolean) {
        val workBase = totalIn - workFrames                // absolute index of work[0]
        val outFramesTotal = (totalIn * outRate + inRate - 1) / inRate
        var n = 0
        while (true) {
            val i = nextOut
            if (final && i >= outFramesTotal) break
            val pos = i * ratio
            val i0 = pos.toLong()
            if (!final && i0 + 1 >= totalIn) break
            val f = (pos - i0).toFloat()
            val i1 = minOf(i0 + 1, totalIn - 1)
            val a = ((i0 - workBase) * channels).toInt()
            val b = ((i1 - workBase) * channels).toInt()
            for (c in 0 until channels) {
                val x = work[a + c]
                out[n * channels + c] = x + (work[b + c] - x) * f
            }
            nextOut++; n++
            if (n == OUT_FRAMES) { sink(out, n); n = 0 }
        }
        if (n > 0) sink(out, n)
    }

    private fun retain(work: FloatArray, keepFrom: Long, workFrames: Int) {
        val workBase = totalIn - workFrames
        val from = maxOf(keepFrom, workBase)
        val startIdx = ((from - workBase) * channels).toInt()
        carry = work.copyOfRange(startIdx, workFrames * channels)
        carryBase = from
    }

    companion object {
        /** Output block size (frames): bounds every transient array. */
        const val OUT_FRAMES = 4096

        /** One-shot helper built on the streaming path (tests / small buffers). */
        fun resample(src: PcmBuffer, rate: Int, chunkFrames: Int = 4096): PcmBuffer {
            val r = StreamingResampler(src.sampleRate, rate, src.channels)
            val acc = ArrayList<FloatArray>(); var total = 0
            val grab = { b: FloatArray, n: Int -> acc += b.copyOf(n * src.channels); total += n * src.channels }
            var pos = 0
            val chunk = FloatArray(chunkFrames * src.channels)
            while (pos < src.frames) {
                val n = minOf(chunkFrames, src.frames - pos)
                System.arraycopy(src.samples, pos * src.channels, chunk, 0, n * src.channels)
                r.process(chunk, n, grab); pos += n
            }
            r.finish(grab)
            val out = FloatArray(total); var o = 0
            for (a in acc) { System.arraycopy(a, 0, out, o, a.size); o += a.size }
            return PcmBuffer(rate, src.channels, out)
        }
    }
}

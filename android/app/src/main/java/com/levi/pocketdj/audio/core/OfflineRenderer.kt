package com.levi.pocketdj.audio.core

/**
 * A manual [AudioSink]: nothing renders until [renderFrames] is called. Used by JVM tests and
 * instrumented probes to pull N frames out of a graph deterministically (same clock semantics
 * as the device sink).
 */
class OfflineRenderer(
    override val sampleRate: Int = 44_100,
    val blockFrames: Int = 512,
) : AudioSink {
    override val clock = RenderClock(sampleRate)
    override val underruns: Long get() = 0
    override var onRoutingChanged: ((Boolean) -> Unit)? = null
    @Volatile private var renderer: BlockRenderer? = null
    override val isRendering: Boolean get() = renderer != null

    override fun start(renderer: BlockRenderer) { this.renderer = renderer }
    override fun stop() { renderer = null }
    override fun release() { renderer = null }
    override fun latencyFrames(): Int = 0

    /** Pull exactly [frames] frames (in [blockFrames] chunks) and return them interleaved. */
    fun renderFrames(frames: Int): FloatArray {
        val r = checkNotNull(renderer) { "OfflineRenderer not started" }
        val out = FloatArray(frames * 2)
        val block = FloatArray(blockFrames * 2)
        var done = 0
        while (done < frames) {
            val n = minOf(blockFrames, frames - done)
            r.render(block, n)
            System.arraycopy(block, 0, out, done * 2, n * 2)
            clock.advance(n)
            done += n
        }
        return out
    }

    companion object {
        /** Index (frame) of the first frame whose either channel is non-zero, or -1. */
        fun firstNonZeroFrame(interleaved: FloatArray): Int {
            var i = 0
            while (i < interleaved.size) {
                if (interleaved[i] != 0f || (i + 1 < interleaved.size && interleaved[i + 1] != 0f)) return i / 2
                i += 2
            }
            return -1
        }
    }
}

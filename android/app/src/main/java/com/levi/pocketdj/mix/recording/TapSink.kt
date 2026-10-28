package com.levi.pocketdj.mix.recording

import com.levi.pocketdj.audio.core.FloatRing
import com.levi.pocketdj.mix.graph.TapSink
import java.util.concurrent.atomic.AtomicLong

/**
 * The persistent house-sum tap. Installed ONCE on the graph; start/stop only flips [capturing] so a
 * recording never adds or removes a node. The render thread copies each clean-house block into a
 * lock-free SPSC [FloatRing]; the writer thread drains it. Never blocks or allocates on the render
 * thread; a full queue drops the block and counts it.
 */
class RecordingTapSink(capacityFrames: Int = 44_100 * 4, val channels: Int = 2) : TapSink {
    private val ring = FloatRing(capacityFrames * channels)
    @Volatile private var capturing = false
    private val dropped = AtomicLong(0)

    override val isCapturing: Boolean get() = capturing

    fun setCapturing(on: Boolean) { capturing = on }

    /** Floats lost because the consumer fell behind. */
    val droppedFloats: Long get() = dropped.get()

    /** Render thread. A block either fits whole or is dropped whole (no half-written stereo frames). */
    override fun onHouse(buf: FloatArray, frames: Int) {
        val n = frames * channels
        if (ring.writable < n) { dropped.addAndGet(n.toLong()); return }
        ring.write(buf, 0, n)
    }

    /** Writer thread: copy up to [maxFloats] queued floats into [dst]; returns the float count read. */
    fun drain(dst: FloatArray, maxFloats: Int): Int = ring.read(dst, 0, minOf(maxFloats, dst.size) and 1.inv())

    val queuedFloats: Int get() = ring.readable

    /** Drop stale audio when a take starts (consumer side; the producer is gated off). */
    fun clear() { ring.clearConsumer() }
}

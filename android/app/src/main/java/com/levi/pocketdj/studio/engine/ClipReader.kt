package com.levi.pocketdj.studio.engine

import java.io.File
import java.io.RandomAccessFile
import java.nio.ByteOrder
import java.nio.MappedByteBuffer
import java.nio.channels.FileChannel

/**
 * Random-access source of one arranger clip window (interleaved canonical stereo float). The render thread
 * only calls [read] (allocation-free into a caller-owned array); a background feeder calls [prefetch] a few
 * seconds ahead of the playhead so the render callback never takes a cold page fault.
 */
interface ClipReader {
    /** Window length in frames. */
    val frameCount: Int

    /** Copy [frames] frames starting at window frame [srcFrame] into [dst] at float offset [dstOff] (interleaved). */
    fun read(dst: FloatArray, dstOff: Int, srcFrame: Int, frames: Int)

    /** Fault the pages backing [srcFrame, srcFrame+frames) in (feeder thread; no-op for in-memory readers). */
    fun prefetch(srcFrame: Int, frames: Int) {}

    fun close() {}
}

/** The short-clip path: the window already lives on the heap as floats. */
class ArrayClipReader(private val samples: FloatArray, private val firstFrame: Int = 0, override val frameCount: Int = samples.size / 2 - firstFrame) : ClipReader {
    override fun read(dst: FloatArray, dstOff: Int, srcFrame: Int, frames: Int) =
        System.arraycopy(samples, (firstFrame + srcFrame) * 2, dst, dstOff, frames * 2)
}

/**
 * PCM16 little-endian stereo window in a page file, memory-mapped read-only. Heap cost is zero regardless of
 * the window length; resident memory is whatever the OS keeps of the pages the feeder/renderer touched.
 */
class MappedPcm16ClipReader(private val file: File, override val frameCount: Int) : ClipReader {
    private val raf = RandomAccessFile(file, "r")
    private val buf: MappedByteBuffer = raf.channel.map(FileChannel.MapMode.READ_ONLY, ClipPageStore.HEADER_BYTES.toLong(), frameCount.toLong() * BYTES_PER_FRAME)
        .also { it.order(ByteOrder.LITTLE_ENDIAN) }
    @Volatile private var touchSink = 0

    override fun read(dst: FloatArray, dstOff: Int, srcFrame: Int, frames: Int) {
        var p = srcFrame * BYTES_PER_FRAME
        var d = dstOff
        for (i in 0 until frames * 2) { dst[d++] = ClipPageStore.dequantize(buf.getShort(p)); p += 2 }
    }

    override fun prefetch(srcFrame: Int, frames: Int) {
        val from = (srcFrame.coerceIn(0, frameCount)).toLong() * BYTES_PER_FRAME
        val to = ((srcFrame.toLong() + frames).coerceIn(0, frameCount.toLong())) * BYTES_PER_FRAME
        var p = from
        var acc = 0
        while (p < to) { acc += buf.get(p.toInt()); p += PAGE }
        touchSink = acc // keep the loads observable so the JIT cannot elide the touches
    }

    override fun close() { runCatching { raf.close() } }

    companion object {
        const val BYTES_PER_FRAME = 4
        private const val PAGE = 4096
    }
}

/**
 * Keeps the pages a few seconds ahead of the render cursor resident (the "feeder"). [tick] is one pass and is
 * what tests call; [start] runs it on a daemon thread every [periodMs]. Seeks need no special call: the cursor
 * the renderer publishes jumps and the next tick (or [MultitrackRenderContext.prime] at load) follows it.
 */
class ClipFeeder(private val ahead: () -> Unit, private val periodMs: Long = 200L) {
    @Volatile private var running = false
    private var thread: Thread? = null

    fun tick() = ahead()

    fun start() {
        if (running) return
        running = true
        thread = Thread({
            while (running) {
                runCatching { ahead() }
                try { Thread.sleep(periodMs) } catch (_: InterruptedException) { break }
            }
        }, "clip-feeder").also { it.isDaemon = true; it.start() }
    }

    fun stop() { running = false; thread?.interrupt(); thread = null }
}

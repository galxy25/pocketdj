package com.levi.pocketdj.audio.core

import android.os.Process

/**
 * The slice of the native Oboe stream the sink needs (see cpp/pdjdsp/oboe_sink.cpp). The native data
 * callback only memcpy's from a lock-free ring, so the Kotlin render thread is the sole producer and
 * NOTHING on the realtime path crosses JNI or allocates. Seam so the rebuild/prime logic is JVM-testable.
 */
interface OboeBackend {
    /** Build + start the stream (also drops stale ring audio). False on failure. */
    fun open(): Boolean
    fun close()
    fun release()
    /** Non-blocking copy of [frames] interleaved stereo frames; returns frames accepted. */
    fun write(buf: FloatArray, frames: Int): Int
    fun freeFrames(): Int
    fun bufferedFrames(): Int
    fun underruns(): Long
    /** The device went away under the stream (route change); the owner must [open] again. */
    fun disconnected(): Boolean
    fun streamLatencyFrames(): Int
}

/**
 * Studio's device sink: an Oboe low-latency stream (Float, stereo, exclusive) behind the shared
 * [AudioSink] contract. A render thread keeps the native ring topped up with [BlockRenderer] blocks;
 * on a stream disconnect it rebuilds the stream with short backoff and re-primes (the ring is
 * flushed on reopen, then refilled before the first callback matters), reporting via
 * [onRoutingChanged]. [clock] advances per block rendered (same contract as AudioTrackSink).
 */
class OboeSink(
    override val sampleRate: Int,
    private val blockFrames: Int = 512,
    private val backendFactory: () -> OboeBackend,
) : AudioSink {
    override val clock = RenderClock(sampleRate)
    override var onRoutingChanged: ((Boolean) -> Unit)? = null

    private var backend: OboeBackend? = null
    @Volatile private var thread: Thread? = null
    @Volatile private var running = false
    @Volatile private var rendering = false
    @Volatile private var underrunBase = 0L
    @Volatile private var renderer: BlockRenderer? = null
    private val buf = FloatArray(blockFrames * 2)
    private var rebuildAttempt = 0
    private var nextRebuildAt = 0L

    override val isRendering: Boolean get() = rendering
    override val underruns: Long get() = underrunBase + (backend?.underruns() ?: 0)

    @Synchronized override fun start(renderer: BlockRenderer) {
        if (running) return
        val b = backendFactory()
        if (!b.open()) { b.release(); rendering = false; return } // owner's watchdog retries start()
        backend = b
        this.renderer = renderer
        running = true
        rendering = true
        rebuildAttempt = 0
        thread = Thread({ loop() }, "pdj-oboe-feed").also { it.priority = Thread.MAX_PRIORITY; it.start() }
    }

    private fun loop() {
        runCatching { Process.setThreadPriority(Process.THREAD_PRIORITY_URGENT_AUDIO) }
        while (running) {
            val worked = try { pumpOnce(System.nanoTime() / 1_000_000) } catch (e: Throwable) {
                rendering = false
                AudioDiag.stop("OboeSink", "render-exception", e.toString())
                false
            }
            if (!worked) try { Thread.sleep(2) } catch (_: InterruptedException) { }
        }
    }

    /**
     * One feeder step: rebuild a dead stream (with backoff), else render one block into the ring if it
     * fits. Returns true when it did work (the loop then spins again without sleeping). [nowMs] is
     * injected so tests drive the backoff deterministically.
     */
    internal fun pumpOnce(nowMs: Long): Boolean {
        val b = backend ?: return false
        if (b.disconnected()) {
            rendering = false
            if (nowMs < nextRebuildAt) return false
            underrunBase += b.underruns()
            val ok = b.open()
            if (ok) {
                rebuildAttempt = 0
                rendering = true
                AudioDiag.play("OboeSink", "stream-rebuilt", started = true)
                onRoutingChanged?.invoke(true)
            } else {
                nextRebuildAt = nowMs + retryDelayMs(rebuildAttempt++)
                AudioDiag.play("OboeSink", "stream-rebuild-failed", started = false, detail = "attempt=$rebuildAttempt")
            }
            return ok
        }
        val r = renderer ?: return false
        if (b.freeFrames() < blockFrames) return false
        r.render(buf, blockFrames)
        val n = b.write(buf, blockFrames)
        if (n < blockFrames) return false // ring raced full; the unwritten tail is dropped (cannot happen with one producer)
        rendering = true
        clock.advance(blockFrames)
        return true
    }

    @Synchronized override fun stop() {
        running = false
        thread?.let { runCatching { it.join(500) } }
        thread = null
        backend?.let { runCatching { it.close() }; runCatching { it.release() } }
        backend = null
        renderer = null
        rendering = false
    }

    override fun release() = stop()

    override fun latencyFrames(): Int {
        val b = backend ?: return 0
        return b.bufferedFrames() + b.streamLatencyFrames()
    }

    companion object {
        /** Rebuild backoff: 20, 40, 80, then 100 ms — the first three attempts land inside 300 ms. */
        fun retryDelayMs(attempt: Int): Long = minOf(100L, 20L shl attempt.coerceIn(0, 10))
    }
}

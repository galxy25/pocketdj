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
    private val spawnFeeder: Boolean = true, // false = tests drive [pumpOnce] by hand
    private val backendFactory: () -> OboeBackend,
) : AudioSink {
    override val clock = RenderClock(sampleRate)
    override var onRoutingChanged: ((Boolean) -> Unit)? = null

    private var backend: OboeBackend? = null
    @Volatile private var thread: Thread? = null
    @Volatile private var running = false
    /** Bumped by every stop(); a feeder that outlived a bounded join sees its generation is stale and exits. */
    @Volatile private var generation = 0
    /** Native close/release handed to a feeder still inside open()/render when stop() gave up joining. */
    private val orphanClose = java.util.concurrent.atomic.AtomicReference<Runnable?>(null)
    @Volatile private var rendering = false
    @Volatile private var renderer: BlockRenderer? = null
    private val buf = FloatArray(blockFrames * 2)
    private var rebuildAttempt = 0
    private var renderFailed = false
    private var wasDisconnected = false
    private var nextRebuildAt = 0L

    override val isRendering: Boolean get() = rendering
    override val underruns: Long get() = backend?.underruns() ?: 0 // the native counter is cumulative across reopens

    @Synchronized override fun start(renderer: BlockRenderer) {
        if (running) return
        val b = backendFactory()
        if (!b.open()) { b.release(); rendering = false; return } // owner's watchdog retries start()
        backend = b
        this.renderer = renderer
        running = true
        rendering = true
        // A park (stop) then restart is a fresh stream: clear any disconnect/backoff state left by the last life.
        rebuildAttempt = 0
        wasDisconnected = false
        nextRebuildAt = 0L
        renderFailed = false
        if (spawnFeeder) {
            val gen = generation
            thread = Thread({ loop(gen) }, "pdj-oboe-feed").also { it.priority = Thread.MAX_PRIORITY; it.start() }
        }
    }

    /** Test seam: wire a backend + renderer WITHOUT spawning the feeder thread (drive [pumpOnce] by hand). */
    internal fun attachForTest(b: OboeBackend, r: BlockRenderer) { backend = b; renderer = r; rendering = true }

    private fun loop(gen: Int) {
        runCatching { Process.setThreadPriority(Process.THREAD_PRIORITY_URGENT_AUDIO) }
        while (running && gen == generation) {
            val worked = try { pumpOnce(System.nanoTime() / 1_000_000) } catch (e: Throwable) {
                rendering = false
                AudioDiag.stop("OboeSink", "render-exception", e.toString())
                renderFailed = true
                false
            }
            val pause = if (renderFailed) 50L else 2L
            renderFailed = false
            if (!worked) try { Thread.sleep(pause) } catch (_: InterruptedException) { }
        }
        orphanClose.getAndSet(null)?.run() // stop() timed out on us: free the native handle now that nothing uses it
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
            if (!wasDisconnected) { wasDisconnected = true; onRoutingChanged?.invoke(false) }
            if (nowMs < nextRebuildAt) return false
            val ok = b.open()
            if (ok) {
                wasDisconnected = false
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
        generation++
        val b = backend
        val t = thread
        // Bounded join (main-thread callers): the feeder may be inside a slow native open() or a render.
        if (t != null && t !== Thread.currentThread()) runCatching { t.join(JOIN_MS) }
        thread = null
        backend = null
        renderer = null
        rendering = false
        if (b != null) {
            val free = Runnable { runCatching { b.close() }; runCatching { b.release() } }
            if (t != null && t.isAlive && t !== Thread.currentThread()) {
                // Never free a handle the feeder may still be using: it frees it when it exits (or we do, if it already did).
                orphanClose.set(free)
                if (!t.isAlive) orphanClose.getAndSet(null)?.run()
            } else free.run()
        }
    }

    override fun release() = stop()

    override fun latencyFrames(): Int {
        val b = backend ?: return 0
        return b.bufferedFrames() + b.streamLatencyFrames()
    }

    companion object {
        const val JOIN_MS = 500L
        /** Rebuild backoff: 20, 40, 80, then 100 ms — the first three attempts land inside 300 ms. */
        fun retryDelayMs(attempt: Int): Long = minOf(100L, 20L shl attempt.coerceIn(0, 10))
    }
}

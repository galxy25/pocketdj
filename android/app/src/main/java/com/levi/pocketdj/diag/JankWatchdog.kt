package com.levi.pocketdj.diag

import android.view.Choreographer

/** Pure frame-gap detector: a gap above [thresholdMs] between frames is a main-thread stall. */
class JankDetector(private val thresholdMs: Long = 500) {
    private var lastNanos = 0L

    /** Feed a frame time; returns the gap in ms when it exceeded the threshold, else null. */
    fun onFrame(frameTimeNanos: Long): Long? {
        val prev = lastNanos
        lastNanos = frameTimeNanos
        if (prev == 0L) return null
        val gap = (frameTimeNanos - prev) / 1_000_000
        return if (gap > thresholdMs) gap else null
    }

    /** Forget the last frame (app backgrounded: the gap is not jank). */
    fun reset() { lastNanos = 0L }
}

/** Choreographer-driven watchdog logging `[jank] main thread stalled Nms` lines. */
class JankWatchdog(
    private val report: (String, String) -> Unit,
    private val detector: JankDetector = JankDetector(),
) : Choreographer.FrameCallback {
    private var running = false

    fun start() {
        if (running) return
        running = true
        detector.reset()
        Choreographer.getInstance().postFrameCallback(this)
    }

    fun stop() {
        running = false
        Choreographer.getInstance().removeFrameCallback(this)
        detector.reset()
    }

    override fun doFrame(frameTimeNanos: Long) {
        if (!running) return
        detector.onFrame(frameTimeNanos)?.let { report("jank", "main thread stalled ${it}ms") }
        Choreographer.getInstance().postFrameCallback(this)
    }
}

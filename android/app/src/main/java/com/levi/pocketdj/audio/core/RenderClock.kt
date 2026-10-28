package com.levi.pocketdj.audio.core

import java.util.concurrent.atomic.AtomicLong

/**
 * The sink's sample clock. [now] is the render frame of the NEXT block to be produced, so a
 * scheduled start at `now + lead` lands on one exact frame no matter which thread computes it.
 */
class RenderClock(val sampleRate: Int) {
    private val frames = AtomicLong(0)

    /** Frames rendered so far (the render frame the next block starts at). */
    fun now(): Long = frames.get()

    /** Called by the sink after each block. */
    fun advance(n: Int) { frames.addAndGet(n.toLong()) }

    fun reset() { frames.set(0) }

    fun secondsToFrames(seconds: Double): Long = Math.round(seconds * sampleRate)

    fun framesToSeconds(f: Long): Double = f.toDouble() / sampleRate

    /** The render frame [leadSeconds] from now. */
    fun frameAfter(leadSeconds: Double): Long = now() + secondsToFrames(leadSeconds)
}

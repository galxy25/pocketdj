package com.levi.pocketdj.mix.graph

import com.levi.pocketdj.mix.model.Deck
import java.util.concurrent.atomic.AtomicLong
import kotlin.math.abs

/**
 * Render-thread heartbeat. [lastRenderAt] advances on every block, [lastAudibleAt] only when the
 * house sum carries signal (so "render thread alive but silent" is distinguishable from "stuck").
 * Stamps are `System.nanoTime()`; 0 = never.
 */
class MixTapPulse {
    @Volatile var lastRenderAt = 0L; private set
    @Volatile var lastAudibleAt = 0L; private set
    @Volatile var blocks = 0L; private set
    @Volatile var peak = 0f; private set

    /** Called by the render thread with the clean house sum of one block. */
    fun note(buf: FloatArray, frames: Int) {
        var p = 0f
        var i = 0
        val n = frames * 2
        while (i < n) { val a = abs(buf[i]); if (a > p) p = a; i++ }
        val now = System.nanoTime()
        lastRenderAt = now
        if (p > AUDIBLE) lastAudibleAt = now
        peak = p
        blocks++
    }

    fun reset() { lastRenderAt = 0L; lastAudibleAt = 0L; blocks = 0L; peak = 0f }

    companion object { const val AUDIBLE = 1e-4f }
}

/**
 * Recording hook on the CLEAN house sum (after both mainGains, before the cue pan and the
 * limiter). Called on the render thread: implementations must copy into a lock-free queue and
 * never block or allocate.
 */
interface TapSink {
    val isCapturing: Boolean
    fun onHouse(buf: FloatArray, frames: Int)
}

/** Test/probe seam: a deck's post-trim, pre-fader block (also on the render thread). */
fun interface MixDeckCapture {
    fun onDeck(deck: Deck, buf: FloatArray, frames: Int)
}

/**
 * Seqlock-published playhead stamp so the control thread can read a COHERENT
 * (inputClock, mainFrame, stemFrame) triple without locking the render thread.
 */
class PosStamp {
    private val seq = AtomicLong(0)
    @Volatile private var a = 0L
    @Volatile private var b = 0L
    @Volatile private var c = 0L

    fun write(inputClock: Long, mainFrame: Long, stemFrame: Long) {
        seq.incrementAndGet() // odd: writing
        a = inputClock; b = mainFrame; c = stemFrame
        seq.incrementAndGet()
    }

    /** Fill [out] (size >= 3) with a consistent triple. */
    fun read(out: LongArray) {
        while (true) {
            val s1 = seq.get()
            if (s1 and 1L == 1L) continue
            val x = a; val y = b; val z = c
            if (seq.get() == s1) { out[0] = x; out[1] = y; out[2] = z; return }
        }
    }
}

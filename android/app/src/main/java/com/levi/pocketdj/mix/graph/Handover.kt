package com.levi.pocketdj.mix.graph

import java.util.concurrent.atomic.AtomicInteger
import java.util.concurrent.atomic.AtomicLong
import java.util.concurrent.atomic.AtomicReference

/**
 * The main (full mix) <-> stems handover, as a gain state machine.
 *
 * Control thread: [schedule] / [settle] publish an immutable plan (generation-guarded; a newer plan
 * supersedes an older one atomically, so rapid toggles land on the LAST intent). Render thread:
 * [advance] is called once per input chunk and yields the per-chunk linear gain ramps
 * ([mainG0]->[mainG1], [stemG0]->[stemG1]); the deck chain multiplies the voices by them.
 *
 * The fade is LINEAR (coherent sources: the full mix and the stems sum to the same signal, so
 * main*(1-t) + stems*t stays flat; equal-power would bulge +3 dB). A plan that supersedes an
 * in-flight fade starts from the CURRENT gains, so the sum of both sides stays 1 and nothing dips.
 */
class Handover(val fadeFrames: Int) {
    private class Plan(val gen: Int, val toStems: Boolean, val startFrame: Long, val fadeFrames: Int, val instant: Boolean)

    private val planRef = AtomicReference<Plan?>(null)
    private val genCounter = AtomicInteger(0)

    /** Control-side intent: where the deck is heading (or sits). */
    private val intentRef = AtomicLong(0L) // (gen shl 1) | toStems: abort() can flip it only if no newer plan exists
    val intentStems: Boolean get() = (intentRef.get() and 1L) != 0L
    /** Generation of the last plan that completed (render thread writes). */
    @Volatile var landedGen = 0; private set
    /** True side of the last landed plan. */
    @Volatile var landedToStems = false; private set
    /** Generation of the last plan aborted by the alignment check. */
    @Volatile var abortedGen = 0; private set
    /** Last plan generation handed out. */
    val latestGen: Int get() = genCounter.get()

    val inFlight: Boolean get() = planRef.get() != null

    // ---- render-thread state ----
    var mainGain = 1f; private set
    var stemGain = 0f; private set
    var mainG0 = 1f; private set
    var mainG1 = 1f; private set
    var stemG0 = 0f; private set
    var stemG1 = 0f; private set
    private var activeGen = 0
    private var fromM = 1f
    private var fromS = 0f
    private var activeStart = 0L
    private var activeFade = 1
    private var checkPending = false

    /** Published copies for the control thread (approximate; used for "is the incoming side live"). */
    @Volatile var publishedMain = 1f; private set
    @Volatile var publishedStem = 0f; private set

    // ---------------------------------------------------------------- control

    /** Fade to [toStems] starting at input-clock frame [startFrame]. Returns the plan generation. */
    fun schedule(toStems: Boolean, startFrame: Long, frames: Int = fadeFrames): Int {
        val g = genCounter.incrementAndGet()
        intentRef.set((g.toLong() shl 1) or (if (toStems) 1L else 0L))
        planRef.set(Plan(g, toStems, startFrame, maxOf(1, frames), false))
        return g
    }

    /** Land the intent (or [toStems]) at the next block with no fade: "settle before transport". */
    fun settle(toStems: Boolean = intentStems): Int {
        val g = genCounter.incrementAndGet()
        intentRef.set((g.toLong() shl 1) or (if (toStems) 1L else 0L))
        planRef.set(Plan(g, toStems, Long.MIN_VALUE, 1, true))
        return g
    }

    // ---------------------------------------------------------------- render

    /**
     * Compute the gain ramp for the chunk [chunkStart, chunkStart+n). Returns true when a plan
     * landed in this chunk (the chain then stops the outgoing voices).
     */
    fun advance(chunkStart: Long, n: Int): Boolean {
        mainG0 = mainGain; stemG0 = stemGain
        val p = planRef.get()
        if (p == null) { mainG1 = mainG0; stemG1 = stemG0; return false }
        if (p.gen != activeGen) {
            activeGen = p.gen
            fromM = mainGain; fromS = stemGain
            activeStart = if (p.instant) chunkStart else maxOf(p.startFrame, chunkStart)
            activeFade = p.fadeFrames
            checkPending = !p.instant
        }
        val t = if (p.instant) 1f else ((chunkStart + n - activeStart).toFloat() / activeFade).coerceIn(0f, 1f)
        val toM = if (p.toStems) 0f else 1f
        val toS = 1f - toM
        mainG1 = fromM + (toM - fromM) * t
        stemG1 = fromS + (toS - fromS) * t
        mainGain = mainG1; stemGain = stemG1
        publishedMain = mainGain; publishedStem = stemGain
        if (t >= 1f) {
            // A newer plan published between get() and the CAS owns the deck: report nothing landed
            // and let it take over from the current gains on the next chunk.
            if (planRef.compareAndSet(p, null)) { landedToStems = p.toStems; landedGen = p.gen; return true }
            return false
        }
        return false
    }

    /**
     * True exactly once per plan, in the chunk where the incoming side must be sample-aligned with
     * the outgoing one (the first chunk that ends past the fade start).
     */
    fun alignmentDue(chunkStart: Long, n: Int): Boolean {
        if (!checkPending) return false
        val p = planRef.get() ?: return false
        if (p.gen != activeGen) return false
        if (chunkStart + n > activeStart) { checkPending = false; return true }
        return false
    }

    /** The incoming side was not where the outgoing one is: undo the plan, keep the old side. */
    fun abort() {
        val p = planRef.get() ?: return
        if (p.gen != activeGen) return
        if (planRef.compareAndSet(p, null)) {
            // The outgoing side kept playing (the incoming one is paused): it carries the deck at full level.
            mainGain = if (p.toStems) 1f else 0f; stemGain = 1f - mainGain
            publishedMain = mainGain; publishedStem = stemGain
            // Only revert the intent if no newer plan was published meanwhile (single atomic compare).
            val was = (p.gen.toLong() shl 1) or (if (p.toStems) 1L else 0L)
            intentRef.compareAndSet(was, (p.gen.toLong() shl 1) or (if (p.toStems) 0L else 1L))
            abortedGen = p.gen
        }
    }

    /** Whether the plan currently in flight heads to the stems (render thread). */
    val activeToStems: Boolean get() = planRef.get()?.toStems ?: intentStems
}

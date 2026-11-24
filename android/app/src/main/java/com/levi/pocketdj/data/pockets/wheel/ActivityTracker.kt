package com.levi.pocketdj.data.pockets.wheel

import com.levi.pocketdj.data.motion.MotionSegment
import com.levi.pocketdj.data.motion.MotionSettle

/**
 * Port of iOS `ActivityTracker` (PocketRunStore Phase 5b): "is the body doing something new, for long enough?". Pure.
 * The clock restarts whenever the activity changes; low-confidence samples are ignored.
 */
class ActivityTracker {
    var activity: String? = null
        private set
    var sinceMs: Long? = null
        private set

    /** Fold in a live sample (an ENTER on Android: the activity began at [MotionSegment.startMs]). */
    fun note(seg: MotionSegment) {
        if (seg.confidence < MotionSettle.MIN_CONFIDENCE) return
        if (seg.activity != activity) {
            activity = seg.activity
            sinceMs = seg.startMs
        }
    }

    /** The activity ended (an EXIT): forget it unless a different one has since begun. */
    fun ended(activity: String) {
        if (this.activity == activity) { this.activity = null; sinceMs = null }
    }

    /** The run mode a sustained activity implies (running / walking / trip), or null. */
    fun sustainedMode(nowMs: Long): PocketMode? {
        val a = activity ?: return null
        val t = sinceMs ?: return null
        if (nowMs - t < SUSTAIN_MS) return null
        return modeFor(a)
    }

    companion object {
        /** A change must hold this long before a run re-targets (iOS `sustainSeconds` = 180). */
        const val SUSTAIN_MS = 180_000L

        fun modeFor(activity: String): PocketMode? = when (activity) {
            MotionToken.RUNNING -> PocketMode.RUNNING
            MotionToken.WALKING -> PocketMode.WALKING
            MotionToken.AUTOMOTIVE, MotionToken.CYCLING -> PocketMode.TRIP
            else -> null
        }

        /** Once per mode per run: a sustained [mode] re-targets unless the run already is / was re-targeted to it. */
        fun shouldRetarget(mode: PocketMode?, retargetedMode: PocketMode?, profileMode: PocketMode?): Boolean =
            mode != null && mode != (retargetedMode ?: profileMode)
    }
}

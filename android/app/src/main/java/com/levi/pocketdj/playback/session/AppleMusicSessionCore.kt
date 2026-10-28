package com.levi.pocketdj.playback.session

import com.levi.pocketdj.playback.am.AmStatus
import com.levi.pocketdj.playback.am.AppleMusicController

/**
 * The Looper-free decision logic of [AppleMusicPlayerAdapter] (a SimpleBasePlayer cannot be built on the
 * JVM), so the three session-facing rules are unit-testable:
 *
 *  1. CLAIM GATE: while the controller tears the ExoPlayer row down, the adapter must NOT take the
 *     MediaSession - the service swaps `mediaSession.player` on claim, and a teardown `stop()` sent through
 *     the session would then hit the adapter and kill the Apple Music audio just started.
 *  2. QUIET HANDOFF: another owner starting silences AM without the listener-pause bookkeeping
 *     (PauseDiscriminator / intentional-pause), and only when AM is actually sounding.
 *  3. STOP is a full set stop (the controller's stop), never a bare engine stop the poll loop would read
 *     as a dead source and advance past.
 */
class AppleMusicSessionCore(
    private val engine: AppleMusicController,
    private val onStopRequested: () -> Unit,
) {
    @Volatile private var held = false
    @Volatile private var deferredClaim = false

    /** Suppress session claims until [releaseClaims]. */
    fun holdClaims() { held = true }

    /** Lift the gate; true when a claim was deferred meanwhile (the caller re-evaluates [shouldClaim]). */
    fun releaseClaims(): Boolean {
        held = false
        val d = deferredClaim
        deferredClaim = false
        return d
    }

    /** Should the adapter take the session now? (AM is sounding a live row and does not already own it.) */
    fun shouldClaim(alreadyActive: Boolean): Boolean {
        if (alreadyActive) return false
        if (engine.track == null || engine.snapshot().status != AmStatus.PLAYING) return false
        if (held) { deferredClaim = true; return false }
        return true
    }

    fun pauseForHandoff() {
        if (engine.track == null) return
        val st = engine.snapshot().status
        if (st == AmStatus.PLAYING || st == AmStatus.BUFFERING) engine.pauseQuiet()
    }

    fun stop() = onStopRequested()
}

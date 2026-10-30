package com.levi.pocketdj.mix.engine

/**
 * Beat-phase math for sync / glide downbeat alignment, in AUDIBLE time.
 *
 * Source positions run ahead of what is heard by the time-stretcher's delay (`lag`, source seconds,
 * different per deck because it scales with tempo). Aligning raw positions would leave the two
 * audible beats offset by the difference of the lags; this subtracts each deck's lag first.
 */
object PhaseAlignMath {
    /** Phase in beats (0..1) of an AUDIBLE source time against the song's first downbeat. */
    fun audiblePhase(positionSec: Double, lagSec: Double, firstDownbeatSec: Double, beatSec: Double): Double {
        val x = (positionSec - lagSec - firstDownbeatSec) / beatSec
        return ((x % 1.0) + 1.0) % 1.0
    }

    /** Signed phase gap lead - follower, wrapped to [-0.5, 0.5]. */
    fun wrappedDelta(leadPhase: Double, followerPhase: Double): Double {
        var d = leadPhase - followerPhase
        if (d > 0.5) d -= 1 else if (d < -0.5) d += 1
        return d
    }

    /**
     * The follower's new source position: shift by the wrapped audible phase gap (in follower beats).
     * Never negative. [errorMs] reports the residual audible offset that was corrected, for diagnostics.
     */
    data class Target(val seekSec: Double, val errorMs: Double)

    fun target(
        leadPos: Double, leadLag: Double, leadDb: Double, leadBeat: Double,
        folPos: Double, folLag: Double, folDb: Double, folBeat: Double,
    ): Target {
        val d = wrappedDelta(
            audiblePhase(leadPos, leadLag, leadDb, leadBeat),
            audiblePhase(folPos, folLag, folDb, folBeat),
        )
        return Target(maxOf(0.0, folPos + d * folBeat), d * folBeat * 1000.0)
    }
}

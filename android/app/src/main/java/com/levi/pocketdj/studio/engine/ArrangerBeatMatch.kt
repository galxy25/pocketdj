package com.levi.pocketdj.studio.engine

import com.levi.pocketdj.studio.audio.StudioAudio
import kotlin.math.max
import kotlin.math.min
import kotlin.math.roundToLong

/**
 * Pure Beat Match geometry shared by BOTH arranger read paths (live [MultitrackPlayer] and
 * [ArrangerBouncer]) so a bounce can never drift from playback (iOS `ArrangerBeatMatch`).
 * Beat Match warps every clip so its detected tempo equals the master bpm and snaps clip starts to the
 * master beat grid.
 */
object ArrangerBeatMatch {
    /**
     * Beat-Match warp (master / clip bpm) x per-track tempo; rate > 1 = faster/shorter. Beat Match off, or a
     * clip with no usable grid (`clipBpm <= 0`: unanalyzed or the zero-bpm sentinel), contributes a warp of 1x.
     * Clamped 1/32..32 (the stretcher's legal range).
     */
    fun rate(clipBpm: Double, masterBpm: Double, tempoRatio: Double, beatMatch: Boolean): Double {
        val warp = if (beatMatch && clipBpm > 0 && masterBpm > 0) masterBpm / clipBpm else 1.0
        return min(32.0, max(1.0 / 32, warp * tempoRatio))
    }

    /** Snap a start frame to the nearest master beat when beat-matching (else unchanged). */
    fun snappedStartFrame(frame: Int, beatFrames: Double, beatMatch: Boolean): Int {
        if (!beatMatch || beatFrames <= 0) return frame
        return (Math.floor(frame / beatFrames + 0.5) * beatFrames).toInt()
    }

    /** Frames of one master beat at [bpm] (0 when bpm is unusable). */
    fun beatFrames(bpm: Double, sampleRate: Int = StudioAudio.CANONICAL_RATE): Double =
        if (bpm > 0) 60.0 / bpm * sampleRate else 0.0

    /** Length of a source window of [srcFrames] after a warp at [rate] (rate 2 halves it). */
    fun warpedFrames(srcFrames: Long, rate: Double): Long =
        if (rate <= 0) srcFrames else (srcFrames / rate).roundToLong()

    /**
     * Where the scissor window start ([fileStartMs], source time) lands in the warped clip's own timeline:
     * the whole file is stretched by 1/[rate], so the offset scales the same way.
     */
    fun scaledFileStartMs(fileStartMs: Int, rate: Double): Int =
        if (rate <= 0) fileStartMs else (fileStartMs / rate).roundToLong().toInt()

    /** True when the clip's audio must be re-rendered through the stretcher (rate off 1x or a pitch shift). */
    fun needsBake(rate: Double, pitchCents: Double): Boolean = Math.abs(rate - 1) > 0.0005 || Math.abs(pitchCents) > 0.5
}

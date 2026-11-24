package com.levi.pocketdj.playback.dj

import com.levi.pocketdj.mix.model.Camelot
import kotlin.math.abs
import kotlin.math.cos
import kotlin.math.ln
import kotlin.math.max
import kotlin.math.min
import kotlin.math.sqrt

/**
 * AUTO TRANSITION: the decisions that define what an Auto-DJ transition IS, shared by the Mix tab's
 * Auto-DJ and Now Playing DJ Mode (port of iOS `Playback/AutoTransition.swift`). Pure functions on
 * value inputs; no engine state. The engines own WHEN to begin, the clocks, the decks and how a
 * ramp value is applied.
 */
object AutoTransition {
    // Ranges
    val rateRange: ClosedFloatingPointRange<Double> = 0.5..2.0
    val pitchRange: ClosedFloatingPointRange<Double> = -12.0..12.0

    // Timing constants
    /** Mix Glide bends the outgoing tempo up ~10%, so the pre-roll fit divides the runway by this. */
    const val GLIDE_TEMPO_HEADROOM = 1.12
    const val MIN_RUNWAY_FADE_SECONDS = 0.5
    const val MIN_IMMEDIATE_FADE_SECONDS = 0.2
    const val PRE_ROLL_MARGIN_SECONDS = 0.3
    /** A pre-roll / post-roll at or under this is treated as none. */
    const val MIN_RAMP_SECONDS = 0.05

    /** The timing of ONE transition. */
    data class Plan(
        val isGlide: Boolean,
        val preRollSeconds: Double,
        val fadeSeconds: Double,
        val postRollSeconds: Double,
        /** Non-null: restore the configured fade to this baseline after the crossfade. */
        val fadeRestore: Double?,
    ) {
        val hasPreRoll: Boolean get() = preRollSeconds > MIN_RAMP_SECONDS
        val hasPostRoll: Boolean get() = isGlide && postRollSeconds > MIN_RAMP_SECONDS
    }

    fun inLeadWindow(secondsLeft: Double, lead: Double): Boolean = secondsLeft <= lead

    fun headroom(mixGlide: Boolean): Double = if (mixGlide) GLIDE_TEMPO_HEADROOM else 1.0

    /** Plan the tick-driven ADVANCE: cap the fade to the runway, then fit the pre-roll after fade + margin. */
    fun advancePlan(
        secondsLeft: Double, fade: Double, glide: Double, fxGlide: Boolean, mixGlide: Boolean,
        fadeOverridePending: Boolean = false,
    ): Plan {
        var f = fade
        var restore: Double? = null
        if (secondsLeft < fade && !fadeOverridePending) {
            restore = fade
            f = max(MIN_RUNWAY_FADE_SECONDS, secondsLeft)
        }
        val isGlide = fxGlide || mixGlide
        var preroll = 0.0
        if (isGlide) {
            preroll = max(0.0, min(glide, secondsLeft / headroom(mixGlide) - f - PRE_ROLL_MARGIN_SECONDS))
        }
        return Plan(isGlide, preroll, f, if (isGlide) glide else 0.0, restore)
    }

    /** Plan an IMMEDIATE transition (manual skip / hand-over): no pre-roll, floored one-off fade. */
    fun immediatePlan(
        fade: Double, baselineFade: Double, glide: Double, fxGlide: Boolean, mixGlide: Boolean,
        fadeOverridePending: Boolean = false,
    ): Plan {
        val isGlide = fxGlide || mixGlide
        return Plan(
            isGlide, 0.0, max(MIN_IMMEDIATE_FADE_SECONDS, fade),
            if (isGlide) glide else 0.0,
            if (fadeOverridePending) null else baselineFade,
        )
    }

    // Equal-power crossfade (Float math, like iOS cosf)
    data class Gains(val outgoing: Float, val incoming: Float)

    fun equalPowerGains(progress: Float): Gains {
        val half = Math.PI.toFloat() / 2f
        return Gains(cos(half * progress), cos(half * (1f - progress)))
    }

    // Tempo / pitch
    /** 1 Camelot key as semitones at the 10%-per-key convention. */
    val SEMITONES_PER_KEY: Double = 12 * (ln(1.1) / ln(2.0))

    fun octaveFolded(ratio: Double): Double {
        if (!ratio.isFinite() || ratio <= 0) return 1.0
        var r = ratio
        while (r > rateRange.endInclusive) r /= 2
        while (r < rateRange.start) r *= 2
        return r.coerceIn(rateRange.start, rateRange.endInclusive)
    }

    fun syncRate(leadBPM: Double, leadRate: Double, followerBPM: Double): Double {
        if (!(followerBPM > 0)) return 1.0
        return octaveFolded(leadBPM * leadRate / followerBPM)
    }

    fun signedCamelotSteps(a: String?, b: String?): Int? = Camelot.signedSteps(a, b)

    fun glideRate(keys: Double): Double = (1 + 0.10 * keys).coerceIn(rateRange.start, rateRange.endInclusive)
    fun glidePitch(keys: Double): Double =
        (keys * SEMITONES_PER_KEY).coerceIn(pitchRange.start, pitchRange.endInclusive)

    data class GlideTargets(val outRate: Double, val outPitch: Double, val inRate: Double, val inPitch: Double)

    val identityGlide = GlideTargets(1.0, 0.0, 1.0, 0.0)

    fun glideParams(fromCamelot: String?, toCamelot: String?, fromBPM: Double?, toBPM: Double?): GlideTargets {
        var outPitch = 0.0
        var inPitch = 0.0
        var outRate = 1.0
        var inRate = 1.0
        val d = signedCamelotSteps(fromCamelot, toCamelot)
        if (d != null && abs(d) >= 1) {
            val mag = min(1.0, abs(d).toDouble() / 2.0)
            val dir = if (d > 0) 1.0 else -1.0
            outPitch = glidePitch(dir * mag)
            inPitch = glidePitch(-dir * mag)
        }
        if (fromBPM != null && toBPM != null && fromBPM > 0 && toBPM > 0) {
            val split = sqrt(octaveFolded(fromBPM / toBPM))
            inRate = split.coerceIn(rateRange.start, rateRange.endInclusive)
            outRate = (1 / split).coerceIn(rateRange.start, rateRange.endInclusive)
        }
        return GlideTargets(outRate, outPitch, inRate, inPitch)
    }

    // Glide ramps (linear; p 0..1)
    data class Ramp(val rate: Double, val pitch: Double, val fxStrength: Double)

    fun outgoingRamp(p: Double, outRate: Double, outPitch: Double, fxPeak: Double): Ramp =
        Ramp(1 + (outRate - 1) * p, outPitch * p, p * fxPeak)

    fun incomingRamp(p: Double, inRate: Double, inPitch: Double, fxPeak: Double): Ramp =
        Ramp(inRate + (1 - inRate) * p, inPitch * (1 - p), (1 - p) * fxPeak)

    // FX texture
    enum class TextureEffect(val raw: String) { FILTER("filter"), REVERB("reverb"), FLANGER("flanger") }

    val texturePool: List<TextureEffect> = listOf(TextureEffect.FILTER, TextureEffect.REVERB, TextureEffect.FLANGER)
    const val TEXTURE_PEAK_MIN = 0.5
    const val TEXTURE_PEAK_SPAN = 0.3
    const val TEXTURE_RUN_MIN = 3
    const val TEXTURE_RUN_CHOICES = 3

    /** Mutable splitmix64 state (unsigned 64-bit semantics via ULong). */
    class Rng(var state: ULong)

    data class Texture(val effect: TextureEffect, val peak: Double, val run: Int)

    fun splitmix64(rng: Rng): ULong {
        rng.state += 0x9E37_79B9_7F4A_7C15uL
        var z = rng.state
        z = (z xor (z shr 30)) * 0xBF58_476D_1CE4_E5B9uL
        z = (z xor (z shr 27)) * 0x94D0_49BB_1331_11EBuL
        return z xor (z shr 31)
    }

    fun rollTexture(rng: Rng): Texture {
        val a = splitmix64(rng)
        val b = splitmix64(rng)
        val c = splitmix64(rng)
        val effect = texturePool[(a % texturePool.size.toULong()).toInt()]
        val peak = TEXTURE_PEAK_MIN + (b % 1000uL).toDouble() / 1000.0 * TEXTURE_PEAK_SPAN
        val run = TEXTURE_RUN_MIN + (c % TEXTURE_RUN_CHOICES.toULong()).toInt()
        return Texture(effect, peak, run)
    }

    /** FNV-1a over the first song id (or "seed") xor the count. */
    fun fxSeed(firstSongId: String?, count: Int): ULong {
        var h = 0xcbf2_9ce4_8422_2325uL
        for (byte in (firstSongId ?: "seed").toByteArray(Charsets.UTF_8)) {
            h = (h xor (byte.toInt() and 0xFF).toULong()) * 0x0000_0100_0000_01B3uL
        }
        return h xor count.toULong()
    }

    // Phase align
    data class BeatRef(val bpm: Double?, val firstDownbeatMs: Int? = null, val beatsMs: List<Int>? = null)

    data class BeatPhase(val phase: Double, val beatSeconds: Double)

    /** Beat phase (fraction of a beat; negative before the first downbeat, like iOS) and beat length. */
    fun beatPhase(ref: BeatRef, position: Double): BeatPhase? {
        val bpm = ref.bpm ?: return null
        if (!(bpm > 0) || !bpm.isFinite()) return null
        val beats = ref.beatsMs
        if (beats != null && beats.size >= 2) {
            val ms = position * 1000
            if (ms >= beats[0].toDouble() && ms < beats[beats.size - 1].toDouble()) {
                var lo = 0
                var hi = beats.size - 1
                while (hi - lo > 1) {
                    val mid = (lo + hi) / 2
                    if (beats[mid].toDouble() <= ms) lo = mid else hi = mid
                }
                val len = (beats[lo + 1] - beats[lo]).toDouble()
                if (len > 0) return BeatPhase((ms - beats[lo].toDouble()) / len, len / 1000)
            }
        }
        val beat = 60.0 / bpm
        val db = (ref.firstDownbeatMs ?: 0).toDouble() / 1000.0
        // Kotlin's % is truncating, matching Swift's truncatingRemainder.
        return BeatPhase(((position - db) / beat) % 1.0, beat)
    }

    /** Seconds to move the INCOMING playhead so its beat phase lands on the outgoing's; 0 without BPMs. */
    fun phaseAlignOffset(
        outgoing: BeatRef, outgoingPosition: Double, incoming: BeatRef, incomingPosition: Double,
    ): Double {
        val lead = beatPhase(outgoing, outgoingPosition) ?: return 0.0
        val fol = beatPhase(incoming, incomingPosition) ?: return 0.0
        var delta = lead.phase - fol.phase
        if (delta > 0.5) delta -= 1 else if (delta < -0.5) delta += 1
        return delta * fol.beatSeconds
    }

    fun phaseAlignOffsetMs(
        outgoing: BeatRef, outgoingPositionMs: Double, incoming: BeatRef, incomingPositionMs: Double,
    ): Double = phaseAlignOffset(outgoing, outgoingPositionMs / 1000, incoming, incomingPositionMs / 1000) * 1000
}

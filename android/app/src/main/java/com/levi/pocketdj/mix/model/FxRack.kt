package com.levi.pocketdj.mix.model

import kotlin.math.exp
import kotlin.math.floor
import kotlin.math.log10
import kotlin.math.pow
import kotlin.math.sin

/**
 * One concrete flavour of an [Effect] family. Flat enum: the single [raw] string is what
 * persistence and the session timeline carry. [effect] is the invariant: a variant belongs to
 * exactly one family.
 */
enum class EffectVariant(val raw: String, val effect: Effect, val label: String, val longLabel: String) {
    LOW_PASS("lowPass", Effect.FILTER, "LP", "Low-pass"),
    HIGH_PASS("highPass", Effect.FILTER, "HP", "High-pass"),
    BAND_PASS("bandPass", Effect.FILTER, "BP", "Band-pass"),
    ROOM("room", Effect.REVERB, "Room", "Room"),
    HALL("hall", Effect.REVERB, "Hall", "Hall"),
    PLATE("plate", Effect.REVERB, "Plate", "Plate"),
    CATHEDRAL("cathedral", Effect.REVERB, "Cathedral", "Cathedral"),
    FLANGE("flange", Effect.FLANGER, "Flanger", "Flanger"),
    CHORUS("chorus", Effect.FLANGER, "Chorus", "Chorus"),
    ECHO("echo", Effect.FLANGER, "Echo", "Echo"),
    PUNCH("punch", Effect.COMPRESSOR, "Punch", "Punch"),
    GLUE("glue", Effect.COMPRESSOR, "Glue", "Glue"),
    LIMIT("limit", Effect.COMPRESSOR, "Limit", "Limit");

    companion object {
        fun fromRaw(s: String?): EffectVariant? = entries.firstOrNull { it.raw == s }

        /** Every variant of one family, in menu order. */
        fun all(effect: Effect): List<EffectVariant> = entries.filter { it.effect == effect }

        /** The variant a slot lands on when switched TO [effect] (reproduces pre-rack sound). */
        fun default(effect: Effect): EffectVariant = when (effect) {
            Effect.COMPRESSOR -> PUNCH
            Effect.REVERB -> HALL
            Effect.FLANGER -> FLANGE
            Effect.FILTER -> LOW_PASS
        }
    }
}

enum class ModSource(val raw: String, val label: String) {
    OFF("off", "Off"), LFO("lfo", "LFO"), ENVELOPE("envelope", "Env");

    companion object { fun fromRaw(s: String?) = entries.firstOrNull { it.raw == s } }
}

/** Beat-synced LFO rates in musical units; [beats] = cycle length in beats (4/4). */
enum class ModRate(val raw: String, val beats: Double, val label: String) {
    BAR("bar", 4.0, "1 bar"),
    HALF("half", 2.0, "1/2"),
    QUARTER("quarter", 1.0, "1/4"),
    QUARTER_TRIPLET("quarterTriplet", 2.0 / 3.0, "1/4T"),
    EIGHTH("eighth", 0.5, "1/8");

    companion object { fun fromRaw(s: String?) = entries.firstOrNull { it.raw == s } }
}

enum class ModShape(val raw: String) {
    SINE("sine"), TRIANGLE("triangle"), SAW("saw"), RAMP("ramp"), SQUARE("square");

    val label: String get() = raw.replaceFirstChar { it.uppercase() }

    companion object { fun fromRaw(s: String?) = entries.firstOrNull { it.raw == s } }
}

/** One slot's modulation configuration (user intent; the live value is runtime plumbing). */
data class SlotMod(
    val source: ModSource = ModSource.OFF,
    val rate: ModRate = ModRate.BAR,
    /** SIGNED depth -1..+1; negative inverts. */
    val depth: Double = 0.5,
    val shape: ModShape = ModShape.SINE,
    /** Cycle phase offset 0..<1. */
    val phase: Double = 0.0,
) {
    /** Normalised copy: depth clamped to -1..1, phase folded into 0..<1. */
    fun normalized(): SlotMod = copy(depth = depth.coerceIn(-1.0, 1.0), phase = phase - floor(phase))

    companion object {
        /** Mirror of the iOS validating init. */
        fun of(
            source: ModSource, rate: ModRate = ModRate.BAR, depth: Double = 0.5,
            shape: ModShape = ModShape.SINE, phase: Double = 0.0,
        ): SlotMod = SlotMod(source, rate, depth, shape, phase).normalized()
    }
}

/**
 * One of a deck's FX rack slots. Invariant `variant.effect == effect` is held by the
 * constructor (mismatch falls back to the family default) and the mutators. Immutable value:
 * mutators return a new slot.
 */
class FXSlot(
    effect: Effect,
    variant: EffectVariant? = null,
    val enabled: Boolean = false,
    strength: Double = 0.5,
    mod: SlotMod = SlotMod(),
) {
    val effect: Effect = effect
    /** Always normalised (depth -1..1, phase 0..<1), whatever construction path built it. */
    val mod: SlotMod = mod.normalized()
    val variant: EffectVariant = (variant ?: EffectVariant.default(effect)).let {
        if (it.effect == effect) it else EffectVariant.default(effect)
    }
    /** 0..1 user value; audible only while [enabled]. */
    val strength: Double = strength.coerceIn(0.0, 1.0)

    /** Switch family; variant resets to that family's default. Same family: unchanged. */
    fun setEffect(e: Effect): FXSlot =
        if (e == effect) this else FXSlot(e, null, enabled, strength, mod)

    /** Pick a variety of the SAME family; a cross-family variant is ignored. */
    fun setVariant(v: EffectVariant): FXSlot =
        if (v.effect != effect) this else FXSlot(effect, v, enabled, strength, mod)

    fun setStrength(v: Double): FXSlot = FXSlot(effect, variant, enabled, v, mod)
    fun setEnabled(on: Boolean): FXSlot = FXSlot(effect, variant, on, strength, mod)
    fun setMod(m: SlotMod): FXSlot = FXSlot(effect, variant, enabled, strength, m.normalized())

    override fun equals(other: Any?): Boolean =
        other is FXSlot && effect == other.effect && variant == other.variant &&
            enabled == other.enabled && strength == other.strength && mod == other.mod

    override fun hashCode(): Int = listOf(effect, variant, enabled, strength, mod).hashCode()
    override fun toString(): String = "FXSlot($effect/$variant enabled=$enabled strength=$strength mod=$mod)"
}

/** The rack's size and factory layout (the pre-rack grid order). */
object FxRack {
    const val SLOT_COUNT = 4

    fun defaultSlots(): List<FXSlot> = listOf(
        FXSlot(Effect.COMPRESSOR), FXSlot(Effect.REVERB), FXSlot(Effect.FLANGER), FXSlot(Effect.FILTER),
    )
}

/** Bounds-checked read: a stale slot index returns null instead of throwing. */
fun <T> List<T>.getSafe(i: Int): T? = if (i in indices) this[i] else null

/**
 * Pure variant to node-parameter mapping for every effect family, plus modulation math.
 * Port of iOS `FXParams`. Floats where iOS returned Float.
 */
object FxParams {
    enum class ModTarget { CUTOFF, WET_FEEDBACK }

    /** What modulation may MOVE per family; delayTime is deliberately never modulated. */
    fun modulates(e: Effect): ModTarget? = when (e) {
        Effect.FILTER -> ModTarget.CUTOFF
        Effect.FLANGER -> ModTarget.WET_FEEDBACK
        Effect.REVERB, Effect.COMPRESSOR -> null
    }

    /** Waveform value at [phase01] to 0..1. Saw FALLS, ramp rises, square is a half-cycle gate. */
    fun wave(shape: ModShape, phase01: Double): Double {
        val p = phase01 - floor(phase01)
        return when (shape) {
            ModShape.SINE -> (sin(2 * Math.PI * p - Math.PI / 2) + 1) / 2
            ModShape.TRIANGLE -> if (p < 0.5) p * 2 else 2 - p * 2
            ModShape.SAW -> 1 - p
            ModShape.RAMP -> p
            ModShape.SQUARE -> if (p < 0.5) 1.0 else 0.0
        }
    }

    /** User base strength plus the modulator offset, clamped 0..1; identity when off / depth 0. */
    fun modulated(base: Double, mod: SlotMod, phase01: Double?, env: Double): Double {
        val b = base.coerceIn(0.0, 1.0)
        if (mod.depth == 0.0) return b
        return when (mod.source) {
            ModSource.OFF -> b
            ModSource.LFO -> {
                val p = phase01 ?: return b
                val w = wave(mod.shape, p)
                (b + mod.depth * (w * 2 - 1)).coerceIn(0.0, 1.0)
            }
            ModSource.ENVELOPE -> (b + mod.depth * env.coerceIn(0.0, 1.0)).coerceIn(0.0, 1.0)
        }
    }

    /** Linear RMS to 0..1 drive over a fixed -40..0 dBFS window. */
    fun envelopeCurve(rms: Float): Double {
        if (!(rms > 0f)) return 0.0
        val db = 20 * log10(rms.toDouble())
        return ((db + 40) / 40).coerceIn(0.0, 1.0)
    }

    /** One-pole coefficient for time constant [tau] at step [dt]: 1 - exp(-dt/tau). */
    fun ballisticsCoef(dt: Double, tau: Double): Float {
        if (!(tau > 0) || !(dt > 0)) return 1f
        return (1 - exp(-dt / tau)).toFloat()
    }

    // Filter

    /** Cutoff / centre frequency (Hz) for a filter variant at strength [s]. */
    fun filterFrequency(v: EffectVariant, s: Double): Float {
        val c = s.coerceIn(0.0, 1.0)
        return when (v) {
            EffectVariant.LOW_PASS -> (18_000.0 * (250.0 / 18_000.0).pow(c)).toFloat()
            EffectVariant.HIGH_PASS -> (30.0 * (2_000.0 / 30.0).pow(c)).toFloat()
            EffectVariant.BAND_PASS -> (4_000.0 * (300.0 / 4_000.0).pow(c)).toFloat()
            else -> 1_000f
        }
    }

    /** Filter bandwidth in octaves: LP/HP 0.5; BP tightens 1.5 to 0.5. */
    fun filterBandwidth(v: EffectVariant, s: Double): Float =
        if (v == EffectVariant.BAND_PASS) (1.5 - 1.0 * s.coerceIn(0.0, 1.0)).toFloat() else 0.5f

    enum class FilterShape { RESONANT_LOW_PASS, RESONANT_HIGH_PASS, BAND_PASS }

    fun filterType(v: EffectVariant): FilterShape = when (v) {
        EffectVariant.HIGH_PASS -> FilterShape.RESONANT_HIGH_PASS
        EffectVariant.BAND_PASS -> FilterShape.BAND_PASS
        else -> FilterShape.RESONANT_LOW_PASS
    }

    // Reverb

    /** Reverb flavours (the Android reverb maps these to its own tank parameters). */
    enum class ReverbPreset { MEDIUM_ROOM, PLATE, CATHEDRAL, MEDIUM_HALL }

    fun reverbPreset(v: EffectVariant): ReverbPreset = when (v) {
        EffectVariant.ROOM -> ReverbPreset.MEDIUM_ROOM
        EffectVariant.PLATE -> ReverbPreset.PLATE
        EffectVariant.CATHEDRAL -> ReverbPreset.CATHEDRAL
        else -> ReverbPreset.MEDIUM_HALL
    }

    // Modulation delay

    /** Delay time (seconds). */
    fun modDelayTime(v: EffectVariant, s: Double): Double {
        val c = s.coerceIn(0.0, 1.0)
        return when (v) {
            EffectVariant.FLANGE -> 0.004
            EffectVariant.CHORUS -> 0.012 + 0.013 * c
            EffectVariant.ECHO -> 0.15 + 0.35 * c
            else -> 0.004
        }
    }

    /** Feedback (%). */
    fun modFeedback(v: EffectVariant, s: Double): Float {
        val c = s.coerceIn(0.0, 1.0).toFloat()
        return when (v) {
            EffectVariant.FLANGE -> c * 60
            EffectVariant.CHORUS -> c * 15
            EffectVariant.ECHO -> c * 70
            else -> c * 60
        }
    }

    /** Wet/dry mix (%). */
    fun modWetDryMix(v: EffectVariant, s: Double): Float {
        val c = s.coerceIn(0.0, 1.0).toFloat()
        return when (v) {
            EffectVariant.CHORUS -> c * 45
            else -> c * 50
        }
    }

    /** Low-pass cutoff (Hz) inside the delay. */
    fun modLowPassCutoff(v: EffectVariant): Float = when (v) {
        EffectVariant.CHORUS -> 12_000f
        EffectVariant.ECHO -> 8_000f
        else -> 15_000f
    }

    // Compressor

    fun compThreshold(v: EffectVariant, s: Double): Float {
        val c = s.coerceIn(0.0, 1.0).toFloat()
        return when (v) {
            EffectVariant.PUNCH -> -30 * c
            EffectVariant.GLUE -> -20 * c
            EffectVariant.LIMIT -> -20 * c
            else -> -30 * c
        }
    }

    fun compHeadRoom(v: EffectVariant): Float = when (v) {
        EffectVariant.GLUE -> 10f
        EffectVariant.LIMIT -> 0.5f
        else -> 5f
    }

    fun compAttack(v: EffectVariant): Float = when (v) {
        EffectVariant.GLUE -> 0.030f
        EffectVariant.LIMIT -> 0.001f
        else -> 0.020f
    }

    fun compRelease(v: EffectVariant): Float = when (v) {
        EffectVariant.GLUE -> 0.40f
        EffectVariant.LIMIT -> 0.05f
        else -> 0.15f
    }

    fun compMakeup(v: EffectVariant, s: Double): Float {
        val c = s.coerceIn(0.0, 1.0).toFloat()
        return when (v) {
            EffectVariant.GLUE -> 8 * c
            EffectVariant.LIMIT -> 6 * c
            else -> 15 * c
        }
    }
}

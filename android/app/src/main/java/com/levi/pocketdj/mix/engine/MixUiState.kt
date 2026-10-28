package com.levi.pocketdj.mix.engine

import com.levi.pocketdj.mix.model.Deck
import com.levi.pocketdj.mix.model.EQBand
import com.levi.pocketdj.mix.model.Effect
import com.levi.pocketdj.mix.model.FXSlot
import com.levi.pocketdj.mix.model.FxRack
import com.levi.pocketdj.mix.model.LoadedTrack
import com.levi.pocketdj.mix.model.MeterSource

/**
 * One deck's observable state (iOS `DeckState`). Hot values (playhead, VU) are deliberately NOT
 * here: they live in [DeckPositions] / `MixDeckLevels` and are polled, so a 10 Hz tick never
 * re-emits the [MixUiState] flow.
 */
data class DeckState(
    val loaded: LoadedTrack? = null,
    /** Analog shared-album seek offset (null for a per-song cut / digital file). */
    val startMs: Int? = null,
    /** Length of the scheduled window in seconds (0 = nothing loaded). */
    val durationSec: Double = 0.0,
    val isPlaying: Boolean = false,
    val volume: Double = 1.0,
    val rate: Double = 1.0,
    val pitch: Double = 0.0,
    /** Always exactly [FxRack.SLOT_COUNT] positional slots; duplicates are legal. */
    val slots: List<FXSlot> = FxRack.defaultSlots(),
    val stemMode: Boolean = false,
    val stemMuted: Set<String> = emptySet(),
    val stemVol: Map<String, Double> = emptyMap(),
    /** CUE / PFL send; cueVol is the independent monitor level. Both survive a deck reset. */
    val cued: Boolean = false,
    val cueVol: Double = 1.0,
    val loopOn: Boolean = false,
    val loopUnits: Double = 2.0,
    val eqLow: Double = 0.0,
    val eqMid: Double = 0.0,
    val eqHigh: Double = 0.0,
) {
    fun eqGain(b: EQBand): Double = when (b) { EQBand.LOW -> eqLow; EQBand.MID -> eqMid; EQBand.HIGH -> eqHigh }

    fun withEq(b: EQBand, db: Double): DeckState = when (b) {
        EQBand.LOW -> copy(eqLow = db); EQBand.MID -> copy(eqMid = db); EQBand.HIGH -> copy(eqHigh = db)
    }

    fun withSlot(i: Int, f: (FXSlot) -> FXSlot): DeckState =
        if (i !in slots.indices) this else copy(slots = slots.mapIndexed { k, s -> if (k == i) f(s) else s })

    /** Index of the first slot holding [e], or null if the rack has none of that family. */
    fun firstSlot(e: Effect): Int? = slots.indexOfFirst { it.effect == e }.takeIf { it >= 0 }

    // Effect-keyed shims (FIRST-MATCH): a read is "ANY slot of this family", a write hits the FIRST.
    fun isEnabled(e: Effect): Boolean = slots.any { it.effect == e && it.enabled }
    fun strength(e: Effect): Double = slots.firstOrNull { it.effect == e }?.strength ?: 0.5
    fun withEnabled(e: Effect, on: Boolean): DeckState = firstSlot(e)?.let { i -> withSlot(i) { it.setEnabled(on) } } ?: this
    fun withStrength(e: Effect, v: Double): DeckState = firstSlot(e)?.let { i -> withSlot(i) { it.setStrength(v) } } ?: this
}

/** The engine's whole observable surface. */
data class MixUiState(
    val a: DeckState = DeckState(),
    val b: DeckState = DeckState(),
    /** True iff EITHER deck is playing (drives the master transport). */
    val isRunning: Boolean = false,
    /** 0 = full A, 1 = full B, equal-power; centered so both loaded decks are audible. */
    val crossfader: Double = 0.5,
    /** Cue monitor on the right channel (house on the left) when true. */
    val cueOnRight: Boolean = true,
    /** Exclusive beat-match lead. */
    val leadDeck: Deck? = null,
    val meterSourceA: MeterSource = MeterSource.POST,
    val meterSourceB: MeterSource = MeterSource.POST,
) {
    fun deck(d: Deck): DeckState = if (d == Deck.A) a else b
    fun withDeck(d: Deck, s: DeckState): MixUiState = if (d == Deck.A) copy(a = s) else copy(b = s)
    fun meterSource(d: Deck): MeterSource = if (d == Deck.A) meterSourceA else meterSourceB
    val anyCued: Boolean get() = a.cued || b.cued
}

/**
 * Per-deck playhead (source seconds) and window length, outside the StateFlow: the seek slider
 * polls this ~10 Hz so a tick never recomposes the whole deck (iOS positionA/positionB).
 */
class DeckPositions {
    @Volatile private var pa = 0.0
    @Volatile private var pb = 0.0
    fun get(d: Deck): Double = if (d == Deck.A) pa else pb
    internal fun set(d: Deck, v: Double) { if (d == Deck.A) pa = v else pb = v }
}

/** The lock-screen / in-app "Now Playing" deck rule, as a pure function. */
object NowPlayingRule {
    /**
     * Exactly one deck playing -> that deck. Ambiguous (zero or both): stay with [last] if it
     * still has a track; else cold-start fallback A, then B. null only when neither is loaded.
     */
    fun pick(aLoaded: Boolean, bLoaded: Boolean, aPlaying: Boolean, bPlaying: Boolean, last: Deck?): Deck? {
        val ap = aLoaded && aPlaying
        val bp = bLoaded && bPlaying
        if (ap != bp) return if (ap) Deck.A else Deck.B
        if (last != null && (if (last == Deck.A) aLoaded else bLoaded)) return last
        if (aLoaded) return Deck.A
        return if (bLoaded) Deck.B else null
    }
}

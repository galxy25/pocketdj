package com.levi.pocketdj.mix.engine

import com.levi.pocketdj.mix.model.BeatMath
import com.levi.pocketdj.mix.model.Deck
import com.levi.pocketdj.mix.model.FXSlot
import com.levi.pocketdj.mix.model.FxParams
import com.levi.pocketdj.mix.model.LoadedTrack
import com.levi.pocketdj.mix.model.ModSource

/** Pure slot-modulation rules (iOS `effectiveStrength` / `modWanted` / `modFire`), separated for tests. */
object ModMath {
    /** The tick period: ~60 Hz. */
    const val TICK_MS = 16L
    /** Skip a node write when the live value moved less than this (idle LFO / flat envelope costs nothing). */
    const val DEAD_BAND = 0.002
    /** An envelope tap older than this reads as SILENCE (parked taps can never hold an effect open). */
    const val ENV_STALE_NANOS = 500_000_000L
    /** Cap on wall-clock extrapolation between playhead updates (a stalled engine can't run the phase away). */
    const val MAX_EXTRAPOLATION_SEC = 0.15

    /** A slot the tick must drive: enabled, a source selected, and a family modulation may move. */
    fun isLive(s: FXSlot): Boolean =
        s.enabled && s.mod.source != ModSource.OFF && FxParams.modulates(s.effect) != null

    /**
     * The strength the nodes should see: the stored value plus the modulator's offset. Modulation is
     * live ONLY while the deck plays (a paused deck sits exactly on the stored values); identity for
     * Reverb / Compressor and for source Off. [phase] null = nothing to lock to (LFO then holds base).
     */
    fun effectiveStrength(slot: FXSlot, playing: Boolean, phase: Double?, env: Double): Double {
        if (!playing || slot.mod.source == ModSource.OFF || FxParams.modulates(slot.effect) == null) return slot.strength
        return FxParams.modulated(slot.strength, slot.mod, phase, env)
    }

    /**
     * LFO cycle phase at SOURCE time [atSec] over the track's grid (measured beats/downbeats, else the
     * bpm + firstDownbeatMs lattice). Source time means a faster tempo shortens the wall cycle.
     */
    fun lfoPhase(track: LoadedTrack, slot: FXSlot, atSec: Double): Double? =
        BeatMath.cyclePhase(
            atMs = atSec * 1000.0,
            beatsMs = track.beatsMs, downbeatsMs = track.downbeatsMs,
            bpm = track.matchBpm ?: 0.0,
            firstDownbeatMs = track.firstDownbeatMs ?: 0,
            cycleBeats = slot.mod.rate.beats,
            offset = slot.mod.phase,
        )

    /** True when the LFO is riding the catalog/lattice estimate (no measured beats) - the sheet shows "est.". */
    fun isEstimated(track: LoadedTrack?): Boolean = track != null && track.beatsMs.isNullOrEmpty()

    /** True when an LFO can lock to nothing at all (no beats and no BPM) - the sheet shows a warning. */
    fun hasNoGrid(track: LoadedTrack?): Boolean =
        track == null || (track.beatsMs.isNullOrEmpty() && !((track.matchBpm ?: 0.0) > 0.0))

    /** The playhead for phase derivation: the sample-accurate one if served, else extrapolated position. */
    fun clockPosition(
        truePlayhead: Double?, position: Double, lastPos: Double?, stampNanos: Long?,
        nowNanos: Long, rate: Double,
    ): ClockStep {
        if (truePlayhead != null) return ClockStep(truePlayhead, truePlayhead, nowNanos)
        if (lastPos != position || stampNanos == null) return ClockStep(position, position, nowNanos)
        val elapsed = ((nowNanos - stampNanos) / 1e9).coerceIn(0.0, MAX_EXTRAPOLATION_SEC)
        return ClockStep(position + elapsed * rate, position, stampNanos)
    }

    data class ClockStep(val seconds: Double, val lastPos: Double, val stamp: Long)
}

/**
 * The ~60 Hz slot-modulation driver (iOS `modFire`). A SECOND tick, separate from the 10 Hz engine
 * tick: it runs only while a deck is playing with a live modulating slot, derives each LFO's phase
 * from the playhead every tick (never integrated, so jitter cannot drift), and writes NODE params
 * only through the engine's render snapshot. Stored strength, the session and the recorder are never
 * touched; delayTime is never moved (FxSlotNodes derives it from the BASE strength).
 *
 * Wiring: [install] sets `engine.slotStrengthProvider` (so every other write path, including the
 * Auto-DJ glide, composes with the wobble) and `engine.onSlotsChanged`.
 */
class ModController(
    private val engine: MixEngine,
    private val driver: TickDriver,
    private val hydrator: BeatGridHydrator? = null,
    private val nanoClock: () -> Long = System::nanoTime,
    private val playhead: (Deck) -> Double? = { engine.truePlayhead(it) },
    private val envelope: (Deck) -> Double = { d ->
        val f = engine.graph.deck(d).envelope
        if (System.nanoTime() - f.updatedAtNanos < ModMath.ENV_STALE_NANOS) f.value.toDouble() else 0.0
    },
) {
    private val phases = Array(Deck.entries.size) { arrayOfNulls<Double>(SLOTS) }
    private val written = Array(Deck.entries.size) { DoubleArray(SLOTS) { -1.0 } }
    private val wasActive = BooleanArray(Deck.entries.size)
    private val lastPos = arrayOfNulls<Double>(Deck.entries.size)
    private val stamp = arrayOfNulls<Long>(Deck.entries.size)
    private val lastDiagNanos = LongArray(Deck.entries.size)
    private var handle: AutoCloseable? = null

    /** Diagnostics for the emulator pass: one line per mod write burst (rate-limited by the caller's diag sink). */
    var diag: ((String) -> Unit)? = null

    val isTicking: Boolean get() = handle != null

    fun install() {
        engine.slotStrengthProvider = ::strengthFor
        engine.onSlotsChanged = ::onSlotsChanged
    }

    /** The live strength for one slot (mirrors read by every write path). */
    fun strengthFor(deck: Deck, i: Int, slot: FXSlot): Double {
        val playing = engine.deckState(deck).isPlaying
        if (!playing) return slot.strength
        val env = if (slot.mod.source == ModSource.ENVELOPE) envelope(deck) else 0.0
        return ModMath.effectiveStrength(slot, true, phases[deck.ordinal].getOrNull(i), env)
    }

    fun onSlotsChanged(deck: Deck, modChanged: Boolean) {
        if (modChanged) {
            val st = engine.deckState(deck)
            // Beat-synced LFO needs the MEASURED grid now: the lazy download is gated on the beat-pulse setting.
            if (st.slots.any { it.mod.source == ModSource.LFO }) {
                st.loaded?.let { hydrator?.hydrate(deck, it.songId, force = true) }
            }
        }
        startIfNeeded()
    }

    private fun wanted(): Boolean = Deck.entries.any { d ->
        val s = engine.deckState(d)
        s.isPlaying && s.slots.any(ModMath::isLive)
    }

    fun startIfNeeded() {
        if (handle != null || !wanted()) return
        handle = driver.start(ModMath.TICK_MS) { fire() }
    }

    fun stop() { handle?.close(); handle = null }

    /** One step. Returns false (and clears the handle) when nothing needs modulating any more. */
    internal fun fire(): Boolean {
        var anyLive = false
        val now = nanoClock()
        for (d in Deck.entries) {
            val di = d.ordinal
            val st = engine.deckState(d)
            val live = st.slots.indices.filter { ModMath.isLive(st.slots[it]) }
            if (!st.isPlaying || live.isEmpty()) {
                if (wasActive[di]) {
                    // SNAP-BACK: land every node on the stored strengths exactly once.
                    wasActive[di] = false
                    diag?.invoke("mod ${d.name} snap-back")
                    phases[di].fill(null); written[di].fill(-1.0)
                    engine.reapplySlots(d)
                }
                continue
            }
            anyLive = true
            val starting = !wasActive[di]
            wasActive[di] = true
            val step = ModMath.clockPosition(
                playhead(d), engine.position(d), lastPos[di], stamp[di], now, st.rate,
            )
            lastPos[di] = step.lastPos; stamp[di] = step.stamp
            val track = st.loaded
            var dirty = false
            for (i in live) {
                val slot = st.slots[i]
                phases[di][i] = if (slot.mod.source == ModSource.LFO && track != null)
                    ModMath.lfoPhase(track, slot, step.seconds) else null
                val eff = strengthFor(d, i, slot)
                if (diag != null && (starting || now - lastDiagNanos[di] >= DIAG_INTERVAL_NANOS)) {
                    lastDiagNanos[di] = now
                    diag?.invoke("mod ${d.name} slot$i src=${slot.mod.source.name.lowercase()} " +
                        "phase=${phases[di][i]?.let { "%.3f".format(it) } ?: "-"} base=${"%.3f".format(slot.strength)} eff=${"%.3f".format(eff)}")
                }
                if (kotlin.math.abs(eff - written[di][i]) >= ModMath.DEAD_BAND) {
                    written[di][i] = eff
                    dirty = true
                }
            }
            if (dirty) engine.params.setSlots(d, engine.slotParamList(d))
        }
        if (!anyLive && wasActive.none { it }) { handle = null; return false }
        return true
    }

    private companion object { const val SLOTS = 4; const val DIAG_INTERVAL_NANOS = 500_000_000L }
}

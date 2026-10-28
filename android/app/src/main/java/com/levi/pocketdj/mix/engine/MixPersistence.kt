package com.levi.pocketdj.mix.engine

import com.levi.pocketdj.mix.model.Effect
import com.levi.pocketdj.mix.model.FXSlot
import com.levi.pocketdj.mix.model.FilterMode
import com.levi.pocketdj.mix.model.EffectVariant
import com.levi.pocketdj.mix.store.AutoSnapshot
import com.levi.pocketdj.mix.store.DeckSnapshot
import com.levi.pocketdj.mix.store.FXSlotSnapshot
import com.levi.pocketdj.mix.store.MixDeckSnapshot
import com.levi.pocketdj.mix.store.TrackRef

/**
 * Live state <-> durable snapshot, as pure functions (the engine owns WHEN to persist / restore).
 *
 * Persisted: per-deck track identity + playhead + volume/tempo/pitch/effects/stem/loop/EQ state,
 * crossfader, lead deck, the Auto-DJ queue. EXCLUDED on purpose (iOS invariant): cue/PFL routing
 * and cue volume (transient monitoring state), recording state, VU/taps, beat grids (re-derived
 * by the normal load path), and in-flight transition state.
 */
object MixPersistence {
    /** `lengthMs` round-trips the playback WINDOW so an analog shared-album fallback re-windows. */
    fun deckSnapshot(s: DeckState, positionMs: Int): DeckSnapshot? {
        val l = s.loaded ?: return null
        val lengthMs = if (s.durationSec > 0) (s.durationSec * 1000).toInt() else null
        val filterMode = s.firstSlot(Effect.FILTER)?.let { s.slots[it].variant }
            .let { if (it == EffectVariant.HIGH_PASS) FilterMode.HIGH_PASS else FilterMode.LOW_PASS }
        return DeckSnapshot(
            track = TrackRef(l.songId, l.title, l.artist, l.bpm, l.camelot, l.key, l.albumId, lengthMs),
            positionMs = positionMs,
            volume = s.volume, rate = s.rate, pitch = s.pitch,
            // Flat fields = the rollback contract (an older build knows nothing about slots).
            compressor = s.isEnabled(Effect.COMPRESSOR), reverb = s.isEnabled(Effect.REVERB),
            flanger = s.isEnabled(Effect.FLANGER), filter = s.isEnabled(Effect.FILTER),
            compStrength = s.strength(Effect.COMPRESSOR), reverbStrength = s.strength(Effect.REVERB),
            flangerStrength = s.strength(Effect.FLANGER), filterStrength = s.strength(Effect.FILTER),
            stemMode = s.stemMode, stemMuted = s.stemMuted.sorted(), stemVol = s.stemVol,
            loopOn = s.loopOn, loopUnits = s.loopUnits,
            eqLow = s.eqLow, eqMid = s.eqMid, eqHigh = s.eqHigh,
            filterMode = filterMode.raw,
            // The rack's lossless form (duplicates, varieties, mod).
            fxSlots = s.slots.map { FXSlotSnapshot.from(it) },
        )
    }

    /** nil when there is nothing to restore (both decks empty and no auto queue). */
    fun snapshot(
        a: DeckSnapshot?, b: DeckSnapshot?, crossfader: Double, leadDeck: String?,
        auto: AutoSnapshot?, wasRunning: Boolean, nowMs: Long,
    ): MixDeckSnapshot? {
        if (a == null && b == null && auto == null) return null
        return MixDeckSnapshot(
            deckA = a, deckB = b, crossfader = crossfader, leadDeck = leadDeck,
            auto = auto, wasRunning = wasRunning, updatedAt = nowMs.toDouble(),
        )
    }

    /** The rack to apply on restore (lossless slots, or the pre-rack flat fields migrated). */
    fun restoredSlots(ds: DeckSnapshot): List<FXSlot> = ds.resolvedSlots.map { it.toSlot() }

    /** A deck persisted AT its end has nothing left to schedule: re-cue it and mark it exhausted. */
    fun atEnd(positionMs: Int, lengthMs: Int?): Boolean = lengthMs != null && lengthMs > 0 && positionMs >= lengthMs - 500

    /** What a parked (not yet materialized) restore WOULD show, without touching audio. */
    data class ParkedSummary(val title: String?, val artist: String?, val autoLabel: String?, val hasAuto: Boolean)

    fun parkedSummary(snap: MixDeckSnapshot): ParkedSummary {
        val liveRaw = snap.auto?.liveDeck ?: snap.leadDeck ?: (if (snap.deckA != null) "A" else "B")
        val live = if (liveRaw == "B") (snap.deckB ?: snap.deckA) else (snap.deckA ?: snap.deckB)
        return ParkedSummary(
            live?.track?.title, live?.track?.artist, snap.auto?.sourceLabel,
            snap.auto?.queue?.isNotEmpty() == true,
        )
    }
}

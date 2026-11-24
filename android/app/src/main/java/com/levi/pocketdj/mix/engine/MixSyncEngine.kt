package com.levi.pocketdj.mix.engine

import com.levi.pocketdj.mix.model.Deck
import com.levi.pocketdj.mix.model.EQBand
import com.levi.pocketdj.mix.model.Effect
import com.levi.pocketdj.mix.model.EffectVariant
import com.levi.pocketdj.mix.model.FXSlot
import com.levi.pocketdj.mix.model.FxRack
import com.levi.pocketdj.mix.model.LoadedTrack
import com.levi.pocketdj.mix.model.MixRanges
import com.levi.pocketdj.mix.model.ModRate
import com.levi.pocketdj.mix.model.ModShape
import com.levi.pocketdj.mix.model.ModSource
import com.levi.pocketdj.mix.model.SlotMod
import com.levi.pocketdj.mix.store.DeckSnapshot
import com.levi.pocketdj.remote.mix.MixSyncEvent
import com.levi.pocketdj.remote.mix.MixSyncKind

/**
 * One LOCAL gesture as the multiplayer layer hears it (iOS `MixEngine.Gesture`): the `MixSessionEvent` fields. [kind] is
 * a `MixEventKind.raw`, or one of the sync-only kinds below (gestures the session log never recorded as such).
 */
data class Gesture(
    val kind: String,
    val deck: Deck? = null,
    val param: String? = null,
    val value: Double? = null,
    val flag: Boolean? = null,
    val slot: Int? = null,
    val posMs: Int? = null,
    /** `load` only: the track that took the deck. */
    val track: LoadedTrack? = null,
    val lengthMs: Int? = null,
    /** `loop` / `loopUnits` only: the exact window (source ms) the loop holds; every device loops THESE frames. */
    val loopStartMs: Int? = null,
    val loopEndMs: Int? = null,
    /** WHO caused it. Only [Cause.USER] is a DJ's gesture the session may share. */
    val cause: Cause = Cause.USER,
) {
    enum class Cause {
        /** A hand on this device's Mix UI. */
        USER,

        /** The SYSTEM's transport for this device (lock screen / headset / Auto / Assistant, an audio-focus loss): a local pause/resume only. */
        SYSTEM,

        /** The engine itself (a watchdog retiring a silent deck, a sink rebuild, a zero-length deck, teardown). Never shared. */
        ENGINE,
    }

    companion object {
        const val LOAD = "load"
        const val EJECT = "eject"
        const val LOOP = "loop"
        const val LOOP_UNITS = "loopUnits"
    }
}

/**
 * The Mix engine's multiplayer seams (iOS `MixEngine` "Multiplayer Mix" section). The engine knows nothing about sessions,
 * owners or the wire: it offers a TAP that reports every local gesture, a GUARD under which remote events are applied
 * through the ordinary public setters (no tap, no session-log record, so nothing echoes and the corpus stays this DJ's own
 * hands), a SCHEDULED START so every device starts a deck on the same instant, and an Auto-DJ BLOCK. The audio graph is
 * untouched. Main thread only.
 */
interface MixSyncEngine {
    /** Every local gesture (null = no session listening). Never fires for a remote apply, a restore, or a compound gesture's parts. */
    var gestureTap: ((Gesture) -> Unit)?

    /** True while a REMOTE event is being applied (a depth counter: nested applies stay guarded). */
    val isApplyingRemote: Boolean

    /** Apply a remote participant's event: everything [body] does through the public setters is neither tapped nor session-logged. */
    fun applyingRemote(body: () -> Unit)

    /** Run [body] as a NON-user cause: every transport it drives taps with [cause] (outermost non-user wins). */
    fun caused(cause: Gesture.Cause, body: () -> Unit)

    /**
     * SCHEDULED START: cue [deck] at [fromMs] (source ms) and start it so that source frame SOUNDS at [atLocalMs] (a local
     * wall-clock epoch ms), fired early by the output path's latency. A start too close (or already past) is pushed out to
     * the minimum lead and the cue moved forward by the gap x rate. A looping deck folds the cue into its window.
     */
    fun syncPlay(deck: Deck, fromMs: Int, atLocalMs: Double)

    /** The drift loop's temporary rate multiplier (clamped to +-1 %); 1.0 clears it. Multiplies the user's tempo. */
    fun syncNudgeRate(deck: Deck, factor: Double)

    /** Engage / re-place the loop on EXACTLY `[startMs, endMs)` (the owner's window). `on == false` releases it. */
    fun syncSetLoop(deck: Deck, on: Boolean, units: Double?, startMs: Int?, endMs: Int?)

    /**
     * Drive the deck's whole board to EXACTLY [controls] (the model's latest event per control, in host order) folded over
     * a fresh deck's defaults; unlisted controls reset to default. DIFFED: an in-sync deck hears nothing. Loop + transport
     * are the caller's; cue / PFL stays this device's.
     */
    fun syncSetControls(deck: Deck, controls: List<MixSyncEvent>)

    /** The deck's whole board as session events (load -> controls), built from the same snapshot the durable session persists. */
    fun syncSeedEvents(deck: Deck): List<MixSyncEvent>

    /** A multiplayer session drives the decks: the durable session is suspended; the user's own mix is given back when it ends. */
    fun syncSessionActive(on: Boolean)

    /** Why the Auto-DJ is unavailable (a multiplayer session owns the decks), else null. */
    fun setAutoDjBlocked(reason: String?)

    /** A Remote CONTROLLER plays nothing here: every deck goes quiet (a running Auto-DJ is suspended). */
    fun silenceForRemoteController()

    /** What the listener HEARS at this instant, source seconds: the playhead backed off by output latency x rate, folded into a loop. */
    fun audiblePlayhead(deck: Deck): Double

    /** Seconds from a rendered frame to the listener's ears (the scheduled start fires this much early). */
    val outputLatencySeconds: Double

    /** Whether [deck] holds [songId] and can sound it now (loaded and not waiting on bytes): the multiplayer readiness report. */
    fun deckReady(deck: Deck, songId: String): Boolean

    /** The armed loop's window in source ms, else null: what a `loop` gesture shares. */
    fun loopWindowMs(deck: Deck): Pair<Int, Int>?
}

/** What the engine needs from the loop / stem controllers (MIX-8) for the sync seams; installed by [MixDeckExtras]. */
interface SyncExtras {
    fun setLoopExact(deck: Deck, on: Boolean, units: Double?, startMs: Int?, endMs: Int?)
    fun setStemMode(deck: Deck, on: Boolean)
    fun toggleStemMute(deck: Deck, name: String)
    fun setStemVolume(deck: Deck, name: String, v: Double)
}

/** The sync seams' pure arithmetic. */
object MixSyncMath {
    /** The shortest a scheduled start waits: the stem-start lead, so every voice lands on one frame. */
    const val MIN_LEAD = DeckController.START_LEAD

    /** The longest a scheduled start waits (a skewed / bogus instant must not park a deck silent for seconds). */
    const val MAX_LEAD = 2.0

    /** The drift nudge's bound: +-1 %. */
    const val NUDGE_MIN = 0.99
    const val NUDGE_MAX = 1.01

    /** The lead a requested [desired] one actually schedules: at least [MIN_LEAD], at most [MAX_LEAD]. */
    fun scheduledLead(desired: Double): Double = minOf(maxOf(MIN_LEAD, desired), maxOf(MIN_LEAD, MAX_LEAD))

    /** Seconds from [nowLocalMs] to [atLocalMs], less the output path's [latencySeconds] (fire early). */
    fun desiredLead(atLocalMs: Double, nowLocalMs: Double, latencySeconds: Double): Double =
        (atLocalMs - nowLocalMs) / 1000.0 - latencySeconds

    /**
     * The source second the deck must sit at when it STARTS (the scheduled lead may exceed [desiredLead]; the cue moves
     * forward by the gap x rate so the deck sounds where it would have been, never late by the gap).
     */
    fun cueSeconds(fromMs: Int, lead: Double, desiredLead: Double, rate: Double, durationSec: Double): Double =
        (fromMs / 1000.0 + (lead - desiredLead) * rate).coerceIn(0.0, maxOf(0.0, durationSec))

    /** Where the deck must be RIGHT NOW for [fromMs] to sound at the desired instant (the immediate-start fallback). */
    fun nowSeconds(fromMs: Int, desiredLead: Double, rate: Double): Double = fromMs / 1000.0 - desiredLead * rate

    /** Input-clock frames a deck consumes over [leadSeconds] of wall time at [rate] (the stretcher pulls rate x input per output frame). */
    fun inputLeadSeconds(leadSeconds: Double, rate: Double): Double = leadSeconds * rate

    /** The nudge actually applied: clamped to [NUDGE_MIN]..[NUDGE_MAX]; 1.0 (within 1e-9) means "none". */
    fun clampNudge(factor: Double): Double = factor.coerceIn(NUDGE_MIN, NUDGE_MAX)

    fun isNeutral(factor: Double): Boolean = Math.abs(factor - 1.0) < 1e-9

    /** [sec] folded into the loop window [start, end): forwards and backwards. */
    fun foldIntoLoop(sec: Double, start: Double, end: Double): Double {
        val len = end - start
        if (len <= 0) return sec
        val r = (sec - start) % len
        return start + (if (r < 0) r + len else r)
    }

    /** The exact loop window the owner sent, bounded to the deck; null when it is degenerate. */
    fun exactWindow(startMs: Int, endMs: Int, durationSec: Double): Pair<Double, Double>? {
        if (endMs <= startMs) return null
        val s = startMs / 1000.0
        val e = if (durationSec > 0) minOf(endMs / 1000.0, durationSec) else endMs / 1000.0
        return if (e > s) s to e else null
    }
}

/** A deck's whole board as the session sets it (what [SyncBoardFold] resolves). */
data class SyncBoard(
    val rate: Double,
    val pitch: Double,
    val volume: Double,
    val eqLow: Double,
    val eqMid: Double,
    val eqHigh: Double,
    val slots: List<FXSlot>,
    val stemMode: Boolean,
    val stemMuted: Set<String>,
    val stemVol: Map<String, Double>,
    val lead: Boolean,
) {
    fun eqGain(b: EQBand): Double = when (b) { EQBand.LOW -> eqLow; EQBand.MID -> eqMid; EQBand.HIGH -> eqHigh }
}

/** Resolves the session's control events over a fresh deck's defaults (iOS `syncSetControls` fold). Pure. */
object SyncBoardFold {
    private fun band(param: String?): EQBand? = EQBand.entries.firstOrNull { it.label.equals(param, ignoreCase = true) }

    /** [curSlots] is only read for an `effectMod`'s phase (a local LFO's phase is kept). */
    fun fold(controls: List<MixSyncEvent>, curSlots: List<FXSlot> = FxRack.defaultSlots()): SyncBoard {
        var rate = 1.0; var pitch = 0.0; var volume = 1.0
        var eqLow = 0.0; var eqMid = 0.0; var eqHigh = 0.0
        var slots: List<FXSlot> = FxRack.defaultSlots()
        var stemMode = false
        val muted = LinkedHashSet<String>()
        val stemVol = LinkedHashMap<String, Double>()
        var lead = false

        fun slotIndex(e: MixSyncEvent): Int? {
            e.slot?.let { return it }
            val fx = Effect.fromRaw(e.param) ?: return null
            return slots.indexOfFirst { it.effect == fx }.takeIf { it >= 0 }
        }
        fun edit(i: Int?, f: (FXSlot) -> FXSlot) {
            if (i == null || i !in slots.indices) return
            slots = slots.mapIndexed { k, s -> if (k == i) f(s) else s }
        }

        for (e in controls) {
            when (e.kind) {
                MixSyncKind.TEMPO, MixSyncKind.SYNC -> e.value?.let { rate = it.coerceIn(MixRanges.rate.start, MixRanges.rate.endInclusive) }
                "pitch" -> e.value?.let { pitch = it.coerceIn(MixRanges.pitch.start, MixRanges.pitch.endInclusive) }
                "volume" -> e.value?.let { volume = it.coerceIn(MixRanges.volume.start, MixRanges.volume.endInclusive) }
                "eq" -> {
                    val v = e.value
                    val b = band(e.param)
                    if (v != null && b != null) {
                        val g = v.coerceIn(MixRanges.eq.start, MixRanges.eq.endInclusive)
                        when (b) { EQBand.LOW -> eqLow = g; EQBand.MID -> eqMid = g; EQBand.HIGH -> eqHigh = g }
                    }
                }
                "effectToggle" -> { val on = e.flag ?: continue; edit(slotIndex(e)) { it.setEnabled(on) } }
                "effectStrength" -> { val v = e.value ?: continue; edit(slotIndex(e)) { it.setStrength(v) } }
                "effectSlot" -> {
                    val i = e.slot
                    val fx = Effect.fromRaw(e.param)
                    if (i != null && fx != null) edit(i) { it.setEffect(fx) }
                }
                "effectVariant" -> {
                    val i = e.slot
                    val v = EffectVariant.fromRaw(e.param)
                    if (i != null && v != null) edit(i) { it.setVariant(v) }
                }
                "effectMod" -> {
                    val i = e.slot ?: continue
                    val parts = e.param?.split(":") ?: continue
                    if (parts.size != 3) continue
                    val src = ModSource.fromRaw(parts[0]) ?: continue
                    val r = ModRate.fromRaw(parts[1]) ?: continue
                    val shape = ModShape.fromRaw(parts[2]) ?: continue
                    val phase = curSlots.getOrNull(i)?.mod?.phase ?: 0.0
                    edit(i) { it.setMod(SlotMod(src, r, e.value ?: 0.5, shape, phase)) }
                }
                "filterMode" -> {
                    val hp = e.param == "highPass"
                    val lp = e.param == "lowPass"
                    val i = slots.indexOfFirst { it.effect == Effect.FILTER }
                    if ((hp || lp) && i >= 0) edit(i) { it.setVariant(if (hp) EffectVariant.HIGH_PASS else EffectVariant.LOW_PASS) }
                }
                "stemMode" -> e.flag?.let { stemMode = it }
                "stemMute" -> {
                    val name = e.param ?: continue
                    val m = e.flag ?: continue
                    if (m) muted.add(name) else muted.remove(name)
                }
                "stemVolume" -> {
                    val name = e.param ?: continue
                    val v = e.value ?: continue
                    stemVol[name] = v.coerceIn(0.0, 1.0)
                }
                MixSyncKind.LEAD -> lead = e.flag ?: false
                else -> Unit
            }
        }
        return SyncBoard(rate, pitch, volume, eqLow, eqMid, eqHigh, slots, stemMode, muted, stemVol, lead)
    }
}

/** A deck's snapshot as session events (iOS `syncDeckStateEvents`). Pure. */
object SyncSeed {
    /** [loopMs] is the armed window in source ms (only emitted with `loopOn`). Transport is the caller's. */
    fun events(deck: Deck, ds: DeckSnapshot, lead: Boolean, loopMs: Pair<Int, Int>?): List<MixSyncEvent> {
        val d = deck.label
        val out = ArrayList<MixSyncEvent>()
        val t = ds.track
        out += MixSyncEvent(
            kind = MixSyncKind.LOAD, deck = d, songId = t.songId, title = t.title, artist = t.artist, bpm = t.bpm,
            camelot = t.camelot, key = t.key, albumId = t.albumId, lengthMs = t.lengthMs,
        )
        out += MixSyncEvent(kind = MixSyncKind.TEMPO, deck = d, value = ds.rate)
        out += MixSyncEvent(kind = "pitch", deck = d, value = ds.pitch)
        out += MixSyncEvent(kind = "volume", deck = d, value = ds.volume)
        out += MixSyncEvent(kind = "eq", deck = d, param = "low", value = ds.eqLow ?: 0.0)
        out += MixSyncEvent(kind = "eq", deck = d, param = "mid", value = ds.eqMid ?: 0.0)
        out += MixSyncEvent(kind = "eq", deck = d, param = "high", value = ds.eqHigh ?: 0.0)
        ds.resolvedSlots.forEachIndexed { i, sl ->
            out += MixSyncEvent(kind = "effectSlot", deck = d, param = sl.effect, slot = i)
            out += MixSyncEvent(kind = "effectVariant", deck = d, param = sl.variant, slot = i)
            out += MixSyncEvent(kind = "effectToggle", deck = d, param = sl.effect, flag = sl.on, slot = i)
            out += MixSyncEvent(kind = "effectStrength", deck = d, param = sl.effect, value = sl.strength, slot = i)
            val mod = sl.resolvedMod
            if (mod.source != ModSource.OFF) {
                out += MixSyncEvent(
                    kind = "effectMod", deck = d, param = "${mod.source.raw}:${mod.rate.raw}:${mod.shape.raw}",
                    value = mod.depth, slot = i,
                )
            }
        }
        out += MixSyncEvent(kind = "stemMode", deck = d, flag = ds.stemMode)
        for (name in ds.stemMuted) out += MixSyncEvent(kind = "stemMute", deck = d, param = name, flag = true)
        for ((name, v) in ds.stemVol.entries.sortedBy { it.key }) out += MixSyncEvent(kind = "stemVolume", deck = d, param = name, value = v)
        if (lead) out += MixSyncEvent(kind = MixSyncKind.LEAD, deck = d, flag = true)
        if (ds.loopOn == true) {
            out += MixSyncEvent(
                kind = MixSyncKind.LOOP, deck = d, value = ds.loopUnits, flag = true,
                loopStartMs = loopMs?.first, loopEndMs = loopMs?.second,
            )
        }
        return out
    }
}

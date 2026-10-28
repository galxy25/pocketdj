package com.levi.pocketdj.mix.engine

import com.levi.pocketdj.mix.model.BeatGrid
import com.levi.pocketdj.mix.model.BeatMath
import com.levi.pocketdj.mix.model.Deck
import com.levi.pocketdj.mix.model.LoadedTrack
import com.levi.pocketdj.mix.model.roundAway
import com.levi.pocketdj.mix.store.DeckSnapshot
import kotlin.math.floor
import kotlin.math.max
import kotlin.math.min

/** Which edge of a loop window a nudge moves. */
enum class LoopEdge { START, END }

/** A loop window in SOURCE seconds. */
typealias LoopWindow = Pair<Double, Double>

/**
 * Pure loop (infinity) math, ported from iOS `MixEngine` (loopUsesBeats / loopUnitSeconds /
 * loopBounds / loopWindowMath / clampLoopWindow / nudge / loopSchedulable). No audio, no engine.
 */
object LoopMath {
    const val MIN_UNITS = 1.0
    const val MAX_UNITS = 32.0
    /** A sub-50 ms window is a click, not a loop. */
    const val MIN_WINDOW_SEC = 0.05

    /** Does this track count loop length in BEATS? A measured grid (>= 2 beats) or any usable bpm; else SECONDS. */
    fun usesBeats(l: LoadedTrack?): Boolean {
        if (l == null) return false
        if ((l.beatsMs?.size ?: 0) >= 2) return true
        return (l.gridBpm ?: l.bpm ?: 0.0) > 0
    }

    /**
     * One loop unit in seconds: the MEDIAN gap of the measured lattice first (the async grid hydrate can
     * patch beats WITHOUT a gridBpm, and the window walks that same lattice), else a beat at the grid
     * tempo (clamped 20...300), else exactly 1 s.
     */
    fun unitSeconds(l: LoadedTrack?): Double {
        if (!usesBeats(l)) return 1.0
        val beats = l?.beatsMs
        if (beats != null && beats.size >= 2) {
            val gaps = beats.zipWithNext { a, b -> (b - a).toDouble() }.filter { it > 0 }.sorted()
            if (gaps.isNotEmpty()) {
                val median = gaps[gaps.size / 2]
                if (median > 0) return median / 1000.0
            }
        }
        val bpm = l?.gridBpm ?: l?.bpm ?: 120.0
        return 60.0 / min(max(bpm, 20.0), 300.0)
    }

    /**
     * Fit a window inside the deck: floor length [MIN_WINDOW_SEC] and, when it would overrun the end,
     * SLIDE back rather than shrink (a 4-beat loop stays 4 beats engaged in the last bar).
     */
    fun clampWindow(start: Double, end: Double, durationSec: Double): LoopWindow? {
        if (durationSec <= 0) return null
        var s = start
        val len = min(max(end - s, MIN_WINDOW_SEC), durationSec)
        var e = s + len
        if (e > durationSec) { e = durationSec; s = max(0.0, e - len) }
        if (s < 0) { s = 0.0; e = min(durationSec, len) }
        return if (e > s) s to e else null
    }

    /** Snap [anchorSec] back to the previous unit boundary off [phaseSec], then run [units] forward. */
    fun windowMath(anchorSec: Double, phaseSec: Double, unitSeconds: Double, units: Double, durationSec: Double): LoopWindow? {
        if (!(unitSeconds > 0) || !(units > 0) || !(durationSec > 0)) return null
        val anchor = min(max(0.0, anchorSec), durationSec)
        val rel = anchor - phaseSec
        val start = if (rel >= 0) phaseSec + floor(rel / unitSeconds) * unitSeconds else phaseSec
        return clampWindow(start, start + units * unitSeconds, durationSec)
    }

    /**
     * The window for [units] around [anchorSec]: START snaps back to the previous unit boundary (the beat
     * you are in, or the previous whole second) and runs [units] forward. A measured grid drives both
     * edges through [BeatMath] (real tempo drift is honored); else the lattice is synthesized from bpm +
     * downbeat phase. Clamped into the deck, sliding back rather than shrinking.
     */
    fun bounds(l: LoadedTrack?, units: Double, anchorSec: Double, durationSec: Double): LoopWindow? {
        if (durationSec <= 0) return null
        val u = min(max(units, MIN_UNITS), MAX_UNITS)
        val anchor = min(max(0.0, anchorSec), durationSec)
        if (!usesBeats(l)) return windowMath(anchor, 0.0, 1.0, u, durationSec)
        val bpm = l?.gridBpm ?: l?.bpm ?: 120.0
        val period = unitSeconds(l)
        val beats = l?.beatsMs
        if (beats != null && beats.size >= 2) {
            val anchorMs = anchor * 1000
            val prevMs = BeatMath.lastBeat(beats, l.downbeatsMs, anchorMs)?.beatMs
            val startMs = (prevMs ?: anchorMs.toInt()).toDouble()
            val sb = BeatMath.sliceBoundaries(
                roundAway(startMs).toInt(), u, BeatGrid(bpm, l.firstDownbeatMs ?: 0, beats),
            )
            val start: Double
            val end: Double
            if (sb != null) { start = sb.startMs / 1000.0; end = sb.endMs / 1000.0 }
            else { start = startMs / 1000; end = start + u * period }
            return clampWindow(start, end, durationSec)
        }
        return windowMath(anchor, (l?.firstDownbeatMs ?: 0) / 1000.0, period, u, durationSec)
    }

    data class Nudged(val window: LoopWindow, val units: Double)

    /**
     * Move one EDGE by +-[deltaUnits] units. Both edges stay inside the deck; the window is clamped to
     * 1...32 units (clamping only the derived count would let repeated nudges grow a 40-unit loop while
     * the stored length reads 32, after which the slider's equality guard makes the mismatch unfixable).
     */
    fun nudge(w: LoopWindow, edge: LoopEdge, deltaUnits: Double, unit: Double, durationSec: Double): Nudged? {
        val step = unit * deltaUnits
        var s = w.first
        var e = w.second
        when (edge) {
            LoopEdge.START -> s = min(max(0.0, s + step), e - unit)
            LoopEdge.END -> e = min(max(e + step, s + unit), durationSec)
        }
        val maxLen = MAX_UNITS * unit
        if (e - s > maxLen) { if (edge == LoopEdge.START) s = e - maxLen else e = s + maxLen }
        if (e <= s) return null
        val units = min(max(Math.round((e - s) / unit).toDouble(), MIN_UNITS), MAX_UNITS)
        return Nudged(s to e, units)
    }

    /** The playhead may be re-used as a resume point only strictly inside the window (20 ms margins). */
    fun resumeInside(here: Double?, w: LoopWindow): Boolean = here != null && here > w.first + 0.02 && here < w.second - 0.02

    /**
     * Would the window play on a voice with this reach? [frontierSec] null = complete files. A loop on
     * STREAMING stems must hold the WHOLE window (a pass cut short at their frontier would play a
     * shorter loop than the playhead folds over, and could never top up past it).
     */
    fun schedulable(w: LoopWindow, frontierSec: Double?, endSec: Double): Boolean {
        if (!(w.second > w.first)) return false
        if (frontierSec != null && w.second > frontierSec) return false
        return min(w.second, endSec) > w.first
    }
}

/**
 * Loop (infinity) controller: repeat a beat/second window until released. The window lives on the
 * [com.levi.pocketdj.audio.core.Voice] itself (the decoder wraps frame-exactly and the position counter
 * folds identically), so unlike iOS there is no segment queue to top up and no timeline-reset guard.
 *
 * Order is load-bearing: prove the window is schedulable BEFORE touching any voice, and commit loopOn
 * only on success (a refused window leaves the deck exactly as it was, never lit-but-silent).
 */
class LoopController(
    private val core: EngineCore,
    private val stems: StemController? = null,
    var hydrator: BeatGridHydrator? = null,
) {
    private val windows = HashMap<Deck, LoopWindow>()

    /** Persistence/UI nudge after a window change. */
    private fun persist(debounced: Boolean) = core.persist(debounced)

    fun loopOn(deck: Deck): Boolean = core.deckState(deck).loopOn
    fun loopUnits(deck: Deck): Double = core.deckState(deck).loopUnits
    fun loopUsesBeats(deck: Deck): Boolean = LoopMath.usesBeats(core.deckState(deck).loaded)
    fun loopUnitSeconds(deck: Deck): Double = LoopMath.unitSeconds(core.deckState(deck).loaded)

    /** The live window (null unless a loop is armed). Also the engine tick's fold provider. */
    fun loopWindow(deck: Deck): LoopWindow? {
        if (!core.deckState(deck).loopOn) return null
        val w = windows[deck] ?: return null
        return if (w.second > w.first) w else null
    }

    private fun here(deck: Deck): Double = core.controller(deck).trueSeconds() ?: core.position(deck)

    private fun bounds(deck: Deck, anchor: Double): LoopWindow? {
        val s = core.deckState(deck)
        return LoopMath.bounds(s.loaded, s.loopUnits, anchor, core.duration(deck))
    }

    /** Forget everything about a deck's loop: the ONE teardown (load, restart/reset, clear, release). */
    fun clear(deck: Deck) {
        if (core.deckState(deck).loopOn) core.updateDeck(deck) { it.copy(loopOn = false) }
        windows.remove(deck)
        core.controller(deck).setLoopSeconds(null, includeStems = true)
    }

    /** Would the window play on the deck's stems (frontier + reach)? */
    fun schedulableOnStems(deck: Deck, w: LoopWindow): Boolean {
        val reach = stems?.reach(deck) ?: return false
        return LoopMath.schedulable(w, reach.frontierSec, reach.endSec)
    }

    private fun schedulable(deck: Deck, w: LoopWindow, onStems: Boolean): Boolean =
        if (onStems) schedulableOnStems(deck, w)
        else w.second > w.first && w.second <= core.duration(deck) + 1e-6

    /** (Re)apply the deck's window to its voices. [resumeAt] strictly inside keeps the playhead where it is. */
    private fun armLoop(deck: Deck, resumeAt: Double? = null): Boolean {
        val w = loopWindow(deck) ?: return false
        val c = core.controller(deck)
        if (!c.isOpen) return false
        val onStems = stems?.active(deck) == true
        if (!schedulable(deck, w, onStems)) return false   // <- check before any voice is touched
        stems?.settleStemFade(deck)
        val keepLive = LoopMath.resumeInside(resumeAt, w)
        val target = if (keepLive) resumeAt!! else w.first
        c.setLoopSeconds(w, includeStems = onStems)
        // A rendering voice carries its own live position through setLoop; anything else (paused, or a
        // fresh window start) is positioned explicitly.
        if (!(keepLive && core.deckState(deck).isPlaying && core.isRendering)) c.seekSeconds(target)
        core.setPosition(deck, target)
        return true
    }

    /** Re-apply the loop to the voices that just became the deck's carrier (a stem handover). */
    fun rearmForHandover(deck: Deck) {
        if (loopWindow(deck) == null) return
        armLoop(deck, resumeAt = here(deck))
    }

    /** Engage / release the loop. */
    fun setLoop(deck: Deck, on: Boolean) {
        val s = core.deckState(deck)
        val loaded = s.loaded ?: return
        if (on == s.loopOn) return
        if (on) {
            hydrator?.hydrate(deck, loaded.songId, force = true)   // beats need the grid NOW
            val anchor = here(deck)
            val w = bounds(deck, anchor) ?: return
            core.updateDeck(deck) { it.copy(loopOn = true) }
            windows[deck] = w
            if (!armLoop(deck, resumeAt = anchor)) {
                clear(deck)
                core.diag("loop ON ${deck.label} REFUSED - window not schedulable")
                return
            }
            core.diag(
                "loop ON ${deck.label} ${fmt(w.first)}-${fmt(w.second)}s " +
                    "(${core.deckState(deck).loopUnits.toInt()} ${if (loopUsesBeats(deck)) "beat" else "sec"})",
            )
        } else {
            val resume = here(deck)
            clear(deck)
            core.seek(deck, resume)   // the rest of the track carries on; re-times the auto-mix end via the seek hook
            core.diag("loop OFF ${deck.label} -> ${fmt(resume)}s")
        }
        persist(debounced = false)
    }

    /** Set the loop LENGTH in units (1...32). Keeps the window start; re-arms when live. */
    fun setLoopUnits(deck: Deck, units: Double) {
        val u = min(max(Math.round(units).toDouble(), LoopMath.MIN_UNITS), LoopMath.MAX_UNITS)
        if (u == core.deckState(deck).loopUnits) return
        core.updateDeck(deck) { it.copy(loopUnits = u) }
        val w = windows[deck]
        if (core.deckState(deck).loopOn && w != null) {
            val nw = bounds(deck, w.first)
            if (nw != null) {
                // Keep playing where we are: a length slider re-arms per step.
                val h = here(deck)
                windows[deck] = nw
                armLoop(deck, resumeAt = if (h > nw.first && h < nw.second) h else null)
            }
        }
        persist(debounced = true)
    }

    /** Nudge one EDGE by +-[deltaUnits] units (the popover arrows); loopUnits follows the new length. */
    fun nudgeLoop(deck: Deck, edge: LoopEdge, deltaUnits: Double) {
        val w = loopWindow(deck) ?: return
        val n = LoopMath.nudge(w, edge, deltaUnits, loopUnitSeconds(deck), core.duration(deck)) ?: return
        val h = here(deck)
        windows[deck] = n.window
        core.updateDeck(deck) { it.copy(loopUnits = n.units) }
        armLoop(deck, resumeAt = if (h > n.window.first && h < n.window.second) h else null)
        persist(debounced = true)
    }

    /** Scrubbing while LOOPED moves the loop to where the playhead was dropped. */
    fun onSeeked(deck: Deck, sec: Double) {
        if (!core.deckState(deck).loopOn) return
        val nw = bounds(deck, sec) ?: return
        windows[deck] = nw
        armLoop(deck, resumeAt = null)
        persist(debounced = true)
    }

    /** The beat grid landed after the loop was armed on synthesized beats: re-resolve on the real lattice. */
    fun reresolve(deck: Deck) {
        if (loopWindow(deck) == null) return
        val h = here(deck)
        val nw = bounds(deck, h) ?: return
        windows[deck] = nw
        armLoop(deck, resumeAt = if (h > nw.first && h < nw.second) h else null)
    }

    /** Durable-session restore: length first, then engage around the restored playhead. */
    fun restore(deck: Deck, ds: DeckSnapshot) {
        ds.loopUnits?.let { u ->
            core.updateDeck(deck) { it.copy(loopUnits = min(max(Math.round(u).toDouble(), 1.0), 32.0)) }
        }
        if (ds.loopOn == true) setLoop(deck, true)
    }

    private fun fmt(x: Double) = String.format(java.util.Locale.US, "%.2f", x)
}

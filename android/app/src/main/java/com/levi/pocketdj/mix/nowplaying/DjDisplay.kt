package com.levi.pocketdj.mix.nowplaying

import com.levi.pocketdj.mix.model.Effect
import com.levi.pocketdj.mix.model.MixRanges
import com.levi.pocketdj.playback.dj.AutoTransition
import com.levi.pocketdj.playback.dj.DjLeveling
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.asStateFlow
import java.util.Locale
import kotlin.math.abs

/**
 * P2-DJ-12 (iOS `DJAutomationDisplay`): what the Now Playing controls SHOW while DJ automation drives them. Read-only:
 * the listener's own values (the engine's rate / pitch / effect slots, FX Lock carry, the snapshot, settings) never
 * see these. A touch acts on what is shown ([DjDisplayTouch]) and ends the glide.
 */
data class DjFxShown(val on: Boolean, val strength: Double)

/** One song's leveling as heard: its status and the trim on it right now (dB; moves through the 2 s ramp). */
data class DjLevelSide(val status: DjLeveling.Status, val trimDb: Double)

/**
 * The leveling readout: the shown song's trim, and during a crossfade the outgoing's trim fading out ([outGain]) against
 * the incoming's coming in ([inGain]) - equal-power.
 */
data class DjLevelingReadout(
    val current: DjLevelSide,
    val outgoing: DjLevelSide? = null,
    val outGain: Double = 0.0,
    val inGain: Double = 1.0,
) {
    /** The row is hidden when DJ is not leveling the song at all (DJ off, a plain row). */
    val visible: Boolean get() = current.status != DjLeveling.Status.INACTIVE || outgoing != null

    companion object { val NONE = DjLevelingReadout(DjLevelSide(DjLeveling.Status.INACTIVE, 0.0)) }
}

data class DjDisplay(
    /** Automation is driving the controls right now (a transition, or a hand-back's ease). */
    val active: Boolean = false,
    /** The tempo HEARD on the song the controls show (pre-roll: the outgoing; from the fade start: the incoming). */
    val rate: Double = 1.0,
    /** Semitones heard (listener's + the glide's). */
    val pitch: Double = 0.0,
    /** Effects heard: the listener's own, or the transition's sweep on an effect the listener has off. Absent = off. */
    val effects: Map<Effect, DjFxShown> = emptyMap(),
    /** 0 = all outgoing .. 1 = all incoming (0 through the pre-roll, 1 after the fade). */
    val crossfade: Double = 0.0,
    /** `idle` / `preRoll` / `fade` / `postRoll`; `ease` on a hand-back. */
    val phase: String = "idle",
    val leveling: DjLevelingReadout = DjLevelingReadout.NONE,
) {
    /** What the TEMPO control shows: the automated tempo while automation runs, else the listener's. */
    fun shownRate(listener: Double): Double = if (active) rate else listener
    fun shownPitch(listener: Double): Double = if (active) pitch else listener

    /** What an effect control shows: while automating, the heard state (absent = off); else the listener's own. */
    fun shownEffect(e: Effect, listenerOn: Boolean, listenerStrength: Double): DjFxShown =
        if (!active) DjFxShown(listenerOn, listenerStrength)
        else effects[e] ?: DjFxShown(false, listenerStrength)

    companion object { val IDLE = DjDisplay() }
}

/** What a touch on a control does while a display is up (the touch acts on what is SHOWN). */
object DjDisplayTouch {
    /** A tap on an effect flips the SHOWN state (tapping a swept effect turns it off). */
    fun tapTargetOn(shown: DjFxShown): Boolean = !shown.on

    /** A strength drag on a swept effect (shown on, listener off) first turns the listener's effect on so it stays on. */
    fun strengthDragNeedsEnable(shown: DjFxShown, listenerOn: Boolean): Boolean = shown.on && !listenerOn
}

/** The pure parts of publishing the display (JVM-tested). */
object DjDisplayMath {
    /** ~16 Hz while automation runs. */
    const val INTERVAL_MS = 62L

    const val RATE_EPS = 0.0005
    const val PITCH_EPS = 0.005
    const val XFADE_EPS = 0.005
    const val LEVEL_DB_EPS = 0.05
    const val LEVEL_GAIN_EPS = 0.01

    fun phaseName(phase: DjPhase, easing: Boolean): String = when {
        phase == DjPhase.PREROLL -> "preRoll"
        phase == DjPhase.FADING -> "fade"
        phase == DjPhase.POSTROLL -> "postRoll"
        easing -> "ease"
        else -> "idle"
    }

    /** Crossfade 0..1 for a phase: 0 through the pre-roll, the fade's progress, 1 after (post-roll and hand-back ease). */
    fun crossfade(phase: DjPhase, fadeProgress: Double): Double = when (phase) {
        DjPhase.PREROLL -> 0.0
        DjPhase.FADING -> fadeProgress.coerceIn(0.0, 1.0)
        else -> 1.0
    }

    /**
     * The effects as heard: every listener-ON slot at its strength, plus the transition's sweep ([texture]) on an effect
     * the listener has off. [listener] holds the listener's ON effects only.
     */
    fun heardEffects(listener: Map<Effect, Double>, texture: Pair<Effect, Double>?): Map<Effect, DjFxShown> {
        val out = LinkedHashMap<Effect, DjFxShown>()
        for ((e, s) in listener) out[e] = DjFxShown(true, s)
        if (texture != null && texture.first !in out) out[texture.first] = DjFxShown(true, texture.second)
        return out
    }

    fun clampPitch(p: Double): Double = p.coerceIn(MixRanges.pitch.start, MixRanges.pitch.endInclusive)

    /** The leveling readout while idle / pre-roll / post-roll (one song) or crossfading (outgoing -> incoming, equal-power). */
    fun levelingReadout(phase: DjPhase, current: DjLevelSide, outgoing: DjLevelSide?, fadeProgress: Double): DjLevelingReadout {
        if (phase == DjPhase.FADING && outgoing != null) {
            val g = AutoTransition.equalPowerGains(fadeProgress.coerceIn(0.0, 1.0).toFloat())
            return DjLevelingReadout(current, outgoing, g.outgoing.toDouble(), g.incoming.toDouble())
        }
        return DjLevelingReadout(current)
    }

    private fun near(a: DjLevelSide?, b: DjLevelSide?): Boolean = when {
        a == null && b == null -> true
        a != null && b != null -> a.status == b.status && abs(a.trimDb - b.trimDb) < LEVEL_DB_EPS
        else -> false
    }

    /** Keep [prev] unless the leveling readout changed by something a 0.1 dB readout / the meter can show. */
    fun settleLeveling(prev: DjLevelingReadout, next: DjLevelingReadout): DjLevelingReadout =
        if (near(prev.current, next.current) && near(prev.outgoing, next.outgoing) &&
            abs(prev.outGain - next.outGain) < LEVEL_GAIN_EPS && abs(prev.inGain - next.inGain) < LEVEL_GAIN_EPS) prev else next

    /** Field-wise: keep what has not moved by a visible amount (no redraw for float noise). */
    fun settle(prev: DjDisplay, next: DjDisplay): DjDisplay {
        val xf = if (abs(prev.crossfade - next.crossfade) > XFADE_EPS ||
            ((next.crossfade == 0.0 || next.crossfade == 1.0) && prev.crossfade != next.crossfade)) next.crossfade else prev.crossfade
        return DjDisplay(
            active = next.active,
            rate = if (abs(prev.rate - next.rate) > RATE_EPS) next.rate else prev.rate,
            pitch = if (abs(prev.pitch - next.pitch) > PITCH_EPS) next.pitch else prev.pitch,
            effects = if (prev.effects == next.effects) prev.effects else next.effects,
            crossfade = xf,
            phase = next.phase,
            leveling = settleLeveling(prev.leveling, next.leveling),
        )
    }
}

/** The leveling readout's words (iOS `DJLevelingReadoutRow.words`). */
object DjLevelingText {
    fun words(side: DjLevelSide): String = when (side.status) {
        DjLeveling.Status.MEASURED, DjLeveling.Status.ESTIMATED -> {
            val db = db(side.trimDb)
            if (side.status == DjLeveling.Status.ESTIMATED) "≈ $db" else db
        }
        DjLeveling.Status.MEASURING -> "measuring…"
        DjLeveling.Status.OFF -> "off"
        DjLeveling.Status.UNAVAILABLE -> "unavailable"
        DjLeveling.Status.INACTIVE -> "—"
    }

    /** "+3.2 dB" / "−4.5 dB" (a true minus sign) / "0.0 dB". */
    fun db(v: Double): String =
        if (abs(v) < 0.05) "0.0 dB" else String.format(Locale.US, "%s%.1f dB", if (v > 0) "+" else "−", abs(v))

    /** The row's one-line text: "+3.2 dB", or "−4.5 dB → +3.2 dB" during a crossfade. */
    fun line(r: DjLevelingReadout): String =
        r.outgoing?.let { "${words(it)} → ${words(r.current)}" } ?: words(r.current)

    /** TalkBack value. */
    fun a11y(r: DjLevelingReadout): String =
        r.outgoing?.let { "${words(it)} fading to ${words(r.current)}" } ?: words(r.current)

    /** Meter bars (trim dB, weight 0..1, live) - only measured / estimated sides draw. */
    data class Bar(val db: Double, val weight: Double, val live: Boolean)

    fun bars(r: DjLevelingReadout): List<Bar> {
        fun shows(s: DjLevelSide) = s.status == DjLeveling.Status.MEASURED || s.status == DjLeveling.Status.ESTIMATED
        val out = ArrayList<Bar>()
        r.outgoing?.takeIf(::shows)?.let { out += Bar(it.trimDb, r.outGain, false) }
        if (shows(r.current)) out += Bar(r.current.trimDb, if (r.outgoing == null) 1.0 else r.inGain, true)
        return out
    }
}

/** The published display (a StateFlow the panel and the DJ chip bind). Single-writer: the engine, on the main thread. */
class DjDisplayHub {
    private val _flow = MutableStateFlow(DjDisplay.IDLE)
    val flow: StateFlow<DjDisplay> = _flow.asStateFlow()
    val value: DjDisplay get() = _flow.value

    fun publish(next: DjDisplay) { _flow.value = DjDisplayMath.settle(_flow.value, next) }

    /** Leveling only (idle ramps, status changes). */
    fun publishLeveling(r: DjLevelingReadout) {
        val cur = _flow.value
        val settled = DjDisplayMath.settleLeveling(cur.leveling, r)
        if (settled !== cur.leveling) _flow.value = cur.copy(leveling = settled)
    }

    /** Automation ended: the controls show the listener's values again; the leveling readout stays. */
    fun clear(leveling: DjLevelingReadout = _flow.value.leveling) {
        publish(DjDisplay(leveling = leveling))
    }
}

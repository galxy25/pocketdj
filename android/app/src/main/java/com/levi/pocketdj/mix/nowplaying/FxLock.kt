package com.levi.pocketdj.mix.nowplaying

import com.levi.pocketdj.diag.NPLog
import com.levi.pocketdj.mix.model.Effect
import com.levi.pocketdj.playback.durable.SessionFxLock
import com.levi.pocketdj.playback.durable.SessionFxSetting
import com.levi.pocketdj.playback.sequencer.SessionExtra
import com.levi.pocketdj.playback.sequencer.SessionExtraKey
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.asStateFlow
import kotlinx.serialization.json.JsonObject

/**
 * FX LOCK - "keep my effects across tracks" for a Now Playing playback SESSION (iOS `FXLock.swift`, the sibling of
 * [StemLock]).
 *
 * Off (default): the Now Playing mini-mix controls reset on every track change. On: the EFFECTS state of the playing
 * track (each of the four effects' on/off and strength) CARRIES to every following track; tempo, pitch and gain do
 * NOT carry. The carry is captured from USER effect actions only ([NowPlayingDspEngine.onUserEffectChange]).
 *
 * With at least one carried effect ON ([FxLockState.wantsFX]) a mixable track engages the DSP at its start and the
 * effects RAMP IN from transparent over [RAMP_SECONDS]. A row the DSP cannot own plays dry under [Indicator.WAITING]
 * and the lock carries on; a live Mix-tab session leaves it [Indicator.DORMANT].
 *
 * SESSION scope, exactly like the Stem Lock: stored in the durable session under `fxLock` (iOS JSON), restored held
 * with it, CLEARED by a new session and by stop. Skips, edits and restore keep it.
 */
object FxLock {
    /** How long carried effects take to come up from transparent (iOS `NowPlayingDSP.fxRampSeconds`). */
    const val RAMP_SECONDS = 0.25
    /** Ramp resolution (iOS `fxRampSteps`). */
    const val RAMP_STEPS = 12
    /** Strength writes (a slider drag fires per tick) reach the disk after this quiet period (iOS 400 ms). */
    const val PERSIST_DEBOUNCE_MS = 400L

    /** The effect keys this build can apply (equal to iOS `MixEngine.Effect.rawValue`). */
    val knownKeys: Set<String> = Effect.entries.map { it.raw }.toSet()

    /** One `fxlock` line on the Now Playing trace lane (song ids only, never titles). */
    fun log(message: String) { NPLog.lane(NPLog.NP, "fxlock $message") }

    /** What the Now Playing surfaces show for the lock on the CURRENT track. */
    enum class Indicator {
        /** The lock is off. */
        OFF,
        /** Locked, carrying no effect that is on (or nothing playing yet): nothing to apply. */
        IDLE,
        /** Locked with effects, and the DSP owns this track: the carried effects are on air. */
        APPLIED,
        /** Locked with effects, but THIS track plays outside the DSP: dry for now. */
        WAITING,
        /** Locked with effects while a Mix-tab session is live: dormant (one DSP surface). */
        DORMANT,
    }
}

/**
 * The persisted FX Lock state (iOS `FXLockState`). [effects] is keyed by the raw effect name; only effects moved off
 * neutral are listed. Keys a newer build added stay in the map (and on disk), and are ignored on apply.
 */
data class FxLockState(
    val enabled: Boolean = false,
    val effects: Map<String, SessionFxSetting> = emptyMap(),
    /** Top-level keys of the stored object this build does not know (kept verbatim on re-encode). */
    val unknownKeys: JsonObject = JsonObject(emptyMap()),
) {
    /** Lock on AND at least one KNOWN carried effect ON: the only state that changes playback or downloads. */
    val wantsFX: Boolean get() = enabled && effects.any { (k, v) -> v.on && k in FxLock.knownKeys }

    /** One-line summary for the trace (`fx=reverb:0.70,filter:0.30` - ON effects only, sorted). */
    val logSummary: String
        get() {
            val on = effects.filter { it.value.on }.keys.sorted()
            if (on.isEmpty()) return "fx=none"
            return "fx=" + on.joinToString(",") { "$it:${"%.2f".format(java.util.Locale.US, effects[it]?.strength ?: 0.5)}" }
        }

    /** The durable-session shape. */
    fun toSession(): SessionFxLock = SessionFxLock(enabled = enabled, effects = effects, unknownKeys = unknownKeys)

    companion object {
        fun fromSession(s: SessionFxLock?): FxLockState =
            if (s == null) FxLockState()
            else FxLockState(
                enabled = s.enabled,
                effects = s.effects.mapValues { (_, v) -> v.copy(strength = v.strength.coerceIn(0.0, 1.0)) },
                unknownKeys = s.unknownKeys,
            )
    }
}

/**
 * The session-scoped lock: carry state and the pure indicator rule (iOS `SetlistPlayer.fxLock*`). Main thread.
 * Registered as the `fxLock` [SessionExtra] of the sequencer's session. [onChanged] fires after every change
 * (`debounced` = a mid-track strength drag, which the owner coalesces).
 */
class FxLockSession(private val onChanged: (debounced: Boolean) -> Unit = {}) : SessionExtra<SessionFxLock> {
    private val _state = MutableStateFlow(FxLockState())
    val state: StateFlow<FxLockState> = _state.asStateFlow()
    val current: FxLockState get() = _state.value

    /** True while the lock itself drives the DSP (its writes must not re-capture as USER changes). */
    var applying = false

    /** Something was set or restored this session: an off state is then WRITTEN (it must overwrite a stored ON). */
    private var touched = false

    /** Turn the lock on (capturing the CURRENT effects, [snapshot]) or off (forgetting them). */
    fun setLock(on: Boolean, snapshot: Map<String, SessionFxSetting>) {
        val keep = current.unknownKeys
        _state.value = if (on) FxLockState(enabled = true, effects = snapshot, unknownKeys = keep) else FxLockState(unknownKeys = keep)
        touched = true
        onChanged(false)
    }

    /**
     * A USER effect action: [snapshot] is the engine's whole effect state. Returns true when the carry changed.
     * Effects this build does not know stay as stored.
     */
    fun onUserEffectChange(snapshot: Map<String, SessionFxSetting>): Boolean {
        val st = current
        if (!st.enabled || applying) return false
        val merged = st.effects.filterKeys { it !in FxLock.knownKeys } + snapshot.filterKeys { it in FxLock.knownKeys }
        if (merged == st.effects) return false
        _state.value = st.copy(effects = merged)
        onChanged(true)
        return true
    }

    /** A new session / stop: unlocked, nothing carried, nothing stored. */
    fun reset() {
        if (current.enabled) FxLock.log("lock cleared (session ended / new session)")
        _state.value = FxLockState()
        touched = false
    }

    override val key: SessionExtraKey<SessionFxLock> get() = SessionExtraKey.FX_LOCK

    /** Null until the lock was ever used this session, so a session that never touched it stays byte-identical on disk. */
    override fun write(): SessionFxLock? = if (touched || current.enabled) current.toSession() else null

    /** HELD restore: the state comes back and nothing is armed. */
    override fun restoreHeld(value: SessionFxLock) {
        _state.value = FxLockState.fromSession(value)
        touched = true
    }

    companion object {
        /** The indicator rule (iOS `fxLockIndicator`). [engaged]: the DSP owns the current track. */
        fun indicator(
            state: FxLockState, currentSongId: String?, heldForResume: Boolean, engaged: Boolean, mixSessionActive: Boolean,
        ): FxLock.Indicator {
            if (!state.enabled) return FxLock.Indicator.OFF
            if (!state.wantsFX || currentSongId == null || heldForResume) return FxLock.Indicator.IDLE
            if (engaged) return FxLock.Indicator.APPLIED
            if (mixSessionActive) return FxLock.Indicator.DORMANT
            return FxLock.Indicator.WAITING
        }

        /**
         * The strength scale of effect ramp step [step] of [steps] (1-based): 0 -> 1 linearly; the ramp's
         * last step lands exactly on the set strength.
         */
        fun rampScale(step: Int, steps: Int = FxLock.RAMP_STEPS): Double =
            if (steps <= 0) 1.0 else (step.toDouble() / steps).coerceIn(0.0, 1.0)
    }
}

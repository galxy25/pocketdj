package com.levi.pocketdj.playback.dj

import com.levi.pocketdj.playback.durable.SessionDjMode
import com.levi.pocketdj.playback.sequencer.SequencerListener
import com.levi.pocketdj.playback.sequencer.SessionEndReason
import com.levi.pocketdj.playback.sequencer.SessionExtra
import com.levi.pocketdj.playback.sequencer.SessionExtraKey
import com.levi.pocketdj.playback.sequencer.SourceRef
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.asStateFlow
import kotlinx.serialization.json.JsonObject

/** Is a Remote session (Listen Together / Backseat) attached? P2-REM-5 binds the real one; the default never is. */
interface RemoteSessionProbe {
    val active: Boolean
    val activeFlow: StateFlow<Boolean>

    object Inactive : RemoteSessionProbe {
        override val active: Boolean get() = false
        override val activeFlow: StateFlow<Boolean> = MutableStateFlow(false)
    }
}

/**
 * The engine side of DJ Mode (planner replan, DSP arm / leveling). Empty defaults: the engine packages (P2-DJ-7/8/10)
 * bind real ones; this shell only decides WHEN each runs.
 */
interface DjEngineHooks {
    /** DJ turned ON or resumed: seed/refresh membership, request a replan and engage + arm + level the current local row. */
    fun applyOnTrackStart(liveClock: Boolean) {}

    /** DJ OFF or suspended: cancel the replan task, disarm the transition engine, leveling inactive. */
    fun disarm() {}

    /** DJ turned OFF or suspended while Mix Mode's DSP is engaged: ramp the level back to 0 dB (the track carries on). */
    fun levelToZero() {}

    /** The session's planner seed became known (first ON, or a restore arming): prime the planner PRNG. */
    fun plannerSeeded(seed: ULong) {}

    /** The engine's DJ status (mixing / next ready / buffering / no-mix reason); null = [DjMode.Indicator.NextReady]. */
    fun indicator(): DjMode.Indicator? = null

    companion object { val None: DjEngineHooks = object : DjEngineHooks {} }
}

/** Why DJ Mode is on but not acting. Remote wins when both hold (iOS `djIndicator` order). */
enum class DjSuspension { NONE, MIX_TAB, REMOTE }

/**
 * DJ MODE, session side (np-dj-mode; iOS `SetlistPlayer.setDJMode` / `resetDJMode` / `observeRemoteSessionForDJ`).
 *
 * A [SequencerListener] plus the durable-session extra `djMode`:
 *  - ON turns Mix Mode on, seeds the planner (`fxSeed` over the queue), and asks the engine to replan + engage;
 *  - OFF disarms and levels back to 0 dB; the playing track carries on;
 *  - Mix Mode turning off turns DJ off ([onMixModeChanged]);
 *  - a new play / stop / replaced run clears it; a held restore brings it back HELD (nothing arms until first play);
 *  - SUSPENDED while the Mix tab runs or a Remote session is attached: [djActive] is false, the arm and leveling go,
 *    and resuming re-engages the playing row exactly like turning DJ on.
 *
 * Main-thread only, like the sequencer.
 */
class DjModeController(
    private val ports: Ports,
    private val engine: DjEngineHooks = DjEngineHooks.None,
    var remote: RemoteSessionProbe = RemoteSessionProbe.Inactive,
) : SequencerListener, SessionExtra<SessionDjMode> {

    interface Ports {
        val running: Boolean
        val held: Boolean
        val sessionId: String?
        val currentSongId: String?
        val mixTabActive: Boolean
        val mixModeEnabled: Boolean

        /** The session's Mix Mode switch (the coordinator's `setMixMode`). */
        fun setMixMode(on: Boolean)
        val queueFirstSongId: String?
        val queueCount: Int

        /** Mix Mode exists on this device (always, on Android). */
        val supported: Boolean get() = true

        /** Persist the durable session now. */
        fun persist()
        fun log(line: String) {}
    }

    private val _state = MutableStateFlow(DJModeState())

    /** The session's DJ Mode (what the chip and menus observe). */
    val state: StateFlow<DJModeState> = _state.asStateFlow()
    val enabled: Boolean get() = _state.value.enabled

    private var restoredSinceStart = false
    private var restoredUnknownKeys: JsonObject? = null
    private var lastSuspension = DjSuspension.NONE

    val suspension: DjSuspension
        get() = when {
            !enabled -> DjSuspension.NONE
            remote.active -> DjSuspension.REMOTE
            ports.mixTabActive -> DjSuspension.MIX_TAB
            else -> DjSuspension.NONE
        }

    /** DJ Mode is on AND allowed to act now (supported, not held, Mix tab idle, no Remote session). */
    val djActive: Boolean
        get() = ports.supported && enabled && ports.running && !ports.held && !ports.mixTabActive && !remote.active

    /** What the Mix panel's DJ status shows. */
    fun indicator(): DjMode.Indicator {
        if (!enabled || !ports.running) return DjMode.Indicator.Off
        return when (suspension) {
            DjSuspension.REMOTE -> DjMode.Indicator.SuspendedRemote
            DjSuspension.MIX_TAB -> DjMode.Indicator.Suspended
            DjSuspension.NONE -> engine.indicator() ?: DjMode.Indicator.NextReady
        }
    }

    // ---- toggle -------------------------------------------------------------------------------------------------

    /** Turn the session's DJ Mode on/off (iOS `setDJMode`). No-op with no session or when unchanged. */
    fun setDjMode(on: Boolean) {
        if (!ports.running || enabled == on || (on && !ports.supported)) return
        _state.value = _state.value.copy(enabled = on)
        log("mode ${if (on) "ON" else "OFF"} session=${ports.sessionId ?: "-"} song=${ports.currentSongId ?: "-"}")
        if (on) {
            if (!ports.mixModeEnabled) ports.setMixMode(true)
            if (_state.value.planner == null) {
                val seed = AutoTransition.fxSeed(ports.queueFirstSongId, ports.queueCount)
                _state.value = _state.value.copy(planner = DjPlannerState(seed).toJson())
            }
            lastSuspension = suspension
            plannerSeed()?.let { engine.plannerSeeded(it) }
            // Suspended (Mix tab / Remote): switched on but nothing arms until the suspension ends.
            if (lastSuspension == DjSuspension.NONE && !ports.held) engine.applyOnTrackStart(liveClock = true)
        } else {
            lastSuspension = DjSuspension.NONE
            engine.disarm()
            engine.levelToZero()
        }
        ports.persist()
    }

    fun toggleDjMode() = setDjMode(!enabled)

    /** Mix Mode switched: turning it OFF turns DJ off (np-dj-mode §1). Call BEFORE the lane re-plans. */
    fun onMixModeChanged(mixEnabled: Boolean) {
        if (!mixEnabled && enabled) setDjMode(false)
    }

    /** New session / stop: DJ off, its selector state forgotten. */
    fun resetDjMode() {
        if (enabled) log("mode cleared (session ended / new session)")
        _state.value = DJModeState()
        lastSuspension = DjSuspension.NONE
        engine.disarm()
    }

    // ---- suspension ---------------------------------------------------------------------------------------------

    /** The Mix tab started / stopped, or the Remote probe flipped: re-evaluate the suspension. */
    fun onSuspensionInputsChanged() {
        if (!enabled || !ports.running) return
        val now = suspension
        if (now == lastSuspension) return
        val was = lastSuspension
        lastSuspension = now
        if (now != DjSuspension.NONE) {
            log(if (now == DjSuspension.REMOTE) "remote session attached - DJ Mode paused" else "mix tab live - DJ Mode paused")
            engine.disarm()
            engine.levelToZero()
        } else if (!ports.held) {
            log("${if (was == DjSuspension.REMOTE) "remote session ended" else "mix tab idle"} - DJ Mode resumes")
            engine.applyOnTrackStart(liveClock = true)
        }
    }

    // ---- SequencerListener --------------------------------------------------------------------------------------

    override fun onSessionStarted(sessionId: String, source: SourceRef) {
        restoredSinceStart = false
        restoredUnknownKeys = null
        resetDjMode() // a fresh play never starts with DJ on; a HELD restore overwrites right after (restoreHeld/onHeld)
    }

    override fun onSessionEnded(reason: SessionEndReason) {
        restoredSinceStart = false
        restoredUnknownKeys = null
        resetDjMode()
    }

    override fun onHeld() {
        // A held restore without a stored djMode key = off. Nothing is armed until the first play.
        if (!restoredSinceStart && enabled) {
            _state.value = DJModeState()
            log("mode cleared (held restore carries no DJ mode)")
        }
    }

    override fun onResumedFromHold() {
        // First play of a restored deck: DJ arms now (unless suspended).
        if (enabled && !ports.mixModeEnabled) { setDjMode(false); return } // DJ implies Mix Mode (restored DJ-on / Mix-off)
        if (enabled) {
            lastSuspension = suspension
            plannerSeed()?.let { engine.plannerSeeded(it) }
            if (lastSuspension == DjSuspension.NONE) engine.applyOnTrackStart(liveClock = true)
        }
    }

    // ---- SessionExtra (durable session key `djMode`) ------------------------------------------------------------

    override val key: SessionExtraKey<SessionDjMode> get() = SessionExtraKey.DJ_MODE

    override fun write(): SessionDjMode =
        SessionDjMode(
            enabled = enabled,
            planner = _state.value.planner as? JsonObject,
            unknownKeys = restoredUnknownKeys ?: JsonObject(emptyMap()),
        )

    /** HELD restore: the flag and the selector position come back; nothing arms before the first play. */
    override fun restoreHeld(value: SessionDjMode) {
        restoredSinceStart = true
        restoredUnknownKeys = value.unknownKeys
        val on = value.enabled && ports.supported
        _state.value = DJModeState(enabled = on, planner = value.planner)
        lastSuspension = DjSuspension.NONE
        if (on) log("mode ON (held restore - arms on the first play)")
    }

    private fun plannerSeed(): ULong? = (_state.value.planner as? JsonObject)?.let { DjPlannerState.fromJson(it)?.seed }

    private fun log(line: String) = ports.log("[dj] $line")
}

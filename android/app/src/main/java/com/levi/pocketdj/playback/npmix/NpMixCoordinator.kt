package com.levi.pocketdj.playback.npmix

import com.levi.pocketdj.mix.nowplaying.NowPlayingPrefetcher
import com.levi.pocketdj.mix.nowplaying.NpMixMode
import com.levi.pocketdj.mix.nowplaying.NpMixModeState
import com.levi.pocketdj.mix.nowplaying.NpMixSettings
import com.levi.pocketdj.playback.durable.SessionNpMixMode
import com.levi.pocketdj.playback.sequencer.QueueItem
import com.levi.pocketdj.playback.sequencer.SequencerListener
import com.levi.pocketdj.playback.sequencer.SessionEndReason
import com.levi.pocketdj.playback.sequencer.SessionExtra
import com.levi.pocketdj.playback.sequencer.SessionExtraKey
import com.levi.pocketdj.playback.sequencer.SourceRef
import com.levi.pocketdj.playback.sequencer.TrackStart
import com.levi.pocketdj.playback.sequencer.Transition
import com.levi.pocketdj.playback.sequencer.UserTransport
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.asStateFlow

/**
 * NOW PLAYING MIX MODE, session side (np-mix-mode phase 2; iOS `SetlistPlayer.setMixMode` / `resetMixMode` /
 * `scheduleStemLockReplan` / `prefetchStepFinished`).
 *
 * A [SequencerListener] plus the durable-session extra `npMixMode` (`{"enabled":bool}`):
 *  - a fresh `play()` starts from `npMixModeDefaultOn` ([onSessionStarted]); a stop / replaced run clears it;
 *  - a HELD restore delivers the stored flag and arms NOTHING (no buffering until the first ▶:
 *    [buffering] is false while held, the lane re-plans on [onResumedFromHold]);
 *  - SUSPENDED while the Mix tab runs ([Ports.mixTabActive]); [onMixTabChanged] resumes it;
 *  - never re-orders the queue (it only reads it);
 *  - the lane worker is the shared [NowPlayingPrefetcher] (one step at a time); this class decides WHEN it
 *    re-plans: coalesced to one plan per turn through [Ports.post];
 *  - a landed `.song` step for the playing row triggers the swap-on-land hand-off ([SwapOnLand]).
 *
 * Main-thread only, like the sequencer.
 */
class NpMixCoordinator(
    private val ports: Ports,
    private val swap: HandOff,
) : SequencerListener, SessionExtra<SessionNpMixMode> {

    /** What the coordinator needs from the app. */
    interface Ports {
        /** The settings snapshot (buffer window, cellular policy, "start in Mix Mode"). */
        fun settings(): NpMixSettings

        /** Mix Mode exists on this device (never gated off on Android; kept for parity with tvOS). */
        val supported: Boolean get() = true

        /** A Mix-tab session owns the audio (`DspHostPorts.mixSessionActive`). */
        val mixTabActive: Boolean

        /** Device playback mode: the lane never downloads into it. */
        val deviceMode: Boolean

        /** A sequencer run exists / is held (restored, awaiting the first ▶). */
        val running: Boolean
        val held: Boolean
        val sessionId: String?
        val currentSongId: String?

        /** The row (uid) the cursor is on, for the owed-hand-off identity. */
        val currentUid: String?

        /** The resolve ids of the current row and the next one: the Mix stream loader never evicts these. */
        fun currentAndNextResolveIds(): List<String>

        /** Re-plan the download lane now (buffering = Mix Mode is on and allowed to download). */
        fun replanLane()

        /** Persist the durable session now (a feature toggled). */
        fun persist()

        /** Mix Mode turned OFF: the storage manager runs its cap check (np-mix-mode §3.5). */
        fun onModeOff()

        /** Run [block] on a later turn of the main looper (coalesces re-plans). */
        fun post(block: () -> Unit)

        fun log(line: String) {}
    }

    /** The swap-on-land driver as the coordinator sees it (the [SwapOnLand.Runner] in production). */
    interface HandOff {
        /** Hand the playing row over to its local file now (suspends; the implementation launches it). */
        fun attempt(reason: String)

        /** A curable refusal came due again (first audio, PLAY, Mix tab idle). */
        fun retryOwed(trigger: String)

        /** The current row changed. */
        fun rowChanged(currentUid: String?)
        fun sessionEnded()
    }

    private val _state = MutableStateFlow(NpMixModeState())

    /** The session's Mix Mode (what the panel's switch and chip observe). */
    val state: StateFlow<NpMixModeState> = _state.asStateFlow()
    val enabled: Boolean get() = _state.value.enabled

    /** Mix Mode is on AND allowed to download right now: not held, not suspended by the Mix tab, not device mode. */
    val buffering: Boolean
        get() = ports.supported && enabled && ports.running && !ports.held && !ports.mixTabActive && !ports.deviceMode

    private var replanQueued = false
    private var lastLaneLine = ""
    private var restoredSinceStart = false
    private var restoredUnknownKeys: kotlinx.serialization.json.JsonObject? = null

    /** Re-plans actually run (test seam + diagnostics). */
    var replanCount = 0
        private set

    // ---- toggle -----------------------------------------------------------------------------------------

    /**
     * Turn the session's Mix Mode on/off (iOS `setMixMode`). No-op with no session or when unchanged. ON: the lane
     * re-plans and the current row may already be complete on disk (a stream adopted moments ago) -> hand off.
     * OFF: buffering stops (the Stem Lock's own plan, if any, carries on); the current track keeps whatever it
     * is playing; buffered files stay temporary and expire on schedule.
     */
    /** Called right after the switch flips, BEFORE the lane re-plans (DJ Mode turns itself off here). */
    var onModeSwitched: ((Boolean) -> Unit)? = null

    fun setMixMode(on: Boolean) {
        if (!ports.running || enabled == on || (on && !ports.supported)) return
        _state.value = NpMixModeState(enabled = on)
        onModeSwitched?.invoke(on)
        lastLaneLine = ""
        log("mode ${if (on) "ON" else "OFF"} session=${ports.sessionId ?: "-"} song=${ports.currentSongId ?: "-"}")
        ports.persist()
        if (!on) {
            // Synchronous: the Mix Mode steps leave the lane NOW (the lock's stay).
            replan()
            ports.onModeOff()
        } else {
            scheduleReplan()
            swap.attempt("mode-on")
        }
    }

    fun toggleMixMode() = setMixMode(!enabled)

    /** New session / stop: Mix Mode starts as [on] (the Settings default for a new session) or cleared. */
    fun resetMixMode(on: Boolean) {
        val next = on && ports.supported
        if (enabled != next) log(if (next) "mode ON (new-session default)" else "mode cleared (session ended / new session)")
        _state.value = NpMixModeState(enabled = next)
        lastLaneLine = ""
        swap.sessionEnded()
    }

    // ---- re-planning ------------------------------------------------------------------------------------

    /** Re-plan the lane now. */
    fun replan() {
        replanQueued = false
        replanCount++
        ports.replanLane()
    }

    /** Coalesce re-plans (a queue edit + a track start in one turn plan once). Nothing to do when idle and off. */
    fun scheduleReplan() {
        if (replanQueued) return
        if (!enabled && !ports.running) return
        replanQueued = true
        ports.post { if (replanQueued) replan() }
    }

    /** The network class changed: the window resizes. */
    fun onNetworkChanged(net: String) {
        if (enabled) log("network -> $net")
        scheduleReplan()
    }

    /**
     * The lane's plan changed: one `[npmix] lane step=… row=…` line per step (deduplicated like iOS `lastMixPlanLine`),
     * so the emulator trace shows rows 1-3 working. Only while Mix Mode is buffering.
     */
    fun noteLanePlan(currentRowId: String?, steps: List<NowPlayingPrefetcher.Step>, net: String) {
        if (!buffering) return
        val line = "net=$net cur=${currentRowId ?: "-"} " + if (steps.isEmpty()) "(nothing to fetch)" else steps.joinToString(" -> ")
        if (line == lastLaneLine) return
        lastLaneLine = line
        if (steps.isEmpty()) log("lane step=- row=${currentRowId ?: "-"} (nothing to fetch) net=$net")
        for (s in steps) log("lane step=$s row=${s.songId} net=$net")
    }

    /** A lane step finished. The playing row's `.song` landing hands a presigned stream over to the local file. */
    fun onStepFinished(step: NowPlayingPrefetcher.Step, ok: Boolean) {
        log("lane done step=$step ok=${if (ok) 1 else 0}")
        if (!ok || step !is NowPlayingPrefetcher.Step.Song) return
        if (!ports.running || ports.held) return
        val cur = ports.currentAndNextResolveIds().firstOrNull() ?: return
        if (cur == step.id) swap.attempt("landed")
    }

    /** The Mix tab started / stopped: Mix Mode is SUSPENDED while it is live (np-mix-mode §4.5). */
    fun onMixTabChanged(live: Boolean) {
        if (!enabled) return
        log("mix tab ${if (live) "live - suspended" else "idle - resumed"}")
        scheduleReplan()
        // A current-row buffer that landed while suspended (a cancelled step that finished anyway) is never
        // re-fetched: hand off onto it now. Also retries an owed hand-off.
        if (!live) swap.attempt("mix-tab-idle")
    }

    /** `MixStreamLoader.pinnedIds` addition: the audio ids of the NP current + next row (never evicted). */
    fun pinnedStreamIds(): Set<String> =
        if (!ports.running) emptySet() else ports.currentAndNextResolveIds().toSet()

    // ---- SequencerListener ------------------------------------------------------------------------------

    override fun onSessionStarted(sessionId: String, source: SourceRef) {
        restoredSinceStart = false
        restoredUnknownKeys = null
        // A fresh play starts from the Settings default; a HELD restore overwrites it right after (restoreHeld/onHeld).
        resetMixMode(ports.settings().modeDefaultOn)
    }

    override fun onSessionEnded(reason: SessionEndReason) {
        resetMixMode(false)
        replan() // the lane leaves with the session (the Stem Lock's own plan, if any, re-plans on its own)
    }

    override fun onHeld() {
        // A held restore without a stored npMixMode key = off (iOS: the snapshot's absent key reads as default).
        if (!restoredSinceStart && enabled) {
            _state.value = NpMixModeState(enabled = false)
            log("mode cleared (held restore carries no mix mode)")
        }
        // HELD: nothing is armed - no planning, no buffering - until the first play.
        replan()
    }

    override fun onResumedFromHold() {
        // First ▶ of a restored deck: the lane arms now.
        scheduleReplan()
    }

    override fun onTransition(t: Transition) {
        swap.rowChanged(ports.currentUid)
    }

    override fun onTrackStarted(start: TrackStart) {
        swap.rowChanged(start.item.uid)
        scheduleReplan()
    }

    override fun onQueueChanged(generation: Long) {
        scheduleReplan()
    }

    override fun onUserTransport(kind: UserTransport) {
        when (kind) {
            // The listener asked for sound again: a hand-off refused while paused comes due.
            UserTransport.PLAY -> if (enabled) swap.retryOwed("user-play")
            // Edits re-plan through onQueueChanged; a skip/jump through onTrackStarted.
            else -> Unit
        }
    }

    override fun onFirstAudio(item: QueueItem, source: String) {
        // A hand-off that came due during the start window retries now.
        if (enabled) {
            swap.retryOwed("after-start")
            // A row preloaded as a stream whose file landed while it was still "next" never gets a step-finished
            // event of its own: try once at first audio so it still hands off to the local copy.
            swap.attempt("first-audio")
        }
    }

    // ---- SessionExtra (durable session key `npMixMode`) -------------------------------------------------

    override val key: SessionExtraKey<SessionNpMixMode> get() = SessionExtraKey.NP_MIX_MODE

    override fun write(): SessionNpMixMode =
        SessionNpMixMode(enabled = enabled, unknownKeys = restoredUnknownKeys ?: kotlinx.serialization.json.JsonObject(emptyMap()))

    /** HELD restore: the flag comes back, but nothing arms (no planning / buffering before the first ▶). */
    override fun restoreHeld(value: SessionNpMixMode) {
        restoredSinceStart = true
        restoredUnknownKeys = value.unknownKeys
        val on = value.enabled && ports.supported
        _state.value = NpMixModeState(enabled = on)
        lastLaneLine = ""
        if (on) log("mode ON (held restore - buffers on the first play)")
    }

    private fun log(line: String) {
        NpMixMode.log(line)
        ports.log(line)
    }
}

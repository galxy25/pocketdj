package com.levi.pocketdj.playback.dj

import com.levi.pocketdj.di.AppGraph
import com.levi.pocketdj.screens.nowplaying.NowPlayingSeams
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.SupervisorJob
import kotlinx.coroutines.flow.distinctUntilChanged
import kotlinx.coroutines.flow.map
import kotlinx.coroutines.launch

/**
 * Production assembly of DJ Mode's session shell (P2-DJ-6): the [DjModeController] on the sequencer's hooks and
 * durable extras, the Mix tab / Remote / Mix Mode observations, and the engine seam the later packages bind
 * ([engineHooks]). Lives in the playback graph (`app.playbackGraph.djMode`); [install] runs once after Mix Mode's.
 */
class DjModeWiring(private val app: AppGraph) {
    private val scope = CoroutineScope(SupervisorJob() + Dispatchers.Main.immediate)
    private val seq get() = app.playbackGraph.sequencer
    private val mix get() = app.playbackGraph.npMix.coordinator

    /** P2-DJ-8/10 replace this with the transition engine + planner driver before the flag flips. */
    @Volatile var engineHooks: DjEngineHooks = DjEngineHooks.None

    private val delegating = object : DjEngineHooks {
        override fun applyOnTrackStart(liveClock: Boolean) = engineHooks.applyOnTrackStart(liveClock)
        override fun disarm() = engineHooks.disarm()
        override fun levelToZero() = engineHooks.levelToZero()
        override fun plannerSeeded(seed: ULong) = engineHooks.plannerSeeded(seed)
        override fun indicator() = engineHooks.indicator()
    }

    private val ports = object : DjModeController.Ports {
        override val running: Boolean get() = seq.isRunning
        override val held: Boolean get() = seq.isHeldForResume
        override val sessionId: String? get() = seq.sessionId
        override val currentSongId: String? get() = seq.currentSongId
        override val mixTabActive: Boolean get() = NowPlayingSeams.mixSessionActive
        override val mixModeEnabled: Boolean get() = mix.enabled
        override fun setMixMode(on: Boolean) = mix.setMixMode(on)
        override val queueFirstSongId: String? get() = seq.state.value.queue.firstOrNull()?.id
        override val queueCount: Int get() = seq.state.value.queue.size
        override fun persist() = seq.sessionExtras.notifyChanged()
        override fun log(line: String) { com.levi.pocketdj.diag.NPLog.lane("dj", line) }
    }

    val controller: DjModeController by lazy { DjModeController(ports, delegating) }

    private var installed = false

    /** Register on the sequencer and observe Mix Mode / the Mix tab / Remote. Idempotent; main thread. */
    fun install() {
        if (installed) return
        installed = true
        seq.hooks.add(controller)
        seq.sessionExtras.register(controller)
        seq.djModeEnabled = { controller.enabled } // a random insert never lands ahead of the listener's pick
        scope.launch { mix.state.map { it.enabled }.distinctUntilChanged().collect { controller.onMixModeChanged(it) } }
        scope.launch { NowPlayingSeams.mixSessionActiveFlow.collect { controller.onSuspensionInputsChanged() } }
        scope.launch { controller.remote.activeFlow.collect { controller.onSuspensionInputsChanged() } }
    }
}

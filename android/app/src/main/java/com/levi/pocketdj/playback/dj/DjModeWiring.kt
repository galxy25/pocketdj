package com.levi.pocketdj.playback.dj

import com.levi.pocketdj.di.AppGraph
import com.levi.pocketdj.mix.MixSettings
import com.levi.pocketdj.mix.mixSettingsFlow
import com.levi.pocketdj.mix.nowplaying.DjPhase
import com.levi.pocketdj.mix.nowplaying.DjTransitionSpec
import com.levi.pocketdj.playback.album.AlbumRun
import com.levi.pocketdj.playback.sequencer.QueueItem
import com.levi.pocketdj.playback.sequencer.RepeatMode
import com.levi.pocketdj.playback.sequencer.SequencerListener
import com.levi.pocketdj.playback.sequencer.TrackStart
import com.levi.pocketdj.screens.nowplaying.NowPlayingSeams
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.SupervisorJob
import kotlinx.coroutines.flow.SharingStarted
import kotlinx.coroutines.flow.distinctUntilChanged
import kotlinx.coroutines.flow.map
import kotlinx.coroutines.flow.stateIn
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

    /**
     * The engine side of DJ Mode: P2-DJ-8's [conductor]. The DSP / controller graphs are only touched once DJ is first turned
     * on ([ensureBound]), so a car connect or a DJ-less session never builds them. P2-DJ-10/11 hang the planner driver and
     * leveling off the conductor's [DjConductor.Env] seams.
     */
    @Volatile var engineHooks: DjEngineHooks = object : DjEngineHooks {
        override fun applyOnTrackStart(liveClock: Boolean) { ensureBound(); conductor.applyOnTrackStart(liveClock) }
        override fun disarm() { if (bound) conductor.disarm() }
        override fun levelToZero() { if (bound) conductor.levelToZero() }
        override fun plannerSeeded(seed: ULong) = conductor.plannerSeeded(seed)
        override fun indicator() = if (bound) conductor.indicator() else null
    }

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

    // ---- P2-DJ-8: the conductor's production seams ---------------------------------------------------------------------

    private val mixSettings by lazy {
        app.settings.mixSettingsFlow().stateIn(scope, SharingStarted.Eagerly, MixSettings())
    }
    private val mixGraph get() = app.mixGraph
    private val engine get() = mixGraph.npDspEngine
    private val host get() = mixGraph.npDspHost
    private val catalog get() = app.catalogRepository.state.value.catalog

    private fun rowRuns(i: Int): Boolean {
        val q = seq.state.value.queue
        val item = q.getOrNull(i) ?: return false
        val tl = seq.albumTimelines?.timeline(item.id) ?: return false
        // A per-song cut of an album song is not the shared side: the record only plays through when the side's file is used.
        if (host.resolveLocal(item.id)?.isCut == true) return false
        return AlbumRun.albumRun(q, i, tl, seq.effectiveRepeatMode == RepeatMode.ONE).next != null
    }

    private val env = object : DjConductor.Env {
        override val djActive: Boolean get() = controller.djActive
        override val running: Boolean get() = seq.isRunning
        override val held: Boolean get() = seq.isHeldForResume
        override fun currentItem(): QueueItem? = seq.state.value.current
        override fun nextItem(): QueueItem? = seq.state.value.let { if (it.isRunning) it.queue.getOrNull(it.index + 1) else null }
        override val queueCount: Int get() = seq.state.value.queue.size
        override val repeatOne: Boolean get() = seq.effectiveRepeatMode == RepeatMode.ONE
        override val repeatAll: Boolean get() = seq.effectiveRepeatMode == RepeatMode.ALL
        override val playsRemaining: Int get() = seq.currentPlaysRemaining
        override val halted: Boolean get() = seq.isPausedByCascade
        override fun settings(): DJModeSettings = mixSettings.value.dj
        override fun timings() = mixSettings.value.let { DjMode.Timings(it.autoMixLeadSeconds, it.autoMixFadeSeconds, it.mixGlideSeconds, it.skipFadeSeconds) }
        override fun currentInAlbumRun(): Boolean = rowRuns(seq.state.value.index)
        override fun nextStartsAlbumRun(): Boolean = rowRuns(seq.state.value.index + 1)

        override fun localSource(item: QueueItem): DjConductor.LocalSource? {
            val r = host.resolveLocal(item.id) ?: return null
            val len = item.lengthMs ?: 0L
            val start = if (r.isCut) 0L else (r.startMs ?: 0).toLong()
            var window = len
            if (!r.isCut && start > 0) {
                val end = app.ripsRepository.analogEndMs(item.id, start, len)
                if (end != null && end > start) window = end - start
            }
            return DjConductor.LocalSource(r.file, start, window, AutoTransition.BeatRef(r.gridBpm, r.firstDownbeatMs, r.beatsMs))
        }

        override fun facts(songId: String): DjConductor.Facts? {
            val song = catalog?.songsById?.get(songId) ?: return null
            return DjConductor.Facts(song.bpm, song.camelot)
        }

        override val dspEngaged: Boolean get() = engine.isEngaged
        override val dspEngagedSongId: String? get() = engine.engagedSongId
        override val dspRate: Double get() = engine.rate
        override val dspSecondsLeft: Double get() = engine.djSecondsLeft()
        override val dspPhase: DjPhase get() = engine.dj.phase

        override fun currentMixable(): Boolean {
            val cur = seq.state.value.current ?: return false
            return !app.playbackController.isAppleMusicActive && !seq.isWaitingForLive && host.resolveLocal(cur.id) != null
        }

        override fun currentReadyToEngage(): Boolean {
            val cur = seq.state.value.current ?: return false
            val np = app.playbackController.nowPlaying.value ?: return false
            return cur.matches(np.songId) && (np.isPlaying || seq.discriminator.pausedByListener)
        }

        override suspend fun engageCurrent(liveClock: Boolean): Boolean = host.engage()
        override fun arm(lead: Double, build: () -> DjTransitionSpec?) = engine.dj.armDj(lead, build)
        override fun disarm() = engine.dj.disarmDj()
        override fun levelToZero() { if (engine.isEngaged) engine.setLevelDb(0.0) }

        override fun advanceAtFadeStart(songId: String): Boolean {
            val item = seq.state.value.queue.getOrNull(seq.state.value.index + 1) ?: return false
            val undoMeta = mixGraph.djAdoptMeta(item, seq.contextFor(item))
            host.djAdvanceFor = songId
            val ok = seq.advanceAtDjFadeStart()
            if (!ok) { host.djAdvanceFor = null; undoMeta() }
            return ok
        }

        override fun playPlain(item: QueueItem) {
            // The row's History play was recorded by the advance: its plain load must not record a second one.
            com.levi.pocketdj.playback.PlaybackService.armSuppressHistory(item.id)
            if (!seq.restartCurrentRow(item.uid, 0L)) com.levi.pocketdj.playback.PlaybackService.armSuppressHistory(null)
        }

        override fun log(line: String) { com.levi.pocketdj.diag.NPLog.lane(com.levi.pocketdj.diag.NPLog.DJ, line) }
    }

    /** The conductor (P2-DJ-8). Cheap to build: [env] reads the graphs lazily. */
    val conductor: DjConductor by lazy { DjConductor(env, scope) }

    @Volatile private var bound = false

    /** First DJ use: hook the DSP's DJ callbacks, the heartbeat and the sequencer's adopt failure. Main thread. */
    private fun ensureBound() {
        if (bound) return
        bound = true
        val dj = engine.dj
        dj.onFadeStart = { conductor.onFadeStart(it) }
        dj.onTransitionEnded = { id, how -> conductor.onTransitionEnded(id, how) }
        dj.onHandBack = { conductor.onHandBack(it) }
        dj.onDeclined = { conductor.onEngineDeclined(it) }
        host.djPoll = { conductor.poll() }
        seq.onDjAdoptFailed = { _ -> seq.state.value.current?.let { conductor.onIncomingFailed(it.id) } }
    }

    /** Every start path ends here (the last step of the locks-on-track-start chain, in effect: the arm waits for the row to sound). */
    private val trackListener = object : SequencerListener {
        override fun onTrackStarted(start: TrackStart) {
            if (!controller.enabled) return
            ensureBound()
            conductor.onTrackStarted(start.item.id)
        }
    }

    private var installed = false
    private var remoteJob: kotlinx.coroutines.Job? = null

    /** Point DJ at a (new) Remote probe: re-launches the collector and re-evaluates the suspension. Main thread. */
    fun bindRemote(probe: RemoteSessionProbe) {
        controller.remote = probe
        remoteJob?.cancel()
        remoteJob = scope.launch { probe.activeFlow.collect { controller.onSuspensionInputsChanged() } }
    }

    /** Register on the sequencer and observe Mix Mode / the Mix tab / Remote. Idempotent; main thread. */
    fun install() {
        if (installed) return
        installed = true
        seq.hooks.add(controller)
        seq.hooks.add(trackListener)
        seq.sessionExtras.register(controller)
        seq.djModeEnabled = { controller.enabled } // a random insert never lands ahead of the listener's pick
        mix.onModeSwitched = { controller.onMixModeChanged(it) } // synchronous, before the lane re-plans
        scope.launch { mix.state.map { it.enabled }.distinctUntilChanged().collect { controller.onMixModeChanged(it) } } // backstop
        scope.launch { NowPlayingSeams.mixSessionActiveFlow.collect { controller.onSuspensionInputsChanged() } }
        bindRemote(controller.remote)
    }
}

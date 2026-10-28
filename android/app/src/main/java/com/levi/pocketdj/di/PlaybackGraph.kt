package com.levi.pocketdj.di

import com.levi.pocketdj.playback.health.DeadAirMeter
import com.levi.pocketdj.playback.health.PlaybackSupervisor
import com.levi.pocketdj.playback.health.PowerRunwayLock
import com.levi.pocketdj.playback.outcome.PlayOutcomeRegistry
import com.levi.pocketdj.playback.sequencer.RowResolverRegistry
import com.levi.pocketdj.playback.sequencer.SetlistSequencer
import com.levi.pocketdj.screens.nowplaying.NowPlayingRoutes
import com.levi.pocketdj.shell.FeatureModule
import com.levi.pocketdj.shell.Flushable
import com.levi.pocketdj.shell.NavEntry
import kotlinx.coroutines.flow.distinctUntilChanged
import kotlinx.coroutines.flow.map
import kotlinx.coroutines.launch

/**
 * Sidecar graph for the playback area (decision D3). Owns the wiring of the app-scoped
 * [SetlistSequencer] (built inside `PlaybackController`, which holds the Media3 port) to the
 * collections / settings / outcome seams. Packages in this area override the FeatureModule
 * members they contribute and add their own lazies here - never in AppGraph.
 */
class PlaybackGraph(private val app: AppGraph) : FeatureModule {
    override val area: String = "playback"

    override val navEntries: List<NavEntry> get() = NowPlayingRoutes.entries

    /** The app-scoped sequencer (the Android SetlistPlayer). */
    val sequencer: SetlistSequencer get() = app.playbackController.sequencer

    /**
     * The per-row resolve ladder. Burned-first (SVC-4), studio-local (STU-7), Apple Music (PB-8) and
     * rip-on-demand (PB-3) register their rung here from their own sidecar.
     */
    val rowSourceResolvers: RowResolverRegistry get() = app.playbackController.rowResolvers

    /** Fan-out of play outcomes to every FeatureModule.playOutcomeListeners entry. */
    val outcomes: PlayOutcomeRegistry = PlayOutcomeRegistry { app.features.playOutcomeListeners }

    /** The dead-air KPI (`filesDir/pocketdj-dead-air.json`, iOS document shape). */
    val deadAirMeter: DeadAirMeter by lazy {
        DeadAirMeter(file = java.io.File(app.appContext.filesDir, DeadAirMeter.FILE_NAME))
    }

    /** Backgrounding persists the meter and logs the day's summary line. */
    override val flushables: List<Flushable> = listOf(Flushable { deadAirMeter.flush() })

    /**
     * The 1 Hz keep-playing supervisor over the setlist lane. Ticks only while a run exists
     * ([wire] starts/stops it from the sequencer state).
     */
    val supervisor: PlaybackSupervisor.Shell by lazy {
        val seq = sequencer
        var lastPos = -1L
        PlaybackSupervisor.Shell(
            scope = app.playbackController.sequencerScopeForHealth,
            probe = {
                val engine = seq.engine
                val st = seq.state.value
                val d = seq.discriminator
                var probe = PlaybackSupervisor.Probe(
                    songId = st.currentSongId,
                    held = seq.isHeldForResume,
                    cascadeHalted = seq.isPausedByCascade,
                    startPending = seq.isStartPending,
                    interruptionOpen = d.interruptionOpen,
                    intentPlaying = d.intentPlaying,
                )
                if (engine == null || !seq.isRunning || !engine.hasLoadedItem) {
                    lastPos = -1L
                    probe
                } else {
                    // Proof of sound: rendering AND the clock advanced (a wedged-but-"playing" decoder is not sound).
                    val pos = engine.positionMs
                    val audible = engine.isPlaying && lastPos >= 0 && kotlin.math.abs(pos - lastPos) > 100
                    lastPos = pos
                    probe = probe.copy(
                        lane = PlaybackSupervisor.Lane.LOCAL,
                        userPaused = d.pausedByListener,
                        trackEnded = engine.trackEnded,
                        audible = audible,
                    )
                    probe
                }
            },
            perform = { action ->
                when (action) {
                    PlaybackSupervisor.Action.REKICK -> seq.engine?.rekick("supervisor.L1")
                    PlaybackSupervisor.Action.RETRY_IN_PLACE -> seq.supervisorRetryInPlace()
                    PlaybackSupervisor.Action.ESCALATE -> seq.supervisorEscalate()
                }
            },
            meter = deadAirMeter,
        )
    }

    /** Idempotent: connect the sequencer's capture seams. Called once from AppGraph init. */
    fun wire() {
        val seq = sequencer
        seq.historyContextProvider = { id -> app.collections.historyContext(id) }
        seq.originProvider = { id -> app.collections.originCollection(id) }
        seq.outcomes = outcomes
        // PB-3 zero-dead-air: the KPI, the start runway, and the supervisor that ticks only while a run exists.
        seq.meter = deadAirMeter
        seq.runwayLock = PowerRunwayLock(app.appContext)
        app.appScope.launch(kotlinx.coroutines.Dispatchers.Main) {
            seq.state.map { it.isRunning }.distinctUntilChanged().collect { running ->
                if (running) supervisor.start() else supervisor.stopTicking()
            }
        }
        // Burned-first rung: a READY burn plays from disk (offline-capable). Without this the
        // ladder fell straight through to the network manifest rung.
        app.playbackController.localFiles = app.servicesGraph.burnedFirst
    }
}

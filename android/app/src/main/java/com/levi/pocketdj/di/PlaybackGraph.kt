package com.levi.pocketdj.di

import com.levi.pocketdj.data.history.PlayHistoryStore
import com.levi.pocketdj.data.store.VersionedJsonWriter
import com.levi.pocketdj.playback.durable.AppLifecycleFlusher
import com.levi.pocketdj.playback.durable.PLAYBACK_SESSION_FILE
import com.levi.pocketdj.playback.durable.PlaybackSessionStore
import com.levi.pocketdj.playback.durable.ResumptionProvider
import com.levi.pocketdj.playback.durable.SessionRestorer
import com.levi.pocketdj.playback.durable.SessionWriter
import com.levi.pocketdj.playback.health.DeadAirMeter
import com.levi.pocketdj.playback.health.PlaybackSupervisor
import com.levi.pocketdj.playback.health.PowerRunwayLock
import com.levi.pocketdj.playback.outcome.PlayOutcomeRegistry
import com.levi.pocketdj.playback.outcome.SkipTracker
import com.levi.pocketdj.playback.sequencer.RowResolverRegistry
import com.levi.pocketdj.playback.sequencer.SetlistSequencer
import com.levi.pocketdj.screens.nowplaying.NowPlayingRoutes
import com.levi.pocketdj.shell.FeatureModule
import com.levi.pocketdj.shell.Flushable
import com.levi.pocketdj.shell.NavEntry
import kotlinx.coroutines.delay
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

    /**
     * The strict <50 % skip classifier (PB-5). Verdicts mark the history event, max-merge the listened
     * fraction and fan out to every FeatureModule outcome listener.
     */
    val skipTracker: SkipTracker by lazy {
        SkipTracker(
            markSkipped = { PlayHistoryStore.get(app.appContext).markSkipped(it) },
            noteListened = { id, f -> PlayHistoryStore.get(app.appContext).noteListened(id, f) },
            // SVC-6: the ONE skip verdict feeds PlayStatsStore (stats are keyed by base id); off the caller's thread.
            noteSkip = { id ->
                app.appScope.launch(kotlinx.coroutines.Dispatchers.IO) {
                    app.servicesGraph.playStats.noteSkipped(com.levi.pocketdj.data.edition.SongVariant.baseId(id))
                }
            },
            onVerdict = { song, skipped, f -> outcomes.emit(song, skipped, f) },
        )
    }

    /** The dead-air KPI (`filesDir/pocketdj-dead-air.json`, iOS document shape). */
    val deadAirMeter: DeadAirMeter by lazy {
        DeadAirMeter(file = java.io.File(app.appContext.filesDir, DeadAirMeter.FILE_NAME))
    }

    /** PB-4 durable playback session (`filesDir/pocketdj-playback-session.json`, iOS snapshot shape). */
    val sessionStore: PlaybackSessionStore by lazy {
        val f = java.io.File(app.appContext.filesDir, PLAYBACK_SESSION_FILE)
        PlaybackSessionStore(f, VersionedJsonWriter(f, VersionedJsonWriter.backgroundExecutor("pdj-session-writer")))
    }

    /** Sequencer state -> session store (real-time snapshot). Main-thread only. */
    val sessionWriter: SessionWriter by lazy {
        val seq = sequencer
        SessionWriter(
            store = sessionStore,
            position = { seq.engine?.positionMs ?: 0L },
            isPlaying = { seq.engine?.isPlaying == true },
            heldOffset = { seq.resumeOffsetMs },
            positionValid = { seq.engine?.hasLoadedItem == true && seq.currentRowLoaded },
            consumedResumeOffset = { seq.lastResumeOffsetMs },
            stemLock = { app.mixGraph.stemLockForSession() },   // MIX-18
        )
    }

    /** Held restore at launch (and for the system's playback-resumption request). */
    val sessionRestorer: SessionRestorer by lazy {
        SessionRestorer(
            store = sessionStore,
            sequencer = sequencer,
            anyBackendPlaying = { sequencer.engine?.isPlaying == true || app.playbackController.isAppleMusicActive },
        )
    }

    val resumptionProvider: ResumptionProvider by lazy { ResumptionProvider(sessionRestorer, sessionStore) }

    /** Backgrounding persists the meter and the live session snapshot. */
    override val flushables: List<Flushable> = listOf(
        Flushable { deadAirMeter.flush() },
        AppLifecycleFlusher(sessionStore),
    )

    /** Final review: continue-on-another-device session (iOS registers it file-only). */
    override val syncEntries: List<com.levi.pocketdj.shell.SyncEntry> = listOf(
        com.levi.pocketdj.shell.SyncEntry("playback-session", com.levi.pocketdj.playback.durable.PLAYBACK_SESSION_FILE),
    )

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
                        // PB-8: the Apple Music lane is detector-only (the SDK owns its own buffering).
                        lane = if (app.playbackController.isAppleMusicActive) PlaybackSupervisor.Lane.APPLE_MUSIC else PlaybackSupervisor.Lane.LOCAL,
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

    /** Non-suspending mirror of EditionSettings (the decider is read on Main). */
    @Volatile private var preferExplicitMirror: Boolean? = null

    /** Idempotent: connect the sequencer's capture seams. Called once from AppGraph init. */
    fun wire() {
        val seq = sequencer
        seq.historyContextProvider = { id -> app.collections.historyContext(id) }
        seq.originProvider = { id -> app.collections.originCollection(id) }
        // Final review: the edition decision (clean-only collections + "Prefer explicit versions") was never wired.
        seq.cleanOnlyProvider = { id ->
            val origin = app.collections.originCollection(id)?.second
            origin != null && (app.collections.pocket(origin)?.cleanOnly ?: app.collections.playlist(origin)?.cleanOnly) == true
        }
        seq.editionDecider = com.levi.pocketdj.data.edition.PolicyEditionDecider(
            preferExplicit = { preferExplicitMirror },
            song = { id -> app.catalogRepository.state.value.catalog?.songsById?.get(id) },
            isStored = { id -> app.servicesGraph.burnStore.hasLocalFile(id) },
            ready = { app.catalogRepository.state.value.catalog != null },
        )
        app.appScope.launch(kotlinx.coroutines.Dispatchers.IO) {
            com.levi.pocketdj.data.edition.EditionSettings.flow(app.settings).collect { preferExplicitMirror = it }
        }
        seq.outcomes = outcomes
        // PB-5: the History choke point arms the tracker; the sequencer feeds samples + advance-aways.
        seq.skipTracker = skipTracker
        // Off-main: the store reads the (up to 20k-row) log from disk on first touch.
        app.appScope.launch(kotlinx.coroutines.Dispatchers.Default) {
            PlayHistoryStore.get(
                app.appContext,
                onRecord = { e -> skipTracker.noteTrackStarted(e.id, e.songId) },
                onResume = { e -> skipTracker.noteTrackResumed(e.id, e.songId, e.wasSkipped == true) },
            )
        }
        // PB-3 zero-dead-air: the KPI, the start runway, and the supervisor that ticks only while a run exists.
        seq.meter = deadAirMeter
        seq.runwayLock = PowerRunwayLock(app.appContext)
        app.appScope.launch(kotlinx.coroutines.Dispatchers.Main) {
            seq.state.map { it.isRunning }.distinctUntilChanged().collect { running ->
                if (running) supervisor.start() else supervisor.stopTicking()
            }
        }
        // PB-4: held restore FIRST (before the writer observes: a restore is not a write), then the
        // real-time writer + 1 Hz position tick.
        app.appScope.launch(kotlinx.coroutines.Dispatchers.Main) {
            // Final review: the whole session JSON (hundreds of rows) is decoded on IO, only the install runs on Main.
            val snap = kotlinx.coroutines.withContext(kotlinx.coroutines.Dispatchers.IO) { runCatching { sessionStore.load() }.getOrNull() }
            runCatching { sessionRestorer.restoreIfIdle(snap) }
            launch { seq.state.collect { runCatching { sessionWriter.onState(it) } } }
            while (true) {
                delay(1_000)
                runCatching { sessionWriter.tick() }
            }
        }
        // Burned-first rung: a READY burn plays from disk (offline-capable). Without this the
        // ladder fell straight through to the network manifest rung.
        app.playbackController.localFiles = app.servicesGraph.burnedFirst
    }
}

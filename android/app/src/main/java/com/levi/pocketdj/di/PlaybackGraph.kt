package com.levi.pocketdj.di

import com.levi.pocketdj.playback.outcome.PlayOutcomeRegistry
import com.levi.pocketdj.playback.sequencer.RowResolverRegistry
import com.levi.pocketdj.playback.sequencer.SetlistSequencer
import com.levi.pocketdj.screens.nowplaying.NowPlayingRoutes
import com.levi.pocketdj.shell.FeatureModule
import com.levi.pocketdj.shell.NavEntry

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

    /** Idempotent: connect the sequencer's capture seams. Called once from AppGraph init. */
    fun wire() {
        val seq = sequencer
        seq.historyContextProvider = { id -> app.collections.historyContext(id) }
        seq.originProvider = { id -> app.collections.originCollection(id) }
        seq.outcomes = outcomes
        // Burned-first rung: a READY burn plays from disk (offline-capable). Without this the
        // ladder fell straight through to the network manifest rung.
        app.playbackController.localFiles = com.levi.pocketdj.playback.sequencer.LocalFileResolver { item ->
            val store = app.servicesGraph.burnStore
            val id = item.resolveId
            store.localUrlPreferringCut(id)?.let { cut ->
                com.levi.pocketdj.playback.sequencer.burnedLocalFile(
                    cut.file, cut.isCut, store.startMs(id), store.items.value[id]?.durationMs,
                    toUri = { android.net.Uri.fromFile(it).toString() },
                )
            }
        }
    }
}

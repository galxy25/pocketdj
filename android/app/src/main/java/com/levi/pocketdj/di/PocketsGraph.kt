package com.levi.pocketdj.di

import com.levi.pocketdj.data.pockets.wheel.PocketMomentCache
import com.levi.pocketdj.data.pockets.wheel.PocketMomentEngine
import com.levi.pocketdj.shell.FeatureModule
import com.levi.pocketdj.shell.ResetHook
import kotlinx.coroutines.flow.distinctUntilChanged
import kotlinx.coroutines.flow.map
import java.io.File
import java.util.concurrent.CopyOnWriteArrayList

/**
 * Sidecar graph for the Pocket wheel area (P2-POC-5, decision D3). Owns the app-scoped [PocketMomentCache];
 * later pocket packages (run store, motion timeline) register their own device-local clearers through
 * [registerWheelClear] so "Delete history" and account deletion wipe the whole wheel with one call.
 */
class PocketsGraph(private val app: AppGraph) : FeatureModule {
    override val area: String = "pockets"

    private val cacheFile: File get() = File(app.appContext.filesDir, PocketMomentCache.FILE_NAME)

    private val cacheLazy = lazy {
        PocketMomentCache(cacheFile, app.servicesGraph.pocketPalette, app.appScope).also { c ->
            val history = com.levi.pocketdj.data.history.PlayHistoryStore.get(app.appContext)
            c.historyRevision = { history.revision }
            c.historyEvents = { history.events }
            c.catalogSnapshot = {
                val cat = app.catalogRepository.state.value.catalog
                (cat?.songsById ?: emptyMap()) to (cat?.albumsById ?: emptyMap())
            }
            c.collectionsInput = { app.collectionsGraph.pocketsCollectionsInput() }
            c.favoriteIds = { app.collectionsGraph.favorites.favoriteIds }
            c.setlistToPlaylist = { app.collections.setlists.associate { it.id to it.playlistId } }
            c.timbreVectors = { app.browseGraph.timbreCatalog.vectors() }
            c.cloudPatterns = {
                app.collectionsGraph.listeningPockets.results.value?.patterns.orEmpty()
                    .map { PocketMomentEngine.CloudPatternRef(it.id, it.timeBucket, it.dayType) }
            }
            c.liveCollectionIds = {
                val cat = app.catalogRepository.state.value.catalog
                if (cat == null) null else
                    app.collections.pockets.map { it.id }.toSet() + app.collections.playlists.map { it.id } +
                        cat.playlists.map { it.playlist.id }
            }
        }
    }

    /** The app-scoped wheel snapshot cache. First touch reads the (small) cache file: build off-main. */
    val wheelCache: PocketMomentCache by cacheLazy

    private val clearers = CopyOnWriteArrayList<() -> Unit>()

    /** Extra device-local wheel state (pocket run store, motion timeline + opt-in) that [wheelClearLocal] must wipe. */
    fun registerWheelClear(clear: () -> Unit) { clearers += clear }

    /**
     * iOS `wheelClearLocal`: clears the run store / motion state (registered clearers), the wheel cache (memory +
     * file) and the palette. Called from Delete history and account deletion. Best-effort per step.
     */
    fun wheelClearLocal() {
        for (c in clearers) runCatching { c() }
        if (cacheLazy.isInitialized()) runCatching { wheelCache.clearLocal() }
        else runCatching { cacheFile.delete() }
        runCatching { app.servicesGraph.pocketPalette.clear() }
    }

    /** First foreground: follow history revisions (one rebuild per launch, then debounced). Idempotent. */
    fun start() {
        val history = com.levi.pocketdj.data.history.PlayHistoryStore.get(app.appContext)
        wheelCache.attach(history.state.map { it.revision }.distinctUntilChanged())
    }

    override val resetHooks: List<ResetHook> = listOf(ResetHook { wheelClearLocal() })
}

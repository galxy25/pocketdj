package com.levi.pocketdj.di

import com.levi.pocketdj.data.pockets.wheel.PocketMomentCache
import com.levi.pocketdj.data.pockets.wheel.PocketMomentEngine
import com.levi.pocketdj.shell.FeatureModule
import com.levi.pocketdj.shell.ResetHook
import kotlinx.coroutines.flow.distinctUntilChanged
import kotlinx.coroutines.launch
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
            c.catalogLoaded = { app.catalogRepository.state.value.catalog != null }
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

    /**
     * The centre-play-button brain (P2-POC-6). Its `play` seam is wired by the run store (P2-POC-7); until then
     * `playBest` reports "nothing started". Cheap to build: every input is a lambda read at refresh time.
     */
    val wheelController: com.levi.pocketdj.data.pockets.wheel.PocketWheelController by lazy {
        val history = com.levi.pocketdj.data.history.PlayHistoryStore.get(app.appContext)
        com.levi.pocketdj.data.pockets.wheel.PocketWheelController(
            snapshot = { wheelCache.snapshot.value },
            historyEvents = { history.events },
        ).also { c ->
            // Limitation: UI_MODE_TYPE_CAR only; a phone projecting to Android Auto is not detected (needs androidx.car.app CarConnection).
            c.motionNow = { kotlinx.coroutines.withContext(kotlinx.coroutines.Dispatchers.IO) { motionStore.currentActivity() } }
            c.carConnected = { app.collectionsGraph.carConnected() == true }
            c.contextGuess = { runCatching { app.collectionsGraph.listeningContextProvider.currentContextGuess() }.getOrNull() }
            c.cloudResults = {
                val svc = app.collectionsGraph.listeningPockets
                if (svc.isEnabled) svc.results.value else null
            }
            c.play = { profile -> kotlinx.coroutines.withContext(kotlinx.coroutines.Dispatchers.Main.immediate) { runStore.start(profile) } }
            c.emptyFallback = { emptyFallbackProfile(history.events, app.collectionsGraph.favorites.favoriteIds.isNotEmpty(), wheelCache.snapshot.value.collectionNames) }
        }
    }

    /**
     * The adaptive pocket run store (P2-POC-8). App-scoped; runs on the main thread (it drives the main-thread
     * sequencer) and hops to Default only for planner compute. Wires the History tag hook into the sequencer so every
     * run row's play records its `pocketRun` provenance.
     */
    val runStore: com.levi.pocketdj.data.pockets.wheel.PocketRunStore by lazy {
        val history = com.levi.pocketdj.data.history.PlayHistoryStore.get(app.appContext)
        val sequencer = app.playbackGraph.sequencer
        val scope = kotlinx.coroutines.CoroutineScope(
            kotlinx.coroutines.SupervisorJob() + kotlinx.coroutines.Dispatchers.Main.immediate +
                kotlinx.coroutines.CoroutineExceptionHandler { _, t -> runCatching { android.util.Log.e("PocketRunStore", "uncaught", t) } },
        )
        com.levi.pocketdj.data.pockets.wheel.PocketRunStore(
            file = File(app.appContext.filesDir, com.levi.pocketdj.data.pockets.wheel.PocketRunStore.FILE_NAME),
            player = com.levi.pocketdj.data.pockets.wheel.SequencerRunPlayer(sequencer),
            scope = scope,
        ).also { st ->
            st.historyEvents = { history.events }
            st.installId = { history.installId }
            st.currentEventId = { app.playbackGraph.skipTracker.currentEventId }
            st.candidates = { runCandidates() }
            // W7: a Mix moment's run plays through Mix Auto-DJ when >= 10 of its songs are deck-loadable.
            st.playThroughMix = { rows, label ->
                app.mixGraph.mixFacade.startAutoMixSongs(
                    com.levi.pocketdj.data.pockets.wheel.PocketRunMixPath.songIds(rows), label,
                    com.levi.pocketdj.data.pockets.wheel.PocketRunMixPath.collections(rows),
                )
            }
            // P2-POC-12: adapt a run to walking & running (opt-in; sequencer path only).
            st.adaptToActivity = {
                motionStore.isActive && com.levi.pocketdj.screens.settings.sections.MotionPrefs.adaptToActivity(app.appContext)
            }
            // Single-slot hooks: remember what WE installed so stop only clears our own callbacks (never a later owner's).
            var ownedEnter: ((com.levi.pocketdj.data.motion.MotionSegment) -> Unit)? = null
            var ownedExit: ((String) -> Unit)? = null
            st.startActivityUpdates = { onSample, onExit ->
                ownedEnter = onSample; ownedExit = onExit
                motionTimeline.onEnter = onSample
                motionTimeline.onExit = onExit
                // Seed with the activity already under way, its clock starting at run start (never an instant re-target on play).
                val n = System.currentTimeMillis()
                runCatching { motionTimeline.segments(n - 2 * 3_600_000L, n + 1).filter { it.endMs >= n - 1_000 }.maxByOrNull { it.endMs } }
                    .getOrNull()?.let { onSample(it.copy(startMs = maxOf(it.startMs, n))) }
            }
            st.stopActivityUpdates = {
                if (motionTimeline.onEnter === ownedEnter) motionTimeline.onEnter = null
                if (motionTimeline.onExit === ownedExit) motionTimeline.onExit = null
                ownedEnter = null; ownedExit = null
            }
            st.profileForMode = { mode -> wheelController.profileForMode(mode) }
            st.mixOwnsRun = { label -> app.mixGraph.mixFacade.let { it.autoMixing && it.autoMixLabel == label } }
            sequencer.pocketRunTagFor = { plan -> st.tag(plan) }
            registerWheelClear { st.clearLocal() }
        }
    }

    /** The planner's candidate universe, built OFF the main thread (every playable song with features + memberships). */
    private suspend fun runCandidates(): Map<String, com.levi.pocketdj.data.pockets.wheel.PocketRunPlanner.Candidate> =
        kotlinx.coroutines.withContext(kotlinx.coroutines.Dispatchers.Default) {
            val cat = app.catalogRepository.state.value.catalog ?: return@withContext emptyMap()
            val burned = runCatching {
                app.servicesGraph.burnStore.items.value.filterValues { it.state == com.levi.pocketdj.data.burns.BurnState.READY }.keys
            }.getOrDefault(emptySet())
            com.levi.pocketdj.data.pockets.wheel.PocketRunCandidates.build(
                songs = cat.songsById,
                albums = cat.albumsById,
                availability = com.levi.pocketdj.data.games.inthepocket.InThePocketAudio(
                    ripIds = app.ripsRepository.manifest.value.keys,
                    burnedIds = burned,
                    canStreamAppleMusic = runCatching { app.settings.current().hasAppleMusic }.getOrDefault(false),
                ),
                collections = app.collectionsGraph.pocketsCollectionsInput(),
                favorites = app.collectionsGraph.favorites.favoriteIds,
                timbre = app.browseGraph.timbreCatalog.vectors(),
                nowMs = System.currentTimeMillis().toDouble(),
            )
        }

    /** P2-POC-11: device-local 7-day motion timeline (never synced). */
    val motionTimeline: com.levi.pocketdj.data.motion.MotionTimelineStore by lazy {
        com.levi.pocketdj.data.motion.MotionTimelineStore(File(app.appContext.filesDir, com.levi.pocketdj.data.motion.MotionTimelineStore.FILE_NAME))
    }

    /** P2-POC-11: the per-device motion opt-in + settle pass. Default OFF; inert without ACTIVITY_RECOGNITION. */
    val motionStore: com.levi.pocketdj.data.motion.ListeningMotionStore by lazy {
        com.levi.pocketdj.data.motion.ListeningMotionStore(
            file = File(app.appContext.filesDir, com.levi.pocketdj.data.motion.ListeningMotionStore.FILE_NAME),
            timeline = motionTimeline,
            hasPermission = { com.levi.pocketdj.data.motion.ActivityTransitionSource.hasPermission(app.appContext) },
            source = com.levi.pocketdj.data.motion.ActivityTransitionSource(app.appContext),
        )
    }

    /** One motion settle pass over this install's plays (off-main). */
    fun settleMotion() {
        app.appScope.launch(kotlinx.coroutines.Dispatchers.IO) {
            runCatching {
                if (!motionStore.isActive) return@runCatching
                val history = com.levi.pocketdj.data.history.PlayHistoryStore.get(app.appContext)
                val songs = app.catalogRepository.state.value.catalog?.songsById // null while loading: iOS settles with the fallback duration
                motionStore.settle(history) { id -> songs?.get(id)?.length?.toInt() }
            }
        }
    }

    private val clearers = CopyOnWriteArrayList<() -> Unit>().apply { add { motionStore.clearLocal() } }

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
        // Palette is cleared inside wheelCache.clearLocal (under the adopt lock); only the uninitialised path needs it here.
        if (!cacheLazy.isInitialized()) runCatching { app.servicesGraph.pocketPalette.clear() }
    }

    /** First foreground: follow history revisions (one rebuild per launch, then debounced). Idempotent. */
    fun start() {
        com.levi.pocketdj.shell.AppLifecycleObserver.motionSettle = { settleMotion() }
        runCatching { motionStore.ensureRegistered() } // registrations don't survive reboot/update
        settleMotion()
        resumeRun()
        val history = com.levi.pocketdj.data.history.PlayHistoryStore.get(app.appContext)
        wheelCache.attach(
            PocketMomentCache.gatedRevisions(
                history.state.map { it.revision }.distinctUntilChanged(),
                app.catalogRepository.state.map { it.catalog != null }.distinctUntilChanged(),
            ),
        )
    }

    /** Installs the run store's History-tag hook on the sequencer and resumes a relaunched mid-run (on Main). */
    fun resumeRun() {
        app.appScope.launch(kotlinx.coroutines.Dispatchers.Main) { runCatching { runStore.resumeTrackingIfNeeded() } }
    }

    override val settingsSections: List<com.levi.pocketdj.shell.SettingsSection> by lazy {
        listOf(com.levi.pocketdj.screens.settings.sections.listeningMotionSection())
    }

    override val resetHooks: List<ResetHook> = listOf(ResetHook { wheelClearLocal() })

    companion object {
        /**
         * T4 of the best-match ladder: the most recently played collection, else Favorites (iOS `emptyFallback`).
         * Pure so it is testable; [hasFavorites] is read by the caller.
         */
        internal fun emptyFallbackProfile(
            events: List<com.levi.pocketdj.data.history.PlayEvent>,
            hasFavorites: Boolean,
            collectionNames: Map<String, String> = emptyMap(),
        ): com.levi.pocketdj.data.pockets.wheel.PocketProfile? {
            val recent = events.asReversed().firstOrNull { it.originCollectionId != null && it.source != com.levi.pocketdj.data.history.PlaySource.GAME }
            val (id, name) = when {
                recent != null -> recent.originCollectionId!! to (collectionNames[recent.originCollectionId] ?: recent.contextName ?: "Your last collection")
                hasFavorites -> com.levi.pocketdj.data.pockets.wheel.PocketWheelIds.FAVORITES to com.levi.pocketdj.data.pockets.wheel.PocketWheelIds.FAVORITES_NAME
                else -> return null
            }
            return com.levi.pocketdj.data.pockets.wheel.PocketProfile(
                tier = com.levi.pocketdj.data.pockets.wheel.PocketProfile.Tier.EMPTY,
                caption = "Getting to know you", detail = name, collections = mapOf(id to 1.0),
            )
        }
    }
}

package com.levi.pocketdj.di

import com.levi.pocketdj.data.search.SearchConfig
import com.levi.pocketdj.data.search.SearchService
import com.levi.pocketdj.data.search.SearchSettings
import com.levi.pocketdj.screens.browse.BrowseSessionFlushable
import com.levi.pocketdj.screens.settings.sections.editionSection
import com.levi.pocketdj.screens.settings.sections.forYouSection
import com.levi.pocketdj.screens.settings.sections.onlineSearchSection
import com.levi.pocketdj.screens.settings.sections.recommendationsSection
import com.levi.pocketdj.data.collections.recommendationsEnabled
import com.levi.pocketdj.shell.FeatureModule
import com.levi.pocketdj.shell.Flushable
import com.levi.pocketdj.shell.SettingsSection
import com.levi.pocketdj.data.history.HistorySettings
import com.levi.pocketdj.screens.history.HistoryBrowseState
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.FlowPreview
import kotlinx.coroutines.flow.collectLatest
import kotlinx.coroutines.flow.debounce
import kotlinx.coroutines.flow.distinctUntilChanged
import kotlinx.coroutines.flow.drop
import kotlinx.coroutines.flow.map
import kotlinx.coroutines.flow.onEach
import kotlinx.coroutines.launch
import kotlinx.coroutines.withContext
import kotlinx.coroutines.plus

/**
 * Sidecar graph for the browse area (decision D3). Packages in this area override the
 * FeatureModule members they contribute and add their own lazies here, never in AppGraph.
 */
@OptIn(FlowPreview::class)
class BrowseGraph(private val app: AppGraph) : FeatureModule {
    override val area: String = "browse"

    /**
     * History's own browse state (BRW-6): persisted filter/sort under `historySnapshotJson`
     * (never Browse's key), transient query + Hide-skips. Hydrated off-main on first touch; every
     * later change is written debounced, and a lifecycle flush writes it immediately — both
     * skipped until the restore ran so defaults never clobber the saved doc.
     */
    private val historyBrowseLazy: Lazy<HistoryBrowseState> = lazy {
        HistoryBrowseState(requireRestore = true).also { state ->
            app.appScope.launch(Dispatchers.IO) {
                runCatching { state.restore(HistorySettings.load(app.settings)) }
                if (!state.restored) state.markRestored()
                state.inputs
                    .map { state.toSnapshot() }
                    .distinctUntilChanged()
                    .drop(1) // the just-restored state — nothing new to write
                    .debounce(HISTORY_WRITE_DEBOUNCE_MS)
                    .collectLatest { runCatching { HistorySettings.save(app.settings, it) } }
            }
        }
    }

    internal val historyBrowse: HistoryBrowseState by historyBrowseLazy

    /** Durable For You feed (BRW-11). Reads its file on first touch: touch off Main. */
    private val forYouFeedLazy: Lazy<com.levi.pocketdj.data.recs.ForYouFeedStore> = lazy {
        com.levi.pocketdj.data.recs.ForYouFeedStore(
            java.io.File(app.appContext.filesDir, com.levi.pocketdj.data.recs.ForYouFeedStore.FILE_NAME),
        )
    }
    val forYouFeedStore: com.levi.pocketdj.data.recs.ForYouFeedStore by forYouFeedLazy

    /** True once both For You lazies exist, so reading them cannot touch disk on Main. */
    val forYouStoresReady: Boolean get() = forYouFeedLazy.isInitialized() && recFeedbackLazy.isInitialized()

    /** 👍/👎 decisions (BRW-11). Reads its file on first touch: touch off Main. */
    private val recFeedbackLazy: Lazy<com.levi.pocketdj.data.recs.RecFeedbackStore> = lazy {
        com.levi.pocketdj.data.recs.RecFeedbackStore(
            file = java.io.File(app.appContext.filesDir, REC_FEEDBACK_FILE),
            scope = app.appScope,
            identityFile = java.io.File(app.appContext.filesDir, "pocketdj-rec-feedback-install-id"),
        )
    }
    val recFeedbackStore: com.levi.pocketdj.data.recs.RecFeedbackStore by recFeedbackLazy

    /** Timbre corpus for the For You refresh (BRW-12): memoized fetch, never throws, empty when offline. */
    val timbreCatalog: com.levi.pocketdj.data.recs.TimbreCatalog by lazy {
        com.levi.pocketdj.data.recs.TimbreCatalog(app.catalogService) {
            "${com.levi.pocketdj.data.config.Endpoints.CATALOG_BASE}/timbre.json"
        }
    }

    // ---- BRW-13: cloud recommendation engine ------------------------------------------------

    /** Live mirrors of the device-local prefs (the service's gates are non-suspend). Default OFF until the first emission. */
    private val recEnabledMirror = kotlinx.coroutines.flow.MutableStateFlow(false)

    /** The privacy-gate mirror as a flow (UI that must retry once the GATE opens keys on this, not the raw pref). */
    val recEnabled: kotlinx.coroutines.flow.StateFlow<Boolean> get() = recEnabledMirror
    private val shareCountsMirror = java.util.concurrent.atomic.AtomicBoolean(true)
    @Volatile private var deviceIdMirror: String = ""

    private val recServiceLazy: Lazy<com.levi.pocketdj.data.recs.RecommendationService> = lazy {
        val files = app.appContext.filesDir
        val collections = app.collections
        val svc = com.levi.pocketdj.data.recs.RecommendationService(
            client = com.levi.pocketdj.data.recs.RecEngineClient(app.httpClient, deviceId = { deviceIdMirror }),
            scope = app.appScope + Dispatchers.IO,
            enabled = { recEnabledMirror.value },
            shareLifetimePlayCounts = { shareCountsMirror.get() },
            profileId = { app.servicesGraph.profile.id },
            deviceId = { deviceIdMirror },
            keyFile = java.io.File(files, REC_KEY_FILE),
            stateFile = java.io.File(files, REC_SYNC_FILE),
            pendingDeleteFile = java.io.File(files, REC_PENDING_DELETE_FILE),
            playsProvider = {
                com.levi.pocketdj.data.history.PlayHistoryStore.get(app.appContext).events.map {
                    com.levi.pocketdj.data.recs.RecPlayEventWire(it.id, it.songId, it.playedAt, it.source.token)
                }
            },
            favoritesProvider = {
                app.collectionsGraph.favorites.entries().map {
                    com.levi.pocketdj.data.recs.RecFavoriteWire(it.songId, it.favorited, it.atMs)
                }
            },
            activityProvider = {
                app.collectionActivity.events.map {
                    com.levi.pocketdj.data.recs.RecActivityWire(
                        it.id, it.at, it.kind.token, it.itemId, it.collectionId, it.collectionKind, it.collectionName,
                    )
                }
            },
            collectionsProvider = {
                val pockets = collections.pockets
                val playlists = collections.playlists
                val albums = com.levi.pocketdj.data.recs.RecCollectionFlattener.referencedAlbumIds(pockets, playlists)
                val albumsById = app.catalogRepository.state.value.catalog?.albumsById
                val tracks = if (albums.isEmpty() || albumsById == null) emptyMap()
                else albums.mapNotNull { id -> albumsById[id]?.let { id to it.trackList } }.toMap()
                com.levi.pocketdj.data.recs.RecCollectionFlattener.flatten(pockets, playlists, albumTracks = tracks)
            },
            recommendationsEnabledFor = { collections.recommendationsEnabled(it) },
        )
        svc.feedbackProvider = { since ->
            recFeedbackStore.decisionsSince(since).map {
                com.levi.pocketdj.data.recs.RecFeedbackWire(it.id, it.at, it.songId, it.verdict, it.surface, it.scope)
            }
        }
        // Final review: Gem Collector filings train the rec engine (iOS recEngine.puzzleEventsProvider).
        svc.puzzleEventsProvider = { since ->
            com.levi.pocketdj.data.games.puzzle.PuzzleRecEventBridge.events(app.gamesGraph.puzzleDecisions.decisions, since).map {
                com.levi.pocketdj.data.recs.RecPuzzleEventWire(it.id, it.atMs, it.gameId, it.songId, it.collectionId, it.action, it.points)
            }
        }
        svc.playCountsProvider = { app.servicesGraph.playStats.playCountsSnapshot() }
        svc.lastPlayedProvider = { app.servicesGraph.playStats.lastPlayedSnapshot() }
        svc
    }

    /** The cloud rec engine (gate, flush, cloud zone, suggestions). Touch off-main: it reads its docs on first use. */
    val recService: com.levi.pocketdj.data.recs.RecommendationService by recServiceLazy

    /**
     * Launch hook (additive line in AppGraph.init): mirror the prefs, then arm the auto-flush loop. The loop
     * also finishes an owed server-side deletion regardless of the toggle; it exits at once when disabled.
     */
    fun startRecs() {
        startReleaseFeed()
        // Final review: the Add-to sheet / context submenu "Suggested" rows read this seam (it was never assigned).
        // Non-blocking cache read; a miss starts one fetch and the revision bump re-renders.
        app.collectionsGraph.collectionSuggestions = { songId ->
            recService.cachedCollectionSuggestions(songId).mapNotNull {
                if (it.kind == "pocket" || it.kind == "playlist") com.levi.pocketdj.screens.collections.CollectionSuggestion(it.kind!!, it.id) else null
            }
        }
        app.appScope.launch(Dispatchers.IO) {
            deviceIdMirror = runCatching { app.settings.ensureInstallId() }.getOrDefault("")
            launch { app.settings.flow(com.levi.pocketdj.data.recs.RecsSettings.SHARE_LIFETIME_PLAY_COUNTS).collect { shareCountsMirror.set(it) } }
            // The mirror is set from EVERY emission of the flow (no get()+drop(1) gap where a toggle between the
            // two is lost). The first emission lands BEFORE the service exists, so the first gate read is truthful.
            var svc: com.levi.pocketdj.data.recs.RecommendationService? = null
            app.settings.flow(com.levi.pocketdj.data.recs.RecsSettings.REC_ENGINE_ENABLED).distinctUntilChanged().collect { on ->
                val prev = recEnabledMirror.value
                recEnabledMirror.value = on
                val s = svc
                if (s == null) {
                    svc = recService.also { it.startAutoFlush() }
                } else if (prev != on) {
                    s.enabledDidChange()
                }
            }
        }
    }

    // ---- New releases feed (BRW-14) ----------------------------------------------------------

    /** Synchronous mirror of "Apple Music is signed in" (the transport's canSync is read off suspend paths). */
    private val amSignedIn = java.util.concurrent.atomic.AtomicBoolean(false)

    private val releaseFeedLazy: Lazy<com.levi.pocketdj.data.recs.ReleaseFeedService> = lazy {
        val tokens = com.levi.pocketdj.data.applemusic.DefaultAppleMusicTokens(app.musicKitDevTokenClient, app.settings)
        val svc = com.levi.pocketdj.data.recs.ReleaseFeedService(
            transport = com.levi.pocketdj.data.recs.AppleMusicReleaseTransport(
                http = app.httpClient,
                tokens = tokens,
                canSyncProvider = { amSignedIn.get() },
                baseOverride = { if (com.levi.pocketdj.BuildConfig.DEBUG) com.levi.pocketdj.data.applemusic.AppleMusicApi.debugBase else null },
            ),
            file = java.io.File(app.appContext.filesDir, com.levi.pocketdj.data.recs.ReleaseFeedService.FILE_NAME),
            scope = app.appScope + Dispatchers.IO,
        )
        svc.ownsRelease = com.levi.pocketdj.data.recs.ReleaseOwnershipProbes.ownership { ownedCatalogIndexOrNull() }
        svc.ownsReleaseVersion = com.levi.pocketdj.data.recs.ReleaseOwnershipProbes.version { ownedCatalogIndexOrNull() }
        svc.playsForArtist = { id -> releasePlaysForArtist(id) }
        svc
    }

    /** The New-releases feed. Reads its file on first touch: touch off Main (or via [releaseFeedIfReady]). */
    val releaseFeed: com.levi.pocketdj.data.recs.ReleaseFeedService by releaseFeedLazy

    /** Non-null once created; lets Main-thread composition read it without a disk hit. */
    fun releaseFeedIfReady(): com.levi.pocketdj.data.recs.ReleaseFeedService? =
        if (releaseFeedLazy.isInitialized()) releaseFeedLazy.value else null

    @Volatile private var ownedIndexMemo: Pair<com.levi.pocketdj.data.catalog.MergedCatalog, com.levi.pocketdj.data.recs.OwnedCatalogIndex>? = null

    /** Ownership joins for the current catalog; null until built off-main (the cold-launch default owns nothing). */
    private fun ownedCatalogIndexOrNull(): com.levi.pocketdj.data.recs.OwnedCatalogIndex? {
        val catalog = app.catalogRepository.state.value.catalog ?: return null
        val memo = ownedIndexMemo
        if (memo != null && memo.first === catalog) return memo.second
        // Never build on the render path (54 ms measured on iOS): schedule it and answer "owns nothing" meanwhile.
        scheduleOwnedIndexBuild(catalog)
        return null
    }

    private val ownedIndexBuilding = java.util.concurrent.atomic.AtomicBoolean(false)

    private fun scheduleOwnedIndexBuild(catalog: com.levi.pocketdj.data.catalog.MergedCatalog) {
        if (!ownedIndexBuilding.compareAndSet(false, true)) return
        app.appScope.launch(Dispatchers.Default) {
            try {
                val index = com.levi.pocketdj.data.recs.OwnedCatalogIndex(catalog, app.catalogRepository.indexArtists())
                ownedIndexMemo = catalog to index
                // The feed's filter just changed from "owns nothing" to the real answer: recompute the UI.
                releaseFeedIfReady()?.ownershipChanged()
            } finally {
                ownedIndexBuilding.set(false)
            }
            // The catalog may have been swapped while building: build for the new one too.
            val now = app.catalogRepository.state.value.catalog
            if (now != null && ownedIndexMemo?.first !== now) scheduleOwnedIndexBuild(now)
        }
    }

    /** Catalog song id that already claims this Apple Music track id (so a New queue plays it as the owned song). */
    fun catalogSongIdForAppleMusicId(appleMusicId: String): String? = ownedCatalogIndexOrNull()?.songId(appleMusicId)

    private val artistIdResolver = com.levi.pocketdj.data.recs.ArtistIdResolver { app.catalogRepository.indexArtists() }

    /** Apple Music artist id for a played artist name (indexed name join); null when the index has none. */
    private fun releaseArtistId(name: String): Int? = artistIdResolver.resolve(name)

    private val releaseArtistNames = java.util.concurrent.ConcurrentHashMap<Int, String>()

    private fun releasePlaysForArtist(artistId: Int): Int {
        val name = releaseArtistNames[artistId] ?: return 0
        val key = com.levi.pocketdj.data.recs.RecVersionIdentity.fold(name)
        return com.levi.pocketdj.data.history.PlayHistoryStore.get(app.appContext).events.count {
            it.artist?.let { a -> com.levi.pocketdj.data.recs.RecVersionIdentity.fold(a) } == key
        }
    }

    /**
     * Launch hook (called from [startRecs]): mirror Apple Music sign-in, run the one-shot listening seed once
     * the catalog + sign-in are there, and note every NEW play (the feed's only steady-state trigger).
     */
    private fun startReleaseFeed() {
        app.appScope.launch(Dispatchers.IO) {
            val feed = releaseFeed
            // Mirror the sign-in from the SAME stream the seed combines on (set before the combine sees it).
            val signedInFlow = app.settings.settings.map { it.hasAppleMusic }
                .onEach { amSignedIn.set(it) }.distinctUntilChanged()
            // Build the ownership index as soon as a catalog lands (not on the first render-path read).
            launch { app.catalogRepository.catalogFlow.collect { c -> if (c != null) ownedCatalogIndexOrNull() } }
            // Seed: needs the artist-id table (catalog) and a signed-in account; retried when either arrives.
            launch {
                kotlinx.coroutines.flow.combine(
                    app.catalogRepository.catalogFlow,
                    signedInFlow,
                ) { catalog, signedIn -> catalog != null && signedIn }.collect { ready ->
                    if (!ready || !feed.needsSeed) return@collect
                    val now = System.currentTimeMillis().toDouble()
                    val events = com.levi.pocketdj.data.history.PlayHistoryStore.get(app.appContext).events
                    val seeds = com.levi.pocketdj.data.recs.ReleaseFeedSeed.recentArtistNames(events, now).mapNotNull { n ->
                        releaseArtistId(n)?.let { id -> releaseArtistNames[id] = n; id to n }
                    }
                    feed.seedFromRecentListening(seeds, now)
                }
            }
            // Steady state: only events that appear AFTER launch and are fresh (a synced replay is not a play).
            launch {
                val store = com.levi.pocketdj.data.history.PlayHistoryStore.get(app.appContext)
                var seen = store.events.lastOrNull()?.id
                store.state.collect { st ->
                    val events = st.events
                    val from = com.levi.pocketdj.data.recs.ReleaseFeedWiring.newEventsStart(events.map { it.id }, seen)
                    seen = events.lastOrNull()?.id ?: seen
                    val now = System.currentTimeMillis().toDouble()
                    for (e in events.subList(from, events.size)) {
                        if (now - e.playedAt > 120_000.0) continue
                        val name = e.artist?.takeIf { it.isNotBlank() }
                            ?: e.songId.let { sid -> app.catalogRepository.state.value.catalog?.songsById?.get(sid)?.artist }?.takeIf { it.isNotBlank() }
                            ?: continue
                        val id = releaseArtistId(name) ?: continue
                        releaseArtistNames[id] = name
                        feed.noteArtistPlayed(id, name, now)
                    }
                }
            }
        }
    }

    override val flushables: List<Flushable> = listOf(
        BrowseSessionFlushable { app.settings.setBrowseSnapshot(it) },
        recsFlushable(recFeedbackLazy),
        Flushable { if (recServiceLazy.isInitialized()) recServiceLazy.value.flushSoon() },
        object : Flushable {
            override suspend fun flush() {
                if (!historyBrowseLazy.isInitialized()) return
                val state = historyBrowseLazy.value
                if (!state.restored) return
                HistorySettings.save(app.settings, state.toSnapshot())
            }
        },
    )

    /** Online-search host resolution (user override -> search-config.json -> baked default). */
    val searchConfig: SearchConfig by lazy {
        SearchConfig(SearchConfig.httpFetcher(app.httpClient)).also { cfg ->
            // Seed the per-user host override from the persisted pref (off-main).
            app.appScope.launch(Dispatchers.IO) {
                runCatching { cfg.setUserHost(SearchSettings.endpoint(app.settings)) }
            }
        }
    }

    val searchService: SearchService by lazy { SearchService(app.httpClient, searchConfig) }

    // ---- BRW-15: Discover (Apple Music catalog search) --------------------------------------

    // ---- BRW-16 (DISC-2): provisional Discover catalog entries ------------------------------

    /**
     * The provisional "Discover" adds (iOS `DiscoverAddsStore`). Lazy - reads its small doc on first touch (the
     * catalog merge touches it off-main). Creating it wires the live-catalog refresh and the History hooks.
     */
    val discoverAdds: com.levi.pocketdj.data.discover.DiscoverAddsStore by lazy {
        com.levi.pocketdj.data.discover.DiscoverAddsStore(
            java.io.File(app.appContext.filesDir, com.levi.pocketdj.data.discover.DiscoverAddsStore.FILE_NAME),
        ).also { store ->
            // A change (local add / user removal / cloud pull) rebuilds the live catalog ONCE.
            store.onChanged = { app.catalogRepository.remergeLocal() }
            // User gestures only (never a cloud pull): the History activity timeline.
            store.onUserCatalogAdd = { items, libraryWrite ->
                app.appScope.launch(Dispatchers.IO) {
                    for (i in items) {
                        app.collectionActivity.record(
                            kind = com.levi.pocketdj.data.activity.ActivityKind.CATALOG_ADD,
                            itemId = i.id, itemTitle = i.title, itemArtist = i.artist, libraryWrite = libraryWrite,
                        )
                    }
                }
            }
        }
    }

    /**
     * Merge-order + supersede wiring (called once from the init below, before any catalog load): the Discover
     * document joins every merge AFTER the real sources; a real row with the same appleMusicId supersedes the
     * provisional twin, whose collection references then follow it (collections + favorites remap).
     */
    private fun wireDiscover() {
        val repo = app.catalogRepository
        repo.provisionalSources = { real -> discoverAdds.resolve(real) }
        repo.onSupersede = { pairs ->
            app.appScope.launch(Dispatchers.IO) {
                runCatching {
                    discoverAdds.remove(pairs.map { it.first })
                    app.collections.remapSongIds(pairs)
                    app.collectionsGraph.favorites.remapSongIds(pairs)
                }
            }
        }
        repo.onAlbumsSuperseded = { pairs ->
            app.appScope.launch(Dispatchers.IO) { runCatching { discoverAdds.supersedeAlbums(pairs) } }
        }
    }

    init {
        wireDiscover()
        // Terminal rip errors outlive the in-memory tracker: persist them onto the owning album.
        app.appScope.launch(Dispatchers.IO) {
            app.ripJobTracker.jobs.collect { jobs ->
                runCatching {
                    discoverAdds.recordFailedTracks(
                        jobs.filterValues { it.phase == com.levi.pocketdj.data.rips.RipJob.PHASE_ERROR }.keys,
                    )
                }
            }
        }
    }

    private val discoverRips = object : com.levi.pocketdj.screens.discover.DiscoverRipPort {
        override suspend fun configured() = app.ripServerClient.isConfigured()
        override suspend fun request(songId: String, title: String, artist: String, appleMusicId: String, lengthMs: Int?) =
            if (!app.ripServerClient.isConfigured()) {
                com.levi.pocketdj.screens.discover.DiscoverRipOutcome.NoServer
            } else {
                val job = app.ripServerClient.requestRip(songId, title, artist, appleMusicId, lengthMs)
                app.ripJobTracker.adopt(songId, job)
                com.levi.pocketdj.screens.discover.DiscoverAddController.outcomeOf(job)
            }
        override suspend fun serverAlbumTracks(collectionId: String) = app.ripServerClient.albumTracks(collectionId).tracks
        override suspend fun albumExpansion(collectionId: String) = app.ripServerClient.albumTracks(collectionId)
        override fun watch(songId: String, jobId: String) { app.ripJobTracker.pollToReady(songId, jobId) }
        override suspend fun refreshManifest() { app.ripsRepository.refresh() }
    }

    private val discoverLibrary = object : com.levi.pocketdj.screens.discover.DiscoverLibraryPort {
        private fun token(r: com.levi.pocketdj.data.applemusic.AmResult<Unit>) =
            com.levi.pocketdj.screens.discover.libraryWriteToken(r)
        override suspend fun addSong(appleMusicId: String) =
            token(app.appleMusicApi.addToLibrary(com.levi.pocketdj.data.applemusic.AmLibraryKind.SONGS, listOf(appleMusicId)))
        override suspend fun addAlbum(appleMusicId: String) =
            token(app.appleMusicApi.addToLibrary(com.levi.pocketdj.data.applemusic.AmLibraryKind.ALBUMS, listOf(appleMusicId)))
        override suspend fun albumTracks(appleMusicId: String) =
            app.appleMusicApi.albumTracks(appleMusicId).let { (it as? com.levi.pocketdj.data.applemusic.AmResult.Ok)?.value }.orEmpty()
    }

    /** Discover "+ Add" flows (song add, album fan-out) and "Remove from Library". */
    val discoverController: com.levi.pocketdj.screens.discover.DiscoverAddController by lazy {
        com.levi.pocketdj.screens.discover.DiscoverAddController(discoverAdds, discoverRips, discoverLibrary).also { c ->
            c.onUserCatalogRemove = { item ->
                app.appScope.launch(Dispatchers.IO) {
                    app.collectionActivity.record(
                        kind = com.levi.pocketdj.data.activity.ActivityKind.CATALOG_REMOVE,
                        itemId = item.id, itemTitle = item.title, itemArtist = item.artist,
                    )
                }
            }
        }
    }

    /** Discover ＋ Add hooks the Discover tab calls. Return true when the add was accepted. */
    var discoverAddSong: suspend (com.levi.pocketdj.screens.discover.DiscoverHit) -> Boolean = { hit ->
        withContext(Dispatchers.IO) { discoverController.addSong(hit).accepted }
    }

    /** iOS Discover album rows are built around live per-track rip progress: the download intent. */
    var discoverAddAlbum: suspend (com.levi.pocketdj.screens.discover.DiscoverAlbumHit) -> Boolean = { hit ->
        withContext(Dispatchers.IO) {
            discoverController.addAlbum(hit, com.levi.pocketdj.screens.discover.AlbumAddIntent.AND_PREPARE_COPIES).accepted
        }
    }

    /** Per-album n/m settle state for the Discover album rows (keyed by provisional album id). */
    val discoverAlbumStates: kotlinx.coroutines.flow.Flow<Map<String, com.levi.pocketdj.data.discover.DiscoverAddState>> by lazy {
        discoverController.albumStates(
            readyIds = app.ripsRepository.manifest.map { it.keys },
            erroredIds = app.ripJobTracker.jobs.map { jobs ->
                jobs.filterValues { it.phase == com.levi.pocketdj.data.rips.RipJob.PHASE_ERROR }.keys
            },
        )
    }

    /** "Add to Apple Music again" for a recorded provisional album; returns the stored write token. */
    suspend fun retryAlbumLibraryWrite(hit: com.levi.pocketdj.screens.discover.DiscoverAlbumHit): String =
        withContext(Dispatchers.IO) { discoverController.retryAlbumLibraryWrite(hit.id, hit.appleMusicId) }

    /** Pre-release refresh (launch/foreground): recheck provisional Discover albums, at most daily until release day. */
    fun refreshProvisionalAlbums() {
        if (!provisionalRefreshing.compareAndSet(false, true)) return // single-flight
        app.appScope.launch(Dispatchers.IO) {
            try { runCatching { discoverController.refreshProvisionalAlbums() } } finally { provisionalRefreshing.set(false) }
        }
    }
    private val provisionalRefreshing = java.util.concurrent.atomic.AtomicBoolean(false)

    /** "Remove from Library" for a user-added provisional song (Discover / Imported). */
    fun removeFromLibrary(songId: String, sourceName: String?, title: String, artist: String?): Boolean =
        discoverController.removeFromLibrary(songId, sourceName, title, artist) { id ->
            app.collectionsGraph.importedSongs.remove(listOf(id))
        }

    suspend fun hasMusicUserToken(): Boolean = app.settings.current().hasAppleMusic

    // ---- BRW-17: "?♪?" song recognizer ------------------------------------------------------

    /**
     * The capture + match pipeline. Release uses the vendored ShazamKit 2.1.1 AAR (app/libs); debug keeps the 12 s no-match stub so the emulator flow is drivable.
     */
    var shazamBackend: com.levi.pocketdj.screens.shazam.RecognitionBackend =
        if (com.levi.pocketdj.BuildConfig.DEBUG) com.levi.pocketdj.screens.shazam.DebugListeningBackend
        else com.levi.pocketdj.screens.shazam.ShazamKitBackend(app.musicKitDevTokenClient)

    /** Apple Music Web API adapter behind the result sheet's Apple Music block. */
    val appleMusicRecognition: com.levi.pocketdj.screens.shazam.AppleMusicRecognitionPort by lazy {
        object : com.levi.pocketdj.screens.shazam.AppleMusicRecognitionPort {
            private fun <T> com.levi.pocketdj.data.applemusic.AmResult<T>.okOrNull() =
                (this as? com.levi.pocketdj.data.applemusic.AmResult.Ok)?.value

            override val available get() = true
            override suspend fun canContribute() = app.settings.current().hasAppleMusic
            override val canAdd get() = true

            @Volatile private var storefront: String? = null
            private suspend fun sf(): String {
                storefront?.let { return it }
                return (app.appleMusicApi.userStorefront().okOrNull() ?: "us").also { storefront = it }
            }

            override suspend fun resolve(storeId: String?, title: String?, artist: String?):
                com.levi.pocketdj.data.applemusic.AppleMusicResolution? {
                val api = app.appleMusicApi
                val front = sf()
                var song = if (!storeId.isNullOrBlank()) api.recognizedSong(storeId, front).okOrNull() else null
                if (song == null) {
                    val term = listOfNotNull(title, artist).joinToString(" ").trim()
                    if (term.isNotEmpty()) song = api.recognizedSongSearch(term, front).okOrNull()
                }
                song ?: return null
                val rows = api.librarySongRows("${song.title} ${song.artist}".trim()).okOrNull().orEmpty()
                return song.copy(inLibrary = com.levi.pocketdj.screens.shazam.libraryRowsContain(rows, song.title, song.artist))
            }

            override suspend fun addSongToLibrary(storeId: String) =
                app.appleMusicApi.addToLibrary(com.levi.pocketdj.data.applemusic.AmLibraryKind.SONGS, listOf(storeId)) is
                    com.levi.pocketdj.data.applemusic.AmResult.Ok

            override suspend fun startRipAndBurn(songId: String, title: String, artist: String, storeId: String):
                com.levi.pocketdj.screens.shazam.RipStart {
                if (!app.ripServerClient.isConfigured()) return com.levi.pocketdj.screens.shazam.RipStart.NO_SERVER
                val burns = app.servicesGraph.burnStore
                // Intent first: whichever path sees the rip land (tracker onRipReady / launch drain) finishes the burn.
                burns.burnWhenRipped(songId, title, artist)
                if (app.ripsRepository.entry(songId) != null) {
                    burns.drainPendingAfterRip()
                    return com.levi.pocketdj.screens.shazam.RipStart.REQUESTED
                }
                val job = app.ripServerClient.requestRip(songId, title, artist, storeId, null)
                app.ripJobTracker.adopt(songId, job)
                if (job.isReady) {
                    // Already ripped server-side: the tracker will never fire, so refresh + drain here.
                    runCatching { app.ripsRepository.refresh() }
                    burns.drainPendingAfterRip()
                } else {
                    job.jobId?.let { app.ripJobTracker.pollToReady(songId, it) }
                }
                return com.levi.pocketdj.screens.shazam.RipStart.REQUESTED
            }
        }
    }

    /** App-scoped add -> rip -> burn driver for the recognizer sheet (survives sheet dismissal). */
    val recognitionAdds: com.levi.pocketdj.screens.shazam.RecognitionAddController by lazy {
        com.levi.pocketdj.screens.shazam.RecognitionAddController(app.appScope + Dispatchers.IO, appleMusicRecognition)
    }

    /** On-demand lyrics (memory -> disk `filesDir/lyrics-cache` -> catalog CDN). */
    val lyricsStore: com.levi.pocketdj.data.lyrics.LyricsStore by lazy {
        com.levi.pocketdj.data.lyrics.LyricsStore(
            cacheDir = java.io.File(app.appContext.filesDir, com.levi.pocketdj.data.lyrics.LyricsStore.DIR_NAME),
            baseUrl = { com.levi.pocketdj.data.config.Endpoints.CATALOG_BASE },
            fetch = com.levi.pocketdj.data.lyrics.LyricsStore.httpFetcher(app.httpClient),
        )
    }

    override val syncEntries: List<com.levi.pocketdj.shell.SyncEntry> = recsSyncEntries(recFeedbackLazy, forYouFeedLazy) +
        // iOS cloudSync "rec-key": every device of the profile presents the SAME bearer key (server TOFU binding).
        com.levi.pocketdj.shell.SyncEntry(REC_KEY_SYNC_KEY, REC_KEY_FILE, onPulled = { recServiceLazy.value.reloadKeyFromDisk() }) +
        // iOS cloudSync "discover-adds": an add on one device shows up in the other's catalog on the next pull.
        com.levi.pocketdj.shell.SyncEntry(
            DISCOVER_ADDS_SYNC_KEY, com.levi.pocketdj.data.discover.DiscoverAddsStore.FILE_NAME,
            onPulled = { discoverAdds.reloadFromDisk() },
        )

    /** Account deletion / "Erase everything" (iOS AccountDeletionService clears both). */
    override val resetHooks: List<com.levi.pocketdj.shell.ResetHook> = recsResetHooks(recFeedbackLazy, forYouFeedLazy) +
        // iOS AccountDeletionService: server DELETE first; a failure parks the credential in the tombstone.
        com.levi.pocketdj.shell.ResetHook {
            val svc = recServiceLazy.value
            svc.clearLocal(cloudDeleted = svc.deleteCloudData())
        } +
        com.levi.pocketdj.shell.ResetHook { discoverAdds.clear() }

    override val settingsSections: List<SettingsSection> by lazy {
        listOf(editionSection(), onlineSearchSection(), forYouSection(), recommendationsSection())
    }

    internal companion object {
        const val REC_FEEDBACK_SYNC_KEY = "rec-feedback"
        const val REC_FEEDBACK_FILE = "pocketdj-rec-feedback.json"
        const val FORYOU_FEED_SYNC_KEY = "foryou-feed"
        const val REC_KEY_SYNC_KEY = "rec-key"
        const val DISCOVER_ADDS_SYNC_KEY = com.levi.pocketdj.data.discover.DiscoverAddsStore.SYNC_KEY
        const val REC_KEY_FILE = "pocketdj-rec-key.json"
        const val REC_SYNC_FILE = "pocketdj-rec-sync.json"
        const val REC_PENDING_DELETE_FILE = "pocketdj-rec-pending-delete.json"

        /** iOS cloudSync "rec-feedback" + "foryou-feed". The sync engine runs off-main, so touching the lazies is safe. */
        fun recsSyncEntries(
            fb: Lazy<com.levi.pocketdj.data.recs.RecFeedbackStore>,
            feed: Lazy<com.levi.pocketdj.data.recs.ForYouFeedStore>,
        ) = listOf(
            com.levi.pocketdj.shell.SyncEntry(
                REC_FEEDBACK_SYNC_KEY, REC_FEEDBACK_FILE,
                onPulled = { fb.value.reloadFromDisk() },
                applyPayload = { fb.value.applyPulledPayload(it) },
            ),
            com.levi.pocketdj.shell.SyncEntry(
                FORYOU_FEED_SYNC_KEY, com.levi.pocketdj.data.recs.ForYouFeedStore.FILE_NAME,
                onPulled = { feed.value.reloadFromDisk() },
                applyPayload = { feed.value.applyPulledPayload(it) },
            ),
        )

        fun recsResetHooks(
            fb: Lazy<com.levi.pocketdj.data.recs.RecFeedbackStore>,
            feed: Lazy<com.levi.pocketdj.data.recs.ForYouFeedStore>,
        ) = listOf(
            com.levi.pocketdj.shell.ResetHook { fb.value.clear() },
            com.levi.pocketdj.shell.ResetHook { feed.value.clear() },
        )

        /** ON_STOP flush for the debounced decisions write; no-op until first touched. */
        fun recsFlushable(fb: Lazy<com.levi.pocketdj.data.recs.RecFeedbackStore>) =
            Flushable { if (fb.isInitialized()) fb.value.flush() }
        const val HISTORY_WRITE_DEBOUNCE_MS = 400L
    }
}

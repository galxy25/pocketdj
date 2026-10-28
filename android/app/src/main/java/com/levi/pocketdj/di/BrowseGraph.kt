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
        override fun watch(songId: String, jobId: String) { app.ripJobTracker.pollToReady(songId, jobId) }
        override suspend fun refreshManifest() { app.ripsRepository.refresh() }
    }

    private val discoverLibrary = object : com.levi.pocketdj.screens.discover.DiscoverLibraryPort {
        private fun token(r: com.levi.pocketdj.data.applemusic.AmResult<Unit>) = when (r) {
            is com.levi.pocketdj.data.applemusic.AmResult.Ok -> com.levi.pocketdj.screens.discover.LibraryWrite.CONFIRMED_WEB
            com.levi.pocketdj.data.applemusic.AmResult.NeedsUserToken -> com.levi.pocketdj.screens.discover.LibraryWrite.SKIPPED_NO_CONNECTION
            is com.levi.pocketdj.data.applemusic.AmResult.RateLimited -> com.levi.pocketdj.screens.discover.LibraryWrite.failed("rate limited")
            is com.levi.pocketdj.data.applemusic.AmResult.Failure -> com.levi.pocketdj.screens.discover.LibraryWrite.failed(r.message)
        }
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

    /** "Remove from Library" for a user-added provisional song (Discover / Imported). */
    fun removeFromLibrary(songId: String, sourceName: String?, title: String, artist: String?): Boolean =
        discoverController.removeFromLibrary(songId, sourceName, title, artist) { id ->
            app.collectionsGraph.importedSongs.remove(listOf(id))
        }

    suspend fun hasMusicUserToken(): Boolean = app.settings.current().hasAppleMusic

    // ---- BRW-17: "?♪?" song recognizer ------------------------------------------------------

    /**
     * The capture + match pipeline. The ShazamKit-for-Android AAR (app/libs/shazamkit-android.aar) is not in
     * the repo, so this defaults to the unavailable backend; the AudioRecord/StreamingSession adapter replaces it.
     */
    var shazamBackend: com.levi.pocketdj.screens.shazam.RecognitionBackend =
        com.levi.pocketdj.screens.shazam.UnavailableRecognitionBackend

    /** Apple Music Web API adapter behind the result sheet's Apple Music block. */
    val appleMusicRecognition: com.levi.pocketdj.screens.shazam.AppleMusicRecognitionPort by lazy {
        object : com.levi.pocketdj.screens.shazam.AppleMusicRecognitionPort {
            private fun <T> com.levi.pocketdj.data.applemusic.AmResult<T>.okOrNull() =
                (this as? com.levi.pocketdj.data.applemusic.AmResult.Ok)?.value

            override val available get() = true
            override suspend fun canContribute() = app.settings.current().hasAppleMusic
            override val canAdd get() = true

            override suspend fun resolve(storeId: String?, title: String?, artist: String?):
                com.levi.pocketdj.screens.shazam.AppleMusicResolution? {
                val api = app.appleMusicApi
                var song = if (!storeId.isNullOrBlank()) api.recognizedSong(storeId).okOrNull() else null
                if (song == null) {
                    val term = listOfNotNull(title, artist).joinToString(" ").trim()
                    if (term.isNotEmpty()) song = api.recognizedSongSearch(term).okOrNull()
                }
                song ?: return null
                val inLib = api.librarySongsContain("${song.title} ${song.artist}".trim(), song.title, song.artist).okOrNull() ?: false
                return song.copy(inLibrary = inLib)
            }

            override suspend fun addSongToLibrary(storeId: String) =
                app.appleMusicApi.addToLibrary(com.levi.pocketdj.data.applemusic.AmLibraryKind.SONGS, listOf(storeId)) is
                    com.levi.pocketdj.data.applemusic.AmResult.Ok

            override suspend fun startRipAndBurn(songId: String, title: String, artist: String, storeId: String) {
                if (!app.ripServerClient.isConfigured()) return
                val job = app.ripServerClient.requestRip(songId, title, artist, storeId, null)
                app.ripJobTracker.adopt(songId, job)
                job.jobId?.takeIf { !job.isReady }?.let { app.ripJobTracker.pollToReady(songId, it) }
            }
        }
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

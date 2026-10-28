package com.levi.pocketdj.di

import com.levi.pocketdj.data.applemusic.AMPlaylistSyncClient
import com.levi.pocketdj.data.applemusic.AmAutoSyncWorker
import com.levi.pocketdj.data.applemusic.AmSyncHost
import com.levi.pocketdj.data.applemusic.AmSyncSettings
import com.levi.pocketdj.data.applemusic.AppleMusicAutoSync
import com.levi.pocketdj.data.applemusic.AutoSyncGate
import com.levi.pocketdj.data.applemusic.CollectionsAmSyncHost
import com.levi.pocketdj.data.applemusic.DefaultAppleMusicTokens
import com.levi.pocketdj.data.applemusic.PlaylistAppleMusicSync
import com.levi.pocketdj.data.applemusic.SharedPrefsAmJobStore
import com.levi.pocketdj.data.applemusic.WriteBackSettings
import com.levi.pocketdj.data.applemusic.PlaylistWriteBack
import com.levi.pocketdj.data.applemusic.WebApiPlaylistWriteBackTransport
import com.levi.pocketdj.data.collections.CollectionsStore
import com.levi.pocketdj.data.favorites.FavoritesAccess
import com.levi.pocketdj.data.favorites.FavoritesStore
import com.levi.pocketdj.data.favorites.favoriteActivityRecorder
import com.levi.pocketdj.data.store.VersionedJsonWriter
import com.levi.pocketdj.shell.FeatureModule
import com.levi.pocketdj.shell.Flushable
import java.io.File
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.flow.distinctUntilChanged
import kotlinx.coroutines.flow.first
import kotlinx.coroutines.flow.map
import kotlinx.coroutines.launch
import kotlinx.coroutines.withContext
import com.levi.pocketdj.data.collections.SourceSyncSettings

/**
 * Sidecar graph for the collections area (decision D3). Contributes the ON_STOP flush
 * barrier: both documents are written inline when dirty (superseding queued off-main writes; FlushOnStop in MainActivity drives it via ProcessLifecycleOwner) so a
 * process kill right after backgrounding cannot lose a batch add (D6).
 */
class CollectionsGraph(private val app: AppGraph) : FeatureModule {
    override val area: String = "collections"

    /**
     * Per-profile favorites (COL-10). Lazy — reads its doc on first touch. User toggles (and
     * only those) append one heart/unheart row to the activity log with live-catalog
     * title/artist snapshots.
     */
    val favorites: FavoritesStore by lazy {
        File(app.appContext.filesDir, FavoritesStore.FILE_NAME).let { f ->
            FavoritesStore(f, writer = VersionedJsonWriter(f, VersionedJsonWriter.backgroundExecutor("pdj-favorites-writer")))
        }.also { store ->
            val record = favoriteActivityRecorder(app.collectionActivity) { id ->
                app.catalogRepository.state.value.catalog?.songsById?.get(id)?.let { it.name to it.artist }
            }
            store.onChanged = { e ->
                record(e)
                // COL-11: push the tap now (no-op when opted out / no AM id / signed out).
                app.appScope.launch(Dispatchers.IO) { runCatching { favoritesSync.pushNow(e) } }
            }
        }
    }

    /** Opt-in two-way Apple Music favorites sync (COL-11). Zero requests while the toggle is OFF. */
    val favoritesSync: com.levi.pocketdj.data.favorites.FavoritesSyncService by lazy {
        com.levi.pocketdj.data.favorites.FavoritesSyncService(
            favorites = favorites,
            remote = com.levi.pocketdj.data.favorites.ApiFavoritesRemote(app.appleMusicApi, amTokens),
            twoWayEnabled = { app.settings.get(com.levi.pocketdj.data.favorites.FavoritesSyncSettings.TWO_WAY) },
            seedOptIn = { app.settings.get(com.levi.pocketdj.data.favorites.FavoritesSyncSettings.APPLY_OWNER_SEED) },
            catalogPairs = {
                app.catalogRepository.state.value.catalog?.songsById?.values
                    ?.mapNotNull { s -> s.appleMusicId?.let { s.id to it } }.orEmpty()
            },
            ready = { app.onboarding.isComplete && app.catalogRepository.state.value.catalog != null },
            fetchSeed = {
                kotlinx.coroutines.withContext(Dispatchers.IO) {
                    app.httpClient.newCall(
                        okhttp3.Request.Builder().url(com.levi.pocketdj.data.config.Endpoints.FAVORITES_SEED_URL).build(),
                    ).execute().use { r -> if (!r.isSuccessful) error("seed ${r.code}"); r.body!!.string() }
                }
            },
        )
    }

    /**
     * The playback `FavoriteSeam` shape (isFavorite/toggle by songId): resolves the song's
     * Apple Music catalog id from the live catalog so the lock-screen ♥ queues a mirrorable entry.
     */
    val favoriteAccess: FavoritesAccess by lazy {
        object : FavoritesAccess {
            override fun isFavorite(songId: String) = favorites.isFavorite(songId)
            override fun toggle(songId: String, appleMusicId: String?): Boolean = favorites.toggle(
                songId,
                appleMusicId ?: app.catalogRepository.state.value.catalog?.songsById?.get(songId)?.appleMusicId,
            )
            override fun set(songId: String, favorited: Boolean, appleMusicId: String?) = favorites.set(
                songId, favorited,
                appleMusicId ?: app.catalogRepository.state.value.catalog?.songsById?.get(songId)?.appleMusicId,
            )
        }
    }

    /**
     * Nullable rec seam for the Add-to sheet's Suggested row / the context submenu: songId ->
     * collection suggestions. Unwired (null) ⇒ no Suggested section (a later rec package sets it).
     */
    @Volatile
    var collectionSuggestions: ((String) -> List<com.levi.pocketdj.screens.collections.CollectionSuggestion>)? = null

    /** Memoized virtual "Recently added" derivation (COL-12). */
    val recentlyAdded: com.levi.pocketdj.data.collections.RecentlyAddedBuilder by lazy { com.levi.pocketdj.data.collections.RecentlyAddedBuilder() }

    /** Window-scoped multi-select state shared by Browse and every collection detail (COL-5). */
    val rowSelection: com.levi.pocketdj.ui.selection.RowSelection by lazy { com.levi.pocketdj.ui.selection.RowSelection() }

    /**
     * The durable Apple Music write-back queue (COL-8). Lazy - decodes its own device-local document
     * on first touch. Transport = Apple Music Web API (dev token + Music-User-Token, SVC-15).
     */
    val writeBack: PlaylistWriteBack by lazy {
        val tokens = DefaultAppleMusicTokens(app.musicKitDevTokenClient, app.settings)
        PlaylistWriteBack(
            file = File(app.appContext.filesDir, PlaylistWriteBack.FILE_NAME),
            transport = WebApiPlaylistWriteBackTransport(app.appleMusicApi, tokens),
            scope = app.appScope,
        ).also { wb ->
            // Catalog seam for the playlist JOIN tie-break (kept out of the queue so it stays data-layer free).
            wb.appleMusicIdsForIndexPlaylist = { indexPlaylistId ->
                val catalog = app.catalogRepository.state.value.catalog
                catalog?.playlists?.firstOrNull { it.playlist.id == indexPlaylistId }
                    ?.playlist?.songIds.orEmpty().mapNotNull { catalog?.songsById?.get(it)?.appleMusicId }
            }
        }
    }

    /**
     * Wire the store's write-back seams (called once from AppGraph's `collections` initializer).
     * Unconditional like the iOS wiring (append-only + non-destructive), gated only on `canWriteBack`.
     * The queue itself is created lazily: nothing is read from disk until the first add/drain.
     */
    fun wireWriteBack(store: CollectionsStore) {
        wireImported(store)
        store.enqueueSourceWriteBack = { item ->
            val wb = writeBack
            if (!wb.canWriteBack) {
                false
            } else {
                val job = wb.enqueue(
                    item.indexPlaylistId, item.playlistName, item.songId, item.appleMusicId,
                    item.title, item.artist, item.album, item.durationMs,
                )
                wb.runSoon()
                job != null
            }
        }
        store.enqueueSourceWriteBackBatch = { items ->
            val wb = writeBack
            if (!wb.canWriteBack) {
                0
            } else {
                val queued = wb.enqueueMany(items)
                if (queued > 0) wb.runSoon()
                queued
            }
        }
        store.canWriteBackUpstream = { writeBack.canWriteBack }
        store.cancelPendingWriteBacks = { indexPlaylistId, songIds -> writeBack.cancelPending(indexPlaylistId, songIds) }
    }

    // ---- Apple Music playlist sync (COL-9) ---------------------------------------------------

    private val amTokens by lazy { DefaultAppleMusicTokens(app.musicKitDevTokenClient, app.settings) }

    /** The WS2 Lambda client. Base = Settings debug override when set, else the live endpoint config. */
    val amSyncClient: AMPlaylistSyncClient by lazy {
        AMPlaylistSyncClient(
            http = app.httpClient,
            tokens = amTokens,
            jobs = SharedPrefsAmJobStore(app.appContext),
            baseProvider = {
                val o = if (com.levi.pocketdj.BuildConfig.DEBUG) runCatching { app.settings.get(AmSyncSettings.BASE_OVERRIDE) }.getOrDefault("") else ""
                o.trim().ifEmpty { com.levi.pocketdj.data.config.RemoteEndpoints.url(com.levi.pocketdj.data.config.EndpointKey.AM_PLAYLIST_SYNC_BASE) }
            },
        )
    }

    /** Sync coordinator (steps, audit trail, interrupted-run hydration). Lazy - reads its docs on first touch. */
    val playlistAmSync: PlaylistAppleMusicSync by lazy {
        PlaylistAppleMusicSync(
            client = amSyncClient,
            transport = WebApiPlaylistWriteBackTransport(app.appleMusicApi, amTokens),
            auditFile = File(app.appContext.filesDir, PlaylistAppleMusicSync.AUDIT_FILE),
            runFile = File(app.appContext.filesDir, PlaylistAppleMusicSync.RUN_FILE),
            catalogLookupsFile = File(app.appContext.filesDir, PlaylistAppleMusicSync.LOOKUPS_FILE),
        ).also { sync ->
            sync.importNewPlaylistsEnabled = { runCatching { app.settings.get(AmSyncSettings.IMPORT_NEW) }.getOrDefault(false) }
        }
    }

    val amSyncHost: AmSyncHost by lazy {
        CollectionsAmSyncHost(app.collections) { app.catalogRepository.state.value.catalog }
    }

    private val autoSyncGate by lazy {
        AutoSyncGate(
            enabled = { app.settings.get(AmSyncSettings.AUTO_ENABLED) },
            minutesOfDay = { AmSyncSettings.clampMinutes(app.settings.get(AmSyncSettings.AUTO_MINUTES)) },
            lastRunMs = { app.settings.get(AmSyncSettings.LAST_AUTO_MS).takeIf { it > 0.0 } },
            setLastRunMs = { app.settings.set(AmSyncSettings.LAST_AUTO_MS, it) },
        )
    }

    /**
     * Foreground / periodic entry (iOS `autoSyncIfDue`): resume an interrupted run, then run the
     * daily pass if its local fire time has passed (claim-before-run). Needs a loaded catalog.
     */
    suspend fun autoSyncTick() {
        if (!app.onboarding.isComplete) return
        if (app.catalogRepository.state.value.catalog == null) return
        val host = amSyncHost
        playlistAmSync.resumeIfInterrupted(host)
        autoSyncGate.runIfDue { runFullPass() }
    }

    /**
     * Manual Sync/Send/Get (iOS `runCollectionsNow`) on the APP scope so leaving Settings does not
     * cancel it: playlist sync, converted-collections reconcile (not push-only), write-back backfill (not pull-only).
     */
    fun startManualSync(direction: PlaylistAppleMusicSync.Direction): kotlinx.coroutines.Job =
        app.appScope.launch(Dispatchers.IO) { runManual(direction) }

    suspend fun runManual(direction: PlaylistAppleMusicSync.Direction) {
        playlistAmSync.syncNow(amSyncHost, direction)
        if (direction != PlaylistAppleMusicSync.Direction.PUSH) {
            app.catalogRepository.state.value.catalog?.let { app.collections.syncConvertedCollections(it.playlists) }
        }
        if (direction != PlaylistAppleMusicSync.Direction.PULL) backfillWriteBacks()
    }

    private suspend fun backfillWriteBacks() {
        if (!writeBack.canWriteBack) return
        val days = WriteBackSettings.clampDays(app.settings.get(WriteBackSettings.BACKFILL_DAYS))
        val n = app.collections.backfillSourceWriteBacks(
            events = app.collectionActivity.state.value.events,
            days = days,
            localInstallId = app.collectionActivity.installId,
        )
        if (n > 0) writeBack.runSoon()
    }

    /** The unattended full pass: two-way playlist sync, converted-collections reconcile, write-back backfill. */
    suspend fun runFullPass() {
        val catalog = app.catalogRepository.state.value.catalog
        playlistAmSync.syncNow(amSyncHost, PlaylistAppleMusicSync.Direction.BOTH)
        if (catalog != null) app.collections.syncConvertedCollections(catalog.playlists)
        backfillWriteBacks()
    }

    override val periodicWork: List<com.levi.pocketdj.shell.PeriodicWorkSpec> by lazy {
        com.levi.pocketdj.work.WorkerRegistry.register(AppleMusicAutoSync.WORK_ID, AmAutoSyncWorker::class.java)
        listOf(com.levi.pocketdj.shell.PeriodicWorkSpec(AppleMusicAutoSync.WORK_ID, repeatMinutes = 60, requiresNetwork = true))
    }

    /** Provisional "Imported" catalog source (COL-15); lazy - reads its small doc on first touch. */
    val importedSongs: com.levi.pocketdj.data.catalog.ImportedSongsStore by lazy {
        com.levi.pocketdj.data.catalog.ImportedSongsStore(
            File(app.appContext.filesDir, com.levi.pocketdj.data.catalog.ImportedSongsStore.FILE_NAME),
        )
    }

    /**
     * Wire portable-zip imports into the catalog (called from [wireWriteBack], i.e. once from the
     * `collections` initializer - touching `app.collections` from this graph's own init would recurse).
     * Imported items append LAST in the merge (real sources shadow them); a change refreshes the catalog.
     */
    private fun wireImported(store: CollectionsStore) {
        wireCatalogSource()
        importedSongs.onChanged = { app.catalogRepository.remergeLocal() }
        store.onPortableItems = { payload ->
            app.appScope.launch(Dispatchers.IO) { runCatching { importedSongs.addPortable(payload) } }
        }
    }

    /** Idempotent: the "Imported" synthetic source joins every catalog merge (also at cold-start seed). */
    private fun wireCatalogSource() {
        app.catalogRepository.syntheticDocuments = { listOfNotNull(importedSongs.syntheticDocument()) }
    }

    /** Tapped `.pdjcollection` → importAny → snackbar counts (claims DeepLinkSeams.importCollection). */
    private val importSeam: com.levi.pocketdj.shell.CollectionImportSeam by lazy {
        com.levi.pocketdj.shell.CollectionImportSeam(
            scope = app.appScope,
            read = { uri ->
                com.levi.pocketdj.data.backup.CollectionShare.readUri(app.appContext.contentResolver, android.net.Uri.parse(uri))
            },
            import = { app.collections.importAny(it) },
            restoreBackup = { bytes ->
                kotlinx.coroutines.runBlocking {
                    com.levi.pocketdj.screens.settings.sections.BackupCoordinator.restore(app, bytes)
                }
            },
        )
    }

    override val deepLinkHandlers: List<com.levi.pocketdj.shell.DeepLinkHandler> by lazy {
        // The dispatcher (ShellGraph) parses/gates file links and calls the seam; claim it here.
        wireCatalogSource()
        runCatching { importSeam.install(app.shellGraph.deepLinkSeams) }
        // DEBUG-only emulator hooks for the COL-9 sync step: `-e pdj.amSyncBase <url>` points the
        // Lambda client at a local mock; `-e pdj.fakeMut <token>` stands in for an Apple Music sign-in.
        listOf(com.levi.pocketdj.shell.DeepLinkHandler { intent ->
            if (com.levi.pocketdj.BuildConfig.DEBUG) {
                intent.getStringExtra("pdj.amSyncBase")?.let { b ->
                    app.appScope.launch { runCatching { app.settings.set(AmSyncSettings.BASE_OVERRIDE, b) } }
                }
                intent.getStringExtra("pdj.pocketsBase")?.let { pocketsDebugBase = it }
                if (intent.hasExtra("pdj.pocketsFakeCreds")) pocketsDebugCreds = true
                intent.getStringExtra("pdj.pocketsEnable")?.let { v ->
                    app.appScope.launch(Dispatchers.IO) {
                        runCatching { app.settings.set(com.levi.pocketdj.data.pockets.PocketsSettings.LISTENING_POCKETS_ENABLED, v == "1") }
                    }
                }
                intent.getStringExtra("pdj.amApiBase")?.let { com.levi.pocketdj.data.applemusic.AppleMusicApi.debugBase = it }
                intent.getStringExtra("pdj.fakeMut")?.let { t ->
                    app.appScope.launch { runCatching { app.settings.setMusicUserToken(t) } }
                }
            }
            if (com.levi.pocketdj.BuildConfig.DEBUG && intent.hasExtra("pdj.autoDump")) {
                com.levi.pocketdj.auto.AutoBrowseDebug.run(
                    app.appContext, app.appScope,
                    picks = intent.getStringExtra("pdj.autoPick").orEmpty().split("|").filter { it.isNotBlank() },
                    roots = listOf("Mix", "Jukebox"),
                )
            }
            false // never consumes the intent
        })
    }

    override val settingsSections: List<com.levi.pocketdj.shell.SettingsSection> by lazy {
        listOf(
            com.levi.pocketdj.screens.settings.sections.backupSection(),
            com.levi.pocketdj.screens.settings.sections.collectionsSyncSection(),
            com.levi.pocketdj.screens.settings.appleMusicSyncSection(),
            com.levi.pocketdj.screens.settings.appleMusicWriteBackSection(),
            com.levi.pocketdj.screens.settings.appleMusicFavoritesSection(),
        )
    }

    override val flushables: List<Flushable> = listOf(
        Flushable {
            app.collections.flushNow()
            app.collectionActivity.flushNow()
            favorites.flushNow()
        },
    )


    // ---- COL-17: listening pockets service + real PocketsBridge ------------------------------------------

    private val pocketsEnabledMirror = java.util.concurrent.atomic.AtomicBoolean(false)

    /**
     * The listening-pockets service. Inert (zero network) until BOTH the rec engine and "Find my listening
     * pockets" are ON and the rec-engine credentials exist. Touch off-main (reads two small docs).
     */
    val listeningPockets: com.levi.pocketdj.data.pockets.ListeningPocketsService by lazy {
        val files = app.appContext.filesDir
        com.levi.pocketdj.data.pockets.ListeningPocketsService(
            history = com.levi.pocketdj.data.history.PlayHistoryStore.get(app.appContext),
            client = com.levi.pocketdj.data.pockets.ListeningPocketsClient(
                http = app.httpClient,
                baseUrl = {
                    (if (com.levi.pocketdj.BuildConfig.DEBUG) pocketsDebugBase else null)
                        ?: com.levi.pocketdj.data.config.RemoteEndpoints.url(com.levi.pocketdj.data.config.EndpointKey.LISTENING_POCKETS_BASE)
                },
                deviceId = { pocketsDeviceId },
            ),
            credentials = ::pocketsCredentials,
            recEngineEnabled = { (com.levi.pocketdj.BuildConfig.DEBUG && pocketsDebugCreds) || app.browseGraph.recEnabled.value },
            pocketsEnabled = { pocketsEnabledMirror.get() },
            scope = kotlinx.coroutines.CoroutineScope(app.appScope.coroutineContext + Dispatchers.IO),
            syncFile = File(files, com.levi.pocketdj.data.pockets.ListeningPocketsService.SYNC_FILE_NAME),
            cacheFile = File(files, com.levi.pocketdj.data.pockets.ListeningPocketsService.CACHE_FILE_NAME),
            deviceId = { pocketsDeviceId },
        ).also { svc ->
            svc.collectionsProvider = ::pocketsCollectionsInput
            svc.onDisabled = {
                app.appScope.launch(Dispatchers.IO) {
                    runCatching { app.settings.set(com.levi.pocketdj.data.pockets.PocketsSettings.LISTENING_LOCATION_ENABLED, false) }
                }
            }
            svc.onUploadFloor = { ms -> app.gamesGraph.roundsClient.setUploadFloor(ms) }
        }
    }

    @Volatile private var pocketsDeviceId: String? = null

    /** DEBUG emulator hooks (`-e pdj.pocketsBase <url>`, `-e pdj.pocketsFakeCreds 1`): mock backend + stand-in creds. */
    @Volatile private var pocketsDebugBase: String? = null
    @Volatile private var pocketsDebugCreds = false

    private fun pocketsCredentials(): com.levi.pocketdj.data.pockets.PocketsCredentials? =
        if (com.levi.pocketdj.BuildConfig.DEBUG && pocketsDebugCreds) {
            com.levi.pocketdj.data.pockets.PocketsCredentials("debug-key", "debug-profile", "debug-secret")
        } else app.browseGraph.recService.sharedCredentials()?.let {
            com.levi.pocketdj.data.pockets.PocketsCredentials(it.key, it.profileId, it.enrollSecret)
        }

    /** The membership snapshot input (iOS `collectionsInput`): pockets, playlists, source playlists, add log. */
    private fun pocketsCollectionsInput(): com.levi.pocketdj.data.pockets.ListeningPocketsCollections.Input {
        val pockets = app.collections.pockets
        val playlists = app.collections.playlists
        val activity = app.collectionActivity.events
        val catalog = app.catalogRepository.state.value.catalog
        val albums = com.levi.pocketdj.data.pockets.ListeningPocketsCollections.referencedAlbumCandidates(pockets, playlists, activity)
        val tracks = if (catalog == null) emptyMap() else albums.mapNotNull { id -> catalog.albumsById[id]?.let { id to it.trackList } }.toMap()
        val sources = catalog?.playlists.orEmpty().map {
            com.levi.pocketdj.data.collections.CollectionFlattener.SourcePlaylist(it.playlist.id, it.playlist.name, it.playlist.songIds)
        }
        return com.levi.pocketdj.data.pockets.ListeningPocketsCollections.Input(
            source = com.levi.pocketdj.data.collections.CollectionFlattener.Source(pockets, playlists, sources, tracks),
            activity = activity,
        )
    }

    /** Wires the service into games (real bridge + opt-in), the rec delete cascade and the history probes. Idempotent, off-main. */
    fun startListeningPockets() {
        app.appScope.launch(Dispatchers.IO) {
            pocketsDeviceId = runCatching { app.settings.ensureInstallId() }.getOrNull()
            val svc = listeningPockets
            val history = com.levi.pocketdj.data.history.PlayHistoryStore.get(app.appContext)
            val bridge = com.levi.pocketdj.data.pockets.LivePocketsBridge(
                service = svc,
                credentialsSource = ::pocketsCredentials,
                installIdSource = { history.installId },
                roundsUploader = { creds, wires, id -> app.gamesGraph.roundsClient.flush(creds, wires, id) },
            )
            app.gamesGraph.servicesBridge = bridge
            app.gamesGraph.pocketsOptIn = object : com.levi.pocketdj.screens.games.PocketsOptIn {
                override val recommendationsEnabled get() = app.browseGraph.recEnabled
                override fun choose(on: Boolean) {
                    app.appScope.launch(Dispatchers.IO) {
                        runCatching { app.settings.set(com.levi.pocketdj.data.pockets.PocketsSettings.LISTENING_POCKETS_ANSWERED, true) }
                        runCatching { app.settings.set(com.levi.pocketdj.data.pockets.PocketsSettings.LISTENING_POCKETS_ENABLED, on) }
                    }
                }
            }
            val listener = com.levi.pocketdj.data.pockets.PocketsPlayListener(svc, carConnected = ::carConnected)
            listener.attach(history)
            runCatching {
                app.browseGraph.recService.onDeleteCloudData = { key, profileId ->
                    svc.deleteCloudData(com.levi.pocketdj.data.pockets.PocketsCredentials(key, profileId, com.levi.pocketdj.data.config.REC_ENGINE_ENROLL_SECRET))
                }
            }
            // Seed the mirror from the stored pref BEFORE the first gate evaluation, so a cold start never reads
            // "pockets off" and closes the gate (which would switch places & trips off every launch).
            runCatching {
                pocketsEnabledMirror.set(app.settings.flow(com.levi.pocketdj.data.pockets.PocketsSettings.LISTENING_POCKETS_ENABLED).first())
            }
            svc.enabledDidChange()
            launch {
                // One collector over BOTH halves of the gate (rec engine + pockets); real changes only.
                kotlinx.coroutines.flow.combine(
                    app.browseGraph.recEnabled,
                    app.settings.flow(com.levi.pocketdj.data.pockets.PocketsSettings.LISTENING_POCKETS_ENABLED),
                ) { rec, pockets -> rec to pockets }
                    .distinctUntilChanged()
                    .collect { (_, pockets) ->
                        pocketsEnabledMirror.set(pockets)
                        svc.enabledDidChange()
                    }
            }
            withContext(Dispatchers.Main) {
                runCatching {
                    androidx.lifecycle.ProcessLifecycleOwner.get().lifecycle.addObserver(
                        androidx.lifecycle.LifecycleEventObserver { _, e ->
                            if (e == androidx.lifecycle.Lifecycle.Event.ON_STOP) listener.onBackgrounded()
                        },
                    )
                }
            }
        }
    }

    /** Car-projection signal: UI_MODE_TYPE_CAR only (a phone running Android Auto is not detectable without the car-app library). */
    private fun carConnected(): Boolean? = runCatching {
        val ui = app.appContext.getSystemService(android.content.Context.UI_MODE_SERVICE) as android.app.UiModeManager
        ui.currentModeType == android.content.res.Configuration.UI_MODE_TYPE_CAR
    }.getOrNull()

    init {
        // Warm the favorites doc off-main: the lazy constructor does a synchronous file read +
        // JSON decode that would otherwise land inside the first ♥ row's composition.
        app.appScope.launch(Dispatchers.IO) { favorites }
        startListeningPockets()
        // COL-8: drain any write-back queued in a previous session (or backed off after a failure) -
        // the queue has no internal timer, so launch is what re-arms it.
        app.appScope.launch(Dispatchers.IO) { runCatching { writeBack.runSoon() } }
        // ...and re-arm on every process foreground (iOS scenePhase .active) + after a Music-User-Token
        // sign-in: a long-lived process would otherwise leave backed-off / signed-out jobs parked.
        app.appScope.launch(Dispatchers.Main) {
            runCatching {
                androidx.lifecycle.ProcessLifecycleOwner.get().lifecycle.addObserver(
                    com.levi.pocketdj.data.applemusic.WriteBackForegroundDrain { writeBack.runSoon() },
                )
            }
        }
        // COL-11: launch + every foreground, drain/reconcile favorites (no-op while opted out).
        // Launch pass = the ON_START observer below (fires on add) + the first loaded catalog; both are
        // gated on onboarding + catalog (iOS syncFavoritesIfReady) so an empty catalog never "syncs".
        app.appScope.launch(Dispatchers.IO) {
            app.catalogRepository.state
                .map { it.catalog }
                .distinctUntilChanged { a, b -> (a == null) == (b == null) }
                .collect { c -> if (c != null) runCatching { favoritesSync.runIfReady() } }
        }
        app.appScope.launch(Dispatchers.Main) {
            runCatching {
                androidx.lifecycle.ProcessLifecycleOwner.get().lifecycle.addObserver(
                    com.levi.pocketdj.data.applemusic.WriteBackForegroundDrain {
                        app.appScope.launch(Dispatchers.IO) { runCatching { favoritesSync.runIfReady() } }
                    },
                )
            }
        }
        // COL-9: on every process foreground, resume an interrupted sync / run the daily pass if due.
        app.appScope.launch(Dispatchers.Main) {
            runCatching {
                androidx.lifecycle.ProcessLifecycleOwner.get().lifecycle.addObserver(
                    com.levi.pocketdj.data.applemusic.WriteBackForegroundDrain {
                        app.appScope.launch(Dispatchers.IO) { runCatching { autoSyncTick() } }
                    },
                )
            }
        }
        app.appScope.launch(Dispatchers.IO) {
            runCatching { app.musicKitAuth.onSignedIn = { writeBack.runSoon() } }
        }
        // Converted-collection source sync (COL-7, iOS onCatalogAssigned): every NEW catalog
        // snapshot (cache seed + refresh) reconciles source-linked pockets/playlists, gated by
        // the global Settings toggle (default ON). Same-instance re-emissions are skipped.
        app.appScope.launch(Dispatchers.IO) {
            app.catalogRepository.state
                .map { it.catalog }
                .distinctUntilChanged { a, b -> a === b }
                .collect { catalog ->
                    try {
                        val on = app.settings.get(SourceSyncSettings.SYNC_CONVERTED_POCKETS)
                        SourceSyncSettings.autoPass(on, catalog, app.collections)
                    } catch (e: kotlinx.coroutines.CancellationException) {
                        throw e
                    } catch (e: Exception) {
                        runCatching { android.util.Log.w("PocketDJ", "[source-sync] auto pass failed: $e") }
                    }
                }
        }
    }
}

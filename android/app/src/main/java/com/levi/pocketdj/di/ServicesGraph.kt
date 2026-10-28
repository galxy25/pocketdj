package com.levi.pocketdj.di

import com.levi.pocketdj.data.burns.AppPrivateBurnFolder
import com.levi.pocketdj.data.burns.BurnStore
import com.levi.pocketdj.data.burns.HttpBurnRips
import com.levi.pocketdj.data.config.Endpoints
import com.levi.pocketdj.data.store.VersionedJsonWriter
import com.levi.pocketdj.data.transfers.BearerPolicy
import com.levi.pocketdj.data.transfers.TransferCoordinator
import com.levi.pocketdj.data.transfers.TransferRuntime
import com.levi.pocketdj.data.transfers.WorkManagerTransferWork
import com.levi.pocketdj.diag.DiagServices
import java.io.File
import com.levi.pocketdj.screens.settings.sections.debugSection
import com.levi.pocketdj.shell.DeepLinkHandler
import com.levi.pocketdj.shell.FeatureModule
import com.levi.pocketdj.shell.Flushable
import com.levi.pocketdj.shell.SettingsSection
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.launch

/**
 * Sidecar graph for the services area (decision D3). Packages in this area override the
 * FeatureModule members they contribute and add their own lazies here — never in AppGraph.
 */
class ServicesGraph(private val app: AppGraph) : FeatureModule {
    override val area: String = "services"

    /** SVC-5 diagnostics stack. Touching [FeatureModule] lists below materializes the log. */
    val diag: DiagServices by lazy { DiagServices.get(app) }

    /** SVC-1 rip client plumbing (constructed in AppGraph because PlaybackController needs it). */
    val ripClient get() = app.ripServerClient
    val presignCache get() = app.presignCache
    val ripJobTracker get() = app.ripJobTracker

    /**
     * SVC-2 the ONE offline store: ledger `filesDir/pocketdj-burns.json`, media `filesDir/burns/`.
     * The download client is the plain app client — it never attaches the rip bearer to S3.
     */
    /**
     * SVC-3 the ONE background-transfer owner (WorkManager). Records persist in
     * `filesDir/pocketdj-transfers.json`; the rip token is read only to decide the bearer flag.
     */
    val transfers: TransferCoordinator by lazy {
        TransferCoordinator(
            file = File(app.appContext.filesDir, "pocketdj-transfers.json"),
            work = WorkManagerTransferWork(app.appContext),
            tokenProvider = { app.settings.current().ripToken },
            ripsHost = { BearerPolicy.hostOf(Endpoints.RIPS_BASE) },
        )
    }

    /**
     * What a (possibly cold-started) BurnDownloadWorker needs. Touching [burnStore] first wires the
     * coordinator's finalize/fail hooks so the ledger flips even when the process was woken by
     * WorkManager alone. The plain client never attaches auth on its own.
     */
    fun transferRuntime(): TransferRuntime {
        burnStore
        val burnsDir = File(app.appContext.filesDir, "burns")
        return TransferRuntime(
            transfers, app.httpClient,
            destDir = { _ -> burnsDir.also { it.mkdirs() } },
            refreshUrl = { rec -> app.ripServerClient.presign(rec.songId, 21_600) },
        )
    }

    private val burnStoreLazy: Lazy<BurnStore> = lazy {
        val rips = HttpBurnRips(
            http = app.httpClient,
            manifestEntry = { app.ripsRepository.entry(it) },
            serverConfigured = { app.ripServerClient.isConfigured() },
            presign = { id, ttl -> app.ripServerClient.presign(id, ttl) },
            ripsBase = { Endpoints.RIPS_BASE },
        )
        BurnStore(
            ledgerFile = File(app.appContext.filesDir, "pocketdj-burns.json"),
            folder = AppPrivateBurnFolder(File(app.appContext.filesDir, "burns")),
            rips = rips,
            lookup = { id ->
                val cat = app.catalogRepository.state.value.catalog
                val song = cat?.songsById?.get(id)
                song to song?.albumId?.let { cat.albumsById[it] }
            },
            writerExecutor = VersionedJsonWriter.backgroundExecutor("pdj-burns-writer"),
            transfers = transfers,
        )
    }
    val burnStore: BurnStore get() = burnStoreLazy.value

    /** SVC-4 collection Rip / Stop (user-requested rips are protected from the rip window). */
    val ripCoordinator: com.levi.pocketdj.data.rips.RipCollectionCoordinator by lazy {
        com.levi.pocketdj.data.rips.RipCollectionCoordinator(app.ripServerClient, app.ripJobTracker)
    }

    /** SVC-4 burned-first resolver: one instance feeds the LOCAL_FILE rung and every direct play path. */
    val burnedFirst: com.levi.pocketdj.playback.sequencer.BurnedRowResolver by lazy {
        com.levi.pocketdj.playback.sequencer.BurnedRowResolver.from(
            preferringCut = { burnStore.localUrlPreferringCut(it) },
            startMs = { burnStore.startMs(it) },
            durationMs = { burnStore.items.value[it]?.durationMs },
        )
    }

    /** SVC-6 per-song play stats (LRP ordering signal), recorded from the core play-event seam. */
    private val playStatsLazy = lazy {
        val f = File(app.appContext.filesDir, com.levi.pocketdj.data.stats.PlayStatsStore.FILE_NAME)
        com.levi.pocketdj.data.stats.PlayStatsStore(f, VersionedJsonWriter(f, VersionedJsonWriter.backgroundExecutor("pdj-play-stats-writer")))
    }
    val playStats: com.levi.pocketdj.data.stats.PlayStatsStore get() = playStatsLazy.value

    /** Starts the recorder once; idempotent. Call off-main (the store reads its doc from disk). */
    fun startPlayStats() {
        if (playStatsStarted.compareAndSet(false, true)) {
            com.levi.pocketdj.data.stats.PlayStatsRecorder(playStats, appleStreaming = { app.playbackController.isAppleMusicActive })
                .start(app.appScope)
        }
    }
    private val playStatsStarted = java.util.concurrent.atomic.AtomicBoolean(false)

    val storageSettings: com.levi.pocketdj.data.storage.DataStoreStorageSettings by lazy {
        com.levi.pocketdj.data.storage.DataStoreStorageSettings(app.settings)
    }

    /** SVC-6 soft-cap prune engine (protected = now-playing row + both Mix decks). */
    val storageManager: com.levi.pocketdj.data.storage.StorageManager by lazy {
        com.levi.pocketdj.data.storage.StorageManager(
            burns = com.levi.pocketdj.data.storage.BurnStorePruneAdapter(burnStore),
            playStats = playStats,
            settings = storageSettings,
            protectedSongIds = {
                buildSet {
                    app.playbackGraph.sequencer.state.value.currentSongId?.let(::add)
                    runCatching {
                        val e = app.mixGraph.mixEngine
                        com.levi.pocketdj.mix.model.Deck.entries.forEach { d -> e.loaded(d)?.songId?.let(::add) }
                    }
                }
            },
            log = { android.util.Log.i("PocketDJ", "[storage] $it") },
        )
    }

    val burnStorageOps: com.levi.pocketdj.data.storage.StorageService.BurnStorageOps by lazy {
        object : com.levi.pocketdj.data.storage.StorageService.BurnStorageOps {
            override fun usageByArtist() = burnStore.usageByArtist()
            override fun stemUsageByArtist() = burnStore.stemUsageByArtist()
            override fun approximateBytes(ids: List<String>) = burnStore.approximateBytes(ids)
            override fun removeBurns(songIds: List<String>) = burnStore.removeBurns(songIds)
            override fun removeStems(songIds: List<String>) = burnStore.removeStems(songIds, protecting = storageManager.protectedSongIds())
        }
    }

    override val settingsSections: List<SettingsSection> by lazy {
        if (diag.channel) listOf(debugSection()) else emptyList()
    }

    override val deepLinkHandlers: List<DeepLinkHandler> by lazy {
        // Keystore/prefs work must not run on the registry (main) path: start on IO.
        if (diag.channel) app.appScope.launch(Dispatchers.IO) { diag.start() }
        listOf(diag.deepLink)
    }

    override val flushables: List<Flushable> by lazy {
        // Subscribe the play-stats recorder off-main as soon as the registry materializes the module.
        app.appScope.launch(Dispatchers.IO) { startPlayStats() }
        listOf(
            diag.flushable,
            Flushable { if (burnStoreLazy.isInitialized()) burnStore.flush() },
            Flushable { if (playStatsLazy.isInitialized()) playStats.flush() },
        )
    }
}

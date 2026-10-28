package com.levi.pocketdj.di

import com.levi.pocketdj.data.burns.AppPrivateBurnFolder
import com.levi.pocketdj.data.burns.BurnStore
import com.levi.pocketdj.data.burns.HttpBurnRips
import com.levi.pocketdj.data.config.Endpoints
import com.levi.pocketdj.data.store.VersionedJsonWriter
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
    val burnStore: BurnStore by lazy {
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
        )
    }

    override val settingsSections: List<SettingsSection> by lazy {
        if (diag.channel) listOf(debugSection()) else emptyList()
    }

    override val deepLinkHandlers: List<DeepLinkHandler> by lazy {
        // Keystore/prefs work must not run on the registry (main) path: start on IO.
        if (diag.channel) app.appScope.launch(Dispatchers.IO) { diag.start() }
        listOf(diag.deepLink)
    }

    override val flushables: List<Flushable> by lazy { listOf(diag.flushable) }
}

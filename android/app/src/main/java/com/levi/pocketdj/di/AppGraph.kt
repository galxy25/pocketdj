package com.levi.pocketdj.di

import android.content.Context
import androidx.datastore.core.handlers.ReplaceFileCorruptionHandler
import androidx.datastore.preferences.core.PreferenceDataStoreFactory
import androidx.datastore.preferences.core.emptyPreferences
import com.levi.pocketdj.data.PdjJson
import com.levi.pocketdj.data.catalog.CatalogRepository
import com.levi.pocketdj.data.catalog.CatalogService
import com.levi.pocketdj.data.rips.RipServerClient
import com.levi.pocketdj.data.rips.RipsRepository
import com.levi.pocketdj.data.settings.AppSettingsStore
import com.levi.pocketdj.playback.PlayEventBus
import com.levi.pocketdj.playback.PlaybackController
import com.levi.pocketdj.screens.browse.BrowseSession
import java.io.File
import java.util.concurrent.TimeUnit
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.SupervisorJob
import okhttp3.OkHttpClient

/**
 * Hand-rolled process-wide object graph (no DI framework — matches the
 * skeleton's zero-magic style). Obtain it anywhere with
 * `AppGraph.get(context)`; everything inside is lazy singletons.
 *
 * Typical launch wiring (from any screen's LaunchedEffect or the activity):
 * ```
 * val graph = AppGraph.get(context)
 * graph.catalogRepository.loadIfNeeded()   // seed-from-cache + refresh
 * graph.ripsRepository.loadAtLaunch()      // rips manifest
 * ```
 */
class AppGraph private constructor(context: Context) {

    private val appContext = context.applicationContext

    /** App-lifetime work scope (repositories, background polls). */
    val appScope: CoroutineScope = CoroutineScope(SupervisorJob() + Dispatchers.Default)

    val json = PdjJson.lenient

    /**
     * Shared OkHttp client. Read timeout 30 s = the iOS per-request doctrine for
     * the big catalog GETs (time without data, not total transfer time).
     */
    val httpClient: OkHttpClient = OkHttpClient.Builder()
        .connectTimeout(15, TimeUnit.SECONDS)
        .readTimeout(30, TimeUnit.SECONDS)
        .build()

    private val settingsDataStore = PreferenceDataStoreFactory.create(
        // A truncated .preferences_pb (power loss mid-write) must reset to
        // defaults, not throw CorruptionException out of every save forever.
        corruptionHandler = ReplaceFileCorruptionHandler { emptyPreferences() },
        scope = CoroutineScope(Dispatchers.IO + SupervisorJob()),
    ) {
        File(appContext.filesDir, "pocketdj-settings.preferences_pb")
    }

    val settings: AppSettingsStore = AppSettingsStore(settingsDataStore, json)

    val catalogService: CatalogService = CatalogService(
        cacheDir = File(appContext.filesDir, "catalog-cache"),
        http = httpClient,
        json = json,
    )

    val catalogRepository: CatalogRepository = CatalogRepository(
        service = catalogService,
        settings = settings,
        scope = appScope,
    )

    val ripsRepository: RipsRepository = RipsRepository(
        cacheDir = File(appContext.filesDir, "rips-cache"),
        http = httpClient,
        json = json,
        scope = appScope,
    )

    val ripServerClient: RipServerClient = RipServerClient(
        http = httpClient,
        json = json,
        configProvider = {
            val current = settings.current()
            RipServerClient.Config(
                baseUrl = current.ripServerUrl,
                token = current.ripToken,
                installId = settings.ensureInstallId(),
            )
        },
    )

    val playbackController: PlaybackController = PlaybackController(
        context = appContext,
        catalog = catalogRepository,
        rips = ripsRepository,
        ripServer = ripServerClient,
        settings = settings,
        scope = appScope,
    )

    /** The History seam: collect `playEvents.events` and record each one. */
    val playEvents: PlayEventBus = PlayEventBus

    init {
        // Restore + persist the Browse view-state (kind/filters/sort/layout/mode,
        // browse.md §7). Wired here (once, app-scoped) so it survives regardless
        // of which screen renders first.
        BrowseSession.attach(settings, appScope)
    }

    companion object {
        @Volatile
        private var instance: AppGraph? = null

        fun get(context: Context): AppGraph =
            instance ?: synchronized(this) {
                instance ?: AppGraph(context).also { instance = it }
            }
    }
}

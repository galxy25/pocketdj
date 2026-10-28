package com.levi.pocketdj.di

import android.content.Context
import androidx.datastore.core.handlers.ReplaceFileCorruptionHandler
import androidx.datastore.preferences.core.PreferenceDataStoreFactory
import androidx.datastore.preferences.core.emptyPreferences
import com.levi.pocketdj.data.PdjJson
import com.levi.pocketdj.data.activity.ActivityKind
import com.levi.pocketdj.data.activity.CollectionActivityStore
import com.levi.pocketdj.data.store.VersionedJsonWriter
import com.levi.pocketdj.data.applemusic.AppleMusicPreviewResolver
import com.levi.pocketdj.data.applemusic.MusicKitAuth
import com.levi.pocketdj.data.applemusic.MusicKitDeveloperTokenClient
import com.levi.pocketdj.data.catalog.CatalogRepository
import com.levi.pocketdj.data.catalog.CatalogService
import com.levi.pocketdj.data.collections.CollectionsStore
import com.levi.pocketdj.data.config.RemoteEndpoints
import com.levi.pocketdj.data.credentials.EncryptedSecretStore
import com.levi.pocketdj.data.credentials.InMemorySecretStore
import com.levi.pocketdj.data.credentials.DeferredSecretStore
import com.levi.pocketdj.data.credentials.SecretMigration
import com.levi.pocketdj.data.credentials.SecretStore
import com.levi.pocketdj.data.history.PlayHistoryStore
import com.levi.pocketdj.data.rips.PresignCache
import com.levi.pocketdj.data.rips.RipJobTracker
import com.levi.pocketdj.data.rips.RipServerClient
import com.levi.pocketdj.data.rips.RipsRepository
import com.levi.pocketdj.data.settings.AppSettingsStore
import com.levi.pocketdj.data.storage.CoilArtworkCache
import com.levi.pocketdj.data.storage.StorageService
import com.levi.pocketdj.playback.PlayEventBus
import com.levi.pocketdj.playback.PlaybackController
import com.levi.pocketdj.screens.browse.BrowseSession
import com.levi.pocketdj.shell.FeatureModuleRegistry
import com.levi.pocketdj.shell.IntentSink
import com.levi.pocketdj.shell.LastSectionStore
import java.io.File
import java.util.concurrent.TimeUnit
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.sync.withLock
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.SupervisorJob
import kotlinx.coroutines.launch
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

    internal val appContext = context.applicationContext

    /** App-lifetime work scope (repositories, background polls). */
    val appScope: CoroutineScope = CoroutineScope(SupervisorJob() + Dispatchers.Default)

    val json = PdjJson.lenient

    /** Launch (force) + foreground (throttled 15 min) fetch of the remote endpoint config. */
    fun refreshEndpoints(force: Boolean = false) {
        appScope.launch(Dispatchers.IO) {
            val changed = RemoteEndpoints.refresh(httpClient, force = force)
            if (changed || force) {
                android.util.Log.i("PocketDJ", "[endpoints] ${if (changed) "changed" else "checked"} ${RemoteEndpoints.summary}")
            }
            // A flipped backend: re-read the rips manifest from the new bucket (the repository's
            // launchGate holds it until onboarding completes).
            if (changed) {
                runCatching { ripsRepository.refresh() }
            }
        }
    }

    /**
     * Shared OkHttp client. Read timeout 30 s = the iOS per-request doctrine for
     * the big catalog GETs (time without data, not total transfer time).
     */
    val httpClient: OkHttpClient = OkHttpClient.Builder()
        .connectTimeout(15, TimeUnit.SECONDS)
        .readTimeout(30, TimeUnit.SECONDS)
        .build()

    private val settingsFile = File(appContext.filesDir, "pocketdj-settings.preferences_pb")

    /**
     * Whether a settings file already existed when the process built its graph (SURF-3): an
     * upgrade from a pre-onboarding build has one, a fresh install does not. Captured BEFORE
     * anything can write it; the onboarding decision tree reads it.
     */
    internal val hadPersistedSettingsAtLaunch: Boolean = settingsFile.exists()

    private val settingsDataStore = PreferenceDataStoreFactory.create(
        // A truncated .preferences_pb (power loss mid-write) must reset to
        // defaults, not throw CorruptionException out of every save forever.
        corruptionHandler = ReplaceFileCorruptionHandler { emptyPreferences() },
        scope = CoroutineScope(Dispatchers.IO + SupervisorJob()),
    ) {
        settingsFile
    }

    /**
     * Keystore-backed secrets (rip token, jukebox token, Music-User-Token, later more —
     * decision D6). Built off the settings DataStore's thread-safe path; the construction
     * touches the Keystore so it is created lazily on first (off-main) use, and failures degrade to the legacy
     * plaintext path rather than crashing launch.
     */
    val secrets: SecretStore = DeferredSecretStore { EncryptedSecretStore.createOrNull(appContext) }

    val settings: AppSettingsStore = AppSettingsStore(settingsDataStore, json, secrets)

    /** Last-visited shell section (History default). */
    val lastSection: LastSectionStore = LastSectionStore(settings)

    // ---- Feature modules (decision D3): the ONLY place the eight sidecars are listed ----
    // Aggregation order is area order and is stable; consumers read [features].
    val playbackGraph: PlaybackGraph by lazy { PlaybackGraph(this) }
    val mixGraph: MixGraph by lazy { MixGraph(this) }
    val studioGraph: StudioGraph by lazy { StudioGraph(this) }
    val gamesGraph: GamesGraph by lazy { GamesGraph(this) }
    val collectionsGraph: CollectionsGraph by lazy { CollectionsGraph(this) }
    val browseGraph: BrowseGraph by lazy { BrowseGraph(this) }
    val servicesGraph: ServicesGraph by lazy { ServicesGraph(this) }
    val shellGraph: ShellGraph by lazy { ShellGraph(this) }

    /** Zero-to-hero first-run state (SURF-3); lives in the shell sidecar. */
    val onboarding: com.levi.pocketdj.onboarding.OnboardingStore get() = shellGraph.onboarding

    /** ON_STOP flush funnel (SURF-2). */
    val flushRegistry: com.levi.pocketdj.shell.FlushRegistry = com.levi.pocketdj.shell.FlushRegistry()

    private val flushLock = kotlinx.coroutines.sync.Mutex()

    /** Serialized (idempotent) flush of every registered + module flushable. */
    suspend fun flushNow() {
        flushLock.withLock { runCatching { flushRegistry.flushAll(features.flushables) } }
    }

    /** Fire-and-forget [flushNow]; safe to call from Activity onPause/onStop. */
    fun flushAsync() {
        appScope.launch { flushNow() }
    }

    val features: FeatureModuleRegistry by lazy {
        FeatureModuleRegistry(
            listOf(
                playbackGraph, mixGraph, studioGraph, gamesGraph,
                collectionsGraph, browseGraph, servicesGraph, shellGraph,
            ),
        )
    }

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
    ).also { it.launchGate = { onboarding.waitUntilComplete() } } // SURF-3 gate seam

    /** Shared rip-server config used by both the rip client and the AM dev-token
     *  client (specs/applemusic.md §5, §8) — the AM token IS minted by the rip
     *  server the user already configured. */
    private val ripConfigProvider: suspend () -> RipServerClient.Config = {
        val current = settings.current()
        RipServerClient.Config(
            baseUrl = current.ripServerUrl,
            token = current.ripToken,
            installId = settings.ensureInstallId(),
        )
    }

    val ripServerClient: RipServerClient = RipServerClient(
        http = httpClient,
        json = json,
        configProvider = ripConfigProvider,
    )

    /** Presigned-URL cache + prefetch for the private rips bucket (SVC-1). */
    val presignCache: PresignCache = PresignCache(
        scope = appScope,
        isConfigured = { ripServerClient.isConfigured() },
        presigner = { songId, ttl -> ripServerClient.presign(songId, ttl) },
    )

    /** Keeps polling rips that outlived the interactive wait; fires onRipReady (SVC-1). */
    val ripJobTracker: RipJobTracker = RipJobTracker(
        scope = appScope,
        fetchJob = { ripServerClient.job(it) },
        refreshManifest = { ripsRepository.refresh() },
    )

    /** Apple Music developer-token client (fetch + cache from the rip server). */
    val musicKitDevTokenClient: MusicKitDeveloperTokenClient = MusicKitDeveloperTokenClient(
        http = httpClient,
        json = json,
        configProvider = ripConfigProvider,
        settings = settings,
    )

    /** Resolves 30-second AM previews (dev-token API, else tokenless iTunes). */
    val appleMusicPreviewResolver: AppleMusicPreviewResolver = AppleMusicPreviewResolver(
        http = httpClient,
        json = json,
        developerTokenProvider = { musicKitDevTokenClient.cachedTokenOrNull() },
    )

    /** Apple Music sign-in wrapper (intent build + result decode + persist). */
    val musicKitAuth: MusicKitAuth by lazy {
        MusicKitAuth(appContext, settings, musicKitDevTokenClient)
    }

    val playbackController: PlaybackController = PlaybackController(
        context = appContext,
        catalog = catalogRepository,
        rips = ripsRepository,
        ripServer = ripServerClient,
        settings = settings,
        scope = appScope,
        devTokenClient = musicKitDevTokenClient,
        previewResolver = appleMusicPreviewResolver,
        presigns = presignCache,
        ripTracker = ripJobTracker,
    )

    /**
     * Settings ▸ Storage measurement + clears (specs/storage.md §2). Clears are
     * wired to the REAL stores/caches and never touch settings/installId. Lazy —
     * the history/activity stores it clears read their docs from disk.
     */
    val storageService: StorageService by lazy {
        StorageService(
            catalogCacheDir = File(appContext.filesDir, "catalog-cache"),
            collectionsFile = File(appContext.filesDir, CollectionsStore.FILE_NAME),
            playHistoryFile = File(appContext.filesDir, PlayHistoryStore.FILE_NAME),
            activityFile = File(appContext.filesDir, CollectionActivityStore.FILE_NAME),
            artwork = CoilArtworkCache(appContext),
            clearCatalogCache = { catalogService.clearCache() },
            clearPlayHistory = { PlayHistoryStore.get(appContext).clear() },
            clearActivity = { collectionActivity.clear() },
            favoritesFile = File(appContext.filesDir, com.levi.pocketdj.data.favorites.FavoritesStore.FILE_NAME),
            // SVC-2: burns/stems measure + clear (BURNS excludes stems so the total never double-counts).
            burnsUsageBytes = { (servicesGraph.burnStore.burnedUsageBytes() - servicesGraph.burnStore.stemUsageBytes()).coerceAtLeast(0L) },
            stemsUsageBytes = { servicesGraph.burnStore.stemUsageBytes() },
            clearBurns = { servicesGraph.burnStore.removeAllBurns() },
            clearStems = { servicesGraph.burnStore.removeAllStems() },
        )
    }

    /** The History seam: collect `playEvents.events` and record each one. */
    val playEvents: PlayEventBus = PlayEventBus

    /**
     * The collection-activity log (History ▸ Activity). Lazy — construction
     * reads its JSON doc from disk; first touch should be off-main.
     */
    /** Single daemon thread shared by the collections + activity version-ordered writers (D6). */
    private val bgWriterExecutor by lazy { VersionedJsonWriter.backgroundExecutor() }

    val collectionActivity: CollectionActivityStore by lazy {
        File(appContext.filesDir, CollectionActivityStore.FILE_NAME).let { f ->
            CollectionActivityStore(f, writer = VersionedJsonWriter(f, bgWriterExecutor))
        }
    }

    /**
     * The collections store (pockets / playlists / setlists / folders). Lazy —
     * construction reads `pocketdj-collections.json`. The activity seam is
     * wired HERE (spec: the store fires its hook only from user-facing add/
     * remove choke points; this wiring just records what arrives).
     */
    val collections: CollectionsStore by lazy {
        File(appContext.filesDir, CollectionsStore.FILE_NAME).let { f ->
            CollectionsStore(f, writer = VersionedJsonWriter(f, bgWriterExecutor))
        }.also { store ->
            store.catalogProvider = { catalogRepository.state.value.catalog }
            store.onActivityBatch = { hooks ->
                collectionActivity.recordAll(
                    ActivityKind.ADD.takeIf { hooks.first().kind == CollectionsStore.ActivityHook.Kind.ADD }
                        ?: ActivityKind.REMOVE,
                    hooks.map {
                        CollectionActivityStore.Entry(
                            it.itemId, it.itemTitle, it.itemArtist,
                            it.collectionId, it.collectionKind, it.collectionName,
                        )
                    },
                )
            }
            store.onActivity = { hook ->
                collectionActivity.record(
                    kind = when (hook.kind) {
                        CollectionsStore.ActivityHook.Kind.ADD -> ActivityKind.ADD
                        CollectionsStore.ActivityHook.Kind.REMOVE -> ActivityKind.REMOVE
                    },
                    itemId = hook.itemId,
                    itemTitle = hook.itemTitle,
                    itemArtist = hook.itemArtist,
                    collectionId = hook.collectionId,
                    collectionKind = hook.collectionKind,
                    collectionName = hook.collectionName,
                )
            }
        }
    }

    init {
        // Remote endpoint config (docs/design/remote-endpoints.md): load the persisted last-good
        // doc synchronously (tiny file) so every first request already resolves to it, then
        // fetch the latest in the background — never blocking launch.
        RemoteEndpoints.install(File(appContext.filesDir, "pocketdj-endpoints.json"))
        android.util.Log.i("PocketDJ", "[endpoints] launch ${RemoteEndpoints.summary}")
        // The forced launch fetch is issued by the foreground hook (PocketDjApplication) so a
        // WorkManager cold start does not pay for it.
        // Restore + persist the Browse view-state (kind/filters/sort/layout/mode,
        // browse.md §7). Wired here (once, app-scoped) so it survives regardless
        // of which screen renders first.
        BrowseSession.attach(settings, appScope)
        // One-shot, idempotent move of plaintext tokens into the SecretStore. Reads fall
        // back to the plaintext copy until it lands, so nothing races it.
        appScope.launch(Dispatchers.IO) {
            runCatching { SecretMigration.run(settingsDataStore, secrets) }
                .onFailure { android.util.Log.e("PocketDJ", "[secrets] migration failed", it) }
        }
        // SVC-2: drop ledger items whose file vanished / were poisoned (after the onboarding gate).
        appScope.launch(Dispatchers.IO) {
            runCatching {
                onboarding.waitUntilComplete()
                servicesGraph.burnStore.reconcileOnLaunch()
            }.onFailure { android.util.Log.e("PocketDJ", "[burns] reconcile failed", it) }
        }
        // MainActivity forwards every intent to IntentSink; the modules' handlers answer.
        appScope.launch { IntentSink.install(features.deepLinkHandlers) }
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

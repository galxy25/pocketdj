package com.levi.pocketdj.di

import android.content.Context
import com.levi.pocketdj.data.burns.BurnDestinationResolver
import com.levi.pocketdj.data.burns.ContentResolverBurnTree
import com.levi.pocketdj.data.burns.SafBurnFolder
import com.levi.pocketdj.data.burns.SharedPrefsBurnFolderPrefs
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
import com.levi.pocketdj.shell.ResetHook
import com.levi.pocketdj.shell.SyncEntry
import com.levi.pocketdj.data.sync.CloudDocDatabase
import com.levi.pocketdj.data.sync.CloudSyncService
import com.levi.pocketdj.data.sync.InMemoryCloudDocDatabase
import com.levi.pocketdj.data.sync.ProfileStore
import com.levi.pocketdj.data.sync.SyncRegistry
import com.levi.pocketdj.data.sync.SyncSettings
import com.levi.pocketdj.data.sync.UnavailableCloudDocDatabase
import com.levi.pocketdj.onboarding.OnboardingPrefs
import com.levi.pocketdj.data.settings.ShellSettings
import com.levi.pocketdj.shell.SettingsSection
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.delay
import kotlinx.coroutines.plus
import kotlinx.coroutines.withContext
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
            // SVC-14: destination comes from the RECORD (captured at enqueue), never from settings.
            resolver = BurnDestinationResolver(burnsDir, File(app.appContext.filesDir, "burns-user"), ::openBurnTree),
        )
    }

    /** SVC-14: the user's SAF burn folder choice (UI + enqueue time only). */
    val burnFolderPrefs: SharedPrefsBurnFolderPrefs by lazy { SharedPrefsBurnFolderPrefs(app.appContext) }

    private fun openBurnTree(uri: String): ContentResolverBurnTree? =
        runCatching { ContentResolverBurnTree(app.appContext, android.net.Uri.parse(uri)) }.getOrNull()

    val burnFolder: SafBurnFolder by lazy {
        SafBurnFolder(
            File(app.appContext.filesDir, "burns"), File(app.appContext.filesDir, "burns-user"),
            burnFolderPrefs, ::openBurnTree,
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
            folder = burnFolder,
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

    /** BRW-7 Collection-timeline cues (`pocketdj-timeline-cues.json`): synced, cleared on account deletion. Touch off-main. */
    private val timelineCuesLazy = lazy {
        val f = File(app.appContext.filesDir, com.levi.pocketdj.data.timeline.TimelineCueStore.FILE_NAME)
        com.levi.pocketdj.data.timeline.TimelineCueStore(f, writer = VersionedJsonWriter(f, VersionedJsonWriter.backgroundExecutor("pdj-timeline-cues-writer")))
    }
    val timelineCues: com.levi.pocketdj.data.timeline.TimelineCueStore get() = timelineCuesLazy.value

    /** Starts the recorder once; idempotent. Call off-main (the store reads its doc from disk). */
    fun startPlayStats() {
        if (playStatsStarted.compareAndSet(false, true)) {
            com.levi.pocketdj.data.stats.PlayStatsRecorder(playStats).start(app.appScope)
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
                com.levi.pocketdj.data.storage.protectedIds(
                    current = app.playbackGraph.sequencer.state.value.current,
                    deckSongIds = runCatching {
                        val e = app.mixGraph.mixEngine
                        com.levi.pocketdj.mix.model.Deck.entries.map { d -> e.loaded(d)?.songId }
                    }.getOrDefault(emptyList()),
                )
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

    // ---- SVC-7 document sync -------------------------------------------------------------

    /** The user's synced identity (iOS ProfileStore); name edits mirror into settings + collections. */
    val profile: ProfileStore by lazy {
        ProfileStore(File(app.appContext.filesDir, ProfileStore.FILE_NAME)).also { p ->
            p.onNameApplied = { name ->
                app.appScope.launch(Dispatchers.IO) {
                    app.settings.set(OnboardingPrefs.PROFILE_NAME, ShellSettings.normalizeProfileName(name))
                    app.collections.performerName = name
                }
            }
        }
    }

    /** SVC-10: the profile id the server holds our secret for, or "" (=> no `X-PocketDJ-Profile`). Keystore read: off-main. */
    suspend fun enrolledProfileId(): String = withContext(Dispatchers.IO) {
        val enrolled = profileSecrets.enrolledProfileId()
        // iOS sends profile.id as stored; the enrolled copy is lowercased. Gate on enrollment, send the stored spelling.
        if (enrolled.isNotEmpty() && profile.id.lowercase() == enrolled) profile.id else enrolled
    }

    // ---- SVC-9 S3 backend, enrollment, device linking ------------------------------------------

    /** The profile sync secret (Keystore SecretStore only). */
    val profileSecrets: com.levi.pocketdj.data.sync.ProfileSecretStore by lazy {
        com.levi.pocketdj.data.sync.ProfileSecretStore(app.secrets)
    }

    val enrollment: com.levi.pocketdj.data.sync.Enrollment by lazy {
        com.levi.pocketdj.data.sync.Enrollment(
            secrets = profileSecrets,
            baseUrl = { com.levi.pocketdj.data.config.RemoteEndpoints.profileSyncBase },
            enrollToken = com.levi.pocketdj.data.sync.Enrollment.tokenFrom(app.secrets),
            http = app.httpClient,
        )
    }

    /** No `profileSyncBase` in the endpoint doc => accountAvailable() is false and nothing hits the network. */
    val s3Database: com.levi.pocketdj.data.sync.S3CloudDocDatabase by lazy {
        com.levi.pocketdj.data.sync.S3CloudDocDatabase(
            baseUrl = { com.levi.pocketdj.data.config.RemoteEndpoints.profileSyncBase },
            profileId = { profile.id },
            secrets = profileSecrets,
            http = app.httpClient,
            enrollment = enrollment,
            deviceName = { android.os.Build.MODEL ?: "Android" },
        )
    }

    /** Stage-1 / Settings device linking (code entry; QR camera scanning is deferred). */
    val linkProbe: com.levi.pocketdj.onboarding.S3LinkDeviceProbe by lazy {
        com.levi.pocketdj.onboarding.S3LinkDeviceProbe(
            secrets = profileSecrets,
            profileId = { profile.id },
            adoptProfileId = { profile.adoptIdentity(it) },
            clearUnauthorized = { s3Database.clearUnauthorized() },
            isUnauthorized = { s3Database.unauthorized.value },
            syncConfigured = { com.levi.pocketdj.data.config.RemoteEndpoints.profileSyncBase != null },
            probeCloud = { cloudSync.probeCloudProfile() },
            restoreCloud = { cloudSync.restoreForOnboarding() },
            holdPushes = { cloudSync.holdPushesForIdentityChange() },
            releasePushes = { cloudSync.releasePushHold() },
        )
    }

    /**
     * The backend the engine syncs against. [UnavailableCloudDocDatabase] until SVC-9 installs the
     * S3 implementation here (or the debug flag swaps in [InMemoryCloudDocDatabase]).
     */
    @Volatile var cloudDocDatabase: CloudDocDatabase = s3Database

    /** Mirror of [SyncSettings.CLOUD_SYNC_ENABLED] (the engine's `enabled` closure is non-suspend). */
    @Volatile private var userSyncEnabled: Boolean = true

    private val cloudSyncLazy = lazy {
        CloudSyncService(
            database = { cloudDocDatabase },
            enabled = { userSyncEnabled },
            stateFile = File(app.appContext.filesDir, "pocketdj-cloudsync-state.json"),
            scope = app.appScope + Dispatchers.IO,
            deviceName = android.os.Build.MODEL ?: "Android",
            log = { tag, msg -> android.util.Log.i("PocketDJ", "[$tag] $msg") },
        ).also { svc ->
            // Onboarding push gate: nothing uploads until the zero-to-hero flow resolves (pulls are not gated).
            svc.pushAllowed = { app.onboarding.isComplete }
            SyncRegistry.registerAll(svc, app.appContext.filesDir, app.features.syncEntries)
        }
    }
    val cloudSync: CloudSyncService get() = cloudSyncLazy.value

    /**
     * Completes when the bounded launch pass has finished (or hit its deadline). DIVERGENCE from iOS:
     * iOS pulls before onboarding resolves; here the launch pass waits for onboarding so it cannot race
     * the zero-to-hero "restore" choice (pulls are otherwise ungated). Owners of restore-later stores
     * (playback-session, mix-decks: registered file-only) MUST `awaitLaunchSync()` before reading their
     * files.
     */
    val launchPass = kotlinx.coroutines.CompletableDeferred<Unit>()

    /** Suspends until the launch pull landed, bounded; returns at once while onboarding is unresolved. */
    suspend fun awaitLaunchSync(timeoutMs: Long = CloudSyncService.LAUNCH_DEADLINE_MS + 2_000L) {
        if (!app.onboarding.isComplete) return
        kotlinx.coroutines.withTimeoutOrNull(timeoutMs) { launchPass.await() }
    }

    /** iOS launch reconcile: a non-empty profile name wins over the PROFILE_NAME pref + performerName. */
    private suspend fun reconcileProfileName() {
        val name = profile.name
        if (name.isEmpty()) return
        if (app.settings.get(OnboardingPrefs.PROFILE_NAME) != ShellSettings.normalizeProfileName(name)) {
            app.settings.set(OnboardingPrefs.PROFILE_NAME, ShellSettings.normalizeProfileName(name))
        }
        app.collections.performerName = name
    }

    /** Debug builds: swap the in-memory backend in/out live (Settings > Profile debug toggle). */
    fun setDebugInMemoryDb(on: Boolean) {
        if (!isDebuggableBuild()) return
        if (on && cloudDocDatabase === s3Database) cloudDocDatabase = InMemoryCloudDocDatabase()
        else if (!on && cloudDocDatabase is InMemoryCloudDocDatabase) cloudDocDatabase = s3Database
    }

    fun isDebuggable(): Boolean = isDebuggableBuild()

    private val syncStarted = java.util.concurrent.atomic.AtomicBoolean(false)
    @Volatile private var appForeground = false

    /**
     * Launch pipeline (idempotent): flag mirror -> profile migration -> wait for onboarding -> the
     * bounded launch pass -> foreground re-sync observer + 20 s active tick. Fire-and-forget.
     */
    fun startCloudSync() {
        if (!syncStarted.compareAndSet(false, true)) return
        app.appScope.launch(Dispatchers.IO) {
            launch { app.settings.flow(SyncSettings.CLOUD_SYNC_ENABLED).collect { userSyncEnabled = it } }
            launch { watchCredentialDocs() } // SVC-10
            // iOS DiagKeyImporter: materialize + push immediately after a .pdjdiagkey import.
            diag.onKeyImported = {
                app.appScope.launch(Dispatchers.IO) {
                    runCatching { diagKeySync.materialize() }
                    runCatching { cloudSync.pushDirty() }
                }
            }
            if (isDebuggableBuild() && app.settings.get(SyncSettings.DEBUG_IN_MEMORY_DB) &&
                cloudDocDatabase === s3Database
            ) {
                cloudDocDatabase = InMemoryCloudDocDatabase()
            }
            profile.migrateIfNeeded(app.settings.get(OnboardingPrefs.PROFILE_NAME))
            reconcileProfileName()
            val svc = cloudSync
            app.onboarding.waitUntilComplete()
            profile.migrateIfNeeded(app.settings.get(OnboardingPrefs.PROFILE_NAME))
            try {
                svc.syncAtLaunch()
            } finally {
                launchPass.complete(Unit)
            }
            withContext(Dispatchers.Main) {
                androidx.lifecycle.ProcessLifecycleOwner.get().lifecycle.addObserver(
                    androidx.lifecycle.LifecycleEventObserver { _, event ->
                        when (event) {
                            androidx.lifecycle.Lifecycle.Event.ON_START -> { appForeground = true; svc.syncOnForeground() }
                            androidx.lifecycle.Lifecycle.Event.ON_STOP -> appForeground = false
                            else -> Unit
                        }
                    },
                )
            }
            while (true) {
                delay(CloudSyncService.ACTIVE_TICK_GAP_MS)
                if (appForeground && app.onboarding.isComplete) svc.syncTick()
            }
        }
    }

    private fun isDebuggableBuild(): Boolean =
        (app.appContext.applicationInfo.flags and android.content.pm.ApplicationInfo.FLAG_DEBUGGABLE) != 0

    // ---- SVC-10 synced connection credentials + diag key ---------------------------------------

    /** Live <-> doc adapter over the settings store (+ SecretStore for the search key pair). Off-main only. */
    private val credentialsPort = object : com.levi.pocketdj.data.credentials.CredentialsPort {
        override fun read() = kotlinx.coroutines.runBlocking {
            val cur = app.settings.current()
            com.levi.pocketdj.data.credentials.SettingsCredentialsDocument(
                ripServerURL = cur.ripServerUrl,
                ripToken = cur.ripToken,
                jukeboxServerURL = cur.jukeboxServerUrl,
                jukeboxToken = cur.jukeboxToken,
                jukeboxTokensRequiredByDefault = cur.jukeboxTokensRequiredByDefault,
                searchAccessKeyID = app.secrets.get(com.levi.pocketdj.data.search.SearchSettings.ACCESS_KEY_ID),
                searchSecretKey = app.secrets.get(com.levi.pocketdj.data.search.SearchSettings.SECRET_KEY),
                searchEndpoint = com.levi.pocketdj.data.search.SearchSettings.endpoint(app.settings),
            )
        }

        override fun apply(doc: com.levi.pocketdj.data.credentials.SettingsCredentialsDocument) {
            kotlinx.coroutines.runBlocking {
                app.settings.setRipServer(doc.ripServerURL, doc.ripToken)
                app.settings.setJukeboxServer(doc.jukeboxServerURL, doc.jukeboxToken)
                app.settings.setJukeboxTokensRequiredByDefault(doc.jukeboxTokensRequiredByDefault)
                com.levi.pocketdj.data.search.SearchSettings.saveCreds(app.secrets, doc.searchAccessKeyID, doc.searchSecretKey)
                com.levi.pocketdj.data.search.SearchSettings.setEndpoint(app.settings, doc.searchEndpoint)
            }
        }
    }

    val credentialsSync: com.levi.pocketdj.data.credentials.CredentialsSync by lazy {
        com.levi.pocketdj.data.credentials.CredentialsSync(
            file = File(app.appContext.filesDir, com.levi.pocketdj.data.credentials.SettingsCredentialsDocument.FILE_NAME),
            port = credentialsPort,
            log = { android.util.Log.i("PocketDJ", "[credsync] $it") },
        )
    }

    val diagKeySync: com.levi.pocketdj.data.credentials.DiagKeySync by lazy {
        com.levi.pocketdj.data.credentials.DiagKeySync(
            file = File(app.appContext.filesDir, com.levi.pocketdj.data.credentials.DiagKeySync.FILE_NAME),
            store = diag.credentials,
        )
    }

    /** Mirrors credential edits into the synced docs (content-compare, blank-install guard inside). Off-main. */
    private suspend fun watchCredentialDocs() {
        kotlinx.coroutines.flow.combine(
            app.settings.settings,
            app.settings.flow(com.levi.pocketdj.data.search.SearchSettings.ENDPOINT),
            app.secrets.revision,
        ) { _, _, _ -> }.collect {
            runCatching { credentialsSync.syncIfChanged() }
            runCatching { diagKeySync.materialize() }
        }
    }

    /** The core synced documents (iOS names). Reload seams re-decode / merge the pulled file. */
    override val syncEntries: List<SyncEntry> = listOf(
        SyncEntry(SyncRegistry.KEY_PROFILE, ProfileStore.FILE_NAME, onPulled = { profile.reloadFromDisk(); false }),
        SyncEntry(SyncRegistry.KEY_COLLECTIONS, com.levi.pocketdj.data.collections.CollectionsStore.FILE_NAME,
            onPulled = { app.collections.reloadFromDisk() },
            applyPayload = { app.collections.applyPulledPayload(it) }),
        SyncEntry(SyncRegistry.KEY_PLAY_HISTORY, com.levi.pocketdj.data.history.PlayHistoryStore.FILE_NAME,
            onPulled = { com.levi.pocketdj.data.history.PlayHistoryStore.get(app.appContext).reloadFromDisk() }),
        SyncEntry(SyncRegistry.KEY_COLLECTION_ACTIVITY, com.levi.pocketdj.data.activity.CollectionActivityStore.FILE_NAME,
            onPulled = { app.collectionActivity.reloadFromDisk() }),
        SyncEntry(SyncRegistry.KEY_PLAY_STATS, com.levi.pocketdj.data.stats.PlayStatsStore.FILE_NAME,
            onPulled = { playStats.reloadFromDisk(); false }),
        SyncEntry(SyncRegistry.KEY_TIMELINE_CUES, com.levi.pocketdj.data.timeline.TimelineCueStore.FILE_NAME,
            onPulled = { timelineCues.reloadFromDisk() }),
        // SVC-10: empty-secret-guarded credentials doc + the diag-key doc (empty never wins).
        SyncEntry(com.levi.pocketdj.data.credentials.SettingsCredentialsDocument.KEY,
            com.levi.pocketdj.data.credentials.SettingsCredentialsDocument.FILE_NAME,
            onPulled = { credentialsSync.applyPulled() },
            applyPayload = { credentialsSync.writePulled(it) }),
        SyncEntry(com.levi.pocketdj.data.credentials.DiagKeySync.KEY,
            com.levi.pocketdj.data.credentials.DiagKeySync.FILE_NAME,
            onPulled = {
                val r = diagKeySync.applyPulled()
                if (r == com.levi.pocketdj.data.credentials.DiagKeySync.PullResult.ADOPTED && diag.channel) diag.log.reloadCredentials()
                false
            }),
    )

    // The cloud-sync state clear and the profile-secret clear are NOT hooks any more: SVC-13's
    // [accountDeletion] runs them explicitly in the iOS order (sync state after settings; identity LAST, once).
    override val resetHooks: List<ResetHook> = listOf(
        // iOS AccountDeletionService: timelineCues?.clear(). Clears (and deletes the file) even if never opened.
        ResetHook { timelineCues.clear() },
    )

    // ---- SVC-13 reset everything + account deletion ----------------------------------------------

    /** Cloud-sync state files + `.pre-cloud` backups; works whether or not the engine was built this process. */
    private fun clearSyncState() {
        if (cloudSyncLazy.isInitialized()) {
            cloudSync.clearLocalSyncState()
        } else {
            val files = app.appContext.filesDir
            File(files, "pocketdj-cloudsync-state.json").delete()
            files.listFiles()?.filter { it.name.endsWith(".pre-cloud") }?.forEach { it.delete() }
        }
    }

    private fun holdPushes() {
        if (cloudSyncLazy.isInitialized()) cloudSync.holdPushesForIdentityChange()
    }

    /** Settings > Reset all app state (device-local). Never touches cloud docs or the profile identity. */
    val appReset: com.levi.pocketdj.data.reset.AppResetService by lazy {
        val files = app.appContext.filesDir
        com.levi.pocketdj.data.reset.AppResetService(
            holdPushes = ::holdPushes,
            ejectMix = {
                // iOS `mix.ejectAll()` before resetEverything: decks off, durable deck snapshot gone. MixEngine is Main-only.
                withContext(Dispatchers.Main) { app.mixGraph.mixEngine.ejectAll() }
                app.mixGraph.mixDeckSession.clear()
            },
            clearCollections = { app.collections.clear() },
            deleteCatalogCache = { app.catalogService.clearCache() },
            deleteCredentialsMirror = {
                credentialsSync.suspendUntilRelaunch()
                File(files, com.levi.pocketdj.data.credentials.SettingsCredentialsDocument.FILE_NAME).delete()
            },
            clearArtwork = { com.levi.pocketdj.data.storage.CoilArtworkCache(app.appContext).clear() },
            clearSecrets = {
                for (n in listOf(
                    com.levi.pocketdj.data.credentials.SecretStore.RIP_TOKEN,
                    com.levi.pocketdj.data.credentials.SecretStore.JUKEBOX_TOKEN,
                    com.levi.pocketdj.data.credentials.SecretStore.MUSIC_USER_TOKEN,
                )) app.secrets.remove(n)
                com.levi.pocketdj.data.search.SearchSettings.clearCreds(app.secrets)
            },
            resetSettings = {
                app.settings.resetToDefaultsKeepingInstallId()
                // Final review: the SharedPreferences-backed settings (iOS resetEverything resets these too).
                val ctx = app.appContext
                runCatching {
                    val burn = ctx.getSharedPreferences("pdj-burn-folder", Context.MODE_PRIVATE)
                    burn.getString("treeUri", null)?.let { u ->
                        runCatching {
                            ctx.contentResolver.releasePersistableUriPermission(
                                android.net.Uri.parse(u),
                                android.content.Intent.FLAG_GRANT_READ_URI_PERMISSION or android.content.Intent.FLAG_GRANT_WRITE_URI_PERMISSION,
                            )
                        }
                    }
                    burn.edit().clear().apply()
                }
                runCatching { ctx.getSharedPreferences("pocketdj-studio-folders", Context.MODE_PRIVATE).edit().clear().apply() }
                runCatching {
                    ctx.getSharedPreferences("pocketdj-diag", Context.MODE_PRIVATE).edit()
                        .remove(com.levi.pocketdj.diag.DiagSettings.K_TELEMETRY).apply()
                    diag.log.telemetryEnabled = false
                }
            },
            markOnboardingPending = {
                com.levi.pocketdj.onboarding.OnboardingStore.markPendingAfterReset(
                    com.levi.pocketdj.onboarding.DataStoreOnboardingMarkerStorage(app.settings),
                )
            },
            clearSyncState = ::clearSyncState,
            log = { android.util.Log.i("PocketDJ", "[reset] $it") },
        )
    }

    /** Tombstone for an account deletion whose server-side erase failed; retried on launch. */
    val pendingErasure: com.levi.pocketdj.data.reset.PendingCloudErasure by lazy {
        com.levi.pocketdj.data.reset.PendingCloudErasure(app.secrets)
    }

    /** Finish an interrupted account erasure (no-op without a tombstone or endpoint). Off-main. */
    suspend fun retryPendingErasure() {
        if (com.levi.pocketdj.data.config.RemoteEndpoints.profileSyncBase == null) return
        pendingErasure.retry { id, secret -> s3Database.deleteProfileAs(id, secret) }
    }

    /**
     * Before the process is killed after a reset/deletion: flush every module, then wait for the
     * stores' async writers so queued deletes (collections, sessions, mix) have actually landed.
     */
    suspend fun drainWriters() = withContext(Dispatchers.IO) {
        runCatching { app.features.flushAll() }
        runCatching { app.collections.awaitWrites() }
        runCatching { app.playbackGraph.sessionStore.awaitWrites() }
        runCatching { app.mixGraph.mixDeckSession.awaitWrites() }
    }

    /** Settings > Delete account (cloud + device). */
    val accountDeletion: com.levi.pocketdj.data.reset.AccountDeletionService by lazy {
        com.levi.pocketdj.data.reset.AccountDeletionService(
            holdPushes = ::holdPushes,
            stopLiveActivity = listOf(
                "jukebox" to { com.levi.pocketdj.data.jukebox.JukeboxGraph.get(app.appContext).repository.endAndAwait() },
                // SetlistSequencer / MixEngine state mutations are Main-confined.
                "playback" to { withContext(Dispatchers.Main) { app.playbackGraph.sequencer.stop() } },
                "mix" to { withContext(Dispatchers.Main) { app.mixGraph.mixEngine.ejectAll() } },
                "transfers" to { transfers.cancelAll() },
            ),
            // The S3 backend needs a configured endpoint doc AND an enrolled secret; the debug in-memory db always runs.
            cloudDeleteEnabled = {
                cloudDocDatabase !== s3Database ||
                    (com.levi.pocketdj.data.config.RemoteEndpoints.profileSyncBase != null && profileSecrets.hasSecret())
            },
            deleteCloudDocs = { keys ->
                cloudDocDatabase.deleteAll((keys + app.features.syncEntries.map { it.key }).distinct())
            },
            deleteCloudProfile = { if (cloudDocDatabase === s3Database) s3Database.deleteProfile() },
            tombstoneCloudProfile = {
                // Only the S3 backend has server-side state a later launch can still erase.
                if (cloudDocDatabase === s3Database) pendingErasure.save(profile.id, profileSecrets.secret())
            },
            localStores = buildList {
                add("collections" to { app.collections.clear() })
                add("favorites" to { app.collectionsGraph.favorites.clear() })
                add("play-stats" to { playStats.clear() })
                add("play-history" to { com.levi.pocketdj.data.history.PlayHistoryStore.get(app.appContext).clear() })
                add("listening-pockets" to { app.collectionsGraph.listeningPockets.clearLocal() })
                add("collection-activity" to { app.collectionActivity.clear() })
                add("playlist-writeback" to { app.collectionsGraph.writeBack.clear() })
                // iOS `playbackSession.clear()` explicitly: the sequencer.stop() path only clears via an async collector.
                add("playback-session" to { app.playbackGraph.sessionStore.clear() })
                // Local diag-key file + stored secret, or the next launch's materialize() re-pushes it under the new identity.
                add("diag-key" to {
                    File(app.appContext.filesDir, com.levi.pocketdj.data.credentials.DiagKeySync.FILE_NAME).delete()
                    diag.credentials.clear()
                })
                // Every area's own hooks (Mix, Studio, Games, Browse recs, timeline cues), named by area.
                app.features.modules.forEach { m ->
                    m.resetHooks.forEachIndexed { i, h -> add("hook:${m.area}#$i" to { h.reset() }) }
                }
            },
            mediaDeletes = listOf(
                "burns" to { burnStore.removeAllBurns() },
                "stems" to { burnStore.removeAllStems() },
                "lyrics" to { app.browseGraph.lyricsStore.clearDisk() },
            ),
            appReset = appReset,
            clearSyncState = ::clearSyncState,
            resetProfile = { profile.reset() },
            clearProfileSecret = { profileSecrets.clear() },
            resetInstallId = { app.settings.resetInstallId() },
            log = { android.util.Log.i("PocketDJ", "[account-deletion] $it") },
        )
    }

    override val settingsSections: List<SettingsSection> by lazy {
        listOf(com.levi.pocketdj.screens.settings.linkDeviceSection(), com.levi.pocketdj.screens.settings.sections.resetSection()) +
            if (diag.channel) listOf(debugSection()) else emptyList()
    }

    override val deepLinkHandlers: List<DeepLinkHandler> by lazy {
        // Keystore/prefs work must not run on the registry (main) path: start on IO.
        if (diag.channel) app.appScope.launch(Dispatchers.IO) { diag.start() }
        app.appScope.launch(Dispatchers.IO) { runCatching { retryPendingErasure() } }
        listOf(diag.deepLink)
    }

    override val flushables: List<Flushable> by lazy {
        listOf(
            diag.flushable,
            Flushable { if (burnStoreLazy.isInitialized()) burnStore.flush() },
            Flushable { if (playStatsLazy.isInitialized()) playStats.flush() },
            Flushable { if (cloudSyncLazy.isInitialized()) cloudSync.pushOnBackground() },
        )
    }
}

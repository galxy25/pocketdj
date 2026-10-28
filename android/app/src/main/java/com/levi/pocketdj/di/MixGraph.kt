package com.levi.pocketdj.di

import android.content.Context
import android.media.AudioManager
import com.levi.pocketdj.audio.core.AudioTrackSink
import com.levi.pocketdj.audio.core.Mp3Decoder
import com.levi.pocketdj.audio.core.VoicePump
import com.levi.pocketdj.data.burns.BurnStore
import com.levi.pocketdj.data.store.VersionedJsonWriter
import com.levi.pocketdj.diag.NPLog
import com.levi.pocketdj.mix.engine.CoroutineTickDriver
import com.levi.pocketdj.mix.engine.MixEngine
import com.levi.pocketdj.mix.engine.MixSourceOpener
import com.levi.pocketdj.mix.engine.MixTrackResolver
import com.levi.pocketdj.mix.engine.ResolvedTrack
import com.levi.pocketdj.mix.engine.VoiceRunner
import com.levi.pocketdj.mix.store.MixDeckSessionStore
import com.levi.pocketdj.mix.store.MixSessionStore
import com.levi.pocketdj.mix.stream.BurnStoreAdopter
import com.levi.pocketdj.mix.stream.ConnectivityNetworkMonitor
import com.levi.pocketdj.mix.stream.MixStreamLoader
import com.levi.pocketdj.mix.stream.MixStreamRips
import com.levi.pocketdj.data.config.Endpoints
import androidx.core.content.ContextCompat
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.SupervisorJob
import kotlinx.coroutines.launch
import kotlinx.coroutines.withContext
import com.levi.pocketdj.data.catalog.IndexSong
import com.levi.pocketdj.data.collections.CollectionCatalog
import com.levi.pocketdj.data.collections.Setlist
import com.levi.pocketdj.data.burns.BurnState
import com.levi.pocketdj.data.burns.BurnSong
import com.levi.pocketdj.mix.download.AutoMixHost
import com.levi.pocketdj.mix.download.AutoPlacement
import com.levi.pocketdj.mix.download.CollectionMixDownloader
import com.levi.pocketdj.mix.download.MixBurnStatus
import com.levi.pocketdj.mix.download.MixDownloadBurns
import com.levi.pocketdj.mix.download.MixDownloadRips
import com.levi.pocketdj.mix.download.MixResolver
import com.levi.pocketdj.mix.download.MixResolverSources
import com.levi.pocketdj.mix.model.AutoMixItem
import com.levi.pocketdj.shell.FeatureModule
import com.levi.pocketdj.shell.Flushable
import com.levi.pocketdj.shell.ResetHook
import java.io.File

/**
 * Sidecar graph for the mix area (decision D3). Owns the two durable Mix documents
 * (`pocketdj-mix-decks.json`, `pocketdj-mix-sessions.json`) over the shared off-main
 * [VersionedJsonWriter]; packages in this area override the FeatureModule members they
 * contribute and add their own lazies here - never in AppGraph.
 */
class MixGraph(private val app: AppGraph) : FeatureModule {
    override val area: String = "mix"

    private val writerExecutor by lazy { VersionedJsonWriter.backgroundExecutor("pdj-mix-writer") }

    /** The live-mix snapshot (decks + crossfader + Auto-DJ). No disk I/O until load()/save(). */
    private val deckLazy = lazy {
        val f = File(app.appContext.filesDir, MixDeckSessionStore.FILE_NAME)
        MixDeckSessionStore(f, writer = VersionedJsonWriter(f, writerExecutor))
    }
    val mixDeckSession: MixDeckSessionStore get() = deckLazy.value

    /** The mix session action log (also the engine's recorder). */
    private val sessionsLazy = lazy {
        val f = File(app.appContext.filesDir, MixSessionStore.FILE_NAME)
        MixSessionStore(f, writer = VersionedJsonWriter(f, writerExecutor))
    }
    val mixSessions: MixSessionStore get() = sessionsLazy.value

    /**
     * MIX-6: growing-file song/stem streams. Built on first use; construction sweeps
     * `cacheDir/mixstream` (partials are never resumed across launches). Hooks fire on the main
     * thread. Adoption goes through the shared [com.levi.pocketdj.data.burns.BurnStore].
     */
    private val streamLoaderLazy = lazy {
        val ripsRepo = app.ripsRepository
        val client = app.ripServerClient
        val ioScope = CoroutineScope(SupervisorJob() + Dispatchers.IO)
        // hasServer is read synchronously on every canStream, but the real check is a suspend
        // settings read. Seed it ONCE before the loader exists (a one-off, tiny blocking read on
        // IO) so the first canStream after a cold start is already correct, then keep it current
        // with a throttled background refresh (not a coroutine per call).
        val flag = com.levi.pocketdj.mix.stream.SeededFlag(
            read = { client.isConfigured() }, scope = ioScope,
            initial = runCatching { kotlinx.coroutines.runBlocking(Dispatchers.IO) { client.isConfigured() } }.getOrDefault(false),
        )
        val rips = object : MixStreamRips {
            override fun hasServer(): Boolean = flag.get()
            override fun entry(songId: String) = ripsRepo.entry(songId)
            override suspend fun presignedUrl(songId: String, ttlSeconds: Int): String? =
                if (client.isConfigured()) client.presign(songId, ttlSeconds) else null
            override fun urlForKey(key: String) = Endpoints.ripAudioUrl(key)
            override fun stemUrls(songId: String) = ripsRepo.entry(songId)?.stemUrls(Endpoints.RIPS_BASE)
        }
        MixStreamLoader(
            rips = rips,
            adopter = BurnStoreAdopter(app.servicesGraph.burnStore),
            directory = File(app.appContext.cacheDir, "mixstream"),
            network = ConnectivityNetworkMonitor(app.appContext),
            http = app.httpClient, // plain client: never attaches the rip bearer to S3
            scope = ioScope,
            callbackExecutor = ContextCompat.getMainExecutor(app.appContext),
        )
    }
    val mixStreamLoader: MixStreamLoader get() = streamLoaderLazy.value

    /**
     * MIX-5: the app-scoped Mix engine. Built on first use, NEVER torn down on leaving the tab. The
     * sink is created lazily on the first real transport (a restore materializes inert). The caller
     * (Mix screen / launch task) invokes [MixEngine.restorePersistedMixIfIdle] and
     * [MixEngine.materializePendingRestoreIfNeeded]; they are not auto-run here.
     */
    val mixEngine: MixEngine by lazy {
        val audio = app.appContext.getSystemService(Context.AUDIO_SERVICE) as AudioManager
        MixEngine(
            sinkFactory = { AudioTrackSink(audio) },
            resolver = BurnStoreTrackResolver(app.servicesGraph.burnStore),
            opener = MixSourceOpener { f ->
                // Mp3Decoder is the only PcmSource today; a burn it cannot open (e.g. adopted .wav) is refused visibly.
                val d = runCatching { Mp3Decoder(f) }.getOrNull()
                if (d == null || d.totalFrames <= 0) {
                    NPLog.lane(NPLog.MIX, "opener refused ${f.name}")
                    runCatching { d?.close() }
                    null
                } else d
            },
            runner = VoiceRunner { v -> val p = VoicePump(v).start(); AutoCloseable { p.stopAndJoin() } },
            tickDriver = CoroutineTickDriver(CoroutineScope(SupervisorJob() + Dispatchers.Main.immediate)),
            deckStore = mixDeckSession,
            diagSink = { NPLog.lane(NPLog.MIX, it) },
        ).also {
            it.recorder = mixSessions
            val main = CoroutineScope(SupervisorJob() + Dispatchers.Main.immediate)
            it.loadOffload = { work, commit ->
                main.launch {
                    val p = withContext(Dispatchers.IO) { work() }
                    commit(p)
                }
            }
        }
    }

    /**
     * MIX-7: crate -> loadables. `streamable` is wired to the stream loader so a ripped-but-not-burned
     * song is loadable (STREAMING MODE).
     */
    val mixResolver: MixResolver by lazy {
        MixResolver(CatalogResolverSources(app), streamable = { mixStreamLoader.canStream(it) })
    }

    /** The Auto-DJ seam over the engine; the Auto-DJ package fills [EngineAutoMixHost]'s hooks. */
    val autoMixHost: EngineAutoMixHost by lazy { EngineAutoMixHost(mixEngine, mixStreamLoader) }

    /** MIX-7: app-scoped collection pull for the Mix tab (survives leaving the tab). */
    val collectionMixDownloader: CollectionMixDownloader by lazy {
        val burns = app.servicesGraph.burnStore
        val ripsRepo = app.ripsRepository
        val catalog = { app.catalogRepository.state.value.catalog }
        CollectionMixDownloader(
            scope = CoroutineScope(SupervisorJob() + Dispatchers.Main.immediate),
            burns = BurnStoreMixBurns(burns, app.servicesGraph.transfers),
            rips = RipsMixRips(ripsRepo, app.ripServerClient, app.servicesGraph.ripCoordinator),
            host = autoMixHost,
        ).also { d ->
            d.resolveRipIds = { mixResolver.memberIds(it) }
            d.resolveLoadables = { mixResolver.loadables(it) }
            d.resolveSourceName = { src ->
                when (src) {
                    is com.levi.pocketdj.mix.model.MixSource.Pocket -> app.collections.pocket(src.value)?.name
                    is com.levi.pocketdj.mix.model.MixSource.Playlist -> app.collections.playlist(src.value)?.name
                    is com.levi.pocketdj.mix.model.MixSource.Setlist -> app.collections.setlist(src.value)?.name
                }
            }
            d.catalogSongCount = { catalog()?.songsById?.size ?: 0 }
            d.songLengthSeconds = { id -> catalog()?.songsById?.get(id)?.length?.takeIf { it > 0 }?.let { it / 1000.0 } }
            d.songTitleArtist = { id -> catalog()?.songsById?.get(id)?.let { it.name to it.artist } ?: (id to "") }
        }
    }

    // ON_STOP: both documents are written inline so a process kill right after backgrounding
    // cannot lose the latest positions / events.
    override val flushables: List<Flushable> = listOf(
        Flushable {
            // Only stores that were actually built this process: constructing one just to
            // flush it would decode + rewrite an unchanged (possibly multi-MB) document on main.
            if (deckLazy.isInitialized()) deckLazy.value.flush()
            if (sessionsLazy.isInitialized()) sessionsLazy.value.flush()
        },
    )

    override val resetHooks: List<ResetHook> = listOf(
        ResetHook {
            if (deckLazy.isInitialized()) deckLazy.value.clear()
            else File(app.appContext.filesDir, MixDeckSessionStore.FILE_NAME).delete()
            if (sessionsLazy.isInitialized()) sessionsLazy.value.clear()
            else File(app.appContext.filesDir, MixSessionStore.FILE_NAME).delete()
        },
    )
}

/** Resolves a song to its burned file (per-song cut preferred), analog window and beat grids. */
class BurnStoreTrackResolver(private val burns: BurnStore) : MixTrackResolver {
    override fun resolve(songId: String): ResolvedTrack? {
        val h = burns.localUrlPreferringCut(songId) ?: return null
        val grid = burns.beatGrid(songId)
        val local = burns.localBeatGrid(songId)
        return ResolvedTrack(
            file = h.file, isCut = h.isCut,
            startMs = if (h.isCut) null else burns.startMs(songId)?.toInt(),
            gridBpm = grid?.bpm, firstDownbeatMs = grid?.firstDownbeatMs?.toInt(), steady = grid?.steady,
            beatsMs = local?.beatsMs?.takeIf { it.isNotEmpty() }, downbeatsMs = local?.downbeatsMs?.takeIf { it.isNotEmpty() },
        )
    }
}

/** Catalog + collections + burn-existence view for [MixResolver]. */
class CatalogResolverSources(private val app: AppGraph) : MixResolverSources {
    private fun catalog() = app.catalogRepository.state.value.catalog
    private fun cc(): CollectionCatalog? = catalog()?.let { c ->
        CollectionCatalog(c.songsById, c.albumsById, app.collections.pockets.associateBy { it.id })
    }
    override fun pocketSongIds(pocketId: String): List<String> =
        cc()?.resolvePocketSongs(pocketId, HashSet())?.map { it.id }.orEmpty()
    override fun playlistSongIds(playlistId: String): List<String> {
        val p = app.collections.playlist(playlistId) ?: return emptyList()
        return cc()?.songsInPlaylist(p)?.map { it.id }.orEmpty()
    }
    override fun setlist(setlistId: String): Setlist? = app.collections.setlist(setlistId)
    override fun song(songId: String): IndexSong? = catalog()?.songsById?.get(songId)
    override fun isOnDisk(songId: String): Boolean = app.servicesGraph.burnStore.localUrl(songId) != null
}

class BurnStoreMixBurns(
    private val burns: BurnStore,
    private val transfers: com.levi.pocketdj.data.transfers.TransferCoordinator,
) : MixDownloadBurns {
    override fun isOnDisk(songId: String) = burns.localUrl(songId) != null
    override val userBurnActive: Boolean get() = burns.progress.value != null
    override suspend fun burn(songId: String, title: String, artist: String) {
        burns.burn(listOf(BurnSong(songId, title, artist)))
    }
    override fun status(songId: String): MixBurnStatus? =
        burns.items.value[songId]?.let { MixBurnStatus(it.state, it.error, it.bytes) }
    override fun requestStop() = burns.requestStop()
    override fun cancelTransfers(songIds: Collection<String>) = burns.cancelTransfers(songIds)
    override fun setOnFinalized(cb: ((String) -> Unit)?) {
        burns.onAnyBurnFinalized = cb?.let { f -> { id: String, _: Long -> f(id) } }
    }
    override fun setOnBytes(cb: ((String, Long) -> Unit)?) { transfers.onBytes = cb }
}

class RipsMixRips(
    private val repo: com.levi.pocketdj.data.rips.RipsRepository,
    private val client: com.levi.pocketdj.data.rips.RipServerClient,
    private val coordinator: com.levi.pocketdj.data.rips.RipCollectionCoordinator,
) : MixDownloadRips {
    // Cached: hasServer is read once per run on the rip lane (a suspend settings read in the client).
    override var hasServer: Boolean = true
        private set
    override fun isRipped(songId: String) = repo.entry(songId) != null
    override fun durationMs(songId: String) = repo.entry(songId)?.durationMs
    override val manifestCount: Int get() = repo.manifest.value.size
    override suspend fun ripCollection(songIds: List<String>) {
        hasServer = client.isConfigured()
        coordinator.ripCollection(songIds) { repo.entry(it) != null }
    }
    override suspend fun cancelCollection(songIds: List<String>) { coordinator.cancelRips(songIds) }
    override suspend fun refreshManifest() { repo.refresh() }
}

/**
 * [AutoMixHost] over the real engine + stream loader. The engine-side facts exist today; the
 * Auto-DJ queue operations are owned by the Auto-DJ package, which assigns [insertHook],
 * [startHook], [labelProvider] and [upcomingProvider] when it lands. Until then they are inert,
 * so a downloader run still fetches and reports progress but never appends to a mix.
 */
class EngineAutoMixHost(
    private val engine: MixEngine,
    private val loader: MixStreamLoader,
) : AutoMixHost {
    var insertHook: ((AutoMixItem, AutoPlacement) -> Unit)? = null
    var startHook: ((List<AutoMixItem>, Boolean, Double, Double, String?) -> Unit)? = null
    var labelProvider: (() -> String?)? = null
    var upcomingProvider: (() -> List<String>)? = null

    override val autoMixing get() = engine.autoMixing
    override val autoEndedExhausted get() = engine.autoEndedExhausted
    override val isRunning get() = engine.isRunning
    override val deckGestureGeneration get() = engine.deckGestureGeneration
    override val autoSourceLabel get() = labelProvider?.invoke()
    override val autoUpcomingSongIds get() = upcomingProvider?.invoke().orEmpty()
    override fun autoQueueInsert(item: AutoMixItem, placement: AutoPlacement) { insertHook?.invoke(item, placement) }
    override fun startAutoMix(items: List<AutoMixItem>, shuffled: Boolean, lead: Double, fade: Double, label: String?) {
        startHook?.invoke(items, shuffled, lead, fade, label)
    }
    override fun isStreaming(songId: String) = loader.isStreaming(songId)
    override fun cancelStreams(songIds: List<String>) = loader.cancel(songIds)
    override fun setStreamHooks(onBytes: ((String, Long) -> Unit)?, onFailed: ((String) -> Unit)?) {
        loader.onBytes = onBytes
        loader.onFailed = onFailed
    }
}

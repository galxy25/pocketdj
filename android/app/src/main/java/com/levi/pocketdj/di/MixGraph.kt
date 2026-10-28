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

package com.levi.pocketdj.di

import android.content.Context
import android.media.AudioManager
import com.levi.pocketdj.mix.engine.autoQueueInsert
import com.levi.pocketdj.mix.engine.autoUpcoming
import com.levi.pocketdj.mix.engine.autoPlayed
import com.levi.pocketdj.mix.engine.onAirTrack
import com.levi.pocketdj.mix.engine.onAirBuffering
import kotlinx.coroutines.flow.first
import com.levi.pocketdj.audio.core.AudioTrackSink
import com.levi.pocketdj.audio.core.Mp3Decoder
import com.levi.pocketdj.audio.core.VoicePump
import com.levi.pocketdj.data.burns.BurnStore
import com.levi.pocketdj.data.store.VersionedJsonWriter
import com.levi.pocketdj.diag.NPLog
import com.levi.pocketdj.mix.engine.CoroutineTickDriver
import com.levi.pocketdj.mix.engine.BurnStemProvider
import com.levi.pocketdj.mix.engine.MixDeckExtras
import com.levi.pocketdj.mix.engine.MixEngine
import com.levi.pocketdj.mix.engine.MixSourceOpener
import com.levi.pocketdj.mix.engine.MixStreamLoaderPort
import com.levi.pocketdj.mix.engine.Mp3StreamSourceFactory
import com.levi.pocketdj.mix.engine.StreamDecks
import com.levi.pocketdj.mix.engine.MixTrackResolver
import com.levi.pocketdj.mix.engine.ResolvedTrack
import com.levi.pocketdj.mix.engine.VoiceRunner
import com.levi.pocketdj.mix.store.MixDeckSessionStore
import com.levi.pocketdj.mix.store.MixSessionStore
import com.levi.pocketdj.mix.recording.asRecordingSessions
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
import com.levi.pocketdj.mix.mixSettingsFlow
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

/** MIX-18: how many upcoming rows the Stem Lock prefetch looks ahead (unmetered network). */
private const val STEM_LOCK_WINDOW = 3

/** MIX-18: a prefetch song step that has not completed in this long is marked failed (frees the lane). */
private const val STEM_LOCK_FETCH_TIMEOUT_MS = 10 * 60_000L

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

    /** MIX-12: the persistent house tap, installed on the engine's graph at first take (start/stop only gates it); plain so launch-time orphan recovery never builds the engine. */
    val recordingTap: com.levi.pocketdj.mix.recording.RecordingTapSink by lazy {
        com.levi.pocketdj.mix.recording.RecordingTapSink()
    }

    /** MIX-12: mix audio recorder. AppGraph calls recoverOrphans() off-main at launch. */
    @Volatile private var recorderBuilt = false
    val mixRecorder: com.levi.pocketdj.mix.recording.MixRecorder by lazy {
        recorderBuilt = true
        val tap = recordingTap
        val mainHandler = android.os.Handler(android.os.Looper.getMainLooper())
        com.levi.pocketdj.mix.recording.MixRecorder(
            root = com.levi.pocketdj.mix.recording.SessionFolders.root(app.appContext.filesDir),
            tap = tap,
            sessions = mixSessions.asRecordingSessions(),
            mixAudible = { mixEngine.isRunning },
            makeWriter = {
                mixEngine.graph.tapSink = tap   // idempotent install
                com.levi.pocketdj.mix.recording.AacAdtsWriter(it, tap, mixEngine.graph.sampleRate)
            },
            postMain = { r -> mainHandler.post(r) },
            scope = kotlinx.coroutines.CoroutineScope(kotlinx.coroutines.SupervisorJob() + kotlinx.coroutines.Dispatchers.Main),
            runFinalize = { r -> Thread(r, "pdj-mix-rec-finalize").start() },
        )
    }

    /** MIX-12: Sessions-screen take playback; pauses the live mix first. */
    val recordingPlayer: com.levi.pocketdj.mix.recording.RecordingPlayer by lazy {
        com.levi.pocketdj.mix.recording.RecordingPlayer(pauseMix = { autoDj.remotePause() })  // suspends Auto-DJ (resumable), not pauseBoth
    }

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
            initial = false,   // Final review: no runBlocking on the (main) thread that first touches the Mix; refreshed below
        ).also { it.refresh() }
        val rips = object : MixStreamRips {
            override fun hasServer(): Boolean = MixDebug.publicRips || flag.get()
            override fun entry(songId: String) = ripsRepo.entry(songId)
            override suspend fun presignedUrl(songId: String, ttlSeconds: Int): String? =
                if (MixDebug.publicRips) ripsRepo.entry(songId)?.let { Endpoints.ripAudioUrl(it.key) }
                else if (client.isConfigured()) client.presign(songId, ttlSeconds) else null
            override fun urlForKey(key: String) = Endpoints.ripAudioUrl(key)
            override fun stemUrls(songId: String) = ripsRepo.entry(songId)?.stemUrls(Endpoints.RIPS_BASE)
        }
        MixStreamLoader(
            rips = rips,
            adopter = BurnStoreAdopter(app.servicesGraph.burnStore),
            directory = File(app.appContext.cacheDir, "mixstream"),
            network = ConnectivityNetworkMonitor(app.appContext),
            http = app.httpClient.newBuilder().addInterceptor(MixDebug.failOnceInterceptor).build(), // plain client: never attaches the rip bearer to S3; interceptor is inert unless Debug arms it
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
    @Volatile private var deckExtras: MixDeckExtras? = null

    /** MIX-8: the stem / loop / beat-grid controllers (built with, and hooked into, [mixEngine]). */
    val mixDeckExtras: MixDeckExtras get() { mixEngine; return checkNotNull(deckExtras) }

    @Volatile private var modControllerInst: com.levi.pocketdj.mix.engine.ModController? = null

    /** MIX-17: the ~60 Hz slot-modulation tick (built with, and hooked into, [mixEngine]). */
    val modController: com.levi.pocketdj.mix.engine.ModController get() { mixEngine; return checkNotNull(modControllerInst) }

    @Volatile private var autoDjInst: com.levi.pocketdj.mix.engine.AutoDj? = null

    /** MIX-9: the Auto-DJ machine (built with, and hooked into, [mixEngine]). */
    val autoDj: com.levi.pocketdj.mix.engine.AutoDj get() { mixEngine; return checkNotNull(autoDjInst) }

    @Volatile private var streamDecksRef: StreamDecks? = null

    /** MIX-10: growing-file decks + stem-stream feed, hooked into [mixEngine] and the stream loader. */
    val mixStreamDecks: StreamDecks get() { mixEngine; return checkNotNull(streamDecksRef) }

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
            diagSink = { com.levi.pocketdj.mix.service.MixDiag.log(it) },
        ).also {
            it.recorder = mixSessions
            installOutcomeBridge(it)
            // SVC-6: Mix deck plays count for the LRP prune (iOS funnels MixEngine.setPlaying -> notePlayed).
            com.levi.pocketdj.data.stats.PlayStatsRecorder.attachMix(it.hooks) { id ->
                app.appScope.launch(Dispatchers.IO) { app.servicesGraph.playStats.notePlayed(id) }
            }
            autoDjInst = com.levi.pocketdj.mix.engine.AutoDj(it).also { dj ->
                it.autoDj = dj
                val b = app.servicesGraph.burnStore
                // Stream-gate-aware readiness: ripped-but-gated songs are deferred, never dropped.
                dj.seams = com.levi.pocketdj.mix.engine.LoaderAutoSeams(
                    burned = { id -> b.hasLocalFile(id) },
                    finishedStream = { id -> mixStreamLoader.stream(id)?.let { st -> st.isComplete && !st.failed } == true },
                    ripped = { id -> mixStreamLoader.isRipped(id) },
                    canStream = { id -> mixStreamLoader.canStream(id, forAuto = true) },
                )
            }
            val main = CoroutineScope(SupervisorJob() + Dispatchers.Main.immediate)
            // MIX-8: stems + loop + beat-grid controllers, hooked into the engine.
            val burns = app.servicesGraph.burnStore
            val extras = MixDeckExtras(
                engine = it,
                provider = BurnStemProvider(burns, mixStreamLoader),
                runner = VoiceRunner { v -> val p = VoicePump(v).start(); AutoCloseable { p.stopAndJoin() } },
                scope = main,
                localGrid = { id -> burns.localBeatGrid(id) },
                downloadGrid = { id -> burns.burnBeatGrid(id) },
            )
            deckExtras = extras
            modControllerInst = com.levi.pocketdj.mix.engine.ModController(
                engine = it, driver = com.levi.pocketdj.mix.engine.CoroutineTickDriver(main), hydrator = extras.hydrator,
            ).also { m -> m.diag = { l -> com.levi.pocketdj.mix.service.MixDiag.log(l) }; m.install() }
            mixStreamLoader.addStemListener { id -> extras.stems.streamProgressed(id) }
            // MIX-10: streaming decks. Progress events (main thread) pump every deck streaming the song;
            // the loader never evicts a stream a deck is playing.
            val loader = mixStreamLoader
            val decks = StreamDecks(
                engine = it, loader = MixStreamLoaderPort(loader), sources = Mp3StreamSourceFactory(),
                stems = extras.stems, hasLocalFile = { id -> burns.hasLocalFile(id) },
            )
            decks.install()
            // The Auto-DJ facts the stream machine needs: a live deck whose stream dies before audio skips ahead.
            autoDjInst?.let { dj ->
                decks.autoHooks = object : com.levi.pocketdj.mix.engine.AutoStreamHooks {
                    override fun isLiveDeck(deck: com.levi.pocketdj.mix.model.Deck) = dj.ui.value.mixing && dj.liveDeck == deck
                    override val isTransitioning: Boolean get() = dj.ui.value.transitioning
                    override fun skipToNext(fadeSeconds: Double) = dj.skipToNext(fadeSeconds)
                }
            }
            streamDecksRef = decks
            loader.onProgress = { id -> decks.streamProgressed(id) }
            loader.pinnedIds = { decks.streamingSongIds }
            it.loadOffload = { work, commit ->
                main.launch {
                    val p = withContext(Dispatchers.IO) { work() }
                    commit(p)
                }
            }
            autoDjInst?.let { dj -> installTransportOwner(it, dj, audio) }
        }
    }

    @Volatile private var sessionPlayerRef: com.levi.pocketdj.mix.service.MixSessionPlayer? = null

    /** MIX-11: the Mix as a [com.levi.pocketdj.playback.session.TransportOwner] (built with [mixEngine]). */
    @androidx.annotation.OptIn(androidx.media3.common.util.UnstableApi::class)
    val mixSessionPlayer: com.levi.pocketdj.mix.service.MixSessionPlayer get() { mixEngine; return checkNotNull(sessionPlayerRef) }

    private var serviceLink: com.google.common.util.concurrent.ListenableFuture<androidx.media3.session.MediaController>? = null

    /**
     * A Mix-only session (nothing played from Browse) has no [com.levi.pocketdj.playback.PlaybackService]
     * yet, so no notification / lock-screen card / foreground promotion. Binding a controller starts it
     * (media3 promotes it to foreground once the session player, the Mix, is playing). Idempotent; the
     * service seeds its MediaSession from the switchboard, so the Mix card is there from the first frame.
     */
    @androidx.annotation.OptIn(androidx.media3.common.util.UnstableApi::class)
    private fun ensureMediaService() {
        if (serviceLink != null) return
        val ctx = app.appContext
        val token = androidx.media3.session.SessionToken(
            ctx, android.content.ComponentName(ctx, com.levi.pocketdj.playback.PlaybackService::class.java),
        )
        serviceLink = androidx.media3.session.MediaController.Builder(ctx, token)
            .setConnectionHints(android.os.Bundle().apply { putBoolean(com.levi.pocketdj.playback.INTERNAL_HINT, true) })
            .buildAsync()
    }

    /**
     * MIX-11 (decision D2, no MixService): the engine's system integration - the SimpleBasePlayer owner of
     * the ONE MediaSession, audio focus, becoming-noisy, routing recovery and the 1 Hz heartbeat hook.
     */
    @androidx.annotation.OptIn(androidx.media3.common.util.UnstableApi::class)
    private fun installTransportOwner(e: MixEngine, dj: com.levi.pocketdj.mix.engine.AutoDj, audio: AudioManager) {
        val art = { albumId: String? ->
            albumId?.let { app.catalogRepository.state.value.catalog?.albumsById?.get(it)?.artCandidates()?.firstOrNull() }
        }
        lateinit var focus: com.levi.pocketdj.mix.service.MixFocusMachine
        // Final review: an idle / displaced Mix must stop its AudioTrack + urgent render thread (pauseEngineIfIdle had no
        // caller). A grace period keeps pause/resume taps from thrashing the HAL; the next play rebuilds the sink.
        val parkHandler = android.os.Handler(android.os.Looper.getMainLooper())
        val parkRunnable = Runnable { e.pauseEngineIfIdle() }
        fun parkSinkSoon(delayMs: Long) { parkHandler.removeCallbacks(parkRunnable); parkHandler.postDelayed(parkRunnable, delayMs) }
        e.keepEngineAlive = { recorderBuilt && mixRecorder.isRecording }   // an open take keeps the sink (and the decks) alive
        e.setlistIsLive = { app.playbackGraph.sequencer.isRunning }       // never materialize a parked mix behind a live set list
        val player = com.levi.pocketdj.mix.service.MixSessionPlayer(
            android.os.Looper.getMainLooper(), com.levi.pocketdj.mix.service.EngineMixTransportPort(e, dj, art),
            onHandoff = { focus.onHandoff(); parkSinkSoon(1_000) },
        )
        sessionPlayerRef = player
        val transport = object : com.levi.pocketdj.mix.service.FocusTransport {
            override val isRunning get() = e.isRunning
            override val mixWantsAudio get() = e.mixWantsAudio
            override val deckAudible get() = com.levi.pocketdj.mix.model.Deck.entries.any {
                e.isPlaying(it) && e.position(it) < e.duration(it) - 0.25
            }
            override val isOwner get() = com.levi.pocketdj.playback.session.SessionSwitchboard.shared.isActive(player)
            override fun remotePause() = dj.remotePause()
            override fun remotePlay() = dj.remotePlay()
            override fun pauseBoth() { e.pauseBoth(); parkSinkSoon(1_000) }
        }
        focus = com.levi.pocketdj.mix.service.MixFocusMachine(
            com.levi.pocketdj.mix.service.AndroidFocusSystem(audio) { change -> focus.onFocusChange(change) }, transport,
        )
        val recovery = com.levi.pocketdj.mix.service.MixRecovery(com.levi.pocketdj.mix.service.EngineRecoveryPort(e, dj))
        val mainHandler = android.os.Handler(android.os.Looper.getMainLooper())
        ContextCompat.registerReceiver(
            app.appContext,
            object : android.content.BroadcastReceiver() {
                override fun onReceive(c: Context?, i: android.content.Intent?) = focus.onBecomingNoisy()
            },
            android.content.IntentFilter(AudioManager.ACTION_AUDIO_BECOMING_NOISY),
            ContextCompat.RECEIVER_NOT_EXPORTED,
        )
        e.onAudioStarted = { parkHandler.removeCallbacks(parkRunnable); ensureMediaService(); player.onAudioStarted(); focus.onAudioStarted() }
        e.onNowPlayingChanged = {
            player.refresh(); focus.onTransportIdle()
            if (!e.mixWantsAudio) parkSinkSoon(15_000) else parkHandler.removeCallbacks(parkRunnable)
        }
        e.onSinkRouting = { ok -> mainHandler.post { recovery.onSinkRouting(ok) } }   // fires on the render thread
        e.onHeartbeat = { player.refresh(); recovery.silentPlayingCheck() }
        dj.onSkipCommandsEnabled = { player.refresh() }
    }

    // ======================================================================================
    // MIX-18: Now Playing Mix mini-panel (swap-on-touch ExoPlayer -> DSP) + Stem Lock
    // ======================================================================================

    private val npMain by lazy { CoroutineScope(SupervisorJob() + Dispatchers.Main.immediate) }
    @Volatile private var npInstalled = false
    /** Resign the npdsp MediaSession owner (set by [installNowPlayingDsp]). */
    @Volatile private var npReleaseSession: () -> Unit = {}
    /** Album/context extras + title/artist cached at engage (the controller's now-playing loses them once npdsp owns the session). */
    @Volatile private var npMeta: NpMeta? = null
    private class NpMeta(val songId: String, val title: String?, val artist: String?, val artworkUri: String?, val extras: android.os.Bundle)

    /** The session-scoped Stem Lock carry; every change re-persists the durable session's `stemLock`. */
    val stemLockSession: com.levi.pocketdj.mix.nowplaying.StemLockSession by lazy {
        com.levi.pocketdj.mix.nowplaying.StemLockSession(onChanged = { persistStemLock() })
    }

    /** Write the lock into the live durable-session snapshot (the SessionWriter supplier covers later saves). */
    private fun persistStemLock() {
        val store = app.playbackGraph.sessionStore
        val snap = store.currentSnapshot ?: return
        if (snap.sessionId != app.playbackGraph.sequencer.state.value.sessionId) return
        store.save(snap.copy(stemLock = stemLockSession.current.toSession()))
    }

    /** What the durable session writer persists (iOS omits the key when the lock is off). */
    fun stemLockForSession(): com.levi.pocketdj.playback.durable.SessionStemLock? =
        if (npInstalled) stemLockSession.current.toSession() else null

    private fun npNetwork(): com.levi.pocketdj.mix.nowplaying.StemLockPrefetcher.Network {
        val cm = app.appContext.getSystemService(Context.CONNECTIVITY_SERVICE) as? android.net.ConnectivityManager
            ?: return com.levi.pocketdj.mix.nowplaying.StemLockPrefetcher.Network.UNMETERED
        val net = cm.activeNetwork
        return when {
            net == null -> com.levi.pocketdj.mix.nowplaying.StemLockPrefetcher.Network.OFFLINE
            cm.restrictBackgroundStatus == android.net.ConnectivityManager.RESTRICT_BACKGROUND_STATUS_ENABLED && cm.isActiveNetworkMetered ->
                com.levi.pocketdj.mix.nowplaying.StemLockPrefetcher.Network.CONSTRAINED
            cm.isActiveNetworkMetered -> com.levi.pocketdj.mix.nowplaying.StemLockPrefetcher.Network.EXPENSIVE
            else -> com.levi.pocketdj.mix.nowplaying.StemLockPrefetcher.Network.UNMETERED
        }
    }

    /** MIX-18: song-then-stems (V>D>O>B) prefetch lane over the shared stream loader + BurnStore. */
    val stemLockPrefetcher: com.levi.pocketdj.mix.nowplaying.StemLockPrefetcher by lazy {
        val burns = app.servicesGraph.burnStore
        com.levi.pocketdj.mix.nowplaying.StemLockPrefetcher(npMain).also { p ->
            p.network = { npNetwork() }
            p.fetchSong = { step ->
                // A finished stream is adopted as an ordinary burn: the prefetch IS the download.
                val loader = mixStreamLoader
                val s = loader.open(step.id, step.title, step.artist)
                var ok = false
                if (s != null) {
                    // Bounded: a stalled rip must not park the single-lane prefetcher forever.
                    kotlinx.coroutines.withTimeoutOrNull(STEM_LOCK_FETCH_TIMEOUT_MS) {
                        while (true) {
                            if (s.isComplete) { ok = true; break }
                            if (s.failed || loader.stream(step.id) !== s) break
                            kotlinx.coroutines.delay(250)
                        }
                    }
                }
                ok
            }
            p.fetchStemPart = { id, part -> burns.burnStemPart(id, part) }
            p.requestStemify = { id -> npMain.launch { runCatching { app.ripJobTracker.stemify(id) } } }
            // Posted (NOT Main.immediate): a step that finishes without suspending must never re-plan re-entrantly.
            val replanHandler = android.os.Handler(android.os.Looper.getMainLooper())
            p.onStepFinished = { _, _ -> replanHandler.post { replanStemLock() } }
        }
    }

    /** Re-plan the prefetch lane from the live queue: lock on + stems carried + a running, non-held run. */
    fun replanStemLock() {
        val pf = stemLockPrefetcher
        val seq = app.playbackGraph.sequencer
        val st = seq.state.value
        val carry = stemLockSession.current
        if (!carry.wantsStems || !st.isRunning || st.isHeldForResume || st.current == null) { pf.cancelAll(); return }
        val burns = app.servicesGraph.burnStore
        val loader = mixStreamLoader
        fun track(q: com.levi.pocketdj.playback.sequencer.QueueItem) = com.levi.pocketdj.mix.nowplaying.StemLockPrefetcher.Track(
            songId = q.id, audioId = q.resolveId, title = q.title, artist = q.artist.orEmpty(),
            songLocal = burns.hasLocalFile(q.resolveId) || loader.stream(q.resolveId)?.isComplete == true, songFetchable = loader.canStream(q.resolveId),
            stemsLocal = burns.stemPartsBurned(q.id), stemsRemote = burns.stemsRemote(q.id),
        )
        val cur = st.current?.takeIf { npDspEngine.isEngaged && npDspEngine.engagedSongId == it.id }?.let(::track)
        pf.apply(
            com.levi.pocketdj.mix.nowplaying.StemLockPrefetcher.plan(
                cur, st.upcomingPlayable.take(STEM_LOCK_WINDOW).map(::track), carry, npNetwork(), STEM_LOCK_WINDOW,
            ),
        )
    }

    /** MIX-18: the single-deck DSP engine over the shared Mix graph (its own sink; never the Mix tab's). */
    val npDspEngine: com.levi.pocketdj.mix.nowplaying.NowPlayingDspEngine by lazy {
        val audio = app.appContext.getSystemService(Context.AUDIO_SERVICE) as AudioManager
        val burns = app.servicesGraph.burnStore
        com.levi.pocketdj.mix.nowplaying.NowPlayingDspEngine(
            sinkFactory = { AudioTrackSink(audio) },
            opener = MixSourceOpener { f ->
                val d = runCatching { Mp3Decoder(f) }.getOrNull()
                if (d == null || d.totalFrames <= 0) { runCatching { d?.close() }; null } else d
            },
            runner = VoiceRunner { v -> val p = VoicePump(v, "pdj-npdsp").start(); AutoCloseable { p.stopAndJoin() } },
            stemSource = object : com.levi.pocketdj.mix.nowplaying.DspStemSource {
                override fun localParts(songId: String) = burns.localStemPartFiles(songId).orEmpty()
                override fun obtainable(songId: String) = burns.stemsRemote(songId)
                override suspend fun fetch(songId: String, parts: List<String>): Boolean =
                    parts.sortedBy { com.levi.pocketdj.mix.nowplaying.StemLock.partPriority.indexOf(it).let { i -> if (i < 0) Int.MAX_VALUE else i } }
                        .all { burns.burnStemPart(songId, it) }
            },
            scope = npMain,
        )
    }

    private val npHostLazy = lazy {
        val controller = app.playbackController
        val seq = app.playbackGraph.sequencer
        val resolver = BurnStoreTrackResolver(app.servicesGraph.burnStore)
        val ports = object : com.levi.pocketdj.mix.nowplaying.DspHostPorts {
            override val currentSongId: String? get() = seq.state.value.let { if (it.isRunning) it.currentSongId else null }
            override val currentTitle: String? get() = controller.nowPlaying.value?.title
            override val currentArtist: String? get() = controller.nowPlaying.value?.artist
            override val currentArtworkUri: String? get() = null
            override val heldForResume: Boolean get() = seq.state.value.isHeldForResume
            override val mixSessionActive: Boolean get() = com.levi.pocketdj.screens.nowplaying.NowPlayingSeams.mixSessionActive
            override val appleMusicActive: Boolean get() = controller.isAppleMusicActive
            override fun resolve(songId: String) = resolver.resolve(songId)
            // The QUEUE row's clipped length (never the controller's now-playing, which may still be the previous row).
            override fun windowLengthMs(songId: String): Long = seq.state.value.current?.takeIf { it.id == songId }?.lengthMs ?: 0L
            override val loadedSongId: String? get() = controller.nowPlaying.value?.songId
            override val playWanted: Boolean get() = !seq.discriminator.pausedByListener
            override fun engineEnded() { npReleaseSession() }
            override suspend fun positionMs(): Long = controller.currentPositionMs()
            override val exoPlaying: Boolean get() = controller.nowPlaying.value?.isPlaying == true
            override fun advanceAfterEnd(songId: String) { seq.handleEnded(songId) }
            override fun log(line: String) = NPLog.lane(NPLog.NP, line)
        }
        com.levi.pocketdj.mix.nowplaying.NowPlayingDspHost(npDspEngine, stemLockSession, ports, replan = { replanStemLock() })
    }

    /** MIX-18: the panel's host (engage / stem-lock apply / ui state). */
    val npDspHost: com.levi.pocketdj.mix.nowplaying.NowPlayingDspHost get() = npHostLazy.value

    /**
     * MIX-18: install the Now Playing DSP: the panel into [com.levi.pocketdj.screens.nowplaying.NowPlayingSeams.dspSlot],
     * the session player (a TransportOwner `npdsp`: ONE MediaSession, never a second card), the sequencer
     * observers (track start -> Stem Lock apply, new session -> clear, held restore -> restore the lock) and
     * the 4 Hz heartbeat. Idempotent; called once at launch.
     */
    @androidx.annotation.OptIn(androidx.media3.common.util.UnstableApi::class)
    fun installNowPlayingDsp() {
        if (npInstalled) return
        npInstalled = true
        try { installNowPlayingDspImpl() } catch (t: Throwable) { npInstalled = false; throw t }
    }

    @androidx.annotation.OptIn(androidx.media3.common.util.UnstableApi::class)
    private fun installNowPlayingDspImpl() {
        val host = npDspHost
        val engine = npDspEngine
        val controller = app.playbackController
        val seq = app.playbackGraph.sequencer
        val lock = stemLockSession
        val ctx = app.appContext

        val port = object : com.levi.pocketdj.mix.nowplaying.NowPlayingDspPort {
            override fun card(): com.levi.pocketdj.mix.service.MixCard? {
                val id = engine.engagedSongId ?: return null
                val meta = npMeta?.takeIf { it.songId == id }
                val dur = engine.durationSec
                return com.levi.pocketdj.mix.service.MixCard(
                    songId = id, title = meta?.title ?: id, artist = meta?.artist.orEmpty(),
                    artworkUri = meta?.artworkUri,
                    durationMs = if (dur > 0) (dur * 1000).toLong() else null,
                    positionMs = (engine.currentTimeSec * 1000).toLong(), rate = engine.rate.toFloat(),
                )
            }
            override val isPlaying get() = engine.isPlaying
            override val hasSounded get() = engine.hasStarted
            override fun play() = engine.play()
            override fun pause() = engine.pause()
            override fun skipNext() { npMain.launch { controller.next() } }
            override fun skipPrevious() { npMain.launch { controller.previous() } }
            override fun release() { engine.disengage(); host.refresh() }
            override fun seekTo(positionMs: Long) { engine.seekTo(positionMs / 1000.0) }
            override fun extras(): android.os.Bundle? = npMeta?.takeIf { it.songId == engine.engagedSongId }?.extras
        }
        val player = com.levi.pocketdj.mix.nowplaying.NowPlayingDspSessionPlayer(android.os.Looper.getMainLooper(), port)
        npReleaseSession = { player.released() }
        // Final review: the DSP engine owns its own sink, so it needs the Mix's focus + becoming-noisy policy
        // (the paused ExoPlayer's focus callbacks reach a player that is already paused).
        val audio = ctx.getSystemService(Context.AUDIO_SERVICE) as AudioManager
        lateinit var npFocus: com.levi.pocketdj.mix.service.MixFocusMachine
        val npTransport = object : com.levi.pocketdj.mix.service.FocusTransport {
            override val isRunning get() = engine.isPlaying
            override val isOwner get() = com.levi.pocketdj.playback.session.SessionSwitchboard.shared.isActive(player)
            override fun remotePause() = engine.pause()
            override fun remotePlay() = engine.play()
            override fun pauseBoth() = engine.pause()
        }
        npFocus = com.levi.pocketdj.mix.service.MixFocusMachine(
            com.levi.pocketdj.mix.service.AndroidFocusSystem(audio) { change -> npFocus.onFocusChange(change) }, npTransport,
        )
        ContextCompat.registerReceiver(
            ctx,
            object : android.content.BroadcastReceiver() {
                override fun onReceive(c: Context?, i: android.content.Intent?) = npFocus.onBecomingNoisy()
            },
            android.content.IntentFilter(AudioManager.ACTION_AUDIO_BECOMING_NOISY),
            ContextCompat.RECEIVER_NOT_EXPORTED,
        )
        // Snapshot the playing row's metadata while the controller still mirrors ExoPlayer, then claim the
        // session BEFORE the voice starts (ExoPlayer pauses silently; remote Play routes to the engine even
        // when the swap was made while paused).
        engine.onEngaged = {
            val np = controller.nowPlaying.value
            val id = np?.songId
            if (np != null && id != null) {
                val x = android.os.Bundle().apply {
                    np.albumId?.let { putString(com.levi.pocketdj.playback.PlaybackContract.EXTRA_ALBUM_ID, it) }
                    putString(com.levi.pocketdj.playback.PlaybackContract.EXTRA_SOURCE, np.context.source)
                    np.context.contextId?.let { putString(com.levi.pocketdj.playback.PlaybackContract.EXTRA_CONTEXT_ID, it) }
                    np.context.contextName?.let { putString(com.levi.pocketdj.playback.PlaybackContract.EXTRA_CONTEXT_NAME, it) }
                }
                val art = np.albumId?.let { a -> app.catalogRepository.state.value.catalog?.albumsById?.get(a)?.artCandidates()?.firstOrNull() }
                npMeta = NpMeta(id, np.title, np.artist, art, x)
            }
            ensureMediaService(); player.claim()
        }
        engine.onDisengaged = { player.released(); npFocus.onTransportIdle() }
        engine.onAudioStarted = { ensureMediaService(); player.onAudioStarted(); npFocus.onAudioStarted() }
        val chained = engine.onChanged
        // Final review recheck: onAudioStarted fires once per engagement, so a resume after a user pause (which
        // abandoned the focus) must re-request it here; idle otherwise.
        engine.onChanged = {
            chained?.invoke(); player.refresh()
            if (engine.isPlaying) npFocus.onAudioStarted() else npFocus.onTransportIdle()
        }

        com.levi.pocketdj.screens.nowplaying.NowPlayingSeams.dspSlot = {
            com.levi.pocketdj.screens.nowplaying.NowPlayingDspPanel(host)
        }

        npMain.launch {
            var prevSession: String? = null
            var lastCur: String? = null
            seq.state.collect { st ->
                val sid = st.sessionId
                if (!st.isRunning) {
                    if (prevSession != null) { host.sessionEnded(); persistStemLock() }
                    prevSession = null
                    if (lastCur != null) { lastCur = null; host.onTrackStarted(null) }
                    return@collect
                }
                if (sid != prevSession) {
                    // The FIRST observed session may be the restored one even when a latched remote play already
                    // un-held it: match on the persisted sessionId, held or not. Disk read stays off Main.
                    val persisted = if (prevSession == null) {
                        kotlinx.coroutines.withContext(Dispatchers.IO) {
                            app.playbackGraph.sessionStore.let { it.currentSnapshot ?: it.load() }
                        }?.takeIf { it.sessionId == sid }
                    } else null
                    if (persisted != null || st.isHeldForResume) {
                        lock.restore(persisted?.stemLock)
                        host.refresh()
                    } else { host.sessionEnded(); persistStemLock() }   // a NEW session clears the lock
                    prevSession = sid
                }
                val cur = if (st.isHeldForResume) null else st.currentSongId
                if (cur != lastCur) { lastCur = cur; host.onTrackStarted(cur) } else replanStemLock()
            }
        }
        npMain.launch {
            var lastMix = false
            while (true) {
                kotlinx.coroutines.delay(250)
                val mixNow = deckExtras != null && mixEngine.isRunning
                if (mixNow != lastMix) { lastMix = mixNow; com.levi.pocketdj.screens.nowplaying.NowPlayingSeams.mixSessionActive = mixNow; host.refresh() }
                host.heartbeat()
                host.carryIfReady()
            }
        }
        // A Mix session starting takes the audio from the DSP engine (one audio owner): the switchboard
        // pauses it via TransportOwner.pauseForHandoff; nothing else to do here.
        @Suppress("UNUSED_VARIABLE") val unused = ctx
    }

    /**
     * MIX-7: crate -> loadables. `streamable` is wired to the stream loader so a ripped-but-not-burned
     * song is loadable (STREAMING MODE).
     */
    val mixResolver: MixResolver by lazy {
        MixResolver(CatalogResolverSources(app), streamable = { mixStreamLoader.streamableInPrinciple(it) })
    }

    /** The Auto-DJ seam over the engine; the Auto-DJ package fills [EngineAutoMixHost]'s hooks. */
    val autoMixHost: EngineAutoMixHost by lazy {
        EngineAutoMixHost(mixEngine, mixStreamLoader).also { h ->
            val dj = autoDj
            h.insertHook = { item, placement ->
                dj.autoQueueInsert(
                    item,
                    if (placement == AutoPlacement.RANDOM) com.levi.pocketdj.data.jukebox.JukeboxDecisionAction.RANDOM
                    else com.levi.pocketdj.data.jukebox.JukeboxDecisionAction.END,
                )
            }
            h.startHook = { items, shuffled, lead, fade, label -> dj.startAutoMix(items, shuffled, lead, fade, label) }
            h.labelProvider = { dj.sourceLabel }
            h.upcomingProvider = { dj.autoUpcoming.map { it.songId } }
        }
    }

    /** MIX-7: app-scoped collection pull for the Mix tab (survives leaving the tab). */
    val collectionMixDownloader: CollectionMixDownloader get() = downloaderLazy.value

    /** The pull state if the downloader already exists; never builds it (car connect must not materialize Mix). */
    fun downloadStateIfBuilt(): com.levi.pocketdj.mix.download.MixDownloadState? =
        if (downloaderLazy.isInitialized()) downloaderLazy.value.state.value else null

    private val downloaderLazy = lazy {
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
            d.declaredMemberCount = { declaredMemberCount(app, it) }
            d.catalogSongCount = { catalog()?.songsById?.size ?: 0 }
            d.songLengthSeconds = { id -> catalog()?.songsById?.get(id)?.length?.takeIf { it > 0 }?.let { it / 1000.0 } }
            d.songTitleArtist = { id -> catalog()?.songsById?.get(id)?.let { it.name to it.artist } ?: (id to "") }
        }
    }

    /** The Mix shell's ports over the engine / downloader / collections (shared by the tab and [mixFacade]). */
    private val portsLazy = lazy {
        val engine = mixEngine
        val dj = autoDj
        val hydrator = mixDeckExtras.hydrator
        val enginePort = object : com.levi.pocketdj.screens.mix.MixEnginePort {
            override val autoMixing get() = engine.autoMixing
            override val isRunning get() = engine.isRunning
            override var autoEnabled: Boolean
                get() = dj.enabled
                set(v) = dj.setAutoEnabled(v)
            override val autoUi get() = dj.ui
            override fun startAutoMix(items: List<AutoMixItem>, shuffled: Boolean, lead: Double, fade: Double, label: String?) =
                dj.startAutoMix(items, shuffled, lead, fade, label)
            override fun skipToNext(fadeSeconds: Double) = dj.skipToNext(fadeSeconds)
            override fun pauseAuto() = dj.pauseAuto()
            override fun resumeAuto() = dj.resumeAuto()
            override fun stopAutoMix() = dj.stopAutoMix()
            override fun setFXGlide(on: Boolean) = dj.setFXGlide(on)
            override fun setMixGlide(on: Boolean) = dj.setMixGlide(on)
            override fun prepare() = engine.prepare()
            override fun materializePendingRestore() = engine.materializePendingRestoreIfNeeded()
            override fun setCueOnRight(right: Boolean) = engine.setCueOnRight(right)
            override fun setBeatPulseEnabled(on: Boolean) = hydrator.setBeatPulseEnabled(on)
            override fun setMixGlideSeconds(seconds: Double) = dj.setMixGlideSeconds(seconds)
            override fun setSkipFadeSeconds(seconds: Double) = dj.setSkipFadeSeconds(seconds)
        }
        val downloader = collectionMixDownloader
        val downloadPort = object : com.levi.pocketdj.screens.mix.MixDownloadPort {
            override val isActive get() = downloader.isActive
            override fun begin(sources: List<com.levi.pocketdj.mix.model.MixSource>) = downloader.begin(sources)
            override fun noteAutoStarted(initialIds: Set<String>, lead: Double, fade: Double, label: String?, shuffled: Boolean) =
                downloader.noteAutoStarted(initialIds, lead, fade, label, shuffled)
            override fun handleMixLeave(engineActive: Boolean) = downloader.handleMixLeave(engineActive)
        }
        val resolver = mixResolver
        val cratePort = object : com.levi.pocketdj.screens.mix.MixCratePort {
            override fun loadables(source: com.levi.pocketdj.mix.model.MixSource) = resolver.loadables(source)
            override suspend fun ensureLoaded() {
                if (app.catalogRepository.state.value.catalog != null) return
                app.catalogRepository.loadIfNeeded()
                kotlinx.coroutines.withTimeoutOrNull(15_000) { app.catalogRepository.state.first { it.catalog != null } }
            }
            override fun name(source: com.levi.pocketdj.mix.model.MixSource): String? = when (source) {
                is com.levi.pocketdj.mix.model.MixSource.Pocket -> app.collections.pocket(source.value)?.name
                is com.levi.pocketdj.mix.model.MixSource.Playlist -> app.collections.playlist(source.value)?.name
                is com.levi.pocketdj.mix.model.MixSource.Setlist -> app.collections.setlist(source.value)?.let { it.name ?: "Set list" }
            }
        }
        Triple(enginePort, downloadPort, cratePort)
    }

    /** MIX-14: the Mix tab's state holder, app-scoped so crate selections survive tab switches and rotation. */
    val mixViewModel: com.levi.pocketdj.screens.mix.MixViewModel by lazy {
        val (enginePort, downloadPort, cratePort) = portsLazy.value
        com.levi.pocketdj.screens.mix.MixViewModel(
            engine = enginePort, downloads = downloadPort, crates = cratePort,
            settingsFlow = app.settings.mixSettingsFlow(),
            scope = CoroutineScope(SupervisorJob() + Dispatchers.Main.immediate),
        )
    }

    // ---- MIX-16: integrations ------------------------------------------------------------------

    private val mainScope by lazy { CoroutineScope(SupervisorJob() + Dispatchers.Main.immediate) }

    /**
     * Mix plays -> History: `onSongPlayed` emits a `source = "mix"` [com.levi.pocketdj.playback.PlayStarted]
     * (contextName = the crate label) and maps deck -> event; `onDeckTrackEnded` writes the listened fraction
     * and the <50 % skip verdict (iOS `MixPlayOutcomeBridge`).
     */
    private fun installOutcomeBridge(e: MixEngine) {
        val history by lazy { com.levi.pocketdj.data.history.PlayHistoryStore.get(app.appContext) }
        val bridge = com.levi.pocketdj.mix.engine.MixPlayOutcomeBridge(
            emit = { ev -> com.levi.pocketdj.playback.PlayEventBus.emit(ev) },
            findEvent = { songId, atMs, final ->
                com.levi.pocketdj.mix.engine.MixPlayOutcomeBridge.pickEvent(
                    history.events, songId, atMs, final,
                    id = { ev -> ev.id }, song = { ev -> ev.songId }, playedAt = { ev -> ev.playedAt },
                    local = { ev -> !history.isFromAnotherDevice(ev) },
                )
            },
            noteListened = { id, f -> history.noteListened(id, f) },
            markSkipped = { id -> history.markSkipped(id) },
            wasSkipped = { id -> history.events.lastOrNull { ev -> ev.id == id }?.wasSkipped == true },
            noteSkip = { id ->
                app.appScope.launch(Dispatchers.IO) {
                    app.servicesGraph.playStats.noteSkipped(com.levi.pocketdj.data.edition.SongVariant.baseId(id))
                }
            },
            trackInfo = { d -> e.loaded(d)?.let { t -> t.title to t.artist } },
            contextLabel = { autoDjInst?.takeIf { it.isMixing }?.sourceLabel ?: mixSessions.currentName },
            contextId = { mixSessions.currentId },
            // The store records off the bus asynchronously: poll briefly, then fall back to the collapsed row.
            resolveAsync = { attempt ->
                mainScope.launch {
                    repeat(RESOLVE_ATTEMPTS) { if (attempt(false)) return@launch; kotlinx.coroutines.delay(RESOLVE_STEP_MS) }
                    attempt(true)
                }
            },
        )
        e.onSongPlayed = bridge::onSongPlayed
        e.onDeckTrackEnded = bridge::onDeckTrackEnded
    }

    /** The running auto mix as the jukebox sees it; null until the engine exists (never builds it). */
    private val jukeboxPort = object : com.levi.pocketdj.data.jukebox.MixJukeboxPort {
        private val dj get() = autoDjInst
        override val autoMixing: Boolean get() = dj?.isMixing == true
        override val isRunning: Boolean get() = dj?.engine?.isRunning == true
        override val onAir: com.levi.pocketdj.data.jukebox.MixJukeboxPort.OnAir?
            get() {
                val d = dj ?: return null
                val track = d.onAirTrack ?: return null
                val deck = when {
                    d.isMixing -> d.liveDeck
                    d.engine.isPlaying(com.levi.pocketdj.mix.model.Deck.A) -> com.levi.pocketdj.mix.model.Deck.A
                    else -> com.levi.pocketdj.mix.model.Deck.B
                }
                val dur = d.engine.duration(deck)
                return com.levi.pocketdj.data.jukebox.MixJukeboxPort.OnAir(
                    songId = track.songId, title = track.title, artist = track.artist,
                    positionMs = (d.engine.position(deck) * 1000).toLong(),
                    durationMs = if (dur > 0) (dur * 1000).toLong() else null,
                    buffering = d.onAirBuffering,
                )
            }
        override val upcoming get() = dj?.autoUpcoming.orEmpty()
        override val played get() = dj?.autoPlayed.orEmpty()
        override fun insert(item: AutoMixItem, action: com.levi.pocketdj.data.jukebox.JukeboxDecisionAction) {
            dj?.autoQueueInsert(item, action)
        }
    }

    /** MIX-16: ShellActions' Mix seam (Assistant / shortcuts / deep links). Cheap: nothing builds until used. */
    val mixFacade: com.levi.pocketdj.mix.MixFacadeImpl by lazy {
        com.levi.pocketdj.mix.MixFacadeImpl(
            starter = {
                val (enginePort, downloadPort, cratePort) = portsLazy.value
                com.levi.pocketdj.screens.mix.MixAutoStarter(enginePort, downloadPort, cratePort, pushSettings = enginePort)
            },
            settings = { app.settings.mixSettingsFlow().first() },
            isAutoMixing = { autoDjInst?.isMixing == true },
            isAutoPaused = { autoDjInst?.isPaused == true },
            // Lock-screen seam, on Main (the engine is Main-confined; the caller may be any thread).
            remotePause = { mainScope.launch { autoDjInst?.remotePause() } },
            remotePlay = { mainScope.launch { autoDjInst?.remotePlay() } },
        )
    }

    init {
        // Jukebox <-> Mix: the app-scoped repository finds the Mix through this process-wide seam.
        com.levi.pocketdj.data.jukebox.MixJukeboxSeam.source = com.levi.pocketdj.data.jukebox.MixJukeboxSource(
            port = { jukeboxPort },
            isLoadable = { id -> app.servicesGraph.burnStore.localUrl(id) != null || mixStreamLoader.canStream(id) },
            // Fire-and-forget (never awaited under BurnStore's runLock). A ripped song burns now; an un-ripped
            // one records the durable burn-when-ripped intent (AppGraph drains it once the rip lands).
            requestBurn = { song ->
                app.appScope.launch(Dispatchers.IO) {
                    runCatching {
                        val bs = app.servicesGraph.burnStore
                        if (app.ripsRepository.entry(song.id) != null) {
                            bs.burn(listOf(com.levi.pocketdj.data.burns.BurnSong(song.id, song.name, song.artist)))
                        } else {
                            bs.burnWhenRipped(song.id, song.name, song.artist)
                        }
                    }
                }
            },
        )
    }

    private companion object {
        const val RESOLVE_ATTEMPTS = 20
        const val RESOLVE_STEP_MS = 50L
    }

    override val navEntries: List<com.levi.pocketdj.shell.NavEntry> get() = com.levi.pocketdj.screens.mix.MixRoutes.entries

    override val settingsSections: List<com.levi.pocketdj.shell.SettingsSection>
        get() = listOf(com.levi.pocketdj.screens.settings.sections.mixSection())

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

    /** Final review: recorded Mix sessions (reload on pull) and the live deck snapshot (file-only), iOS keys. */
    override val syncEntries: List<com.levi.pocketdj.shell.SyncEntry> = listOf(
        com.levi.pocketdj.shell.SyncEntry("mix-sessions", com.levi.pocketdj.mix.store.MixSessionStore.FILE_NAME,
            onPulled = { if (sessionsLazy.isInitialized()) mixSessions.reloadFromDisk(); false }),
        com.levi.pocketdj.shell.SyncEntry("mix-decks", MixDeckSessionStore.FILE_NAME),
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
    override fun exists(songId: String): Boolean = burns.localUrlPreferringCut(songId) != null
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
    override fun cleanOnly(source: com.levi.pocketdj.mix.model.MixSource): Boolean = when (source) {
        is com.levi.pocketdj.mix.model.MixSource.Pocket -> app.collections.pocket(source.value)?.cleanOnly == true
        is com.levi.pocketdj.mix.model.MixSource.Playlist -> app.collections.playlist(source.value)?.cleanOnly == true
        is com.levi.pocketdj.mix.model.MixSource.Setlist -> false
    }
    override fun songsById(): Map<String, IndexSong> = catalog()?.songsById.orEmpty()
}

/** iOS `CollectionsStore.declaredMemberCount(for:)`: members the collection declares, resolved or not. */
fun declaredMemberCount(app: AppGraph, src: com.levi.pocketdj.mix.model.MixSource): Int = when (src) {
    is com.levi.pocketdj.mix.model.MixSource.Pocket ->
        app.collections.pocket(src.value)?.let { it.songIds.size + it.albumIds.size + it.childPocketIds.size } ?: 0
    is com.levi.pocketdj.mix.model.MixSource.Playlist ->
        app.collections.playlist(src.value)?.let { p -> p.sequences.sumOf { countLeaves(it) } } ?: 0
    is com.levi.pocketdj.mix.model.MixSource.Setlist ->
        app.collections.setlist(src.value)?.tracks?.count { it.isText != true && it.songId.isNotEmpty() } ?: 0
}

private fun countLeaves(n: com.levi.pocketdj.data.collections.PlaylistNode): Int = when (n.kind) {
    com.levi.pocketdj.data.collections.PlaylistNode.Kind.SEQUENCE -> n.children.orEmpty().sumOf { countLeaves(it) }
    com.levi.pocketdj.data.collections.PlaylistNode.Kind.SONG,
    com.levi.pocketdj.data.collections.PlaylistNode.Kind.ALBUM,
    com.levi.pocketdj.data.collections.PlaylistNode.Kind.POCKET -> 1
    else -> 0
}

class BurnStoreMixBurns(
    private val burns: BurnStore,
    private val transfers: com.levi.pocketdj.data.transfers.TransferCoordinator,
) : MixDownloadBurns {
    override fun isOnDisk(songId: String) = burns.localUrl(songId) != null
    override val userBurnActive: Boolean get() = burns.loopActive
    override suspend fun burn(songId: String, title: String, artist: String) {
        burns.burn(listOf(BurnSong(songId, title, artist)))
    }
    override fun status(songId: String): MixBurnStatus? =
        burns.items.value[songId]?.let { MixBurnStatus(it.state, it.error, it.bytes) }
    override fun requestStop() = burns.requestStop()
    override fun cancelTransfers(songIds: Collection<String>) = burns.cancelTransfers(songIds)
    override fun watchFinalized(cb: ((String) -> Unit)?) {
        burns.onAnyBurnFinalized = cb?.let { f -> { id: String, _: Long -> f(id) } }
    }
    override fun watchBytes(cb: ((String, Long) -> Unit)?) { transfers.onBytes = cb }
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
    override suspend fun prepare() { hasServer = client.isConfigured() }
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


/** Debug-only (Settings > Debug): stream from the public rips object URL when no reachable rip server exists (emulator). */
object MixDebug {
    @Volatile var publicRips: Boolean = false

    /** ANS-MIX-1 probe: when armed, the first request per URL gets a synthetic HTTP 500. */
    @Volatile var failFirstPerUrl: Boolean = false
    private val failed = java.util.concurrent.ConcurrentHashMap.newKeySet<String>()
    val failOnceInterceptor = okhttp3.Interceptor { chain ->
        val req = chain.request()
        if (failFirstPerUrl && failed.add(req.url.toString())) {
            Thread.sleep(300) // a real 5xx round trip, not an instantaneous local failure
            com.levi.pocketdj.diag.NPLog.lane(com.levi.pocketdj.diag.NPLog.MIX, "[mix] debug: injected HTTP 500 for ${req.url.encodedPath}")
            okhttp3.Response.Builder().request(req).protocol(okhttp3.Protocol.HTTP_1_1).code(500).message("injected")
                .body(okhttp3.ResponseBody.create(null, ByteArray(0))).build()
        } else chain.proceed(req)
    }
}

package com.levi.pocketdj.playback

import android.content.ComponentName
import android.content.Context
import android.net.Uri
import android.os.Bundle
import com.levi.pocketdj.data.rips.RipPlayWait
import androidx.core.os.bundleOf
import androidx.media3.common.MediaItem
import androidx.media3.common.MediaMetadata
import androidx.media3.common.Player
import androidx.media3.session.MediaController
import androidx.media3.session.SessionToken
import com.google.common.util.concurrent.ListenableFuture
import com.google.common.util.concurrent.MoreExecutors
import com.levi.pocketdj.data.catalog.CatalogRepository
import com.levi.pocketdj.data.catalog.IndexAlbum
import com.levi.pocketdj.data.catalog.IndexSong
import com.levi.pocketdj.data.applemusic.AppleMusicPreviewResolver
import com.levi.pocketdj.data.applemusic.MusicKitDeveloperTokenClient
import com.levi.pocketdj.data.rips.PlayAction
import com.levi.pocketdj.data.rips.PlayResolver
import com.levi.pocketdj.data.rips.PresignCache
import com.levi.pocketdj.data.rips.RipJobTracker
import com.levi.pocketdj.data.rips.RipWaitOutcome
import com.levi.pocketdj.data.rips.RipServerClient
import com.levi.pocketdj.data.rips.RipsRepository
import com.levi.pocketdj.data.settings.AppSettingsStore
import com.levi.pocketdj.diag.NPLog
import com.levi.pocketdj.playback.health.EngineProbe
import com.levi.pocketdj.playback.sequencer.CloudRowResolver
import com.levi.pocketdj.playback.sequencer.RipOnDemandSource
import com.levi.pocketdj.playback.session.RipOnDemandBridge
import com.levi.pocketdj.playback.session.RipOnDemandResolver
import com.levi.pocketdj.playback.session.RipOnDemandSession
import com.levi.pocketdj.playback.session.RipResolution
import com.levi.pocketdj.playback.sequencer.LocalFileResolver
import com.levi.pocketdj.playback.sequencer.LocalFileRowResolver
import com.levi.pocketdj.playback.sequencer.QueueItem
import com.levi.pocketdj.playback.sequencer.LocalFileSource
import com.levi.pocketdj.playback.sequencer.ManifestRowResolver
import com.levi.pocketdj.playback.sequencer.PlayRequest
import com.levi.pocketdj.playback.sequencer.PlayerPort
import com.levi.pocketdj.playback.sequencer.RepeatMode
import com.levi.pocketdj.playback.sequencer.RowResolverRegistry
import com.levi.pocketdj.playback.sequencer.SetlistSequencer
import com.levi.pocketdj.playback.sequencer.StreamSource
import com.levi.pocketdj.playback.sequencer.UrlRequest
import kotlinx.coroutines.SupervisorJob
import kotlinx.coroutines.CancellationException
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.async
import kotlinx.coroutines.awaitAll
import kotlinx.coroutines.coroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.asStateFlow
import kotlinx.coroutines.launch
import kotlinx.coroutines.suspendCancellableCoroutine
import kotlinx.coroutines.sync.Mutex
import kotlinx.coroutines.sync.withLock
import kotlinx.coroutines.withContext

/** Result of asking the controller to play something. */
sealed interface PlayOutcome {
    /** Audio is queued and starting. */
    data object Started : PlayOutcome

    /** A rip was triggered; playback starts automatically once it's ready. */
    data class Preparing(val songId: String, val jobId: String?) : PlayOutcome

    /** Metadata-only — no rip and no way to make one (specs/playback.md §3). */
    data class NotPlayable(val reason: PlayAction.MetadataOnly.Reason) : PlayOutcome

    data class Failed(val message: String) : PlayOutcome
}

/** Result of asking the controller to play a whole ordered queue (P2 setlists). */
sealed interface QueueOutcome {
    /**
     * The queue started. When [skippedEntryCount] > 0 the UI should surface
     * "Playing m of n — k not playable on Android" ([QueuePlan.Plan.skippedSummary]).
     */
    data class Started(
        val playableEntryCount: Int,
        val skippedEntryCount: Int,
        val requestedEntryCount: Int,
    ) : QueueOutcome

    /**
     * Every row was unplayable — the iOS "nothing playable" banner case: fail
     * with a message, never start silently.
     */
    data class NothingPlayable(val requestedEntryCount: Int) : QueueOutcome

    data class Failed(val message: String) : QueueOutcome
}

/**
 * The app-facing playback facade (specs/playback.md §3, §5): resolves songIds
 * through the rips manifest, builds the Media3 queue (album context with
 * per-song clip windows), and exposes now-playing state as a StateFlow.
 *
 * Play events for History are NOT emitted here — the service is the single
 * recording site (see [PlayEventBus]); tabs consume `PlayEventBus.events`.
 */
class PlaybackController(
    private val context: Context,
    private val catalog: CatalogRepository,
    private val rips: RipsRepository,
    private val ripServer: RipServerClient,
    private val settings: AppSettingsStore,
    private val scope: CoroutineScope,
    /**
     * Apple Music plumbing (specs/applemusic.md §6, §8). Null on builds/tests
     * without AM wired — the resolver adds the full-track + preview rungs, and
     * its absence keeps the classic manifest→rip→metadata ladder intact.
     */
    devTokenClient: MusicKitDeveloperTokenClient? = null,
    private val previewResolver: AppleMusicPreviewResolver? = null,
    /**
     * Presigned-URL cache (the rips bucket is private). Null = direct manifest URLs (tests,
     * serverless); also falls back to the direct URL when no server is configured.
     */
    private val presigns: PresignCache? = null,
    /** Watches a rip past the 20 s interactive wait and fires onRipReady. Null in tests. */
    private val ripTracker: RipJobTracker? = null,
) {
    /** One immutable now-playing snapshot; null when nothing is loaded. */
    data class NowPlayingInfo(
        val songId: String,
        val title: String?,
        val artist: String?,
        val albumId: String?,
        val isPlaying: Boolean,
        /** Media duration when known (clipped duration for analog windows). */
        val durationMs: Long?,
        /** Live HLS (unseekable) — disable the scrubber. */
        val isLive: Boolean,
        /** 30-second Apple Music preview — badge it, cap the scrubber. */
        val isPreview: Boolean = false,
        val context: PlayContext,
    )

    /** Which engine owns audio right now (single-owner rule, §6.1). */
    private enum class ActiveBackend { EXO, APPLE_MUSIC }

    @Volatile
    private var activeBackend: ActiveBackend = ActiveBackend.EXO

    /**
     * The full-track AM engine (device-only). Owned here so single-owner
     * switching is local; its state feeds the SAME [_nowPlaying] flow so the UI
     * is backend-agnostic (§6.1 rule 2). Null when AM isn't wired.
     */
    private val appleMusicBackend: AppleMusicBackend? =
        devTokenClient?.let { dev ->
            AppleMusicBackend(
                context = context,
                settings = settings,
                devTokenClient = dev,
                onNowPlaying = { info -> _nowPlaying.value = info },
            )
        }

    /** True while the Apple Music engine owns audio (Now Playing transport ladder). */
    val isAppleMusicActive: Boolean get() = activeBackend == ActiveBackend.APPLE_MUSIC

    private val _nowPlaying = MutableStateFlow<NowPlayingInfo?>(null)
    val nowPlaying: StateFlow<NowPlayingInfo?> = _nowPlaying.asStateFlow()

    /** SongId currently being ripped on demand ("Preparing…" affordance). */
    private val _preparingSongId = MutableStateFlow<String?>(null)
    val preparingSongId: StateFlow<String?> = _preparingSongId.asStateFlow()

    /** Last user-visible playback error (rip failures land here). */
    private val _lastError = MutableStateFlow<String?>(null)
    val lastError: StateFlow<String?> = _lastError.asStateFlow()

    /** Acknowledge a shown [lastError] (the app-level snackbar collector). */
    fun clearLastError() {
        _lastError.value = null
    }

    private val urls = PlaybackUrlResolver(presigns)

    // ---- the sequencer (decision D11): owns the queue; ExoPlayer holds only the current row ----

    /** Burned / studio local-file seam (SVC-4 / STU-7 swap the real one in). */
    @Volatile
    var localFiles: LocalFileResolver = LocalFileResolver.None

    /** SVC-4 burned-first: the local file for a plain song id, via the same seam as the ladder. */
    /** File.exists()/dir.list() (analog heal) must not run on the main thread: callers are on Main. */
    private suspend fun burnedFile(songId: String) =
        withContext(Dispatchers.IO) { localFiles.localUrlForPlayback(QueueItem(id = songId)) }

    @Volatile private var cachedMode: PlaybackMode = PlaybackMode.CLOUD
    @Volatile private var cachedRipConfigured: Boolean = false

    /** The per-row resolve ladder; packages register their rung via [RowResolverRegistry.register]. */
    val rowResolvers = RowResolverRegistry(
        initial = listOf(
            LocalFileRowResolver { item -> localFiles.localUrlForPlayback(item) },
            ManifestRowResolver { id -> rips.entry(id) },
            CloudRowResolver(),
        ),
        manifestHit = { id -> rips.entry(id) != null },
        ripServerConfigured = { cachedRipConfigured },
    )

    private val sequencerScope = CoroutineScope(SupervisorJob() + Dispatchers.Main)

    /** The sequencer's Main scope, shared with the supervisor ticker (PlaybackGraph). */
    val sequencerScopeForHealth: CoroutineScope get() = sequencerScope

    /** True while the sequencer's row is what ExoPlayer holds (end / error events feed it). */
    @Volatile private var ownsPlayerField = false
    private var sequencerOwnsPlayer: Boolean
        get() = ownsPlayerField
        set(v) {
            val changed = ownsPlayerField != v
            ownsPlayerField = v
            // The session's command gate depends on this flag, not only on sequencer state emissions.
            if (changed) RunTransportBus.stateChanged?.invoke()
        }

    /** The listener changed repeat mode before the persisted value finished loading. */
    @Volatile private var repeatTouched = false

    /**
     * Rip-on-demand for a rip-required row INSIDE a run (PB-3): one in-flight `POST /rip` per song, shared by
     * the service's data source (durable mp3) and the watcher that swaps a live HLS stream in.
     */
    private val ripSession = RipOnDemandSession(
        scope = scope,
        resolver = RipOnDemandResolver(
            requestRip = { id -> ripServer.requestRip(id) },
            awaitDurable = { job -> awaitDurableRip(job) },
            liveUrl = { path -> liveRipUrl(path) },
            onQueued = { id -> withContext(Dispatchers.Main) { sequencer.notePlaybackRipQueued(id) } },
        ),
    ).also { RipOnDemandBridge.session = it }

    /** Poll a queued rip to its durable url, bounded at 10 minutes (cancelled by a skip). */
    private suspend fun awaitDurableRip(job: com.levi.pocketdj.data.rips.RipJob): String {
        val jobId = job.jobId ?: throw java.io.IOException(job.error ?: "Rip did not start")
        val deadline = System.currentTimeMillis() + RIP_WAIT_CAP_MS
        while (true) {
            when (val outcome = ripServer.awaitReadyInteractive(jobId)) {
                is RipWaitOutcome.Ready -> {
                    runCatching { rips.refresh() }
                    return outcome.url
                }
                is RipWaitOutcome.StillRipping ->
                    if (System.currentTimeMillis() > deadline) throw java.io.IOException("Still ripping")
            }
        }
    }

    /** `<serverUrl><streamPath>?token=<token>` (token omitted when empty) - the iOS `liveURL` builder. */
    private suspend fun liveRipUrl(streamPath: String): String {
        val cfg = settings.current()
        val base = cfg.ripServerUrl.trim().removeSuffix("/")
        val token = cfg.ripToken.trim()
        val url = if (streamPath.startsWith("http")) streamPath else base + "/" + streamPath.removePrefix("/")
        return if (token.isEmpty()) url else url + "?token=" + java.net.URLEncoder.encode(token, "UTF-8")
    }

    /** Facts about the engine holding the sequencer's current row (arms the health machinery). */
    private val engineProbe = object : EngineProbe {
        private val c get() = controller
        override val hasLoadedItem: Boolean
            get() = sequencerOwnsPlayer && activeBackend == ActiveBackend.EXO && (c?.mediaItemCount ?: 0) > 0
        override val isPlaying: Boolean get() = c?.isPlaying == true
        override val positionMs: Long get() = c?.currentPosition ?: 0L
        override val trackEnded: Boolean get() = c?.playbackState == Player.STATE_ENDED
        override fun rekick(by: String) {
            val ctl = c ?: return
            NPLog.lane(NPLog.PLAYBACK, "rekick by=$by pos=${ctl.currentPosition}ms")
            ctl.seekTo(ctl.currentPosition)
            ctl.prepare()
            ctl.play()
        }
    }

    val sequencer: SetlistSequencer = SetlistSequencer(
        scope = sequencerScope,
        port = Media3Port(),
        registry = rowResolvers,
        modeProvider = { cachedMode },
    ).also { seq ->
        seq.progressProvider = { progressFraction() }
        seq.ripWaitProbe = { ripSession.isResolving() }
        seq.engine = engineProbe
        seq.appleMusicActive = { activeBackend == ActiveBackend.APPLE_MUSIC }
        seq.rowOnDevice = { item -> localFiles.localUrlForPlayback(item) != null }
        seq.rowStartsInstantly = { item ->
            !com.levi.pocketdj.data.rips.PlayResolver.isStudioId(item.id) && rips.entry(item.resolveId) != null
        }
        seq.isUserRequestedRip = { id -> ripTracker?.isUserRequestedRip(id) == true }
        seq.cancelPlaybackRips = { ids ->
            scope.launch { runCatching { ripServer.cancelRips(ids) } }
        }
        seq.onRepeatModeChanged = { mode ->
            repeatTouched = true
            scope.launch { runCatching { settings.set(PlaybackPrefKeys.REPEAT_MODE, mode.token) } }
        }
        RunTransportBus.handler = object : RunTransportBus.Handler {
            override val isRunActive: Boolean get() = seq.isRunning && sequencerOwnsPlayer
            override fun next() = seq.skipNext()
            override fun previous() = seq.skipPrevious()
        }
        val base = com.levi.pocketdj.playback.session.SetlistSequencerControl(seq)
        RunTransportBus.control = object : com.levi.pocketdj.playback.session.SequencerControl by base {
            // The session's next/prev/repeat/shuffle exist only while the sequencer's row is on ExoPlayer.
            override val isRunning: Boolean get() = base.isRunning && (sequencerOwnsPlayer || base.isHeldForResume)
        }
        seq.onHeldRestored = {
            RunTransportBus.stateChanged?.invoke()
            RunTransportBus.heldRestored?.invoke()
        }
        sequencerScope.launch { seq.state.collect { RunTransportBus.stateChanged?.invoke() } }
        scope.launch {
            runCatching {
                cachedMode = PlaybackMode.fromToken(settings.get(PlaybackPrefKeys.PLAYBACK_MODE))
                val saved = RepeatMode.fromToken(settings.get(PlaybackPrefKeys.REPEAT_MODE))
                withContext(Dispatchers.Main) {
                    // A cycle the user made before the saved value arrived wins and is persisted.
                    if (!repeatTouched) seq.setRepeatMode(saved)
                }
            }
        }
        scope.launch {
            runCatching {
                settings.flow(PlaybackPrefKeys.PLAYBACK_MODE).collect { cachedMode = PlaybackMode.fromToken(it) }
            }
        }
        scope.launch {
            runCatching { settings.settings.collect { cachedRipConfigured = it.hasRipServer } }
        }
    }

    /** Listened fraction of the current track from the live player position, or null when unknown. */
    private fun progressFraction(): Double? {
        val c = controller ?: return null
        val dur = c.duration
        if (dur <= 0 || dur == androidx.media3.common.C.TIME_UNSET) return null
        return (c.currentPosition.toDouble() / dur).coerceIn(0.0, 1.0)
    }

    /** Bumped at every play entry/commit; a background rip wait only plays if still the owner. */
    private val playGeneration = java.util.concurrent.atomic.AtomicLong()
    private var urlRetriedFor: String? = null

    private var controller: MediaController? = null
    private val controllerMutex = Mutex()

    private val playerListener = object : Player.Listener {
        override fun onEvents(player: Player, events: Player.Events) {
            // Single-owner guard (§6.1): while the Apple Music engine owns audio,
            // its state feeds _nowPlaying via onNowPlaying. The MediaController is a
            // separate (cross-process) service, so its stop()/clearMediaItems()/
            // pause() during an EXO→AM handover arrive as IPC-delayed events that
            // would otherwise clobber the AM now-playing card with a stale/null
            // snapshot (snapshot() returns null once the queue is cleared). Ignore
            // ExoPlayer events entirely unless ExoPlayer is the active backend.
            if (activeBackend == ActiveBackend.APPLE_MUSIC) return
            if (events.containsAny(
                    Player.EVENT_MEDIA_ITEM_TRANSITION,
                    Player.EVENT_IS_PLAYING_CHANGED,
                    Player.EVENT_PLAYBACK_STATE_CHANGED,
                    Player.EVENT_MEDIA_METADATA_CHANGED,
                    Player.EVENT_TIMELINE_CHANGED,
                )
            ) {
                _nowPlaying.value = snapshot(player)
            }
            if (events.contains(Player.EVENT_MEDIA_ITEM_TRANSITION)) refreshAhead()
            if (events.contains(Player.EVENT_PLAYBACK_STATE_CHANGED)) {
                NPLog.lane(NPLog.PLAYBACK, "[playback] engine state=${player.playbackState} item=${player.currentMediaItem?.mediaId}")
            }
            if (sequencerOwnsPlayer &&
                events.contains(Player.EVENT_PLAYBACK_STATE_CHANGED) &&
                player.playbackState == Player.STATE_ENDED
            ) {
                // Natural end of the row the sequencer loaded -> advance (repeat / next / stop).
                player.currentMediaItem?.mediaId?.let(sequencer::handleEnded)
            }
        }

        override fun onIsPlayingChanged(isPlaying: Boolean) {
            if (!isPlaying || activeBackend != ActiveBackend.EXO || !sequencerOwnsPlayer) return
            // First proof of sound for the row the sequencer loaded: closes the start window + dead-air gap.
            sequencer.onFirstAudio(controller?.currentMediaItem?.mediaId)
        }

        override fun onPlayWhenReadyChanged(playWhenReady: Boolean, reason: Int) {
            if (activeBackend == ActiveBackend.EXO) sequencer.discriminator.onPlayWhenReadyChanged(playWhenReady, reason)
        }

        override fun onPlaybackSuppressionReasonChanged(playbackSuppressionReason: Int) {
            if (activeBackend == ActiveBackend.EXO) sequencer.discriminator.onSuppressionChanged(playbackSuppressionReason)
        }

        override fun onPlayerError(error: androidx.media3.common.PlaybackException) {
            NPLog.lane(NPLog.PLAYBACK, "[playback] engine error ${error.errorCodeName} item=${controller?.currentMediaItem?.mediaId} cause=${error.cause?.javaClass?.simpleName}: ${error.cause?.message}")
            val c = controller ?: return
            val item = c.currentMediaItem ?: return
            val id = item.mediaId
            if (activeBackend != ActiveBackend.EXO) return
            // A rip-on-demand placeholder that failed to resolve: there is no presigned url to retry with.
            if (item.requestMetadata.extras?.getString(PlaybackContract.EXTRA_URL)
                    ?.startsWith(RipOnDemandSource.SCHEME + "://") == true
            ) {
                failToSequencer(id)
                return
            }
            val isPreview = item.requestMetadata.extras?.getBoolean(PlaybackContract.EXTRA_IS_PREVIEW) == true
            val isStream = item.requestMetadata.extras?.getBoolean(PlaybackContract.EXTRA_IS_STREAM) == true
            // A presigned URL that expired (long pause) or 403'd: mint a fresh one once per song.
            // A raw stream (jukebox Tune-In) has no song id to presign.
            if (isStream) return
            if (urlRetriedFor == id || isPreview) {
                failToSequencer(id)
                return
            }
            urlRetriedFor = id
            presigns?.invalidate(id)
            scope.launch {
                val fresh = if (settings.current().hasRipServer) presigns?.urlFor(id) else null
                if (fresh == null) {
                    withContext(Dispatchers.Main) { failToSequencer(id) }
                    return@launch
                }
                withController { ctl ->
                    val idx = ctl.currentMediaItemIndex
                    val cur = ctl.currentMediaItem ?: return@withController
                    if (cur.mediaId != id) return@withController
                    val pos = ctl.currentPosition
                    ctl.replaceMediaItem(idx, withUrl(cur, fresh))
                    ctl.seekTo(idx, pos)
                    ctl.prepare()
                    ctl.play()
                }
            }
        }
    }

    /** A dead source in a sequencer run advances the set (never replays). */
    private fun failToSequencer(songId: String) {
        if (sequencerOwnsPlayer) sequencer.handleFailed(songId)
    }

    private fun withUrl(item: MediaItem, url: String): MediaItem {
        val extras = Bundle(item.requestMetadata.extras ?: Bundle()).apply {
            putString(PlaybackContract.EXTRA_URL, url)
        }
        return item.buildUpon()
            .setUri(url)
            .setRequestMetadata(
                MediaItem.RequestMetadata.Builder().setMediaUri(Uri.parse(url)).setExtras(extras).build(),
            )
            .build()
    }

    /**
     * Keep the next few queue items freshly presigned (iOS prefetch-3-ahead): resolved off the
     * critical path while the current song plays, swapped in only if the slot is unchanged.
     */
    private fun refreshAhead() {
        scope.launch {
            try {
                if (activeBackend != ActiveBackend.EXO || !settings.current().hasRipServer) return@launch
                val (from, ids) = withController { c ->
                    val range = PlaybackUrlResolver.aheadIndices(c.currentMediaItemIndex, c.mediaItemCount)
                    range.first to range.map { c.getMediaItemAt(it).mediaId }
                }
                for ((offset, id) in ids.withIndex()) {
                    // Burned-first: a local file item is never swapped back to a network URL.
                    val isLocal = withController { c ->
                        val idx = from + offset
                        idx < c.mediaItemCount && c.getMediaItemAt(idx).let {
                            PlaybackUrlResolver.isLocalItemUrl(
                                it.requestMetadata.extras?.getString(PlaybackContract.EXTRA_URL),
                                it.localConfiguration?.uri?.toString(),
                            )
                        }
                    }
                    if (isLocal) continue
                    val fresh = presigns?.urlFor(id) ?: continue
                    withController { c ->
                        val idx = from + offset
                        if (idx >= c.mediaItemCount || idx <= c.currentMediaItemIndex) return@withController
                        val item = c.getMediaItemAt(idx)
                        if (item.mediaId != id) return@withController
                        if (item.requestMetadata.extras?.getString(PlaybackContract.EXTRA_URL) == fresh) return@withController
                        c.replaceMediaItem(idx, withUrl(item, fresh))
                    }
                }
            } catch (error: Exception) {
                if (error is CancellationException) throw error
            }
        }
    }

    /**
     * Is a ▶ affordance honest for this song right now? Metadata-only rows must
     * not render a play control that can only fail (sources-reality rule).
     */
    fun isPlayable(songId: String): Boolean = rips.isPlayable(songId)

    /**
     * Play a song (specs/playback.md §3 ladder). When [queueAlbumContext] and
     * the song's album is known, the album's playable songs load as the queue
     * from this song's index — analog items get their own clip windows.
     *
     * History context: explicit [playContext] wins; otherwise album-queue plays
     * are tagged `album` (id+name captured now) and singles are `browser`
     * (specs/history.md §4).
     */
    suspend fun play(
        songId: String,
        queueAlbumContext: Boolean = true,
        playContext: PlayContext? = null,
    ): PlayOutcome {
        // Studio mic capture owns the audio path: nothing may start sounding into the take.
        if (!com.levi.pocketdj.studio.engine.AudioFocusPolicy.mayStartPlayback()) return PlayOutcome.Failed("Recording in progress")
        playGeneration.incrementAndGet()
        val merged = catalog.state.value.catalog
        val song = merged?.songsById?.get(songId)
        val ripConfigured = settings.current().hasRipServer
        // A manual ▶ of a song IN the running queue repositions the cursor (it must not queue the
        // album behind it, which would orphan the set) - see setQueueAndPlay's adoption.
        val queueAlbumContext = queueAlbumContext &&
            !withContext(Dispatchers.Main) { sequencer.inRunningQueue(songId) }

        return when (val action = PlayResolver.resolveBurnedFirst(songId, rips.entry(songId), ripConfigured, burnedFile(songId))) {
            // AM ladder (specs/applemusic.md §6.0): a manifest hit (Stream) always
            // wins first; only for a non-manifest song with an appleMusicId do the
            // AM rungs (full-track → preview) sit BEFORE rip-on-demand / metadata.
            is PlayAction.MetadataOnly ->
                tryAppleMusic(songId, song, merged, playContext)
                    ?: PlayOutcome.NotPlayable(action.reason)

            is PlayAction.RipRequired ->
                tryAppleMusic(songId, song, merged, playContext)
                    ?: startRipAndPlay(songId, playContext ?: PlayContext.BROWSER)

            is PlayAction.Stream -> {
                val album = song?.albumId?.let { merged.albumsById[it] }
                if (queueAlbumContext && album != null) {
                    playAlbumQueue(
                        album = album,
                        startSongId = songId,
                        playContext = playContext ?: PlayContext.album(album.id, album.name),
                    )
                } else {
                    val item = mediaItem(
                        songId = songId,
                        action = urls.resolve(songId, action, ripConfigured),
                        song = song,
                        album = song?.albumId?.let { merged?.albumsById?.get(it) },
                        playContext = playContext ?: PlayContext.BROWSER,
                    )
                    setQueueAndPlay(listOf(item), 0, adoptSongId = songId)
                    PlayOutcome.Started
                }
            }
        }
    }

    /** Play a whole album from its first playable track (or [startSongId]). */
    suspend fun playAlbum(albumId: String, startSongId: String? = null): PlayOutcome {
        val merged = catalog.state.value.catalog
            ?: return PlayOutcome.Failed("Catalog not loaded yet")
        val album = merged.albumsById[albumId]
            ?: return PlayOutcome.Failed("Unknown album")
        return playAlbumQueue(
            album = album,
            startSongId = startSongId,
            playContext = PlayContext.album(album.id, album.name),
        )
    }

    /**
     * Play an ordered queue of song ids (a realized setlist / Now Playing run) through the
     * [SetlistSequencer]: nothing is resolved here - each row resolves FRESH at its turn through
     * the [rowResolvers] ladder, unplayable rows are skipped with a `[playback] advance` line, and
     * a per-row `repeatCount` loops on natural end.
     *
     * The History context + navigable origin are captured ONCE at start: [playContext] when given,
     * else from the sequencer's providers keyed by [sourceSetlistId]. [startEntryIndex] addresses
     * the ORIGINAL entry list (empty-id entries are dropped).
     */
    suspend fun playQueue(
        entries: List<QueuePlan.QueueEntry>,
        playContext: PlayContext? = null,
        startEntryIndex: Int = 0,
        sourceSetlistId: String? = null,
    ): QueueOutcome {
        val merged = catalog.state.value.catalog
        val items = QueuePlan.items(entries) { id ->
            val song = merged?.songsById?.get(id)
            Triple(song?.name, song?.artist, song?.length)
        }
        if (items.isEmpty()) return QueueOutcome.NothingPlayable(entries.size)
        val start = QueuePlan.queueIndexForEntry(entries, startEntryIndex)
        withContext(Dispatchers.Main) {
            // The engine is about to be driven by the sequencer.
            sequencerOwnsPlayer = true
            sequencer.play(items, sourceSetlistId, context = playContext, startIndex = start)
        }
        return QueueOutcome.Started(
            playableEntryCount = items.size,
            skippedEntryCount = 0,
            requestedEntryCount = entries.size,
        )
    }

    /** Convenience: queue a frozen setlist's rows in frozen order (context captured from the setlist id). */
    suspend fun playSetlist(
        setlist: com.levi.pocketdj.data.collections.Setlist,
        playContext: PlayContext? = null,
        startEntryIndex: Int = 0,
    ): QueueOutcome = playQueue(
        QueuePlan.entriesForSetlist(setlist),
        playContext,
        startEntryIndex,
        sourceSetlistId = setlist.id,
    )

    /** Play an arbitrary stream (jukebox Tune-In) without disturbing a held queue. */
    suspend fun playUrl(title: String, artist: String?, url: String, seekMs: Long = 0) {
        withContext(Dispatchers.Main) { sequencer.playUrl(title, artist, url, seekMs) }
    }

    // Transport routes to whichever engine owns audio (single-owner, §6.1).
    suspend fun pause() {
        if (activeBackend == ActiveBackend.APPLE_MUSIC) appleMusicBackend?.pause()
        else withController { it.pause() }
    }

    suspend fun resume() {
        if (!com.levi.pocketdj.studio.engine.AudioFocusPolicy.mayStartPlayback()) return
        if (activeBackend == ActiveBackend.APPLE_MUSIC) appleMusicBackend?.resume()
        else withController { it.play() }
    }

    suspend fun next() {
        if (withContext(Dispatchers.Main) { sequencer.isRunning.also { if (it) sequencer.skipNext() } }) return
        if (activeBackend == ActiveBackend.APPLE_MUSIC) appleMusicBackend?.next()
        else withController { it.seekToNextMediaItem() }
    }

    suspend fun previous() {
        if (withContext(Dispatchers.Main) { sequencer.isRunning.also { if (it) sequencer.skipPrevious() } }) return
        if (activeBackend == ActiveBackend.APPLE_MUSIC) appleMusicBackend?.previous()
        else withController { it.seekToPreviousMediaItem() }
    }

    suspend fun seekTo(positionMs: Long) {
        if (activeBackend == ActiveBackend.APPLE_MUSIC) appleMusicBackend?.seekTo(positionMs)
        else withController { it.seekTo(positionMs) }
    }

    suspend fun stop() {
        withContext(Dispatchers.Main) {
            cancelRipOnDemand()
            sequencerOwnsPlayer = false
            sequencer.abandonRun() // the player teardown below is the stop
        }
        if (activeBackend == ActiveBackend.APPLE_MUSIC) {
            appleMusicBackend?.stop()
        } else {
            withController {
                it.stop()
                it.clearMediaItems()
            }
        }
    }

    /** Stop the AM engine without touching ExoPlayer — used before an ExoPlayer
     *  play so the two never sound at once (single-owner switching, §6.1). */
    private suspend fun stopAppleMusic() {
        if (activeBackend == ActiveBackend.APPLE_MUSIC) {
            appleMusicBackend?.stop()
        }
    }

    /**
     * Poll-style position read for the scrubber composable ONLY — deliberately
     * not a hot StateFlow so ~4 Hz position ticks don't recompose the world
     * (specs/playback.md §5.5).
     */
    suspend fun currentPositionMs(): Long =
        if (activeBackend == ActiveBackend.APPLE_MUSIC) {
            appleMusicBackend?.currentPositionMs() ?: 0L
        } else {
            withController { it.currentPosition }
        }

    /** Release the controller connection (the service keeps playing). */
    fun release() {
        val current = controller ?: return
        controller = null
        current.removeListener(playerListener)
        current.release()
    }

    // ---- internals ---------------------------------------------------------

    private suspend fun playAlbumQueue(
        album: IndexAlbum,
        startSongId: String?,
        playContext: PlayContext,
    ): PlayOutcome {
        val merged = catalog.state.value.catalog
            ?: return PlayOutcome.Failed("Catalog not loaded yet")
        val ripConfigured = settings.current().hasRipServer

        // Manifest hits only — metadata-only tracks are skipped in queues.
        val playable = merged.tracks(album).mapNotNull { song ->
            val action = PlayResolver.resolveBurnedFirst(song.id, rips.entry(song.id), false, burnedFile(song.id))
            (action as? PlayAction.Stream)?.let { song to it }
        }
        if (playable.isEmpty()) {
            // Fall back to the single-song ladder (may trigger a rip).
            return if (startSongId != null) {
                play(startSongId, queueAlbumContext = false, playContext = playContext)
            } else if (ripConfigured) {
                PlayOutcome.Failed("No ripped tracks on this album yet")
            } else {
                PlayOutcome.NotPlayable(PlayAction.MetadataOnly.Reason.NO_SERVER_CONFIGURED)
            }
        }

        var startIndex = playable.indexOfFirst { it.first.id == startSongId }
        if (startIndex < 0) startIndex = 0

        // P1 decision for unbounded analog windows (durationMs null in the
        // manifest): the item plays to the album file's natural end (iOS
        // whole-file behavior), so queue items after it would double-play the
        // album tail — truncate the queue after the first unbounded item at or
        // past the start index.
        val lastIndex = playable.withIndex()
            .firstOrNull { (index, entry) -> index >= startIndex && entry.second.isUnboundedAnalog }
            ?.index ?: playable.lastIndex

        val serverConfigured = ripConfigured
        val queueEntries = playable.subList(0, lastIndex + 1)
        // Presign ONLY the start item before playback begins (a hung presign must not hold ▶);
        // the rest start from the direct URL and are swapped to fresh presigned URLs by
        // refreshAhead() while the current song plays (and re-resolved again at each transition).
        val resolved = queueEntries.mapIndexed { index, (song, action) ->
            if (index == startIndex) urls.resolve(song.id, action, serverConfigured) else action
        }
        urls.prefetch(
            queueEntries.drop(startIndex + 1).take(PlaybackUrlResolver.AHEAD).map { it.first.id },
            serverConfigured,
        )
        val queue = queueEntries.mapIndexed { index, (song, _) ->
            val action = resolved[index]
            mediaItem(
                songId = song.id,
                action = action,
                song = song,
                album = album,
                playContext = playContext,
            )
        }
        setQueueAndPlay(queue, startIndex)
        refreshAhead()
        return PlayOutcome.Started
    }

    private suspend fun startRipAndPlay(songId: String, playContext: PlayContext): PlayOutcome {
        val job = try {
            ripServer.requestRip(songId)
        } catch (error: RipServerClient.RipServerException) {
            return PlayOutcome.Failed(error.message ?: "Rip failed")
        } catch (error: Exception) {
            if (error is CancellationException) throw error
            return PlayOutcome.Failed(error.message ?: "Rip failed")
        }

        if (job.isReady) {
            playResolvedUrl(songId, job.url!!, playContext)
            return PlayOutcome.Started
        }
        val jobId = job.jobId
            ?: return PlayOutcome.Failed(job.error ?: "Rip did not start")

        // "Preparing…" path: bounded 20 s interactive wait. A queued rip that outlives it is
        // NOT a failure ("Still ripping…"): the tracker keeps polling and refreshes the manifest
        // + fires onRipReady when it lands, so the row flips playable without another tap.
        _preparingSongId.value = songId
        _lastError.value = null
        val gen = playGeneration.get()
        val wait = RipPlayWait(
            awaitReady = { ripServer.awaitReadyInteractive(it) },
            refreshManifest = { rips.refresh() },
            presignedUrl = { presigns?.urlFor(it) },
            tracker = ripTracker,
        )
        scope.launch {
            try {
                when (
                    val result = wait.run(songId, jobId) {
                        playGeneration.get() == gen && _preparingSongId.value == songId
                    }
                ) {
                    is RipPlayWait.Result.Play -> playResolvedUrl(songId, result.url, playContext)
                    RipPlayWait.Result.StillRipping ->
                        if (playGeneration.get() == gen) {
                            _lastError.value = "Still ripping — this track will be playable in a few minutes."
                        }
                    RipPlayWait.Result.Superseded -> Unit
                }
            } catch (error: Exception) {
                if (error is CancellationException) throw error
                if (playGeneration.get() == gen) _lastError.value = error.message ?: "Rip failed"
            } finally {
                _preparingSongId.compareAndSet(songId, null)
            }
        }
        return PlayOutcome.Preparing(songId, jobId)
    }

    /**
     * The Apple Music rungs (specs/applemusic.md §6.0 rungs 2–3). Returns a
     * [PlayOutcome] when AM handled the song (full-track OR preview), or null so
     * the caller falls through to rip-on-demand / metadata-only. Fully guarded —
     * any AM failure returns null, never a crash (the classic ladder still runs).
     */
    private suspend fun tryAppleMusic(
        songId: String,
        song: IndexSong?,
        merged: com.levi.pocketdj.data.catalog.MergedCatalog?,
        playContext: PlayContext?,
    ): PlayOutcome? {
        val amId = song?.appleMusicId?.takeIf { it.isNotBlank() } ?: return null
        val resolver = previewResolver ?: return null
        val ctx = playContext ?: PlayContext.BROWSER
        val album = song.albumId?.let { merged?.albumsById?.get(it) }

        // Rung 2: full-track (device-only). Hand audio to the AM engine ONLY once
        // it CONFIRMS it is actually playing (backend.play awaits a real PLAYING /
        // error signal, not just the synchronous prepare()). The current ExoPlayer
        // track is PAUSED — not stopped/cleared — during the attempt, so a
        // full-track that can't play (region-locked, subscription hiccup, catalog
        // miss) resumes it instead of leaving silence, and falls through to the
        // preview rung below. Contrast startRipAndPlay, which likewise never
        // disrupts current playback until the new source is ready.
        val backend = appleMusicBackend
        var pausedExo = false
        if (backend != null && runCatching { backend.canPlayFullTrack() }.getOrDefault(false)) {
            // Claim ownership up-front so the ExoPlayer listener's IPC-delayed
            // pause/stop/clear events can't overwrite the AM now-playing card.
            val prior = activeBackend
            activeBackend = ActiveBackend.APPLE_MUSIC
            if (prior == ActiveBackend.EXO) {
                pausedExo = true
                withController { it.pause() }
            }
            val started = runCatching {
                backend.play(amId, songId, song.name, song.artist, song.albumId, ctx)
            }.getOrDefault(false)
            if (started) {
                // AM truly owns audio now → release ExoPlayer for good (guarded
                // events are ignored because activeBackend == APPLE_MUSIC).
                withContext(Dispatchers.Main) {
                    sequencerOwnsPlayer = false
                    sequencer.retirePendingStart()
                }
                withController {
                    it.stop()
                    it.clearMediaItems()
                }
                return PlayOutcome.Started
            }
            // Full-track failed to start → relinquish ownership to whatever owned
            // audio before, and fall through to the preview rung.
            activeBackend = prior
        }

        // Rung 3: 30-second preview via ExoPlayer (emulator-OK).
        val previewUrl = runCatching { resolver.previewUrl(amId) }.getOrNull()
        if (previewUrl == null) {
            // Nothing playable for this song. If we paused a live ExoPlayer track
            // for a failed full-track attempt, resume it so the attempt never
            // leaves silence; the caller then returns NotPlayable honestly.
            if (pausedExo) withController { it.play() }
            return null
        }
        val item = mediaItem(
            songId = songId,
            action = PlayAction.Stream(previewUrl),
            song = song,
            album = album,
            playContext = ctx,
            isPreview = true,
        )
        setQueueAndPlay(listOf(item), 0, adoptSongId = songId)
        return PlayOutcome.Started
    }

    private suspend fun playResolvedUrl(songId: String, url: String, playContext: PlayContext) {
        val merged = catalog.state.value.catalog
        val song = merged?.songsById?.get(songId)
        val album = song?.albumId?.let { merged.albumsById[it] }
        val item = mediaItem(
            songId = songId,
            action = PlayAction.Stream(url),
            song = song,
            album = album,
            playContext = playContext,
        )
        setQueueAndPlay(listOf(item), 0, adoptSongId = songId)
    }

    private fun mediaItem(
        songId: String,
        action: PlayAction.Stream,
        song: IndexSong?,
        album: IndexAlbum?,
        playContext: PlayContext,
        isPreview: Boolean = false,
        originCollectionId: String? = null,
        titleFallback: String? = null,
        artistFallback: String? = null,
    ): MediaItem {
        val artUri = album?.artCandidates()?.firstOrNull()
        val isLive = action.url.contains("/hls/")
        val extras: Bundle = bundleOf(
            PlaybackContract.EXTRA_URL to action.url,
            PlaybackContract.EXTRA_SOURCE to playContext.source,
            PlaybackContract.EXTRA_IS_LIVE to isLive,
            PlaybackContract.EXTRA_IS_PREVIEW to isPreview,
        ).apply {
            action.clipStartMs?.let { putLong(PlaybackContract.EXTRA_CLIP_START_MS, it) }
            action.clipEndMs?.let { putLong(PlaybackContract.EXTRA_CLIP_END_MS, it) }
            playContext.contextId?.let { putString(PlaybackContract.EXTRA_CONTEXT_ID, it) }
            playContext.contextName?.let { putString(PlaybackContract.EXTRA_CONTEXT_NAME, it) }
            album?.id?.let { putString(PlaybackContract.EXTRA_ALBUM_ID, it) }
            playContext.runTag?.let { putString(PlaybackContract.EXTRA_RUN_TAG, it) }
            originCollectionId?.let { putString(PlaybackContract.EXTRA_ORIGIN_COLLECTION_ID, it) }
        }
        return MediaItem.Builder()
            .setMediaId(songId)
            .setRequestMetadata(
                MediaItem.RequestMetadata.Builder()
                    .setMediaUri(Uri.parse(action.url))
                    .setExtras(extras)
                    .build(),
            )
            .setMediaMetadata(
                MediaMetadata.Builder()
                    .setTitle(song?.name ?: titleFallback ?: songId)
                    .setArtist(song?.artist ?: artistFallback)
                    .setAlbumTitle(album?.name)
                    .apply { artUri?.let { setArtworkUri(Uri.parse(it)) } }
                    .build(),
            )
            .build()
    }

    /**
     * Hand audio to ExoPlayer for a NON-sequencer play. [adoptSongId] (a single-row ▶) that is IN the
     * running queue repositions the sequencer's cursor to the nearest occurrence so the set keeps
     * auto-advancing; a non-member single leaves the index untouched. A multi-item queue (album
     * up-next) replaces the run.
     */
    private suspend fun setQueueAndPlay(items: List<MediaItem>, startIndex: Int, adoptSongId: String? = null) {
        // Single-owner: hand audio to ExoPlayer, stopping the AM engine first.
        cancelRipOnDemand() // a foreign play retires the run's rip-on-demand wait
        playGeneration.incrementAndGet()
        urlRetriedFor = null
        stopAppleMusic()
        activeBackend = ActiveBackend.EXO
        withContext(Dispatchers.Main) {
            sequencerOwnsPlayer = when {
                adoptSongId != null -> sequencer.adoptCursor(adoptSongId)
                items.size > 1 -> {
                    sequencer.abandonRun()
                    false
                }
                else -> {
                    // A non-member single: the run is kept but its in-flight start must not load
                    // over the user's pick (slow presign window).
                    sequencer.retirePendingStart()
                    false
                }
            }
        }
        withController {
            it.setMediaItems(items, startIndex, androidx.media3.common.C.TIME_UNSET)
            it.prepare()
            it.play()
        }
    }

    /** The sequencer's engine: loads ONLY the current row into ExoPlayer. */
    private inner class Media3Port : PlayerPort {
        override suspend fun load(request: PlayRequest) {
            val item = request.item
            // A foreign play retires the sequencer's pending start (generation bump, published); if
            // that happens while we await the presign we must stand down, not load over it.
            val entryGeneration = sequencer.state.value.playGeneration
            val merged = catalog.state.value.catalog
            val song = merged?.songsById?.get(item.id)
            val album = song?.albumId?.let { merged.albumsById[it] }
            // Instant metadata (PB-2): the notification shows the new row before any network resolve.
            val instantMd = MediaMetadata.Builder()
                    .setTitle(song?.name ?: item.title ?: item.id)
                    .setArtist(song?.artist ?: item.artist)
                    .setAlbumTitle(album?.name)
                    .apply { album?.artCandidates()?.firstOrNull()?.let { setArtworkUri(Uri.parse(it)) } }
                    .build()
            RunTransportBus.instantMetadata?.invoke(instantMd)
            val ripConfigured = settings.current().hasRipServer
            ripWatchJob?.cancel() // the previous row's live-swap watcher must not touch this one
            ripWatchJob = null
            try {
                val action = when (val src = request.source) {
                    is LocalFileSource -> PlayAction.Stream(src.file.url, src.file.startMs, src.file.endMs)
                    // Presign ONLY the row being started; the next few are warmed below.
                    is StreamSource -> urls.resolve(item.resolveId, src.action, ripConfigured)
                    // Rip-on-demand: the row loads NOW as a placeholder (metadata on the card, BUFFERING);
                    // the service's data source POSTs /rip and reads the durable mp3 when it lands.
                    is RipOnDemandSource -> PlayAction.Stream(RipOnDemandSource.uriFor(src.songId))
                    else -> throw IllegalStateException("No player path for source ${src.backend}")
                }
                if (request.source !is RipOnDemandSource) ripSession.cancel()
                val mi = mediaItem(
                    songId = item.id,
                    action = action,
                    song = song,
                    album = album,
                    playContext = request.context,
                    originCollectionId = request.originCollectionId,
                    titleFallback = item.title,
                    artistFallback = item.artist,
                )
                if (sequencer.state.value.playGeneration != entryGeneration) throw CancellationException("superseded by a foreign play")
                playGeneration.incrementAndGet()
                urlRetriedFor = null
                stopAppleMusic()
                activeBackend = ActiveBackend.EXO
                sequencerOwnsPlayer = true
                val resume = request.resumeAtMs
                val rip = request.source as? RipOnDemandSource
                if (rip != null) { ripSession.cancel(rip.songId); ripSession.begin(rip.songId) } // fresh resolve each load (retry-in-place re-POSTs); BEFORE the load: the data source joins this one
                withController {
                    it.setMediaItems(listOf(mi), 0, resume ?: androidx.media3.common.C.TIME_UNSET)
                    it.prepare()
                    it.play()
                }
                if (rip != null) watchRipOnDemand(rip.songId, item.id, entryGeneration, mi)
            } catch (e: Throwable) {
                // A failed/superseded load must not leave this row's title over whatever is still loaded.
                RunTransportBus.clearInstantMetadata?.invoke(instantMd)
                throw e
            }
            val ahead = sequencer.state.value.upcoming.take(PlaybackUrlResolver.AHEAD).map { it.resolveId }
            urls.prefetch(ahead, ripConfigured)
        }

        override suspend fun loadUrl(request: UrlRequest) {
            val mi = MediaItem.Builder()
                .setMediaId("url:" + request.url)
                .setRequestMetadata(
                    MediaItem.RequestMetadata.Builder()
                        .setMediaUri(Uri.parse(request.url))
                        .setExtras(
                            bundleOf(
                                PlaybackContract.EXTRA_URL to request.url,
                                PlaybackContract.EXTRA_SOURCE to PlayContext.SOURCE_BROWSER,
                                PlaybackContract.EXTRA_IS_LIVE to request.url.contains("/hls/"),
                                PlaybackContract.EXTRA_IS_STREAM to true,
                            ),
                        )
                        .build(),
                )
                .setMediaMetadata(
                    MediaMetadata.Builder().setTitle(request.title).setArtist(request.artist).build(),
                )
                .build()
            playGeneration.incrementAndGet()
            stopAppleMusic()
            activeBackend = ActiveBackend.EXO
            sequencerOwnsPlayer = false // the stream's end must never advance a (held) queue
            withController {
                it.setMediaItems(listOf(mi), 0, if (request.seekMs > 0) request.seekMs else androidx.media3.common.C.TIME_UNSET)
                it.prepare()
                it.play()
            }
        }

        override suspend fun replay(songId: String): Boolean {
            if (!sequencerOwnsPlayer || activeBackend != ActiveBackend.EXO) return false
            return withController { c ->
                val cur = c.currentMediaItem
                if (cur == null || cur.mediaId != songId) {
                    false
                } else {
                    // Same item, no timeline change: no MEDIA_ITEM_TRANSITION, so no second History row.
                    c.seekTo(0)
                    c.prepare()
                    c.play()
                    true
                }
            }
        }

        override suspend fun pause() = withController { it.pause() }
        override suspend fun resume() = withController { it.play() }
        override suspend fun seekTo(positionMs: Long) = withController { it.seekTo(positionMs) }
        override suspend fun stop() {
            // Only tear the engine down if the sequencer still owns it (a foreign single may be playing).
            if (!sequencerOwnsPlayer) return
            sequencerOwnsPlayer = false
            cancelRipOnDemand()
            withController {
                it.stop()
                it.clearMediaItems()
            }
        }
    }

    @Volatile private var ripWatchJob: kotlinx.coroutines.Job? = null

    private fun cancelRipOnDemand() {
        ripWatchJob?.cancel()
        ripWatchJob = null
        ripSession.cancel()
    }

    /**
     * Follow a rip-on-demand row: a LIVE result replaces the placeholder with the HLS stream (waitingForLive,
     * scrubber off, backstop armed); a DURABLE result lets the start watchdog take over while the data source
     * reads the mp3. A failed resolve is left to the data source (it throws -> onPlayerError -> dead source).
     */
    private fun watchRipOnDemand(songId: String, mediaId: String, entryGeneration: Long, placeholder: MediaItem) {
        ripWatchJob?.cancel()
        ripWatchJob = sequencerScope.launch {
            val result = try {
                ripSession.begin(songId).await()
            } catch (e: CancellationException) {
                throw e
            } catch (e: Exception) {
                return@launch
            }
            if (sequencer.state.value.playGeneration != entryGeneration) return@launch
            when (result) {
                is RipResolution.Durable -> sequencer.noteSourceResolved(songId)
                is RipResolution.Live -> {
                    val live = withUrl(placeholder, result.url)
                    val extras = Bundle(live.requestMetadata.extras ?: Bundle()).apply {
                        putBoolean(PlaybackContract.EXTRA_IS_LIVE, true)
                        remove(PlaybackContract.EXTRA_CLIP_START_MS)
                        remove(PlaybackContract.EXTRA_CLIP_END_MS)
                    }
                    val liveItem = live.buildUpon().setRequestMetadata(
                        MediaItem.RequestMetadata.Builder().setMediaUri(Uri.parse(result.url)).setExtras(extras).build(),
                    ).build()
                    var swapped = false
                    withController { c ->
                        if (c.currentMediaItem?.mediaId == mediaId) {
                            c.setMediaItems(listOf(liveItem), 0, androidx.media3.common.C.TIME_UNSET)
                            c.prepare()
                            c.play()
                            swapped = true
                        }
                    }
                    if (swapped && sequencer.state.value.playGeneration == entryGeneration) {
                        sequencer.noteLive(songId)
                        sequencer.noteSourceResolved(songId)
                        result.jobId?.let { ripTracker?.pollToReady(songId, it) }
                    }
                }
            }
        }
    }

    /** Release the AM engine's native resources (sign-out / teardown). */
    fun releaseAppleMusic() {
        appleMusicBackend?.release()
    }

    private fun snapshot(player: Player): NowPlayingInfo? {
        val item = player.currentMediaItem ?: return null
        val extras = item.requestMetadata.extras
        return NowPlayingInfo(
            songId = item.mediaId,
            title = item.mediaMetadata.title?.toString(),
            artist = item.mediaMetadata.artist?.toString(),
            albumId = extras?.getString(PlaybackContract.EXTRA_ALBUM_ID),
            isPlaying = player.isPlaying,
            durationMs = player.duration.takeIf { it != androidx.media3.common.C.TIME_UNSET },
            isLive = extras?.getBoolean(PlaybackContract.EXTRA_IS_LIVE, false) ?: false,
            isPreview = extras?.getBoolean(PlaybackContract.EXTRA_IS_PREVIEW, false) ?: false,
            context = PlayContext(
                source = extras?.getString(PlaybackContract.EXTRA_SOURCE)
                    ?: PlayContext.SOURCE_BROWSER,
                contextId = extras?.getString(PlaybackContract.EXTRA_CONTEXT_ID),
                contextName = extras?.getString(PlaybackContract.EXTRA_CONTEXT_NAME),
            ),
        )
    }

    /** MediaController is main-thread confined; every touch hops to Main. */
    private suspend fun <T> withController(block: (MediaController) -> T): T =
        withContext(Dispatchers.Main) {
            block(obtainController())
        }

    private suspend fun obtainController(): MediaController {
        controller?.let { return it }
        return controllerMutex.withLock {
            controller ?: run {
                val token = SessionToken(context, ComponentName(context, PlaybackService::class.java))
                val built = MediaController.Builder(context, token).buildAsync().await()
                built.addListener(playerListener)
                _nowPlaying.value = snapshot(built)
                controller = built
                built
            }
        }
    }

    private companion object {
        /** A rip-on-demand row waits at most this long for its durable mp3 (a skip cancels it sooner). */
        const val RIP_WAIT_CAP_MS = 600_000L
    }
}

private suspend fun <T> ListenableFuture<T>.await(): T =
    suspendCancellableCoroutine { continuation ->
        addListener(
            {
                try {
                    continuation.resumeWith(Result.success(get()))
                } catch (error: Exception) {
                    continuation.resumeWith(Result.failure(error))
                }
            },
            MoreExecutors.directExecutor(),
        )
        continuation.invokeOnCancellation { cancel(false) }
    }

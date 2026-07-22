package com.levi.pocketdj.playback

import android.content.ComponentName
import android.content.Context
import android.net.Uri
import android.os.Bundle
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
import com.levi.pocketdj.data.rips.PlayAction
import com.levi.pocketdj.data.rips.PlayResolver
import com.levi.pocketdj.data.rips.RipServerClient
import com.levi.pocketdj.data.rips.RipsRepository
import com.levi.pocketdj.data.settings.AppSettingsStore
import kotlinx.coroutines.CancellationException
import kotlinx.coroutines.CoroutineScope
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
        val context: PlayContext,
    )

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

    private var controller: MediaController? = null
    private val controllerMutex = Mutex()

    private val playerListener = object : Player.Listener {
        override fun onEvents(player: Player, events: Player.Events) {
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
        val merged = catalog.state.value.catalog
        val song = merged?.songsById?.get(songId)
        val ripConfigured = settings.current().hasRipServer

        return when (val action = PlayResolver.resolve(songId, rips.entry(songId), ripConfigured)) {
            is PlayAction.MetadataOnly -> PlayOutcome.NotPlayable(action.reason)

            is PlayAction.RipRequired -> startRipAndPlay(songId, playContext ?: PlayContext.BROWSER)

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
                        action = action,
                        song = song,
                        album = song?.albumId?.let { merged?.albumsById?.get(it) },
                        playContext = playContext ?: PlayContext.BROWSER,
                    )
                    setQueueAndPlay(listOf(item), 0)
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
     * Play an ordered queue of song ids (a realized setlist / Now Playing run —
     * specs/realize-play.md §6.3). Resolution happens at queue-BUILD time via
     * [QueuePlan]: manifest hits stream (with analog clip windows), everything
     * else is SKIPPED (P2 cut: no per-row rip-on-demand inside a queue run).
     * Per-item repeatCount expands into consecutive duplicate items.
     *
     * [playContext] is captured once for the whole run (the iOS captured-origin
     * doctrine) — build it from `CollectionsStore.historyContext(...)` so
     * History attributes rows to the right playlist/pocket/setlist.
     *
     * [startEntryIndex] addresses the ORIGINAL entry list (pre-skip,
     * pre-repeat); playback starts at the first playable entry at or after it.
     */
    suspend fun playQueue(
        entries: List<QueuePlan.QueueEntry>,
        playContext: PlayContext,
        startEntryIndex: Int = 0,
    ): QueueOutcome {
        val merged = catalog.state.value.catalog
        val plan = QueuePlan.build(entries) { songId ->
            PlayResolver.resolve(songId, rips.entry(songId), false)
        }
        if (plan.isEmpty) return QueueOutcome.NothingPlayable(entries.size)

        val items = plan.items.map { planned ->
            val song = merged?.songsById?.get(planned.songId)
            val album = song?.albumId?.let { merged.albumsById[it] }
            mediaItem(
                songId = planned.songId,
                action = planned.action,
                song = song,
                album = album,
                playContext = playContext,
            )
        }
        var startIndex = plan.items.indexOfFirst { it.entryIndex >= startEntryIndex }
        if (startIndex < 0) startIndex = 0
        setQueueAndPlay(items, startIndex)
        return QueueOutcome.Started(
            playableEntryCount = plan.playableEntryCount,
            skippedEntryCount = plan.skippedEntryCount,
            requestedEntryCount = plan.requestedEntryCount,
        )
    }

    /** Convenience: queue a frozen setlist's playable rows in frozen order. */
    suspend fun playSetlist(
        setlist: com.levi.pocketdj.data.collections.Setlist,
        playContext: PlayContext,
        startEntryIndex: Int = 0,
    ): QueueOutcome = playQueue(QueuePlan.entriesForSetlist(setlist), playContext, startEntryIndex)

    suspend fun pause() = withController { it.pause() }
    suspend fun resume() = withController { it.play() }
    suspend fun next() = withController { it.seekToNextMediaItem() }
    suspend fun previous() = withController { it.seekToPreviousMediaItem() }
    suspend fun seekTo(positionMs: Long) = withController { it.seekTo(positionMs) }

    suspend fun stop() = withController {
        it.stop()
        it.clearMediaItems()
    }

    /**
     * Poll-style position read for the scrubber composable ONLY — deliberately
     * not a hot StateFlow so ~4 Hz position ticks don't recompose the world
     * (specs/playback.md §5.5).
     */
    suspend fun currentPositionMs(): Long = withController { it.currentPosition }

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
            val action = PlayResolver.resolve(song.id, rips.entry(song.id), false)
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

        val queue = playable.subList(0, lastIndex + 1).map { (song, action) ->
            mediaItem(
                songId = song.id,
                action = action,
                song = song,
                album = album,
                playContext = playContext,
            )
        }
        setQueueAndPlay(queue, startIndex)
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

        // "Preparing…" path (specs/playback.md §4.5 Phase-1 minimum): wait for
        // the durable mp3, refresh the manifest, then start playback.
        _preparingSongId.value = songId
        _lastError.value = null
        scope.launch {
            try {
                val url = ripServer.awaitReady(jobId)
                runCatching { rips.refresh() }
                playResolvedUrl(songId, url, playContext)
            } catch (error: Exception) {
                if (error is CancellationException) throw error
                _lastError.value = error.message ?: "Rip failed"
            } finally {
                _preparingSongId.value = null
            }
        }
        return PlayOutcome.Preparing(songId, jobId)
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
        setQueueAndPlay(listOf(item), 0)
    }

    private fun mediaItem(
        songId: String,
        action: PlayAction.Stream,
        song: IndexSong?,
        album: IndexAlbum?,
        playContext: PlayContext,
    ): MediaItem {
        val artUri = album?.artCandidates()?.firstOrNull()
        val isLive = action.url.contains("/hls/")
        val extras: Bundle = bundleOf(
            PlaybackContract.EXTRA_URL to action.url,
            PlaybackContract.EXTRA_SOURCE to playContext.source,
            PlaybackContract.EXTRA_IS_LIVE to isLive,
        ).apply {
            action.clipStartMs?.let { putLong(PlaybackContract.EXTRA_CLIP_START_MS, it) }
            action.clipEndMs?.let { putLong(PlaybackContract.EXTRA_CLIP_END_MS, it) }
            playContext.contextId?.let { putString(PlaybackContract.EXTRA_CONTEXT_ID, it) }
            playContext.contextName?.let { putString(PlaybackContract.EXTRA_CONTEXT_NAME, it) }
            album?.id?.let { putString(PlaybackContract.EXTRA_ALBUM_ID, it) }
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
                    .setTitle(song?.name ?: songId)
                    .setArtist(song?.artist)
                    .setAlbumTitle(album?.name)
                    .apply { artUri?.let { setArtworkUri(Uri.parse(it)) } }
                    .build(),
            )
            .build()
    }

    private suspend fun setQueueAndPlay(items: List<MediaItem>, startIndex: Int) {
        withController {
            it.setMediaItems(items, startIndex, androidx.media3.common.C.TIME_UNSET)
            it.prepare()
            it.play()
        }
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

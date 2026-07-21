package com.levi.pocketdj.data.jukebox

import android.content.ComponentName
import android.content.Context
import android.net.Uri
import androidx.core.os.bundleOf
import androidx.media3.common.C
import androidx.media3.common.MediaItem
import androidx.media3.common.MediaMetadata
import androidx.media3.session.MediaController
import androidx.media3.session.SessionToken
import com.google.common.util.concurrent.ListenableFuture
import com.google.common.util.concurrent.MoreExecutors
import com.levi.pocketdj.data.catalog.CatalogRepository
import com.levi.pocketdj.data.catalog.IndexSong
import com.levi.pocketdj.data.config.Endpoints
import com.levi.pocketdj.data.rips.PlayAction
import com.levi.pocketdj.data.rips.PlayResolver
import com.levi.pocketdj.data.rips.RipsRepository
import com.levi.pocketdj.playback.PlaybackContract
import com.levi.pocketdj.playback.PlaybackController
import com.levi.pocketdj.playback.PlaybackService
import com.levi.pocketdj.playback.PlayContext
import java.util.concurrent.atomic.AtomicBoolean
import kotlin.random.Random
import kotlinx.coroutines.CancellationException
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.Job
import kotlinx.coroutines.flow.MutableSharedFlow
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.asStateFlow
import kotlinx.coroutines.flow.first
import kotlinx.coroutines.flow.update
import kotlinx.coroutines.isActive
import kotlinx.coroutines.launch
import kotlinx.coroutines.suspendCancellableCoroutine
import kotlinx.coroutines.sync.Mutex
import kotlinx.coroutines.sync.withLock
import kotlinx.coroutines.withContext
import kotlinx.coroutines.withTimeoutOrNull

/**
 * The DJ session engine — the Android `JukeboxStore` equivalent
 * (specs/jukebox.md §4). App-scoped singleton: the 4 s loop runs in the app
 * scope so it survives navigation, and the session persists so a relaunch
 * re-adopts a running party.
 *
 * Loop shape (§4.2): one coroutine while live; each tick posts a player-state
 * snapshot (on change, or on the 15 s heartbeat) and polls guest requests.
 * Posting honest snapshots IS how songs get marked played — the broker derives
 * the played history from now-playing transitions across the posts (§1); this
 * store mirrors that derivation locally for the played-history section.
 *
 * Transport errors never stop the loop; 404/410 folds the session (§2.4).
 */
class JukeboxRepository(
    context: Context,
    private val client: JukeboxClient,
    private val sessionStore: JukeboxSessionStore,
    private val catalog: CatalogRepository,
    private val rips: RipsRepository,
    private val playback: PlaybackController,
    private val scope: CoroutineScope,
) {
    private val appContext = context.applicationContext

    /** Match state for one inbox row (§4.4). */
    sealed interface Match {
        /** Row shows "Matching…" until the async match lands. */
        data object Searching : Match

        /** No catalog candidate — Deny is the only enabled action. */
        data object None : Match

        /**
         * A catalog candidate; [playable] is true only when a public rip exists
         * — a match without audio must stay Deny-only (§5.1).
         */
        data class Found(val song: IndexSong, val playable: Boolean) : Match
    }

    data class RequestRow(
        val request: JukeboxRequest,
        val match: Match = Match.Searching,
    )

    /** One locally-derived played-history row (newest first). */
    data class PlayedEntry(val title: String, val artist: String, val atMs: Long)

    data class UiState(
        val session: JukeboxSessionInfo? = null,
        val starting: Boolean = false,
        /** View + Hear (§5.3) — every new session starts OFF. */
        val hear: Boolean = false,
        /** Pending guest requests, oldest first. */
        val requests: List<RequestRow> = emptyList(),
        /** Locally-derived played history, newest first (mirror of §1). */
        val played: List<PlayedEntry> = emptyList(),
        /** Queue items after the current one, from the last loop tick. */
        val upNextCount: Int = 0,
        /** Transient broker trouble — shown as a subtle hint; loop keeps going. */
        val transientError: String? = null,
        /** Create-view message: start failure or "This jukebox has ended." */
        val notice: String? = null,
    )

    private val _state = MutableStateFlow(UiState())
    val state: StateFlow<UiState> = _state.asStateFlow()

    private var loopJob: Job? = null
    private val tickKick = MutableSharedFlow<Unit>(extraBufferCapacity = 1)
    private val bootstrapped = AtomicBoolean(false)

    /** Requests already decided locally — the poll re-delivers decided ids
     *  because a decision bumps their seq server-side (§2.5, §4.2). Synchronized:
     *  written from the UI thread in [decide], read on Default in [ingest]. */
    private val decided: MutableSet<String> =
        java.util.Collections.synchronizedSet(mutableSetOf<String>())
    private var sinceSeq = 0L
    private var lastPosted: JukeboxStatePayload? = null
    private var lastPostAtMs = 0L
    private var lastOnAir: Pair<String, String>? = null

    private var controller: MediaController? = null
    private val controllerMutex = Mutex()

    /** Re-adopt a persisted session at app start (§4.1 Resume). Idempotent. */
    fun bootstrap() {
        if (!bootstrapped.compareAndSet(false, true)) return
        scope.launch {
            val persisted = sessionStore.load() ?: return@launch
            if (_state.value.session != null) return@launch
            _state.update { it.copy(session = persisted.session, hear = persisted.hear) }
            startLoop()
        }
    }

    /** Start a session (§4.1). Errors land in [UiState.notice]; stay on create. */
    fun start(name: String, requiresToken: Boolean) {
        if (_state.value.session != null || _state.value.starting) return
        _state.update { it.copy(starting = true, notice = null) }
        scope.launch {
            try {
                val created = client.createSession(
                    name = name.trim().ifEmpty { DEFAULT_SESSION_NAME },
                    requiresToken = requiresToken,
                )
                // Stamp the intent locally — the server doesn't echo it (§3.1).
                val stamped = created.copy(requiresToken = requiresToken)
                sessionStore.save(stamped)
                sessionStore.setHear(false)
                resetLoopBookkeeping()
                _state.value = UiState(session = stamped, hear = false)
                startLoop()
            } catch (error: CancellationException) {
                throw error
            } catch (error: Exception) {
                _state.update {
                    it.copy(
                        starting = false,
                        notice = error.message ?: "Couldn't start the jukebox",
                    )
                }
            }
        }
    }

    /**
     * End the party (§4.1): POST /end best-effort, then clear the local session
     * EVEN IF the POST failed — an unreachable broker must not trap the host.
     */
    fun end() {
        val session = _state.value.session ?: return
        loopJob?.cancel()
        loopJob = null
        scope.launch {
            runCatching { client.end(session) }
            sessionStore.clear()
            releaseController()
            resetLoopBookkeeping()
            _state.value = UiState()
        }
    }

    /** Flip View + Hear; an immediate tick shows guests the flip promptly. */
    fun setHear(enabled: Boolean) {
        if (_state.value.session == null) return
        _state.update { it.copy(hear = enabled) }
        scope.launch { sessionStore.setHear(enabled) }
        kick()
    }

    /** Local-intent-only toggle (§3.1, §9) — persisted, never claimed enforced. */
    fun setRequiresTokenIntent(required: Boolean) {
        val session = _state.value.session ?: return
        val stamped = session.copy(requiresToken = required)
        _state.update { it.copy(session = stamped) }
        scope.launch { sessionStore.save(stamped) }
    }

    /**
     * Decide a request (§4.3): the id joins the decided set and leaves the inbox
     * immediately; the POST is fire-and-forget (the local queue edit is the
     * user-visible truth). Placements apply only with a playable match.
     */
    fun decide(requestId: String, action: JukeboxDecisionAction) {
        val session = _state.value.session ?: return
        val row = _state.value.requests.firstOrNull { it.request.id == requestId } ?: return
        decided += requestId
        _state.update { current ->
            current.copy(requests = current.requests.filterNot { it.request.id == requestId })
        }
        scope.launch { runCatching { client.decide(session, requestId, action) } }
        if (action.isPlacement) {
            val found = row.match as? Match.Found
            if (found?.playable == true) {
                scope.launch { applyPlacement(found.song, action) }
            }
        }
    }

    // ---- loop --------------------------------------------------------------

    private fun startLoop() {
        loopJob?.cancel()
        loopJob = scope.launch {
            while (isActive && _state.value.session != null) {
                tick()
                withTimeoutOrNull(TICK_MS) { tickKick.first() }
            }
        }
    }

    /** Request an immediate tick (hear flip, fresh placement). */
    private fun kick() {
        tickKick.tryEmit(Unit)
    }

    private suspend fun tick() {
        val session = _state.value.session ?: return
        val hear = _state.value.hear
        try {
            // 1. Compose + post the snapshot (on change or 15 s heartbeat).
            // "Post positions honestly" (§1): a FAILED player read must skip the
            // state POST for this tick — posting nowPlaying=null would make the
            // broker log the still-playing song as played and flash guests
            // "Nothing playing" over a transient binder hiccup.
            val snapshotResult = runCatching { readPlayer() }
            snapshotResult.exceptionOrNull()?.let { if (it is CancellationException) throw it }
            if (snapshotResult.isSuccess) {
                val snapshot = snapshotResult.getOrNull()
                derivePlayed(snapshot)
                _state.update { it.copy(upNextCount = snapshot?.upNext?.size ?: 0) }
                val payload = composePayload(snapshot, hear)
                val now = System.currentTimeMillis()
                if (payload != lastPosted || now - lastPostAtMs > HEARTBEAT_MS) {
                    client.postState(session, payload)
                    lastPosted = payload
                    lastPostAtMs = now
                }
            }

            // 2. Poll guest requests above the seq high-water mark.
            val page = client.requests(session, sinceSeq)
            sinceSeq = maxOf(sinceSeq, page.seq)
            ingest(page.requests)

            // 3. Success clears the reconnect hint.
            _state.update { it.copy(transientError = null) }
        } catch (error: CancellationException) {
            throw error
        } catch (error: JukeboxClient.JukeboxException) {
            if (error.code == 404 || error.code == 410) {
                foldSession()
            } else {
                _state.update { it.copy(transientError = error.message) }
            }
        } catch (error: Exception) {
            _state.update {
                it.copy(transientError = error.message ?: "Jukebox server unreachable — retrying")
            }
        }
    }

    /** Server-side death (§2.4): clear everything, back to the create view. */
    private suspend fun foldSession() {
        sessionStore.clear()
        releaseController()
        resetLoopBookkeeping()
        _state.value = UiState(notice = "This jukebox has ended.")
    }

    private fun resetLoopBookkeeping() {
        decided.clear()
        sinceSeq = 0
        lastPosted = null
        lastPostAtMs = 0
        lastOnAir = null
    }

    private fun ingest(incoming: List<JukeboxRequest>) {
        val inboxIds = _state.value.requests.map { it.request.id }.toSet()
        val fresh = incoming.filter { request ->
            request.status == JukeboxRequest.STATUS_PENDING &&
                request.id !in decided &&
                request.id !in inboxIds
        }
        if (fresh.isEmpty()) return
        _state.update { current ->
            current.copy(requests = current.requests + fresh.map(::RequestRow))
        }
        fresh.forEach { request ->
            scope.launch(Dispatchers.Default) { computeMatch(request) }
        }
    }

    private fun computeMatch(request: JukeboxRequest) {
        val songs = catalog.state.value.catalog?.songs.orEmpty()
        val song = JukeboxMatcher.match(request.title, request.artist, songs)
        val match = song?.let { Match.Found(it, rips.isPlayable(it.id)) } ?: Match.None
        _state.update { current ->
            current.copy(
                requests = current.requests.map { row ->
                    if (row.request.id == request.id) row.copy(match = match) else row
                },
            )
        }
    }

    // ---- snapshots ---------------------------------------------------------

    private data class PlayerSnapshot(
        val songId: String?,
        val title: String?,
        val artist: String?,
        val durationMs: Long?,
        val positionMs: Long,
        val upNext: List<JukeboxStatePayload.Track>,
    )

    private fun composePayload(snapshot: PlayerSnapshot?, hear: Boolean): JukeboxStatePayload {
        val nowPlaying = snapshot?.songId?.let { songId ->
            JukeboxStatePayload.NowPlaying(
                title = snapshot.title.orEmpty(),
                artist = snapshot.artist.orEmpty(),
                lengthMs = snapshot.durationMs,
                positionMs = snapshot.positionMs,
                streamUrl = if (hear) publicRipUrl(songId) else null,
            )
        }
        return JukeboxStatePayload(
            hear = hear,
            nowPlaying = nowPlaying,
            upNext = snapshot?.upNext.orEmpty(),
        )
    }

    /**
     * Hear-mode gate (§5.3, client-side and load-bearing): ONLY the public https
     * rips-bucket mp3 ever leaves the device — no manifest entry, no streamUrl.
     */
    private fun publicRipUrl(songId: String): String? =
        rips.entry(songId)?.key?.let(Endpoints::ripAudioUrl)

    /**
     * Local mirror of the broker's played-history derivation (§1): a snapshot
     * replacing one track with a different one (or nothing) logs the outgoing
     * track. Same title+artist is a position tick, not a transition.
     */
    private fun derivePlayed(snapshot: PlayerSnapshot?) {
        val current = snapshot?.songId?.let {
            snapshot.title.orEmpty() to snapshot.artist.orEmpty()
        }
        val previous = lastOnAir
        if (previous != null && previous != current) {
            val entry = PlayedEntry(previous.first, previous.second, System.currentTimeMillis())
            _state.update { it.copy(played = (listOf(entry) + it.played).take(PLAYED_CAP)) }
        }
        lastOnAir = current
    }

    // ---- playback integration (§4.3, §5) -----------------------------------

    private suspend fun applyPlacement(song: IndexSong, action: JukeboxDecisionAction) {
        try {
            val snapshot = readPlayer()
            if (snapshot.songId == null) {
                // Nothing playing — the accepted request starts the music with
                // a one-item queue (§4.3).
                playback.play(song.id, queueAlbumContext = false)
                kick()
                return
            }
            val stream = PlayResolver.resolve(song.id, rips.entry(song.id), false)
                as? PlayAction.Stream
            if (stream == null) {
                _state.update {
                    it.copy(transientError = "“${song.name}” isn't playable anymore")
                }
                return
            }
            val item = queueItem(song, stream)
            withController { player ->
                val count = player.mediaItemCount
                val afterCurrent = (player.currentMediaItemIndex + 1).coerceIn(0, count)
                val insertAt = when (action) {
                    JukeboxDecisionAction.NEXT -> afterCurrent
                    JukeboxDecisionAction.END -> count
                    // Uniform random slot within the upcoming tail.
                    else -> if (afterCurrent >= count) count else Random.nextInt(afterCurrent, count + 1)
                }
                player.addMediaItem(insertAt, item)
            }
            kick()
        } catch (error: CancellationException) {
            throw error
        } catch (error: Exception) {
            _state.update { it.copy(transientError = error.message ?: "Couldn't queue the request") }
        }
    }

    /**
     * Build a queue item the [PlaybackService] can resolve — the same
     * [PlaybackContract] request-metadata contract the [PlaybackController]
     * uses, so the URI + clip window survive the controller → session hop.
     */
    private fun queueItem(song: IndexSong, action: PlayAction.Stream): MediaItem {
        val merged = catalog.state.value.catalog
        val album = song.albumId?.let { merged?.albumsById?.get(it) }
        val extras = bundleOf(
            PlaybackContract.EXTRA_URL to action.url,
            PlaybackContract.EXTRA_SOURCE to PlayContext.SOURCE_BROWSER,
            PlaybackContract.EXTRA_IS_LIVE to false,
        ).apply {
            action.clipStartMs?.let { putLong(PlaybackContract.EXTRA_CLIP_START_MS, it) }
            action.clipEndMs?.let { putLong(PlaybackContract.EXTRA_CLIP_END_MS, it) }
            album?.id?.let { putString(PlaybackContract.EXTRA_ALBUM_ID, it) }
        }
        return MediaItem.Builder()
            .setMediaId(song.id)
            .setRequestMetadata(
                MediaItem.RequestMetadata.Builder()
                    .setMediaUri(Uri.parse(action.url))
                    .setExtras(extras)
                    .build(),
            )
            .setMediaMetadata(
                MediaMetadata.Builder()
                    .setTitle(song.name)
                    .setArtist(song.artist)
                    .setAlbumTitle(album?.name)
                    .apply {
                        album?.artCandidates()?.firstOrNull()?.let { setArtworkUri(Uri.parse(it)) }
                    }
                    .build(),
            )
            .build()
    }

    /** One main-thread hop reading now-playing + the upcoming queue tail. */
    private suspend fun readPlayer(): PlayerSnapshot = withController { player ->
        val item = player.currentMediaItem
        val upNext = buildList {
            val from = if (player.currentMediaItemIndex >= 0) player.currentMediaItemIndex + 1 else 0
            for (index in from until player.mediaItemCount) {
                val metadata = player.getMediaItemAt(index).mediaMetadata
                add(
                    JukeboxStatePayload.Track(
                        title = metadata.title?.toString().orEmpty(),
                        artist = metadata.artist?.toString().orEmpty(),
                    ),
                )
            }
        }
        PlayerSnapshot(
            songId = item?.mediaId,
            title = item?.mediaMetadata?.title?.toString(),
            artist = item?.mediaMetadata?.artist?.toString(),
            durationMs = player.duration.takeIf { it != C.TIME_UNSET },
            positionMs = player.currentPosition,
            upNext = upNext,
        )
    }

    /** MediaController is main-thread confined; every touch hops to Main. */
    private suspend fun <T> withController(block: (MediaController) -> T): T =
        withContext(Dispatchers.Main) { block(obtainController()) }

    private suspend fun obtainController(): MediaController {
        controller?.let { return it }
        return controllerMutex.withLock {
            controller ?: run {
                val token = SessionToken(
                    appContext,
                    ComponentName(appContext, PlaybackService::class.java),
                )
                val built = MediaController.Builder(appContext, token).buildAsync().await()
                controller = built
                built
            }
        }
    }

    private suspend fun releaseController() = withContext(Dispatchers.Main) {
        controller?.release()
        controller = null
    }

    companion object {
        const val DEFAULT_SESSION_NAME = "PocketDJ Jukebox"
        private const val TICK_MS = 4_000L
        private const val HEARTBEAT_MS = 15_000L
        private const val PLAYED_CAP = 30
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

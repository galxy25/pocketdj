package com.levi.pocketdj.playback

import android.content.Context
import android.os.Build
import com.apple.android.music.playback.controller.MediaPlayerController
import com.apple.android.music.playback.controller.MediaPlayerControllerFactory
import com.apple.android.music.playback.model.MediaItemType
import com.apple.android.music.playback.model.MediaPlayerException
import com.apple.android.music.playback.model.PlaybackState
import com.apple.android.music.playback.model.PlayerQueueItem
import com.apple.android.music.playback.queue.CatalogPlaybackQueueItemProvider
import com.apple.android.sdk.authentication.TokenProvider
import com.levi.pocketdj.data.applemusic.MusicKitDeveloperTokenClient
import com.levi.pocketdj.data.settings.AppSettingsStore
import kotlinx.coroutines.CancellationException
import kotlinx.coroutines.CompletableDeferred
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.withContext
import kotlinx.coroutines.withTimeoutOrNull

/**
 * Full-track Apple Music playback via the SDK's native `MediaPlayerController` —
 * a SEPARATE audio engine from ExoPlayer (specs/applemusic.md §6.1). **DEVICE-
 * ONLY**: the native `.so` ship arm64/armv7 only, and playback needs a real
 * sign-in + active subscription. On the x86_64 emulator [canPlayFullTrack]
 * returns false and the caller falls through to a preview.
 *
 * The single-owner invariant (one MediaSession / notification, no second card)
 * is enforced by [PlaybackController]: it stops ExoPlayer before this plays and
 * stops this before ExoPlayer plays. This backend never spins up a Media3
 * session of its own — an AM MediaSession bridge is a later slice (§6.1.5).
 *
 * EVERY SDK touch is guarded (catch `Throwable`, incl. `UnsatisfiedLinkError` /
 * `NoClassDefFoundError`) so an unavailable SDK / AM app degrades to preview and
 * NEVER crashes (specs/applemusic.md §6.6, §10 risk 2).
 */
class AppleMusicBackend(
    context: Context,
    private val settings: AppSettingsStore,
    private val devTokenClient: MusicKitDeveloperTokenClient,
    /** Push AM state into the shared now-playing StateFlow (backend-agnostic UI). */
    private val onNowPlaying: (PlaybackController.NowPlayingInfo?) -> Unit,
) {
    private val appContext = context.applicationContext

    private data class Current(
        val songId: String,
        val title: String?,
        val artist: String?,
        val albumId: String?,
        val context: PlayContext,
    )

    @Volatile private var controller: MediaPlayerController? = null
    @Volatile private var current: Current? = null
    @Volatile private var startedSongId: String? = null

    /**
     * Non-null only while a [play] call is awaiting its first terminal signal.
     * The listener completes it: `true` on the first PLAYING, `false` on an
     * error. Distinguishes a HANDOVER failure (caller falls back to preview,
     * ExoPlayer still owns the previous track) from a STEADY-STATE error (AM is
     * the owner → null the card).
     */
    @Volatile private var playConfirm: CompletableDeferred<Boolean>? = null

    // Captured at play() time so the SYNCHRONOUS SDK TokenProvider never blocks
    // (specs/applemusic.md §5 risk 4): both are pre-fetched values.
    @Volatile private var userTokenSnapshot: String = ""

    private val tokenProvider = object : TokenProvider {
        override fun getDeveloperToken(): String = devTokenClient.cachedTokenOrNull().orEmpty()
        override fun getUserToken(): String = userTokenSnapshot
    }

    /**
     * Is the full-track engine even runnable here? arm ABI + a signed-in user +
     * a pre-fetched developer token. False on the emulator / signed-out /
     * no-token — the caller then uses a preview.
     */
    suspend fun canPlayFullTrack(): Boolean {
        if (!isArm()) return false
        val s = settings.current()
        if (s.musicUserToken.isBlank()) return false
        // Ensure a dev token is warm (pre-fetch, non-blocking failure → false).
        if (devTokenClient.cachedTokenOrNull() == null) {
            runCatching { devTokenClient.developerToken() }
        }
        return devTokenClient.cachedTokenOrNull() != null
    }

    /**
     * Queue + play one AM song by its store id (`appleMusicId`, NOT our songId).
     * SUSPENDS until the SDK CONFIRMS real playback: returns true on the first
     * PLAYING state, false on a playback error or if playback never starts within
     * [CONFIRM_TIMEOUT_MS]. `prepare()` returns synchronously even for a track the
     * SDK can't actually play (region-locked / catalog miss / subscription
     * hiccup), so returning on prepare would strand the caller in silence — the
     * caller relies on a truthful false to fall back to a preview.
     */
    suspend fun play(
        appleMusicId: String,
        songId: String,
        title: String?,
        artist: String?,
        albumId: String?,
        context: PlayContext,
    ): Boolean {
        userTokenSnapshot = runCatching { settings.current().musicUserToken }.getOrDefault("")
        val confirm = CompletableDeferred<Boolean>()
        playConfirm = confirm
        val issued = withContext(Dispatchers.Main) {
            try {
                val c = ensureController()
                current = Current(songId, title, artist, albumId, context)
                startedSongId = null
                val provider = CatalogPlaybackQueueItemProvider.Builder()
                    .items(MediaItemType.SONG, appleMusicId)
                    .build()
                c.prepare(provider, /* playWhenReady = */ true)
                true
            } catch (t: Throwable) {
                if (t is CancellationException) throw t
                current = null
                false
            }
        }
        if (!issued) {
            playConfirm = null
            return false
        }
        // Await the async terminal signal (PLAYING vs onPlaybackError); a timeout
        // is a stuck-buffering backstop and counts as failure so the caller
        // degrades to a preview rather than hanging on a dead card.
        val ok = withTimeoutOrNull(CONFIRM_TIMEOUT_MS) { confirm.await() } ?: false
        playConfirm = null
        if (!ok) {
            // Leave no half-started AM playback behind before the caller degrades.
            runCatching { withContext(Dispatchers.Main) { controller?.stop() } }
            current = null
            startedSongId = null
        }
        return ok
    }

    suspend fun pause() = onController { it.pause() }
    suspend fun resume() = onController { it.play() }
    suspend fun next() = onController { it.skipToNextItem() }
    suspend fun previous() = onController { it.skipToPreviousItem() }
    suspend fun seekTo(positionMs: Long) = onController { it.seekToPosition(positionMs) }

    suspend fun stop() = onController {
        it.stop()
        current = null
        startedSongId = null
        onNowPlaying(null)
    }

    /** Cold position read for the scrubber (specs/applemusic.md §6.1 rule 3). */
    suspend fun currentPositionMs(): Long = withContext(Dispatchers.Main) {
        runCatching {
            controller?.currentPosition?.takeIf { it != MediaPlayerController.POSITION_UNKNOWN } ?: 0L
        }.getOrDefault(0L)
    }

    /** Release native resources — on sign-out and app teardown. */
    fun release() {
        val c = controller ?: return
        controller = null
        current = null
        startedSongId = null
        runCatching {
            c.removeListener(listener)
            c.release()
        }
    }

    // ---- internals ---------------------------------------------------------

    private fun ensureController(): MediaPlayerController {
        controller?.let { return it }
        val built = MediaPlayerControllerFactory.createLocalController(appContext, tokenProvider)
        built.addListener(listener)
        controller = built
        return built
    }

    private suspend fun <T> onController(block: (MediaPlayerController) -> T): T? =
        withContext(Dispatchers.Main) {
            val c = controller ?: return@withContext null
            runCatching { block(c) }.getOrNull()
        }

    private fun publishNowPlaying() {
        val info = current ?: return
        val c = controller
        val isPlaying = runCatching { c?.playbackState == PlaybackState.PLAYING }.getOrDefault(false)
        val duration = runCatching {
            c?.duration?.takeIf { it != MediaPlayerController.DURATION_UNKNOWN }
        }.getOrNull()
        onNowPlaying(
            PlaybackController.NowPlayingInfo(
                songId = info.songId,
                title = info.title,
                artist = info.artist,
                albumId = info.albumId,
                isPlaying = isPlaying,
                durationMs = duration,
                isLive = false,
                isPreview = false,
                context = info.context,
            ),
        )
    }

    /** One play → one History row, whichever engine (specs/applemusic.md §6.1
     *  rule 4): emit PlayStarted behind an id-changed gate, like the service. */
    private fun emitStartedIfNeeded() {
        val info = current ?: return
        if (info.songId == startedSongId) return
        startedSongId = info.songId
        PlayEventBus.emit(
            PlayStarted(
                songId = info.songId,
                title = info.title,
                artist = info.artist,
                context = info.context,
                atMs = System.currentTimeMillis(),
            ),
        )
    }

    private val listener = object : MediaPlayerController.Listener {
        override fun onPlayerStateRestored(c: MediaPlayerController) = publishNowPlaying()

        override fun onPlaybackStateChanged(c: MediaPlayerController, previous: Int, now: Int) {
            if (now == PlaybackState.PLAYING) {
                emitStartedIfNeeded()
                // Real playback started → confirm the pending play() handover.
                playConfirm?.complete(true)
            }
            publishNowPlaying()
        }

        override fun onPlaybackStateUpdated(c: MediaPlayerController) = publishNowPlaying()

        override fun onBufferingStateChanged(c: MediaPlayerController, buffering: Boolean) = publishNowPlaying()

        override fun onCurrentItemChanged(c: MediaPlayerController, previous: PlayerQueueItem?, next: PlayerQueueItem?) {
            emitStartedIfNeeded()
            publishNowPlaying()
        }

        override fun onItemEnded(c: MediaPlayerController, item: PlayerQueueItem, endPositionMs: Long) = Unit

        override fun onMetadataUpdated(c: MediaPlayerController, item: PlayerQueueItem) = publishNowPlaying()

        override fun onPlaybackQueueChanged(c: MediaPlayerController, items: MutableList<PlayerQueueItem>) = Unit

        override fun onPlaybackQueueItemsAdded(c: MediaPlayerController, queueInsertionType: Int, containerType: Int, itemType: Int) = Unit

        override fun onPlaybackError(c: MediaPlayerController, error: MediaPlayerException) {
            val pending = playConfirm
            if (pending != null) {
                // Failure DURING a play() handover: report it so PlaybackController
                // falls through to the preview rung and resumes the paused
                // ExoPlayer track. Do NOT null the now-playing card — ExoPlayer
                // still owns the previous track until the caller decides.
                current = null
                startedSongId = null
                pending.complete(false)
                return
            }
            // Steady-state error (AM is already the owning backend): surface a
            // stopped state so the UI doesn't hang on a dead card.
            current = null
            startedSongId = null
            onNowPlaying(null)
        }

        override fun onPlaybackRepeatModeChanged(c: MediaPlayerController, repeatMode: Int) = Unit

        override fun onPlaybackShuffleModeChanged(c: MediaPlayerController, shuffleMode: Int) = Unit
    }

    private companion object {
        /** Handover backstop: max wait for the SDK's first PLAYING / error signal
         *  before [play] gives up so the caller can degrade to a preview. */
        const val CONFIRM_TIMEOUT_MS = 10_000L

        fun isArm(): Boolean =
            Build.SUPPORTED_ABIS?.any { it == "arm64-v8a" || it == "armeabi-v7a" } == true
    }
}

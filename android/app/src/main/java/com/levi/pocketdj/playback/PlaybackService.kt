package com.levi.pocketdj.playback

import android.app.PendingIntent
import android.content.Intent
import androidx.media3.common.AudioAttributes
import androidx.media3.common.C
import androidx.media3.common.MediaItem
import androidx.media3.common.Player
import androidx.media3.exoplayer.ExoPlayer
import androidx.media3.session.MediaSession
import androidx.media3.session.MediaSessionService
import com.google.common.util.concurrent.Futures
import com.google.common.util.concurrent.ListenableFuture

/**
 * The one audio owner (locked decision 4): Media3 ExoPlayer hosted in a
 * MediaSessionService — the media-style notification (art + transport) and
 * lock-screen controls come from the session for free.
 *
 * Also the single History recording site: `onMediaItemTransition` behind an
 * id-changed gate emits [PlayStarted] into [PlayEventBus] (specs/history.md §4)
 * — never `onIsPlayingChanged`, which would double-count pause/resume.
 */
class PlaybackService : MediaSessionService() {

    private var mediaSession: MediaSession? = null

    /** Id-changed gate: a same-song restart/seek must not re-fire the play hook. */
    private var lastPlayEventSongId: String? = null

    override fun onCreate() {
        super.onCreate()
        val player = ExoPlayer.Builder(this)
            .setAudioAttributes(
                AudioAttributes.Builder()
                    .setUsage(C.USAGE_MEDIA)
                    .setContentType(C.AUDIO_CONTENT_TYPE_MUSIC)
                    .build(),
                /* handleAudioFocus = */ true,
            )
            .setHandleAudioBecomingNoisy(true)
            .build()

        player.addListener(object : Player.Listener {
            override fun onMediaItemTransition(mediaItem: MediaItem?, reason: Int) {
                val songId = mediaItem?.mediaId
                if (songId.isNullOrEmpty()) {
                    lastPlayEventSongId = null
                    return
                }
                // The id gate absorbs same-song repeat/seek/auto transitions, but
                // a NEW queue (setMediaItems → PLAYLIST_CHANGED) is a deliberate
                // user play even when the song was the most recent one — e.g.
                // re-tapping yesterday's last track. Emit it; the store's 30 s
                // same-song window absorbs genuine quick restarts.
                if (songId == lastPlayEventSongId &&
                    reason != Player.MEDIA_ITEM_TRANSITION_REASON_PLAYLIST_CHANGED
                ) {
                    return
                }
                lastPlayEventSongId = songId
                val extras = mediaItem.requestMetadata.extras
                PlayEventBus.emit(
                    PlayStarted(
                        songId = songId,
                        title = mediaItem.mediaMetadata.title?.toString(),
                        artist = mediaItem.mediaMetadata.artist?.toString(),
                        context = PlayContext(
                            source = extras?.getString(PlaybackContract.EXTRA_SOURCE)
                                ?: PlayContext.SOURCE_BROWSER,
                            contextId = extras?.getString(PlaybackContract.EXTRA_CONTEXT_ID),
                            contextName = extras?.getString(PlaybackContract.EXTRA_CONTEXT_NAME),
                        ),
                        atMs = System.currentTimeMillis(),
                    ),
                )
            }
        })

        val sessionActivity = packageManager.getLaunchIntentForPackage(packageName)?.let {
            PendingIntent.getActivity(
                this,
                0,
                it,
                PendingIntent.FLAG_IMMUTABLE or PendingIntent.FLAG_UPDATE_CURRENT,
            )
        }

        mediaSession = MediaSession.Builder(this, player)
            .setCallback(SessionCallback())
            .apply { sessionActivity?.let(::setSessionActivity) }
            .build()
    }

    override fun onGetSession(controllerInfo: MediaSession.ControllerInfo): MediaSession? =
        mediaSession

    override fun onTaskRemoved(rootIntent: Intent?) {
        val player = mediaSession?.player
        if (player == null || !player.playWhenReady || player.mediaItemCount == 0) {
            stopSelf()
        }
    }

    override fun onDestroy() {
        mediaSession?.run {
            player.release()
            release()
        }
        mediaSession = null
        super.onDestroy()
    }

    /**
     * Rebuilds playable items from [PlaybackContract] request-metadata extras:
     * the URI and the clip window (analog songs share one album mp3;
     * ClippingConfiguration gives seek-to-start and the end boundary in one
     * shot, so auto-advance fires at `startMs + durationMs`, not file end).
     */
    private class SessionCallback : MediaSession.Callback {
        override fun onAddMediaItems(
            mediaSession: MediaSession,
            controller: MediaSession.ControllerInfo,
            mediaItems: MutableList<MediaItem>,
        ): ListenableFuture<MutableList<MediaItem>> =
            Futures.immediateFuture(mediaItems.map(::resolve).toMutableList())

        private fun resolve(item: MediaItem): MediaItem {
            val extras = item.requestMetadata.extras
            val url = extras?.getString(PlaybackContract.EXTRA_URL)
                ?: item.requestMetadata.mediaUri?.toString()
                ?: item.localConfiguration?.uri?.toString()
                ?: return item
            val builder = item.buildUpon().setUri(url)
            val clipStart = extras?.getLong(PlaybackContract.EXTRA_CLIP_START_MS, -1L) ?: -1L
            val clipEnd = extras?.getLong(PlaybackContract.EXTRA_CLIP_END_MS, -1L) ?: -1L
            if (clipStart >= 0 || clipEnd >= 0) {
                val clipping = MediaItem.ClippingConfiguration.Builder()
                if (clipStart >= 0) clipping.setStartPositionMs(clipStart)
                if (clipEnd >= 0) clipping.setEndPositionMs(clipEnd)
                builder.setClippingConfiguration(clipping.build())
            }
            return builder.build()
        }
    }
}

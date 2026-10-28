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
import com.levi.pocketdj.playback.sequencer.RepeatMode
import com.levi.pocketdj.playback.session.FavoriteCommand
import com.levi.pocketdj.playback.session.SequencerControl
import com.levi.pocketdj.playback.session.SequencerForwardingPlayer
import com.levi.pocketdj.playback.session.SessionSwitchboard
import com.levi.pocketdj.playback.session.TransportLog
import com.levi.pocketdj.playback.session.TransportOwner
import androidx.media3.session.SessionCommand
import androidx.media3.session.SessionCommands
import androidx.media3.session.SessionResult

/**
 * The one audio owner (locked decision 4): Media3 ExoPlayer hosted in a
 * MediaSessionService — the media-style notification (art + transport) and
 * lock-screen controls come from the session for free.
 *
 * Also the single History recording site: `onMediaItemTransition` behind an
 * id-changed gate emits [PlayStarted] into [PlayEventBus] (specs/history.md §4)
 * — never `onIsPlayingChanged`, which would double-count pause/resume.
 */
/** Connection hint set by the in-app MediaController so its commands are not logged as remote `rc`. */
const val INTERNAL_HINT = "pdj.internal"

class PlaybackService : MediaSessionService() {

    private var mediaSession: MediaSession? = null
    private var forwardingPlayer: SequencerForwardingPlayer? = null
    private var exoOwner: ExoOwner? = null
    private var exoPlayer: ExoPlayer? = null

    /** Id-changed gate: a same-song restart/seek must not re-fire the play hook. */
    private var lastPlayEventSongId: String? = null

    override fun onCreate() {
        super.onCreate()
        // PB-3: `pdj-resolve://song/<id>` rows (rip-on-demand inside a run) load immediately and resolve their
        // real url on the loader thread; every other uri passes through the resolver untouched.
        val dataSources = com.levi.pocketdj.playback.session.ResolvingSongDataSource.wrap(
            androidx.media3.datasource.DefaultDataSource.Factory(this),
        )
        val player = ExoPlayer.Builder(this)
            .setMediaSourceFactory(androidx.media3.exoplayer.source.DefaultMediaSourceFactory(dataSources))
            .setAudioAttributes(
                AudioAttributes.Builder()
                    .setUsage(C.USAGE_MEDIA)
                    .setContentType(C.AUDIO_CONTENT_TYPE_MUSIC)
                    .build(),
                /* handleAudioFocus = */ true,
            )
            .setHandleAudioBecomingNoisy(true)
            .setWakeMode(C.WAKE_MODE_NETWORK) // holds CPU+wifi while buffering a long rip-on-demand wait
            .build()
        exoPlayer = player

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
                val extras = mediaItem.requestMetadata.extras
                // A raw stream (jukebox Tune-In) is not a song: never a History row.
                if (extras?.getBoolean(PlaybackContract.EXTRA_IS_STREAM, false) == true) {
                    lastPlayEventSongId = null
                    return
                }
                lastPlayEventSongId = songId
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
                            runTag = extras?.getString(PlaybackContract.EXTRA_RUN_TAG),
                        ),
                        atMs = System.currentTimeMillis(),
                        originCollectionId = extras?.getString(PlaybackContract.EXTRA_ORIGIN_COLLECTION_ID),
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

        val forwarding = SequencerForwardingPlayer(player, DeferredControl, board = SessionSwitchboard.shared)
        forwardingPlayer = forwarding
        val exo = ExoOwner(forwarding)
        exoOwner = exo
        val board = SessionSwitchboard.shared
        board.register(exo)
        player.addListener(object : Player.Listener {
            override fun onIsPlayingChanged(isPlaying: Boolean) {
                if (isPlaying) {
                    exo.hasSounded = true
                    board.setOwner(exo)
                }
            }

            override fun onMediaItemTransition(mediaItem: MediaItem?, reason: Int) = refreshCustomLayout()
        })
        RunTransportBus.instantMetadata = { md -> forwarding.showInstantMetadata(md) }
        RunTransportBus.stateChanged = { forwarding.syncGate() }
        RunTransportBus.heldRestored = { forwarding.onHeldRestored() }
        RunTransportBus.clearInstantMetadata = { md -> forwarding.clearInstantMetadata(md) }
        board.onChange = { o -> mediaSession?.let { s -> val p = (o ?: exo).sessionPlayer; if (s.player !== p) s.player = p }; refreshCustomLayout() }

        mediaSession = MediaSession.Builder(this, board.sessionPlayer(forwarding))
            .setCallback(SessionCallback())
            .apply { sessionActivity?.let(::setSessionActivity) }
            .build()
        // The service can start AFTER the sequencer already runs (cold start from a first play): the
        // stateChanged events fired before this hook existed, so seed the gate now (else the first
        // row shows no next/prev/repeat/shuffle and media-session `next` is dropped).
        forwarding.syncGate()
    }

    override fun onGetSession(controllerInfo: MediaSession.ControllerInfo): MediaSession? =
        mediaSession

    /**
     * A widget / Bluetooth media button starts this service with startForegroundService(). Media3 only
     * promotes to the foreground once it has a notification to show, which an IDLE player (nothing queued,
     * the widget's "play" refused) never produces -> the OS kills the app 10 s later ("did not then call
     * startForeground()"). Promote with a placeholder on Media3's own notification id (so a real playback
     * notification replaces it in place), then drop it again if nothing started playing.
     */
    override fun onStartCommand(intent: Intent?, flags: Int, startId: Int): Int {
        val result = super.onStartCommand(intent, flags, startId)
        if (intent?.action == Intent.ACTION_MEDIA_BUTTON) {
            runCatching {
                val nm = getSystemService(android.app.NotificationManager::class.java)
                if (nm.getNotificationChannel(BOOT_CHANNEL) == null) {
                    nm.createNotificationChannel(
                        android.app.NotificationChannel(BOOT_CHANNEL, "Playback starting", android.app.NotificationManager.IMPORTANCE_LOW),
                    )
                }
                val n = androidx.core.app.NotificationCompat.Builder(this, BOOT_CHANNEL)
                    .setSmallIcon(com.levi.pocketdj.R.drawable.ic_widget_play)
                    .setContentTitle("PocketDJ")
                    .setOngoing(true)
                    .build()
                startForeground(BOOT_NOTIFICATION_ID, n)
            }
            android.os.Handler(android.os.Looper.getMainLooper()).postDelayed({
                val player = mediaSession?.player
                if (player == null || (!player.isPlaying && !player.playWhenReady)) {
                    runCatching { stopForeground(STOP_FOREGROUND_REMOVE) }
                    stopSelf()
                }
            }, 3_000L)
        }
        return result
    }

    companion object {
        private const val BOOT_CHANNEL = "pdj_playback_boot"
        /** Media3's DefaultMediaNotificationProvider.DEFAULT_NOTIFICATION_ID. */
        private const val BOOT_NOTIFICATION_ID = 1001
    }

    override fun onTaskRemoved(rootIntent: Intent?) {
        val player = mediaSession?.player
        if (player == null || !player.playWhenReady || player.mediaItemCount == 0) {
            stopSelf()
        }
    }

    override fun onDestroy() {
        RunTransportBus.instantMetadata = null
        RunTransportBus.stateChanged = null
        RunTransportBus.heldRestored = null
        RunTransportBus.clearInstantMetadata = null
        SessionSwitchboard.shared.onChange = {}
        exoOwner?.let { SessionSwitchboard.shared.unregister(it) }
        forwardingPlayer = null
        // The session's player is the Apple Music adapter whenever it owns the session: releasing
        // `session.player` would leak ExoPlayer and kill the process-lived adapter. Release Exo directly
        // and hand the session back (the adapter stays valid for the next service instance).
        SessionSwitchboard.shared.current?.let { if (it !== exoOwner) SessionSwitchboard.shared.resign(it) }
        mediaSession?.release()
        exoPlayer?.release()
        exoPlayer = null
        exoOwner = null
        mediaSession = null
        super.onDestroy()
    }

    /** The sequencer as seen from the service; inert until the controller registers [RunTransportBus.control]. */
    private object DeferredControl : SequencerControl {
        private val c get() = RunTransportBus.control
        override val isRunning get() = c?.isRunning == true
        override val isHeldForResume get() = c?.isHeldForResume == true
        override val isStartPending get() = c?.isStartPending == true
        override val isPausedByCascade get() = c?.isPausedByCascade == true
        override val currentNeverSounded get() = c?.currentNeverSounded == true
        override val hasRun get() = c?.hasRun == true
        override var repeatMode: RepeatMode
            get() = c?.repeatMode ?: RepeatMode.OFF
            set(v) { c?.repeatMode = v }
        override var shuffleEnabled: Boolean
            get() = c?.shuffleEnabled == true
            set(v) { c?.shuffleEnabled = v }
        override fun skipNext() { c?.skipNext() }
        override fun skipPrevious() { c?.skipPrevious() }
        override fun resumeFromHold() { c?.resumeFromHold() }
        override fun startCurrent() = c?.startCurrent() == true
    }

    /** The standalone ExoPlayer as a [TransportOwner]. */
    private class ExoOwner(override val sessionPlayer: SequencerForwardingPlayer) : TransportOwner {
        override val engine = "exo"
        @Volatile override var hasSounded = false
        override fun pauseForHandoff() { sessionPlayer.silently { sessionPlayer.pause() } }
    }

    private fun refreshCustomLayout() {
        val session = mediaSession ?: return
        val songId = session.player.currentMediaItem?.mediaId
        val owner = SessionSwitchboard.shared.current
        val seam = if (owner == null || owner.engine == "exo") FavoriteCommand.seam else null
        session.setCustomLayout(FavoriteCommand.layout(seam, songId))
    }

    /**
     * Rebuilds playable items from [PlaybackContract] request-metadata extras:
     * the URI and the clip window (analog songs share one album mp3;
     * ClippingConfiguration gives seek-to-start and the end boundary in one
     * shot, so auto-advance fires at `startMs + durationMs`, not file end).
     */
    private inner class SessionCallback : MediaSession.Callback {
        override fun onConnect(
            session: MediaSession,
            controller: MediaSession.ControllerInfo,
        ): MediaSession.ConnectionResult {
            val cmds = MediaSession.ConnectionResult.DEFAULT_SESSION_COMMANDS.buildUpon()
                .add(FavoriteCommand.sessionCommand)
                .build()
            return MediaSession.ConnectionResult.AcceptedResultBuilder(session)
                .setAvailableSessionCommands(cmds)
                .build()
        }

        override fun onPlayerCommandRequest(
            session: MediaSession,
            controller: MediaSession.ControllerInfo,
            playerCommand: Int,
        ): Int {
            // The in-app MediaController is not a remote: its play/pause must not log as `rc`.
            // Media-button / legacy controllers report OUR package name too, so match the in-app
            // MediaController by its connection hint instead (else system `next` never logs an rc line).
            forwardingPlayer?.callerInternal = controller.connectionHints.getBoolean(INTERNAL_HINT, false)
            return super.onPlayerCommandRequest(session, controller, playerCommand)
        }

        override fun onMediaButtonEvent(
            session: MediaSession,
            controllerInfo: MediaSession.ControllerInfo,
            intent: Intent,
        ): Boolean {
            val ev = if (android.os.Build.VERSION.SDK_INT >= 33) {
                intent.getParcelableExtra(Intent.EXTRA_KEY_EVENT, android.view.KeyEvent::class.java)
            } else {
                @Suppress("DEPRECATION") intent.getParcelableExtra(Intent.EXTRA_KEY_EVENT)
            }
            if (ev != null && ev.action == android.view.KeyEvent.ACTION_DOWN && ev.repeatCount == 0 &&
                (ev.keyCode == android.view.KeyEvent.KEYCODE_MEDIA_PLAY_PAUSE ||
                    ev.keyCode == android.view.KeyEvent.KEYCODE_HEADSETHOOK ||
                    ev.keyCode == android.view.KeyEvent.KEYCODE_MEDIA_PLAY)
            ) {
                forwardingPlayer?.callerInternal = false
                if (forwardingPlayer?.onMediaButtonPlayToggle() == true) return true
            }
            return super.onMediaButtonEvent(session, controllerInfo, intent)
        }

        /**
         * Media-button / Bluetooth resumption after the process was killed (PB-4): restore the durable
         * queue HELD. The future fails (nothing for Media3 to load: the sequencer, not the session
         * timeline, owns the queue), but Media3 1.6.1 then calls handlePlayButtonAction -> player.play(),
         * which reaches the forwarding player's held-resume path. So an explicit media-button / Bluetooth
         * play after process death DOES resume at the saved offset (iOS latched remote play). Only the
         * restore itself never plays or writes the file.
         */
        override fun onPlaybackResumption(
            mediaSession: MediaSession,
            controller: MediaSession.ControllerInfo,
        ): ListenableFuture<MediaSession.MediaItemsWithStartPosition> {
            runCatching {
                com.levi.pocketdj.di.AppGraph.get(applicationContext).playbackGraph.resumptionProvider.onPlaybackResumption()
            }
            return Futures.immediateFailedFuture(IllegalStateException("held restore: sequencer owns the queue"))
        }

        override fun onPostConnect(session: MediaSession, controller: MediaSession.ControllerInfo) {
            refreshCustomLayout()
        }

        override fun onCustomCommand(
            session: MediaSession,
            controller: MediaSession.ControllerInfo,
            customCommand: SessionCommand,
            args: android.os.Bundle,
        ): ListenableFuture<SessionResult> {
            if (customCommand.customAction == FavoriteCommand.ACTION) {
                val songId = session.player.currentMediaItem?.mediaId
                val did = FavoriteCommand.press(FavoriteCommand.seam, songId)
                TransportLog.rc(
                    TransportLog.Cmd.FAVORITE,
                    SessionSwitchboard.shared.current?.engine ?: "exo",
                    if (did) TransportLog.Verdict.HANDLED else TransportLog.Verdict.NOT_RUNNING,
                )
                refreshCustomLayout()
                return Futures.immediateFuture(SessionResult(SessionResult.RESULT_SUCCESS))
            }
            return Futures.immediateFuture(SessionResult(SessionResult.RESULT_ERROR_NOT_SUPPORTED))
        }

        /**
         * Voice search through a MediaController (Assistant / Android Auto): the item carries only
         * `requestMetadata.searchQuery` (+ structured extras). The request is handed to
         * [com.levi.pocketdj.assistant.SearchPlayBridge] (the single search seam; SURF-8's
         * MediaLibraryService conversion MUST keep or absorb this hook, not add a second one).
         * The shell's sequencer owns the start, so the controller's set is REFUSED: echoing the
         * current queue would re-prepare the playing item, double-log History and resume the old
         * track before the query resolves. Device-only path.
         */
        override fun onSetMediaItems(
            mediaSession: MediaSession,
            controller: MediaSession.ControllerInfo,
            mediaItems: MutableList<MediaItem>,
            startIndex: Int,
            startPositionMs: Long,
        ): ListenableFuture<MediaSession.MediaItemsWithStartPosition> {
            val item = mediaItems.singleOrNull()
                ?.takeIf { it.mediaId.isEmpty() || it.localConfiguration == null }
            val query = item?.requestMetadata?.searchQuery
            val handler = com.levi.pocketdj.assistant.SearchPlayBridge.handler
            if (item != null && !query.isNullOrBlank() && handler != null) {
                val extras = item.requestMetadata.extras
                val base = com.levi.pocketdj.assistant.MediaSearchRequest.from { extras?.getString(it) }
                handler(base.copy(query = query))
                return Futures.immediateFailedFuture(
                    UnsupportedOperationException("search handled by the shell; player untouched"),
                )
            }
            return super.onSetMediaItems(mediaSession, controller, mediaItems, startIndex, startPositionMs)
        }

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

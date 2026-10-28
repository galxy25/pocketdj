package com.levi.pocketdj.playback.session

import android.os.Looper
import androidx.media3.common.C
import androidx.media3.common.MediaItem
import androidx.media3.common.MediaMetadata
import androidx.media3.common.Player
import androidx.media3.common.SimpleBasePlayer
import androidx.media3.common.util.UnstableApi
import com.google.common.util.concurrent.Futures
import com.google.common.util.concurrent.ListenableFuture
import com.levi.pocketdj.playback.am.AmSnapshot
import com.levi.pocketdj.playback.am.AmStatus
import com.levi.pocketdj.playback.am.AmTrack
import com.levi.pocketdj.playback.am.AppleMusicController

/** What the MediaSession should see while an Apple Music row plays. Plain data so the mapping is JVM-testable. */
data class AmPlayerModel(
    val hasTrack: Boolean,
    val track: AmTrack?,
    val playbackState: Int,
    val playWhenReady: Boolean,
    val positionMs: Long,
    val durationMs: Long?,
    val canSkip: Boolean,
    val commands: Player.Commands,
)

/** Pure SDK-state -> Media3-state mapping (the unit-tested heart of the adapter). */
object AppleMusicAdapterStateMap {
    /** Playlist uids: the neighbours exist only so Media3's next/previous are "available" (BasePlayer gates on them). */
    const val UID_PREV = "am:prev"
    const val UID_NEXT = "am:next"

    fun playbackState(snap: AmSnapshot, hasTrack: Boolean): Int = when {
        !hasTrack -> Player.STATE_IDLE
        snap.status == AmStatus.BUFFERING -> Player.STATE_BUFFERING
        else -> Player.STATE_READY // PLAYING / PAUSED / a STOPPED hold (interruption) all keep the card
    }

    /** BUFFERING counts as "wants to play" (the SDK is spinning up); PAUSED/STOPPED do not. */
    fun playWhenReady(snap: AmSnapshot): Boolean = snap.status == AmStatus.PLAYING || snap.status == AmStatus.BUFFERING

    fun availableCommands(hasTrack: Boolean, canSkip: Boolean, seekable: Boolean): Player.Commands {
        val b = Player.Commands.Builder()
        if (!hasTrack) return b.build()
        b.addAll(
            Player.COMMAND_PLAY_PAUSE,
            Player.COMMAND_STOP,
            Player.COMMAND_GET_METADATA,
            Player.COMMAND_GET_CURRENT_MEDIA_ITEM,
            Player.COMMAND_GET_TIMELINE,
        )
        if (seekable) b.add(Player.COMMAND_SEEK_IN_CURRENT_MEDIA_ITEM)
        if (canSkip) {
            b.addAll(
                Player.COMMAND_SEEK_TO_NEXT,
                Player.COMMAND_SEEK_TO_NEXT_MEDIA_ITEM,
                Player.COMMAND_SEEK_TO_PREVIOUS,
                Player.COMMAND_SEEK_TO_PREVIOUS_MEDIA_ITEM,
            )
        }
        return b.build()
    }

    fun model(track: AmTrack?, snap: AmSnapshot, canSkip: Boolean): AmPlayerModel {
        val has = track != null
        val dur = snap.durationMs?.takeIf { it > 0 }
        return AmPlayerModel(
            hasTrack = has,
            track = track,
            playbackState = playbackState(snap, has),
            playWhenReady = has && playWhenReady(snap),
            positionMs = snap.positionMs.coerceAtLeast(0L),
            durationMs = dur,
            canSkip = has && canSkip,
            commands = availableCommands(has, canSkip, seekable = dur != null),
        )
    }

    /** Index of the current row inside the [playlistUids] this model publishes. */
    fun currentIndex(m: AmPlayerModel): Int = if (m.canSkip) 1 else 0

    /** Routing of a Media3 seek. */
    sealed interface SeekRoute {
        data object Next : SeekRoute
        data object Previous : SeekRoute
        data class Within(val positionMs: Long) : SeekRoute
    }

    fun routeSeek(mediaItemIndex: Int, positionMs: Long, seekCommand: Int, currentIndex: Int): SeekRoute = when {
        seekCommand == Player.COMMAND_SEEK_TO_NEXT || seekCommand == Player.COMMAND_SEEK_TO_NEXT_MEDIA_ITEM -> SeekRoute.Next
        seekCommand == Player.COMMAND_SEEK_TO_PREVIOUS || seekCommand == Player.COMMAND_SEEK_TO_PREVIOUS_MEDIA_ITEM -> SeekRoute.Previous
        mediaItemIndex > currentIndex -> SeekRoute.Next
        mediaItemIndex < currentIndex -> SeekRoute.Previous
        else -> SeekRoute.Within(if (positionMs == C.TIME_UNSET) 0L else positionMs)
    }

    fun toMediaItem(t: AmTrack): MediaItem = MediaItem.Builder()
        .setMediaId(t.songId)
        .setMediaMetadata(
            MediaMetadata.Builder()
                .setTitle(t.title)
                .setArtist(t.artist)
                .setAlbumTitle(t.albumTitle)
                .apply { t.artworkUri?.let { setArtworkUri(android.net.Uri.parse(it)) } }
                .build(),
        )
        .build()
}

/**
 * While an Apple Music row plays, THIS is the MediaSession's player (decision D2): the notification /
 * lock screen / Android Auto show the AM row's title, artist, art, position, and next/previous reach the
 * sequencer, play/pause reach the SDK. The SDK has its own audio engine; this adapter is only the
 * remote-control face. Constructed only when the Apple Music engine is runnable (device, arm ABI), so the
 * emulator never builds one.
 */
@UnstableApi
class AppleMusicPlayerAdapter(
    looper: Looper,
    private val engineControl: AppleMusicController,
    private val onSkipNext: () -> Unit,
    private val onSkipPrevious: () -> Unit,
    /** Is a sequencer run active (so next/previous mean something)? */
    private val canSkip: () -> Boolean,
    private val board: SessionSwitchboard = SessionSwitchboard.shared,
) : SimpleBasePlayer(looper), TransportOwner {

    override val engine: String = "am"
    override val sessionPlayer: Player get() = this
    @Volatile override var hasSounded: Boolean = false
        private set

    @Volatile private var quiet = false

    init {
        board.register(this)
        engineControl.setChangeListener { onEngineChanged() }
    }

    /** Called by the engine (Main) on any change: claim the session on first sound, re-publish state. */
    fun onEngineChanged() {
        val snap = engineControl.snapshot()
        if (snap.status == AmStatus.PLAYING && engineControl.track != null) {
            hasSounded = true
            if (!board.isActive(this)) board.setOwner(this)
        }
        invalidateState()
    }

    /** The row ended / was stopped: hand the session back. */
    fun release(reason: String = "stopped") {
        hasSounded = false
        board.resign(this)
        invalidateState()
    }

    override fun pauseForHandoff() {
        // Another owner started: silence AM without marking it an intentional listener pause.
        quiet = true
        try { engineControl.pause() } finally { quiet = false }
    }

    override fun getState(): State {
        val m = AppleMusicAdapterStateMap.model(engineControl.track, engineControl.snapshot(), canSkip())
        val b = State.Builder()
            .setAvailableCommands(m.commands)
            .setPlaybackState(m.playbackState)
            .setPlayWhenReady(m.playWhenReady, Player.PLAY_WHEN_READY_CHANGE_REASON_REMOTE)
        val t = m.track ?: return b.build()
        val cur = MediaItemData.Builder(t.songId)
            .setMediaItem(AppleMusicAdapterStateMap.toMediaItem(t))
            .apply {
                m.durationMs?.let { setDurationUs(it * 1000L) }
                setIsSeekable(m.durationMs != null)
            }
            .build()
        val list = if (m.canSkip) {
            listOf(MediaItemData.Builder(AppleMusicAdapterStateMap.UID_PREV).build(), cur, MediaItemData.Builder(AppleMusicAdapterStateMap.UID_NEXT).build())
        } else {
            listOf(cur)
        }
        b.setPlaylist(list).setCurrentMediaItemIndex(AppleMusicAdapterStateMap.currentIndex(m))
        b.setContentPositionMs(
            if (m.playWhenReady && m.playbackState == Player.STATE_READY) {
                PositionSupplier.getExtrapolating(m.positionMs, 1f)
            } else {
                PositionSupplier.getConstant(m.positionMs)
            },
        )
        return b.build()
    }

    override fun handleSetPlayWhenReady(playWhenReady: Boolean): ListenableFuture<*> {
        if (playWhenReady) {
            engineControl.play()
        } else {
            engineControl.pause()
        }
        return Futures.immediateVoidFuture()
    }

    override fun handleStop(): ListenableFuture<*> {
        engineControl.stop()
        return Futures.immediateVoidFuture()
    }

    override fun handleSeek(mediaItemIndex: Int, positionMs: Long, seekCommand: Int): ListenableFuture<*> {
        val m = AppleMusicAdapterStateMap.model(engineControl.track, engineControl.snapshot(), canSkip())
        when (val r = AppleMusicAdapterStateMap.routeSeek(mediaItemIndex, positionMs, seekCommand, AppleMusicAdapterStateMap.currentIndex(m))) {
            AppleMusicAdapterStateMap.SeekRoute.Next -> onSkipNext()
            AppleMusicAdapterStateMap.SeekRoute.Previous -> onSkipPrevious()
            is AppleMusicAdapterStateMap.SeekRoute.Within -> engineControl.seekTo(r.positionMs)
        }
        return Futures.immediateVoidFuture()
    }

    override fun handleRelease(): ListenableFuture<*> {
        engineControl.setChangeListener(null)
        board.unregister(this)
        return Futures.immediateVoidFuture()
    }
}

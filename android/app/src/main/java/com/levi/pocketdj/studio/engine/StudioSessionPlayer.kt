package com.levi.pocketdj.studio.engine

import android.os.Looper
import androidx.media3.common.MediaItem
import androidx.media3.common.MediaMetadata
import androidx.media3.common.Player
import androidx.media3.common.SimpleBasePlayer
import androidx.media3.common.util.UnstableApi
import com.google.common.util.concurrent.Futures
import com.google.common.util.concurrent.ListenableFuture
import com.levi.pocketdj.playback.session.SessionSwitchboard
import com.levi.pocketdj.playback.session.TransportOwner

/** What the system card shows while a Studio voice (today: a Loop audition) sounds. */
data class StudioCard(val id: String, val title: String, val subtitle: String, val parked: Boolean = false)

/** Review fix: pause Now Playing for a Studio start unless the Studio already owns the session (that pause would stop the loop). */
fun shouldPauseNowPlayingForStudio(ownerEngine: String?): Boolean = ownerEngine != "studio"

/** What the session adapter needs from the Studio, so the mapping is JVM-testable with a fake. */
interface StudioTransportPort {
    /** The sounding voice's card, or null when nothing studio is sounding. */
    fun card(): StudioCard?
    /** Remote play (notification / lock screen) while a card exists but is stopped: restart the last voice. */
    fun remotePlay()
    /** Remote pause/stop: a loop has no pause, so both end it (the card goes away). */
    fun remoteStop()
    /** Another owner started: silence the Studio voice. Not a remote command. */
    fun handoff()
}

/** The Media3 view of a [StudioCard]; plain data so the mapping is JVM-testable. */
object StudioPlayerStateMap {
    fun commands(hasCard: Boolean): Player.Commands {
        val b = Player.Commands.Builder()
        if (!hasCard) return b.build()
        // Prepare + set-media-item are exposed (like the Mix) so a stray controller call is consumed, never dropped as an error.
        return b.addAll(
            Player.COMMAND_PLAY_PAUSE, Player.COMMAND_STOP, Player.COMMAND_GET_METADATA,
            Player.COMMAND_GET_CURRENT_MEDIA_ITEM, Player.COMMAND_GET_TIMELINE,
            Player.COMMAND_SET_MEDIA_ITEM, Player.COMMAND_PREPARE,
        ).build()
    }

    fun playbackState(hasCard: Boolean) = if (hasCard) Player.STATE_READY else Player.STATE_IDLE

    fun toMediaItem(c: StudioCard): MediaItem = MediaItem.Builder()
        .setMediaId("studio:${c.id}")
        .setMediaMetadata(MediaMetadata.Builder().setTitle(c.title).setArtist(c.subtitle).build())
        .build()

    /** Play/pause from the card: true -> restart, false -> end. */
    fun route(port: StudioTransportPort, playWhenReady: Boolean) { if (playWhenReady) port.remotePlay() else port.remoteStop() }
}

/**
 * While a Studio loop auditions, THIS is the MediaSession's player (engine "studio"): the loop keeps playing with
 * the app backgrounded, behind a media notification whose Stop ends it. Same shape as the Mix's session player:
 * a [TransportOwner] claimed on start ([onAudioStarted]) and resigned on stop ([onAudioStopped]); starting any
 * other owner pauses it via [pauseForHandoff].
 */
@UnstableApi
class StudioSessionPlayer(
    looper: Looper,
    private val port: StudioTransportPort,
    private val board: SessionSwitchboard = SessionSwitchboard.shared,
) : SimpleBasePlayer(looper), TransportOwner {

    override val engine: String = "studio"
    override val sessionPlayer: Player get() = this
    override val hasSounded: Boolean get() = port.card() != null

    init { board.register(this) }

    /** A Studio voice started sounding: claim the session (pausing every other owner). */
    fun onAudioStarted() {
        board.setOwner(this)
        invalidateState()
    }

    /** The Studio voice ended (stop / park / natural): hand the session back. */
    fun onAudioStopped() {
        board.resign(this)
        invalidateState()
    }

    /** Re-publish the card state (park / unpark) without touching ownership. */
    fun refresh() = invalidateState()

    override fun pauseForHandoff() = port.handoff()

    override fun getState(): State {
        val c = port.card()
        val b = State.Builder()
            .setAvailableCommands(StudioPlayerStateMap.commands(c != null))
            .setPlaybackState(StudioPlayerStateMap.playbackState(c != null))
            .setPlayWhenReady(c != null, Player.PLAY_WHEN_READY_CHANGE_REASON_REMOTE)
        if (c == null) return b.build()
        // A parked loop (transient focus loss) KEEPS its card and the foreground service, exactly as ExoPlayer represents it:
        // still READY with playWhenReady, but suppressed.
        if (c.parked) b.setPlaybackSuppressionReason(Player.PLAYBACK_SUPPRESSION_REASON_TRANSIENT_AUDIO_FOCUS_LOSS)
        val item = MediaItemData.Builder("studio:${c.id}")
            .setMediaItem(StudioPlayerStateMap.toMediaItem(c))
            .setIsSeekable(false)
            .build()
        return b.setPlaylist(listOf(item)).setCurrentMediaItemIndex(0).build()
    }

    override fun handleSetMediaItems(mediaItems: List<MediaItem>, startIndex: Int, startPositionMs: Long): ListenableFuture<*> =
        Futures.immediateVoidFuture()

    override fun handlePrepare(): ListenableFuture<*> = Futures.immediateVoidFuture()

    override fun handleSetPlayWhenReady(playWhenReady: Boolean): ListenableFuture<*> {
        StudioPlayerStateMap.route(port, playWhenReady)
        return Futures.immediateVoidFuture()
    }

    override fun handleStop(): ListenableFuture<*> {
        port.remoteStop()
        return Futures.immediateVoidFuture()
    }

    override fun handleRelease(): ListenableFuture<*> {
        board.unregister(this)
        return Futures.immediateVoidFuture()
    }
}

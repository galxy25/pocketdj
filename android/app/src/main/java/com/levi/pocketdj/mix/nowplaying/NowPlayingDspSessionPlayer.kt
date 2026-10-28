package com.levi.pocketdj.mix.nowplaying

import android.os.Looper
import androidx.media3.common.Player
import androidx.media3.common.SimpleBasePlayer
import androidx.media3.common.util.UnstableApi
import com.google.common.util.concurrent.Futures
import com.google.common.util.concurrent.ListenableFuture
import com.levi.pocketdj.mix.service.MixCard
import com.levi.pocketdj.mix.service.MixPlayerStateMap
import com.levi.pocketdj.playback.session.SessionSwitchboard
import com.levi.pocketdj.playback.session.TransportOwner

/** What the session adapter needs from the DSP engine + sequencer (a fake under test). */
interface NowPlayingDspPort {
    /** The engaged track's card, or null when not engaged. */
    fun card(): MixCard?
    val isPlaying: Boolean
    val hasSounded: Boolean
    fun play()
    fun pause()
    fun skipNext()
    fun skipPrevious()
    /** Another owner started (or the session yielded): leave the graph. */
    fun release()
}

/**
 * The Now Playing DSP engine as the ONE MediaSession's player while it owns the audio (decision D2: never a
 * second card). Last-STARTED owns: [onAudioStarted] claims the session and the switchboard pauses ExoPlayer;
 * a later ExoPlayer start (next row) makes the switchboard call [pauseForHandoff], which releases the graph.
 * The card, heart-less, mirrors the Mix card shape; next/previous route to the sequencer.
 */
@UnstableApi
class NowPlayingDspSessionPlayer(
    looper: Looper,
    private val port: NowPlayingDspPort,
    private val board: SessionSwitchboard = SessionSwitchboard.shared,
) : SimpleBasePlayer(looper), TransportOwner {

    override val engine: String = ENGINE
    override val sessionPlayer: Player get() = this
    override val hasSounded: Boolean get() = port.hasSounded

    init { board.register(this) }

    fun onAudioStarted() { board.setOwner(this); invalidateState() }
    fun refresh() = invalidateState()

    /** The engine left the graph on its own (end of window, disengage): hand the session back. */
    fun released() { board.resign(this); invalidateState() }

    override fun pauseForHandoff() { port.release(); invalidateState() }

    private fun model() = MixPlayerStateMap.model(port.card(), port.isPlaying, canSkip = true)

    override fun getState(): State {
        val m = model()
        val b = State.Builder()
            .setAvailableCommands(m.commands)
            .setPlaybackState(m.playbackState)
            .setPlayWhenReady(m.playWhenReady, Player.PLAY_WHEN_READY_CHANGE_REASON_REMOTE)
            .setPlaybackParameters(androidx.media3.common.PlaybackParameters(m.rate))
        val c = port.card() ?: return b.build()
        val cur = MediaItemData.Builder(c.songId)
            .setMediaItem(MixPlayerStateMap.toMediaItem(c))
            .apply { m.durationMs?.let { setDurationUs(it * 1000L) } }
            .setIsSeekable(false)
            .build()
        b.setPlaylist(
            listOf(MediaItemData.Builder(MixPlayerStateMap.UID_PREV).build(), cur, MediaItemData.Builder(MixPlayerStateMap.UID_NEXT).build()),
        ).setCurrentMediaItemIndex(1)
        b.setContentPositionMs(
            if (m.playWhenReady) PositionSupplier.getExtrapolating(m.positionMs, m.rate) else PositionSupplier.getConstant(m.positionMs),
        )
        return b.build()
    }

    override fun handleSetPlayWhenReady(playWhenReady: Boolean): ListenableFuture<*> {
        if (playWhenReady) port.play() else port.pause()
        invalidateState()
        return Futures.immediateVoidFuture()
    }

    override fun handleStop(): ListenableFuture<*> { port.pause(); return Futures.immediateVoidFuture() }

    override fun handleSeek(mediaItemIndex: Int, positionMs: Long, seekCommand: Int): ListenableFuture<*> {
        when (MixPlayerStateMap.route(mediaItemIndex, seekCommand, currentIndex = 1)) {
            MixPlayerStateMap.Route.Next -> port.skipNext()
            MixPlayerStateMap.Route.Previous -> port.skipPrevious()
            MixPlayerStateMap.Route.None -> Unit
        }
        return Futures.immediateVoidFuture()
    }

    override fun handleRelease(): ListenableFuture<*> { board.unregister(this); return Futures.immediateVoidFuture() }

    companion object { const val ENGINE = "npdsp" }
}

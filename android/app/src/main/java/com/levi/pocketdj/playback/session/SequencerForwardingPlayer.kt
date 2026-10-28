package com.levi.pocketdj.playback.session

import androidx.media3.common.MediaItem
import androidx.media3.common.MediaMetadata
import androidx.media3.common.Player
import com.levi.pocketdj.playback.sequencer.RepeatMode
import com.levi.pocketdj.playback.sequencer.SetlistSequencer

/** What the forwarding player needs from the sequencer (fakeable). */
interface SequencerControl {
    val isRunning: Boolean
    val isHeldForResume: Boolean
    val isStartPending: Boolean
    val currentNeverSounded: Boolean
    var repeatMode: RepeatMode
    var shuffleEnabled: Boolean
    fun skipNext()
    fun skipPrevious()
    fun resumeFromHold()
    fun startCurrent(): Boolean
}

class SetlistSequencerControl(private val seq: SetlistSequencer) : SequencerControl {
    override val isRunning get() = seq.isRunning
    override val isHeldForResume get() = seq.isHeldForResume
    override val isStartPending get() = seq.isStartPending
    override val currentNeverSounded get() = seq.currentNeverSounded
    override var repeatMode: RepeatMode
        get() = seq.state.value.repeatMode
        set(v) = seq.setRepeatMode(v)
    override var shuffleEnabled: Boolean
        get() = seq.state.value.shuffleEnabled
        set(v) = seq.setShuffle(v)
    override fun skipNext() = seq.skipNext()
    override fun skipPrevious() = seq.skipPrevious()
    override fun resumeFromHold() = seq.resumeFromHold()
    override fun startCurrent() = seq.startCurrent()
}

/**
 * MediaSession player that drives the sequencer like MPRemoteCommandCenter drives SetlistPlayer:
 * system next/prev/repeat/shuffle/idle-play go to the sequencer, never to ExoPlayer's (single-item)
 * playlist.
 */
class SequencerForwardingPlayer(
    player: Player,
    private val control: SequencerControl,
    private val latch: RemotePlayLatch = RemotePlayLatch(),
    private val engine: String = "exo",
    private val log: (cmd: String, engine: String, verdict: String) -> Unit = TransportLog::rc,
) : SetGatedPlayer(player) {

    @Volatile private var instant: MediaMetadata? = null

    init {
        player.addListener(object : Player.Listener {
            override fun onMediaItemTransition(mediaItem: MediaItem?, reason: Int) { instant = null }
        })
    }

    /** Show [md] as the now-playing metadata until the real item lands (null clears). */
    fun showInstantMetadata(md: MediaMetadata?) {
        instant = md
        val shown = mediaMetadata
        notifyListeners { it.onMediaMetadataChanged(shown) }
    }

    override fun getMediaMetadata(): MediaMetadata = instant ?: super.getMediaMetadata()

    /** Re-evaluate the command gate from the sequencer (call on sequencer state changes). */
    fun syncGate() { updateSetRunning(control.isRunning) }

    private fun route(cmd: String, block: () -> Unit) {
        if (control.isRunning) {
            block()
            log(cmd, engine, TransportLog.Verdict.HANDLED)
        } else {
            log(cmd, engine, TransportLog.Verdict.NOT_RUNNING)
        }
    }

    override fun seekToNext() = route(TransportLog.Cmd.NEXT) { control.skipNext() }
    override fun seekToNextMediaItem() = seekToNext()
    override fun seekToPrevious() = route(TransportLog.Cmd.PREV) { control.skipPrevious() }
    override fun seekToPreviousMediaItem() = seekToPrevious()

    override fun hasNextMediaItem(): Boolean = control.isRunning || super.hasNextMediaItem()
    override fun hasPreviousMediaItem(): Boolean = control.isRunning || super.hasPreviousMediaItem()

    override fun setRepeatMode(repeatMode: Int) =
        route(TransportLog.Cmd.REPEAT) { control.repeatMode = fromExo(repeatMode) }

    override fun getRepeatMode(): Int = toExo(control.repeatMode)

    override fun setShuffleModeEnabled(shuffleModeEnabled: Boolean) =
        route(TransportLog.Cmd.SHUFFLE) { control.shuffleEnabled = shuffleModeEnabled }

    override fun getShuffleModeEnabled(): Boolean = control.shuffleEnabled

    /** The idle player has nothing loaded (ExoPlayer holds ONE row at a time, so idle == no row). */
    private fun isIdle(): Boolean = playbackState == Player.STATE_IDLE || mediaItemCount == 0

    override fun play() {
        if (isIdle()) {
            if (!control.isRunning) {
                if (mediaItemCount > 0) { prepare(); super.play(); return }
                latch.arm()
                log(TransportLog.Cmd.PLAY, engine, TransportLog.Verdict.idlePlay(IdlePlayVerdict.LATCHED))
                return
            }
            val verdict = IdlePlayLadder.decide(control.isHeldForResume, control.isStartPending, control.currentNeverSounded)
            when (verdict) {
                IdlePlayVerdict.RESUME_HELD -> control.resumeFromHold()
                IdlePlayVerdict.START_CURRENT -> control.startCurrent()
                IdlePlayVerdict.START_IN_FLIGHT -> Unit
                IdlePlayVerdict.LATCHED -> latch.arm()
            }
            log(TransportLog.Cmd.PLAY, engine, TransportLog.Verdict.idlePlay(verdict))
            return
        }
        if (playbackState == Player.STATE_BUFFERING && playWhenReady) {
            // A stuck buffer + play key: re-kick instead of letting the toggle land as a pause.
            prepare()
            super.play()
            log(TransportLog.Cmd.PLAY, engine, "rekick-buffering")
            return
        }
        super.play()
        log(TransportLog.Cmd.PLAY, engine, TransportLog.Verdict.HANDLED)
    }

    override fun pause() {
        super.pause()
        log(TransportLog.Cmd.PAUSE, engine, TransportLog.Verdict.HANDLED)
    }

    /** A restore finished: a remote ▶ latched within the window resumes the held deck. */
    fun onHeldRestored() {
        if (latch.consume() && control.isHeldForResume) {
            control.resumeFromHold()
            log(TransportLog.Cmd.PLAY, engine, "latch-consumed")
        }
    }

    companion object {
        fun toExo(m: RepeatMode): Int = when (m) {
            RepeatMode.OFF -> Player.REPEAT_MODE_OFF
            RepeatMode.ALL -> Player.REPEAT_MODE_ALL
            RepeatMode.ONE -> Player.REPEAT_MODE_ONE
        }

        fun fromExo(m: Int): RepeatMode = when (m) {
            Player.REPEAT_MODE_ALL -> RepeatMode.ALL
            Player.REPEAT_MODE_ONE -> RepeatMode.ONE
            else -> RepeatMode.OFF
        }
    }
}

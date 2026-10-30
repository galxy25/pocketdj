package com.levi.pocketdj.playback.session

import androidx.media3.common.MediaItem
import androidx.media3.common.MediaMetadata
import androidx.media3.common.Player
import com.levi.pocketdj.playback.durable.HeldQueue
import com.levi.pocketdj.playback.sequencer.RepeatMode
import com.levi.pocketdj.playback.sequencer.SetlistSequencer

/** What the forwarding player needs from the sequencer (fakeable). */
interface SequencerControl {
    val isRunning: Boolean
    val isHeldForResume: Boolean
    val isStartPending: Boolean
    /** The cascade breaker halted the run (iOS `pausedByCascade`): ▶ must retry the row. */
    val isPausedByCascade: Boolean
    val currentNeverSounded: Boolean
    /** A run exists in the sequencer (raw; [isRunning] additionally requires it to own the player). */
    val hasRun: Boolean
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
    override val isPausedByCascade get() = seq.isPausedByCascade
    override val currentNeverSounded get() = seq.currentNeverSounded
    override val hasRun get() = seq.isRunning
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
 * while a set runs, system next/prev/repeat/shuffle/idle-play go to the sequencer, never to
 * ExoPlayer's (single-item) playlist. When no set runs the base player answers (an album queue
 * keeps its own next/previous).
 */
class SequencerForwardingPlayer(
    player: Player,
    private val control: SequencerControl,
    private val latch: RemotePlayLatch = RemotePlayLatch(),
    private val engine: String = "exo",
    private val log: (cmd: String, engine: String, verdict: String) -> Unit = TransportLog::rc,
    private val board: SessionSwitchboard? = null,
    /** SessionRestorer.restore for the armed resumption set (idempotent; a live run stays untouched). */
    private val restoreForResumption: (HeldQueue) -> Unit = {},
) : SetGatedPlayer(player) {

    @Volatile private var armedResumption: HeldQueue? = null

    /** `onPlaybackResumption` answered with [held]: the next matching setMediaItems restores + resumes it. */
    fun armResumption(held: HeldQueue) { armedResumption = held }

    private fun consumeResumption(items: List<MediaItem>): Boolean {
        val held = armedResumption ?: return false
        if (!held.matches(items)) return false
        armedResumption = null
        // Restore the held deck (never clears a live run), then resume at the held offset. The session
        // timeline stays empty: the sequencer, not the Media3 playlist, owns the queue.
        restoreForResumption(held)
        latch.clear()
        pausedByListener = false
        if (control.isHeldForResume) control.resumeFromHold() else if (control.hasRun && !control.isRunning) control.startCurrent()
        emit(TransportLog.Cmd.PLAY, "resumption")
        return true
    }

    override fun setMediaItems(mediaItems: MutableList<MediaItem>, startIndex: Int, startPositionMs: Long) {
        if (!consumeResumption(mediaItems)) super.setMediaItems(mediaItems, startIndex, startPositionMs)
    }

    override fun setMediaItems(mediaItems: MutableList<MediaItem>, resetPosition: Boolean) {
        if (!consumeResumption(mediaItems)) super.setMediaItems(mediaItems, resetPosition)
    }

    override fun setMediaItems(mediaItems: MutableList<MediaItem>) {
        if (!consumeResumption(mediaItems)) super.setMediaItems(mediaItems)
    }

    @Volatile private var instant: MediaMetadata? = null
    @Volatile private var pausedByListener = false
    @Volatile private var quiet = false

    /** Set by the session callback: the current command comes from our own app, not a remote. */
    @Volatile var callerInternal = false

    private var pushedRepeat: Int = Player.REPEAT_MODE_OFF
    private var pushedShuffle: Boolean = false

    init {
        player.addListener(object : Player.Listener {
            override fun onMediaItemTransition(mediaItem: MediaItem?, reason: Int) { instant = null }
        })
        pushedRepeat = repeatMode
        pushedShuffle = shuffleModeEnabled
    }

    /** Show [md] as the now-playing metadata until the real item lands (null clears). */
    fun showInstantMetadata(md: MediaMetadata?) {
        instant = md
        val shown = mediaMetadata
        notifyListeners { it.onMediaMetadataChanged(shown) }
    }

    /** Clear the overlay only if [md] is still the one showing (a failed load must not wipe a newer row's). */
    fun clearInstantMetadata(md: MediaMetadata) { if (instant === md) showInstantMetadata(null) }

    override fun getMediaMetadata(): MediaMetadata = instant ?: super.getMediaMetadata()

    /** Re-evaluate the command gate and repeat/shuffle mirror from the sequencer (call on its state changes). */
    fun syncGate() {
        updateSetRunning(control.isRunning)
        syncModes()
    }

    /** Tell session listeners when the effective repeat/shuffle changed (platform session + AVRCP update only on events). */
    fun syncModes() {
        val r = repeatMode
        if (r != pushedRepeat) { pushedRepeat = r; notifyListeners { it.onRepeatModeChanged(r) } }
        val sh = shuffleModeEnabled
        if (sh != pushedShuffle) { pushedShuffle = sh; notifyListeners { it.onShuffleModeEnabledChanged(sh) } }
    }

    /** Run internal (non-remote) player calls without a `[transport] rc` line. */
    fun <T> silently(block: () -> T): T {
        quiet = true
        try { return block() } finally { quiet = false }
    }

    private fun emit(cmd: String, verdict: String) {
        if (!quiet && !callerInternal) log(cmd, engine, verdict)
    }

    /** Mic-capture start gate (AudioFocusPolicy.gateStartRaw by default; injectable for JVM tests). */
    var micGate: (String) -> Boolean = { com.levi.pocketdj.studio.engine.AudioFocusPolicy.gateStartRaw(it) }

    /** Arbiter gate: another engine owning the session, or a restored-never-sounded owner, refuses the command. */
    private fun permitted(cmd: String): Boolean {
        val b = board ?: return true
        if (quiet || b.current == null) return true
        val t = b.remoteTarget()
        if (t == null) { emit(cmd, TransportLog.Verdict.REFUSED_IDLE); return false }
        if (t.engine != engine) { emit(cmd, TransportLog.Verdict.NOT_OWNER); return false }
        return true
    }

    /** Running set -> sequencer; otherwise ExoPlayer answers (only a skippable multi-item queue). */
    private fun route(cmd: String, viaSequencer: () -> Unit, viaBase: () -> Unit) {
        if (!permitted(cmd)) return
        when {
            control.isRunning -> { viaSequencer(); emit(cmd, TransportLog.Verdict.HANDLED) }
            mediaItemCount > 1 -> { viaBase(); emit(cmd, TransportLog.Verdict.HANDLED) }
            else -> emit(cmd, TransportLog.Verdict.NOT_RUNNING)
        }
    }

    override fun seekToNext() = route(TransportLog.Cmd.NEXT, { control.skipNext() }, { super.seekToNext() })
    override fun seekToNextMediaItem() = route(TransportLog.Cmd.NEXT, { control.skipNext() }, { super.seekToNextMediaItem() })
    override fun seekToPrevious() = route(TransportLog.Cmd.PREV, { control.skipPrevious() }, { super.seekToPrevious() })
    override fun seekToPreviousMediaItem() = route(TransportLog.Cmd.PREV, { control.skipPrevious() }, { super.seekToPreviousMediaItem() })

    override fun hasNextMediaItem(): Boolean = control.isRunning || super.hasNextMediaItem()
    override fun hasPreviousMediaItem(): Boolean = control.isRunning || super.hasPreviousMediaItem()

    override fun setRepeatMode(repeatMode: Int) {
        if (control.isRunning) {
            control.repeatMode = fromExo(repeatMode)
            emit(TransportLog.Cmd.REPEAT, TransportLog.Verdict.HANDLED)
            syncModes()
        } else {
            super.setRepeatMode(repeatMode)
            pushedRepeat = this.repeatMode // the base player fires its own event
            emit(TransportLog.Cmd.REPEAT, TransportLog.Verdict.HANDLED)
        }
    }

    override fun getRepeatMode(): Int = if (control.isRunning) toExo(control.repeatMode) else super.getRepeatMode()

    override fun setShuffleModeEnabled(shuffleModeEnabled: Boolean) {
        if (control.isRunning) {
            control.shuffleEnabled = shuffleModeEnabled
            emit(TransportLog.Cmd.SHUFFLE, TransportLog.Verdict.HANDLED)
            syncModes()
        } else {
            super.setShuffleModeEnabled(shuffleModeEnabled)
            pushedShuffle = this.shuffleModeEnabled
            emit(TransportLog.Cmd.SHUFFLE, TransportLog.Verdict.HANDLED)
        }
    }

    override fun getShuffleModeEnabled(): Boolean = if (control.isRunning) control.shuffleEnabled else super.getShuffleModeEnabled()

    /** The idle player has nothing loaded (ExoPlayer holds ONE row at a time, so idle == no row). */
    private fun isIdle(): Boolean = playbackState == Player.STATE_IDLE || mediaItemCount == 0

    /** Stuck buffer, still wanted, not paused by the listener: a play/toggle key must kick, not pause. */
    fun shouldRekick(): Boolean =
        playbackState == Player.STATE_BUFFERING && playWhenReady && !pausedByListener

    /** A real re-kick: re-request the load from the current position (prepare/play are no-ops here). */
    fun rekick() {
        seekTo(currentPosition)
        emit(TransportLog.Cmd.PLAY, TransportLog.Verdict.REKICK_BUFFERING)
    }

    /** Media-button hook (headset toggle arrives as pause() while buffering): true = consumed by a re-kick. */
    fun onMediaButtonPlayToggle(): Boolean {
        if (!shouldRekick()) return false
        rekick()
        return true
    }

    override fun play() {
        // Notification / lock-screen / headset play must honour the mic-capture gate exactly like PlaybackController.play.
        if (!micGate("playback.remote")) { emit(TransportLog.Cmd.PLAY, TransportLog.Verdict.REFUSED_MIC); return }
        if (!permitted(TransportLog.Cmd.PLAY)) return
        // iOS onIdlePlay: a cascade halt keeps its item loaded (paused); ▶ retries the row, never resumes in place.
        if (control.isRunning && control.isPausedByCascade) {
            latch.clear()
            pausedByListener = false
            control.startCurrent()
            emit(TransportLog.Cmd.PLAY, TransportLog.Verdict.idlePlay(IdlePlayVerdict.START_CURRENT))
            return
        }
        if (isIdle()) {
            val runActive = control.isRunning || (control.hasRun && mediaItemCount == 0)
            if (!runActive) {
                if (mediaItemCount > 0) {
                    pausedByListener = false
                    prepare(); super.play()
                    emit(TransportLog.Cmd.PLAY, TransportLog.Verdict.REPLAY_IDLE)
                    return
                }
                latch.arm()
                emit(TransportLog.Cmd.PLAY, TransportLog.Verdict.REFUSED_IDLE)
                return
            }
            val verdict = IdlePlayLadder.decide(true, control.isHeldForResume, control.isStartPending)
            pausedByListener = false
            when (verdict) {
                IdlePlayVerdict.RESUME_HELD -> { latch.clear(); control.resumeFromHold() }
                IdlePlayVerdict.START_CURRENT -> { latch.clear(); control.startCurrent() }
                IdlePlayVerdict.START_IN_FLIGHT -> Unit
                IdlePlayVerdict.LATCHED -> latch.arm()
            }
            emit(TransportLog.Cmd.PLAY, TransportLog.Verdict.idlePlay(verdict))
            return
        }
        if (shouldRekick()) { rekick(); return }
        latch.clear()
        pausedByListener = false
        super.play()
        emit(TransportLog.Cmd.PLAY, TransportLog.Verdict.HANDLED)
    }

    override fun pause() {
        pausedByListener = true
        super.pause()
        emit(TransportLog.Cmd.PAUSE, TransportLog.Verdict.HANDLED)
    }

    /** A restore finished: a remote ▶ latched within the window resumes the held deck. */
    fun onHeldRestored() {
        if (latch.consume() && control.isHeldForResume) {
            control.resumeFromHold()
            emit(TransportLog.Cmd.PLAY, "latch-consumed")
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

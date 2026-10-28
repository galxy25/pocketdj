package com.levi.pocketdj.playback.health

import androidx.media3.common.Player

/**
 * Who paused? (iOS `pausedByListener` / `interruptionOpen` / `listenerIntentPlaying`.) The watchdogs and the
 * supervisor must never fight the listener, so the cause of a pause comes from Media3's own reasons, never
 * from timing heuristics:
 *  - `playWhenReady=false` with USER_REQUEST / REMOTE / AUDIO_BECOMING_NOISY -> [pausedByListener] (route
 *    loss is a listener pause, like AVAudioSession's oldDeviceUnavailable);
 *  - `playWhenReady=false` with AUDIO_FOCUS_LOSS, or `playbackSuppressionReason == TRANSIENT_AUDIO_FOCUS_LOSS`
 *    -> [interruptionOpen] (a call / Assistant). ExoPlayer resumes by itself on focus gain; that resume is a
 *    `playWhenReady=true` event which clears the interruption - this class never asks for a pause/play of
 *    its own, so the resume is never undone, and a focus loss while the listener had paused leaves
 *    [pausedByListener] alone (ExoPlayer does not resume what the listener paused).
 *  - `playWhenReady=true` -> the listener (or the resumed interruption) wants sound: [intentPlaying].
 */
class PauseDiscriminator {
    @Volatile var pausedByListener: Boolean = false
        private set

    @Volatile var interruptionOpen: Boolean = false
        private set

    /** The listener's last request was "play" (set by gestures / a resumed interruption / a fresh start). */
    @Volatile var intentPlaying: Boolean = false
        private set

    private var focusLossPause = false

    fun onPlayWhenReadyChanged(playWhenReady: Boolean, reason: Int) {
        if (playWhenReady) {
            pausedByListener = false
            focusLossPause = false
            interruptionOpen = suppressedByFocus
            intentPlaying = true
            return
        }
        when (reason) {
            Player.PLAY_WHEN_READY_CHANGE_REASON_USER_REQUEST,
            Player.PLAY_WHEN_READY_CHANGE_REASON_REMOTE,
            Player.PLAY_WHEN_READY_CHANGE_REASON_AUDIO_BECOMING_NOISY,
            -> {
                pausedByListener = true
                focusLossPause = false
                interruptionOpen = false
                intentPlaying = false
            }
            Player.PLAY_WHEN_READY_CHANGE_REASON_AUDIO_FOCUS_LOSS -> {
                focusLossPause = true
                interruptionOpen = true
            }
            else -> Unit // END_OF_MEDIA_ITEM / SUPPRESSED_TOO_LONG: the player's own doing, not the listener's
        }
    }

    private var suppressedByFocus = false

    fun onSuppressionChanged(suppressionReason: Int) {
        suppressedByFocus = suppressionReason == Player.PLAYBACK_SUPPRESSION_REASON_TRANSIENT_AUDIO_FOCUS_LOSS
        interruptionOpen = suppressedByFocus || focusLossPause
    }

    /** The app itself decided what the listener intends (a halted cascade is "not playing"). */
    fun noteListenerIntent(playing: Boolean) {
        intentPlaying = playing
        if (!playing) interruptionOpen = false
        if (playing) pausedByListener = false
    }
}

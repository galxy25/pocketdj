package com.levi.pocketdj.playback.session

import androidx.media3.common.ForwardingPlayer
import androidx.media3.common.Player
import java.util.concurrent.CopyOnWriteArrayList

/** Pure command masking so it is testable without a player. */
object SetGate {
    val GATED = intArrayOf(
        Player.COMMAND_SEEK_TO_NEXT,
        Player.COMMAND_SEEK_TO_NEXT_MEDIA_ITEM,
        Player.COMMAND_SEEK_TO_PREVIOUS,
        Player.COMMAND_SEEK_TO_PREVIOUS_MEDIA_ITEM,
        Player.COMMAND_SET_REPEAT_MODE,
        Player.COMMAND_SET_SHUFFLE_MODE,
    )

    /**
     * While a set runs, next/prev/repeat/shuffle are forced on (the sequencer serves them). When it
     * does not, ExoPlayer's own answer stands for a real multi-item queue (an album has a next);
     * only an empty/single-item timeline - which cannot skip - is masked.
     */
    fun apply(base: Player.Commands, setRunning: Boolean, itemCount: Int = 1): Player.Commands {
        val b = base.buildUpon()
        if (setRunning) b.addAll(*GATED) else if (itemCount <= 1) GATED.forEach { b.remove(it) }
        return b.build()
    }
}

/**
 * ForwardingPlayer that hides/shows next/prev/repeat/shuffle by [setRunning]. A flip pushes ONE
 * onAvailableCommandsChanged to the session's listeners; setting the same value is a no-op.
 */
open class SetGatedPlayer(player: Player) : ForwardingPlayer(player) {
    @Volatile var setRunning: Boolean = false
        private set

    private val listeners = CopyOnWriteArrayList<Player.Listener>()
    private val wrappers = java.util.concurrent.ConcurrentHashMap<Player.Listener, Player.Listener>()

    /** Rewrites the wrapped player's ungated onAvailableCommandsChanged into the gated set. */
    // NOT `Player.Listener by d`: Kotlin delegation skips Java default methods, and every
    // Player.Listener callback is one, so that form silently swallowed every event except the one
    // overridden (the controller then saw IDLE forever and no row ever advanced). Forward explicitly.
    @Suppress("DEPRECATION")
    private inner class GatedListener(private val d: Player.Listener) : Player.Listener {
        override fun onAvailableCommandsChanged(availableCommands: Player.Commands) {
            d.onAvailableCommandsChanged(SetGate.apply(availableCommands, setRunning, mediaItemCount))
        }
        override fun onEvents(player: Player, events: Player.Events) = d.onEvents(player, events)
        override fun onTimelineChanged(timeline: androidx.media3.common.Timeline, reason: Int) = d.onTimelineChanged(timeline, reason)
        override fun onMediaItemTransition(mediaItem: androidx.media3.common.MediaItem?, reason: Int) = d.onMediaItemTransition(mediaItem, reason)
        override fun onTracksChanged(tracks: androidx.media3.common.Tracks) = d.onTracksChanged(tracks)
        override fun onMediaMetadataChanged(mediaMetadata: androidx.media3.common.MediaMetadata) = d.onMediaMetadataChanged(mediaMetadata)
        override fun onPlaylistMetadataChanged(mediaMetadata: androidx.media3.common.MediaMetadata) = d.onPlaylistMetadataChanged(mediaMetadata)
        override fun onIsLoadingChanged(isLoading: Boolean) = d.onIsLoadingChanged(isLoading)
        override fun onLoadingChanged(isLoading: Boolean) = d.onLoadingChanged(isLoading)
        override fun onTrackSelectionParametersChanged(parameters: androidx.media3.common.TrackSelectionParameters) = d.onTrackSelectionParametersChanged(parameters)
        override fun onPlayerStateChanged(playWhenReady: Boolean, playbackState: Int) = d.onPlayerStateChanged(playWhenReady, playbackState)
        override fun onPlaybackStateChanged(playbackState: Int) = d.onPlaybackStateChanged(playbackState)
        override fun onPlayWhenReadyChanged(playWhenReady: Boolean, reason: Int) = d.onPlayWhenReadyChanged(playWhenReady, reason)
        override fun onPlaybackSuppressionReasonChanged(playbackSuppressionReason: Int) = d.onPlaybackSuppressionReasonChanged(playbackSuppressionReason)
        override fun onIsPlayingChanged(isPlaying: Boolean) = d.onIsPlayingChanged(isPlaying)
        override fun onRepeatModeChanged(repeatMode: Int) = d.onRepeatModeChanged(repeatMode)
        override fun onShuffleModeEnabledChanged(shuffleModeEnabled: Boolean) = d.onShuffleModeEnabledChanged(shuffleModeEnabled)
        override fun onPlayerError(error: androidx.media3.common.PlaybackException) = d.onPlayerError(error)
        override fun onPlayerErrorChanged(error: androidx.media3.common.PlaybackException?) = d.onPlayerErrorChanged(error)
        override fun onPositionDiscontinuity(reason: Int) = d.onPositionDiscontinuity(reason)
        override fun onPositionDiscontinuity(oldPosition: Player.PositionInfo, newPosition: Player.PositionInfo, reason: Int) = d.onPositionDiscontinuity(oldPosition, newPosition, reason)
        override fun onPlaybackParametersChanged(playbackParameters: androidx.media3.common.PlaybackParameters) = d.onPlaybackParametersChanged(playbackParameters)
        override fun onSeekBackIncrementChanged(seekBackIncrementMs: Long) = d.onSeekBackIncrementChanged(seekBackIncrementMs)
        override fun onSeekForwardIncrementChanged(seekForwardIncrementMs: Long) = d.onSeekForwardIncrementChanged(seekForwardIncrementMs)
        override fun onMaxSeekToPreviousPositionChanged(maxSeekToPreviousPositionMs: Long) = d.onMaxSeekToPreviousPositionChanged(maxSeekToPreviousPositionMs)
        override fun onAudioSessionIdChanged(audioSessionId: Int) = d.onAudioSessionIdChanged(audioSessionId)
        override fun onAudioAttributesChanged(audioAttributes: androidx.media3.common.AudioAttributes) = d.onAudioAttributesChanged(audioAttributes)
        override fun onVolumeChanged(volume: Float) = d.onVolumeChanged(volume)
        override fun onDeviceInfoChanged(deviceInfo: androidx.media3.common.DeviceInfo) = d.onDeviceInfoChanged(deviceInfo)
        override fun onDeviceVolumeChanged(volume: Int, muted: Boolean) = d.onDeviceVolumeChanged(volume, muted)
        override fun onVideoSizeChanged(videoSize: androidx.media3.common.VideoSize) = d.onVideoSizeChanged(videoSize)
        override fun onSurfaceSizeChanged(width: Int, height: Int) = d.onSurfaceSizeChanged(width, height)
        override fun onRenderedFirstFrame() = d.onRenderedFirstFrame()
        override fun onCues(cueGroup: androidx.media3.common.text.CueGroup) = d.onCues(cueGroup)
        override fun onMetadata(metadata: androidx.media3.common.Metadata) = d.onMetadata(metadata)
    }

    /** Diffed update: returns true when the value changed (and listeners were told). */
    fun updateSetRunning(running: Boolean): Boolean {
        if (running == setRunning) return false
        setRunning = running
        val cmds = availableCommands
        listeners.forEach { it.onAvailableCommandsChanged(cmds) }
        return true
    }

    protected fun notifyListeners(block: (Player.Listener) -> Unit) = listeners.forEach(block)

    override fun getAvailableCommands(): Player.Commands = SetGate.apply(super.getAvailableCommands(), setRunning, mediaItemCount)

    override fun isCommandAvailable(command: Int): Boolean = availableCommands.contains(command)

    override fun addListener(listener: Player.Listener) {
        listeners += listener
        super.addListener(wrappers.getOrPut(listener) { GatedListener(listener) })
    }

    override fun removeListener(listener: Player.Listener) {
        listeners -= listener
        super.removeListener(wrappers.remove(listener) ?: listener)
    }
}

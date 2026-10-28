package com.levi.pocketdj.playback

import com.levi.pocketdj.data.settings.AppSettingsStore
import com.levi.pocketdj.data.settings.PrefKey
import com.levi.pocketdj.playback.sequencer.RepeatMode

/** Where a run's audio may come from (iOS `PlaybackMode`). */
enum class PlaybackMode(val token: String) {
    /** Stream anything the ladder can resolve. */
    CLOUD("cloud"),

    /** Only rows with an on-device file play; the rest are skipped (UNPLAYABLE_HERE). */
    DEVICE("device");

    companion object {
        fun fromToken(token: String?): PlaybackMode = entries.firstOrNull { it.token == token } ?: CLOUD
    }
}

/** Playback preferences the sequencer reads (keys are persisted names - never rename). */
object PlaybackPrefKeys {
    val PLAYBACK_MODE = PrefKey.string("playbackMode", PlaybackMode.CLOUD.token)
    val REPEAT_MODE = PrefKey.string("playbackRepeatMode", RepeatMode.OFF.token)
}

class PlaybackSettings(private val settings: AppSettingsStore) {
    suspend fun mode(): PlaybackMode = PlaybackMode.fromToken(settings.get(PlaybackPrefKeys.PLAYBACK_MODE))
    suspend fun setMode(mode: PlaybackMode) = settings.set(PlaybackPrefKeys.PLAYBACK_MODE, mode.token)
    suspend fun repeatMode(): RepeatMode = RepeatMode.fromToken(settings.get(PlaybackPrefKeys.REPEAT_MODE))
    suspend fun setRepeatMode(mode: RepeatMode) = settings.set(PlaybackPrefKeys.REPEAT_MODE, mode.token)
}

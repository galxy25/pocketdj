package com.levi.pocketdj.data.stats

import com.levi.pocketdj.data.edition.SongVariant
import com.levi.pocketdj.mix.engine.MixRecordingHooks
import com.levi.pocketdj.playback.PlayEventBus
import com.levi.pocketdj.playback.PlayStarted
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Job
import kotlinx.coroutines.flow.Flow
import kotlinx.coroutines.launch

/**
 * Feeds [PlayStatsStore] from the core play-event seam: a track start is a play (tagged
 * `appleCounted` by the emitter when the Apple Music backend produced it). Skips are NOT derived
 * here: the PlaybackGraph SkipTracker verdict (high-water aware) is the single source and calls
 * [PlayStatsStore.noteSkipped] through its `noteSkip` sink. Mix deck plays arrive via [attachMix].
 * The 30 s re-count window in the store absorbs double hooks.
 */
class PlayStatsRecorder(private val store: PlayStatsStore) {
    /** Stats are keyed by BASE id (a clean/explicit burn "sng_x_clean" plays as "sng_x"). */
    fun onStarted(e: PlayStarted) = store.notePlayed(SongVariant.baseId(e.songId), e.atMs, appleCounted = e.appleCounted)

    fun start(scope: CoroutineScope, started: Flow<PlayStarted> = PlayEventBus.events): Job =
        scope.launch { started.collect { onStarted(it) } }

    companion object {
        /** Mix transport (iOS MixEngine.setPlaying -> notePlayed): every deck play updates the stats. */
        fun attachMix(hooks: MixRecordingHooks, sink: (baseSongId: String) -> Unit) {
            hooks.onPlayStat = { sink(SongVariant.baseId(it)) }
        }
    }
}

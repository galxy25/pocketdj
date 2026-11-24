package com.levi.pocketdj.screens.nowplaying

import androidx.compose.foundation.layout.Box
import androidx.compose.runtime.Composable
import androidx.compose.runtime.collectAsState
import androidx.compose.runtime.getValue
import androidx.compose.ui.Modifier
import androidx.compose.ui.platform.testTag
import com.levi.pocketdj.data.recs.NowPlayingFeedback
import com.levi.pocketdj.data.recs.RecFeedbackStore
import com.levi.pocketdj.screens.foryou.RecFeedbackButtons
import com.levi.pocketdj.ui.FavoriteToggle

/**
 * Install points the Now Playing deck renders only when filled (later packages / areas plug in
 * without editing the screen). All slots are plain vars read at composition time; they are set
 * once at startup by their owning package, never per frame.
 */
object NowPlayingSeams {
    /** The ♥ control for the current song. Defaults to the shared [FavoriteToggle]. */
    @Volatile
    var heart: (@Composable (songId: String, appleMusicId: String?) -> Unit)? =
        { id, amId -> FavoriteToggle(id, appleMusicId = amId) }

    /** 👍/👎 mic-feedback style rating cluster (null until the recs package installs it). */
    @Volatile
    var rating: (@Composable (songId: String) -> Unit)? = null

    /** The ⟲ played list body (PB-7 supplies it). The deck only toggles visibility. */
    @Volatile
    var playedList: (@Composable () -> Unit)? = null

    /** DSP / stem-lock strip slot rendered under the transport (later wave). */
    @Volatile
    var dspSlot: (@Composable () -> Unit)? = null

    /**
     * True while a Mix session owns the deck (the mini bar renders nothing then). Observable: Mix
     * flips this flow so the mini bar recomposes when a session starts or ends.
     */
    val mixSessionActiveFlow: kotlinx.coroutines.flow.MutableStateFlow<Boolean> =
        kotlinx.coroutines.flow.MutableStateFlow(false)

    var mixSessionActive: Boolean
        get() = mixSessionActiveFlow.value
        set(v) { mixSessionActiveFlow.value = v }
}

/**
 * The Now Playing 👍/👎 row (iOS `NowPlayingFeedbackButtons` + `feedbackRow`). Renders nothing unless the
 * running queue is a recommendation the standalone player owns ([NowPlayingFeedback.currentTarget]). It
 * re-derives on every sequencer / Mix / feedback-store change, and files through the shared
 * [NowPlayingFeedback.record] with the iOS `nowPlaying` surface. Never touches the transport.
 */
@Composable
fun NowPlayingFeedbackRow(
    np: NowPlayingFeedback,
    store: RecFeedbackStore,
    sequencer: kotlinx.coroutines.flow.StateFlow<com.levi.pocketdj.playback.sequencer.SequencerState>,
    catalog: com.levi.pocketdj.data.catalog.MergedCatalog?,
) {
    val seq by sequencer.collectAsState()
    val mix by NowPlayingSeams.mixSessionActiveFlow.collectAsState()
    val rev by store.state.collectAsState()
    val target = androidx.compose.runtime.remember(seq, mix, rev) { NowPlayingFeedback.targetFor(store, seq, mix) } ?: return
    Box(Modifier.testTag("np-feedback")) {
        RecFeedbackButtons(
            songId = target.songId,
            scope = target.scope,
            feedback = store,
            catalog = catalog,
            surface = RecFeedbackStore.Surface.NOW_PLAYING,
            recorder = { v -> np.record(v, RecFeedbackStore.Surface.NOW_PLAYING) },
        )
    }
}

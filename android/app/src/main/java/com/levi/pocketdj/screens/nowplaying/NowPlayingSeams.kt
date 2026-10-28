package com.levi.pocketdj.screens.nowplaying

import androidx.compose.runtime.Composable
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

package com.levi.pocketdj.data.jukebox

import androidx.lifecycle.ViewModel
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.launch

/**
 * Tune-In state for one join-route nav entry. Scoped to the entry (not to composition), so the
 * stream survives rotation, tab switches and pushing the mini-player's Now Playing; it stops only
 * on an explicit [stop] (Stop / Leave / ended / lost stream) or when the entry is popped
 * ([onCleared]). [stopper] must stop ONLY the given stream URL (`PlaybackController.stopUrl`).
 */
class JukeboxTuneIn(
    private val scope: CoroutineScope,
    private val stopper: suspend (url: String) -> Unit,
) : ViewModel() {
    private val _tunedIn = MutableStateFlow(false)
    val tunedIn: StateFlow<Boolean> = _tunedIn

    @Volatile private var url: String? = null

    /** The guest pressed Tune In (the stream itself starts once the track is known). */
    fun requestTuneIn() { _tunedIn.value = true }

    /** A stream really started (or re-tuned to the next track). */
    fun noteStarted(streamUrl: String) { url = streamUrl }

    /** Toggle-off / leave / ended: flip off and stop the stream we started, if any. */
    fun stop() {
        _tunedIn.value = false
        val u = url ?: return
        url = null
        scope.launch { stopper(u) }
    }

    public override fun onCleared() {
        stop()
    }
}

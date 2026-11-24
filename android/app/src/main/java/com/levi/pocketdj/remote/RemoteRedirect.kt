package com.levi.pocketdj.remote

import androidx.media3.common.Player
import com.levi.pocketdj.playback.sequencer.QueueItem
import com.levi.pocketdj.playback.sequencer.TransportRedirect
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.asStateFlow

/**
 * A local transport a Backseat CONTROLLER forwards to the session instead of sounding here (iOS `RemoteRedirect`).
 * The sequencer-level [TransportRedirect] maps onto this ([RemoteControllerGate.map]); the surfaces that bypass the
 * sequencer (widget ⏯, a bare MediaController seek, Assistant resume) raise these directly.
 */
sealed interface RemoteRedirect {
    data object PlayPause : RemoteRedirect
    data object Play : RemoteRedirect
    data object Pause : RemoteRedirect
    data object Next : RemoteRedirect
    data object Previous : RemoteRedirect
    data class Seek(val toMs: Long) : RemoteRedirect
    data class PlayItems(val items: List<QueueItem>, val startIndex: Int) : RemoteRedirect

    /** "Play now" of one fresh item (iOS `.playNow`): the session splices it in, or starts it when it is empty. */
    data class PlayNow(val item: QueueItem) : RemoteRedirect
    data class Jump(val uid: String) : RemoteRedirect
}

/**
 * The one place a local transport asks "am I a Backseat controller?". Bound by the session controller (P2-REM-5):
 * [isController] reads its role, [forwarder] turns a [RemoteRedirect] into a session command. With nothing bound
 * (or not a controller) every call returns false and behaviour is exactly as before.
 *
 * Also the registry of [silencers] (NP DSP host, Mix decks - bound by P2-REM-6) that [silenceAll] runs next to the
 * sequencer's own `silenceForController`.
 */
class RemoteControllerGate(private val log: (String) -> Unit = {}) {
    @Volatile var isController: () -> Boolean = { false }
    @Volatile var forwarder: ((RemoteRedirect) -> Unit)? = null

    /** Debug toggle: behave as a controller whose forwards are only logged. */
    @Volatile var fakeController: Boolean = false

    private val silencers = java.util.concurrent.CopyOnWriteArrayList<() -> Unit>()

    /** Snapshot of the registered silencers: the default `extraSilencers` seam of SequencerRemoteTarget. */
    fun silencerSnapshot(): List<() -> Unit> = silencers.toList()

    val active: Boolean get() = fakeController || (isController() && forwarder != null)

    /** Sequencer entry ([SetlistSequencer.transportGate]): true = refused here (forwarded, or a local start dropped). */
    fun intercept(request: TransportRedirect): Boolean {
        if (!active) return false
        val mapped = map(request) ?: return true // LocalStart: refused, never forwarded
        dispatch(mapped)
        return true
    }

    /** A surface outside the sequencer. True = forwarded (the caller must not touch local audio). */
    fun forward(request: RemoteRedirect): Boolean {
        if (!active) return false
        dispatch(request)
        return true
    }

    private fun dispatch(r: RemoteRedirect) {
        log("remote redirect ${name(r)}")
        forwarder?.invoke(r)
    }

    fun addSilencer(s: () -> Unit) { silencers.add(s) }
    fun removeSilencer(s: () -> Unit) { silencers.remove(s) }

    /** Run every registered silencer (a failing one never blocks the rest). */
    fun silenceAll() { silencers.forEach { runCatching(it) } }
    val silencerCount: Int get() = silencers.size

    companion object {
        val shared = RemoteControllerGate { com.levi.pocketdj.diag.NPLog.trace(it) }

        /** Null = never forwarded (an internal restart). */
        fun map(r: TransportRedirect): RemoteRedirect? = when (r) {
            TransportRedirect.PlayPause -> RemoteRedirect.PlayPause
            is TransportRedirect.SetPlaying -> if (r.on) RemoteRedirect.Play else RemoteRedirect.Pause
            TransportRedirect.SkipNext -> RemoteRedirect.Next
            TransportRedirect.SkipPrevious -> RemoteRedirect.Previous
            is TransportRedirect.Play -> RemoteRedirect.PlayItems(r.items, r.startIndex)
            is TransportRedirect.PlayNow -> RemoteRedirect.PlayNow(r.item)
            is TransportRedirect.Jump -> RemoteRedirect.Jump(r.uid)
            TransportRedirect.LocalStart -> null
        }

        fun name(r: RemoteRedirect): String = when (r) {
            RemoteRedirect.PlayPause -> "playPause"
            RemoteRedirect.Play -> "play"
            RemoteRedirect.Pause -> "pause"
            RemoteRedirect.Next -> "next"
            RemoteRedirect.Previous -> "previous"
            is RemoteRedirect.Seek -> "seek"
            is RemoteRedirect.PlayItems -> "playItems"
            is RemoteRedirect.PlayNow -> "playNow"
            is RemoteRedirect.Jump -> "jump"
        }
    }
}

/**
 * Why the audio is silent, for `pausedHere`: the SYSTEM silenced it (becoming-noisy, a permanent focus loss, or a
 * transient loss that never resumed within [TRANSIENT_GRACE_MS]), as opposed to the listener pausing. Pure; fed from
 * the PlaybackService player listener.
 */
class SystemPauseClassifier(private val nowMs: () -> Long = System::currentTimeMillis) {
    private var hardPause = false
    private var suppressedSince: Long? = null

    fun onPlayWhenReadyChanged(playWhenReady: Boolean, reason: Int) {
        if (playWhenReady) { hardPause = false; return }
        hardPause = when (reason) {
            Player.PLAY_WHEN_READY_CHANGE_REASON_AUDIO_BECOMING_NOISY,
            Player.PLAY_WHEN_READY_CHANGE_REASON_AUDIO_FOCUS_LOSS,
            -> true
            // The listener's own pause is not the system's; the player's own doing (end of item) neither.
            else -> false
        }
    }

    fun onSuppressionChanged(suppressionReason: Int) {
        suppressedSince = if (suppressionReason == Player.PLAYBACK_SUPPRESSION_REASON_TRANSIENT_AUDIO_FOCUS_LOSS) {
            suppressedSince ?: nowMs()
        } else null
    }

    val isSystemPaused: Boolean
        get() = hardPause || suppressedSince?.let { nowMs() - it >= TRANSIENT_GRACE_MS } == true

    companion object {
        /** A transient loss (a call, an Assistant turn) that outlasts this has not resumed on its own. */
        const val TRANSIENT_GRACE_MS = 5_000L
    }
}

/**
 * Publishes [flow] from a [classifier]. A transient loss has no closing player event, so on suppression it schedules a
 * re-evaluation at the end of the grace window ([schedule] = delay ms + action; default a daemon timer).
 */
class SystemPauseFlow(
    val classifier: SystemPauseClassifier,
    private val schedule: (Long, () -> Unit) -> Unit,
) {
    private val _flow = MutableStateFlow(false)
    val flow: StateFlow<Boolean> = _flow.asStateFlow()

    val isSystemPaused: Boolean get() = classifier.isSystemPaused

    fun onPlayWhenReadyChanged(playWhenReady: Boolean, reason: Int) {
        classifier.onPlayWhenReadyChanged(playWhenReady, reason)
        refresh()
    }

    fun onSuppressionChanged(reason: Int) {
        classifier.onSuppressionChanged(reason)
        refresh()
        if (reason == Player.PLAYBACK_SUPPRESSION_REASON_TRANSIENT_AUDIO_FOCUS_LOSS) {
            schedule(SystemPauseClassifier.TRANSIENT_GRACE_MS) { refresh() }
        }
    }

    fun refresh() { _flow.value = classifier.isSystemPaused }
}

/** Process-wide system-pause state: [PlaybackService] feeds it, the Remote target reads it. */
object SystemPauseState {
    private val timer by lazy { java.util.concurrent.Executors.newSingleThreadScheduledExecutor { r -> Thread(r, "sys-pause").apply { isDaemon = true } } }
    private val impl = SystemPauseFlow(SystemPauseClassifier()) { ms, f ->
        timer.schedule({ runCatching(f) }, ms + 50, java.util.concurrent.TimeUnit.MILLISECONDS)
    }
    val classifier get() = impl.classifier
    val flow: StateFlow<Boolean> get() = impl.flow

    /** Live value (re-evaluates the transient grace). */
    val isSystemPaused: Boolean get() = impl.isSystemPaused

    fun onPlayWhenReadyChanged(playWhenReady: Boolean, reason: Int) = impl.onPlayWhenReadyChanged(playWhenReady, reason)
    fun onSuppressionChanged(reason: Int) = impl.onSuppressionChanged(reason)
}

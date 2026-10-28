package com.levi.pocketdj.playback.am

import com.levi.pocketdj.playback.AppleMusicBackend

/**
 * The slice of the Apple Music engine the Media3 adapter and the end-monitor driver need, as an
 * interface so the adapter state machine is unit-testable with a fake (the real SDK is device-only).
 * All calls are made on Main.
 */
interface AppleMusicController {
    /** The row the AM engine holds, or null when idle. */
    val track: AmTrack?

    /** Cold read of the SDK. */
    fun snapshot(): AmSnapshot

    fun play()
    fun pause()

    /** Silence the engine for a session handoff: NO listener-intent / intentional-pause bookkeeping. */
    fun pauseQuiet()
    fun seekTo(positionMs: Long)
    fun stop()

    /** Something the adapter renders changed (state, position anchor, metadata). */
    fun setChangeListener(l: (() -> Unit)?)
}

data class AmTrack(
    val songId: String,
    val title: String?,
    val artist: String?,
    val albumTitle: String?,
    val artworkUri: String?,
)

data class AmSnapshot(val status: AmStatus, val positionMs: Long, val durationMs: Long?, val buffering: Boolean = false) {
    companion object {
        val IDLE = AmSnapshot(AmStatus.STOPPED, 0L, null)
    }
}

/**
 * [AppleMusicController] over the SDK-backed [AppleMusicBackend]. Pause/resume mark the monitor's
 * sticky intentional-pause flag so OUR pause is never read as a system skip.
 */
class BackendAppleMusicController(
    private val backend: AppleMusicBackend,
    private val monitor: AppleMusicEndMonitor,
    private val trackFor: (songId: String, title: String?, artist: String?, albumId: String?) -> AmTrack,
) : AppleMusicController {
    override val track: AmTrack?
        get() = backend.currentRow()?.let { trackFor(it.songId, it.title, it.artist, it.albumId) }

    override fun snapshot(): AmSnapshot = backend.snapshot()
    /** Listener intent for the sequencer's [com.levi.pocketdj.playback.health.PauseDiscriminator]. */
    var onPlayIntent: ((playing: Boolean) -> Unit)? = null

    /** ▶ while the monitor holds an interruption: re-queue + seek back instead of a plain resume. */
    var onResumeFromInterruption: ((atSeconds: Double) -> Unit)? = null

    override fun play() {
        monitor.interruptedAtSeconds?.let { at ->
            onResumeFromInterruption?.let { it(at); onPlayIntent?.invoke(true); return }
        }
        monitor.noteIntentionalPause(false)
        onPlayIntent?.invoke(true)
        backend.resumeNow()
    }

    override fun pause() {
        monitor.noteIntentionalPause(true)
        onPlayIntent?.invoke(false)
        backend.pauseNow()
    }
    override fun pauseQuiet() = backend.pauseNow()
    override fun seekTo(positionMs: Long) { monitor.noteSeek(positionMs); backend.seekNow(positionMs) }
    override fun stop() = backend.stopNow()
    override fun setChangeListener(l: (() -> Unit)?) { backend.changeListener = l }
}

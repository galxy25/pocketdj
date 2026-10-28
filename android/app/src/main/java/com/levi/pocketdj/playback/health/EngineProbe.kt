package com.levi.pocketdj.playback.health

/**
 * What the sequencer's health machinery needs to know about the audio engine holding the CURRENT row
 * (the Media3 adapter implements it). Attaching one to the sequencer ARMS the zero-dead-air machinery.
 * All calls are made on the sequencer's (Main) dispatcher.
 */
interface EngineProbe {
    /** The engine holds a media item for the row (a load completed). */
    val hasLoadedItem: Boolean

    /** The engine is rendering sound right now (READY + playWhenReady + not suppressed). */
    val isPlaying: Boolean

    /** Current position inside the loaded item (ms). */
    val positionMs: Long

    /** Duration of the loaded item (ms), or null when unknown. */
    val durationMs: Long? get() = null

    /** The loaded item already reported its natural end (STATE_ENDED). */
    val trackEnded: Boolean

    /** Re-request the load from the current position (`seekTo(position); prepare(); play()`). */
    fun rekick(by: String)
}

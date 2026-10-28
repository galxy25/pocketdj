package com.levi.pocketdj.playback.session

import androidx.media3.common.Player

/**
 * One audio engine that can answer the system transport (standalone ExoPlayer, Mix, Apple Music
 * adapter, Now Playing DSP). Exactly one owns the MediaSession at a time (decision D2).
 */
interface TransportOwner {
    /** Log token: `exo`, `am`, `mix`... */
    val engine: String

    /** The Player the MediaSession should drive while this owner is current. */
    val sessionPlayer: Player

    /** Has this engine produced audio since it was restored/created? A restored-never-sounded engine is no remote target. */
    val hasSounded: Boolean

    /** Silence the engine because another owner started. */
    fun pauseForHandoff()
}

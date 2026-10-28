package com.levi.pocketdj.shell

/** What an Auto-DJ mix is built from (iOS `MixSource`). */
sealed interface MixSource {
    data class Pocket(val id: String) : MixSource
    data class Playlist(val id: String) : MixSource
    data class Setlist(val id: String) : MixSource
}

/** Display name + loadable track count of a started mix (0 ⇒ zero-start pending). */
data class MixStartResult(val name: String, val count: Int)

/**
 * The seam between [ShellActions] and the Mix engine (iOS: `IntentServices.mix` +
 * `MixResolver` + `CollectionMixDownloader`). The Mix area (MIX-x) assigns
 * `ShellActions.mixFacade` once its engine can be driven out of the UI; until then every
 * Auto-Mix action reports "Auto-Mix isn't available yet" and nothing else is affected.
 *
 * Implementations own the iOS invariants: pause/resume go through the lock-screen seam
 * (the only pause that freezes the transition clock), loadable resolution is burned/stem
 * files only, and the collection download run is kicked BEFORE the empty-loadables guard.
 */
interface MixFacade {
    /** An Auto-DJ run is active (playing or suspended). */
    val autoMixing: Boolean

    /** The run was suspended through [pauseAutoMix] / the lock screen. */
    val autoPaused: Boolean

    /** Start a mix from one source. Throws [ShellActionException.NoBurnedSongs] when nothing is on disk. */
    suspend fun startAutoMix(source: MixSource, shuffle: Boolean, allowPendingStart: Boolean): MixStartResult

    /** Two-crate Auto DJ: deck A and deck B crates interleaved. */
    suspend fun startAutoMix(
        deckA: MixSource,
        deckB: MixSource,
        shuffle: Boolean,
        allowPendingStart: Boolean,
    ): MixStartResult

    fun pauseAutoMix()
    fun resumeAutoMix()
}

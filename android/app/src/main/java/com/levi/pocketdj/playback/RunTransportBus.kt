package com.levi.pocketdj.playback

/**
 * Seam between the media session (system next/previous) and the app-scoped sequencer. The service
 * and the controller share a process; the controller registers [handler] at construction.
 * Interim until PB-2's SequencerForwardingPlayer.
 */
object RunTransportBus {
    interface Handler {
        val isRunActive: Boolean
        fun next()
        fun previous()
    }

    @Volatile var handler: Handler? = null

    /** PB-2: the sequencer as the session player sees it (null until the controller is built). */
    @Volatile var control: com.levi.pocketdj.playback.session.SequencerControl? = null

    /** PB-2: instant now-playing metadata for the row being started (null clears). Set by the service. */
    @Volatile var instantMetadata: ((androidx.media3.common.MediaMetadata?) -> Unit)? = null

    /** PB-2: sequencer state changed (running flip, repeat/shuffle) - refresh the command gate. */
    @Volatile var stateChanged: (() -> Unit)? = null

    /** PB-2: drop the overlay [md] only if it is still the one showing (a failed/cancelled load). */
    @Volatile var clearInstantMetadata: ((androidx.media3.common.MediaMetadata) -> Unit)? = null

    /** PB-2: a held restore landed (consumes a latched remote play). Separate from [stateChanged]. */
    @Volatile var heldRestored: (() -> Unit)? = null

    /** P2-ALB-4: the service's album boundary armer (null until the service is up). */
    @Volatile var albumArmer: com.levi.pocketdj.playback.album.AlbumBoundaryArmer? = null

    /** P2-ALB-4: an armed album boundary fired for this song id (the controller reports a natural end). */
    @Volatile var albumBoundaryFired: ((String) -> Unit)? = null

    /** P2-ALB-5: the loaded album run's song clock (controller-owned); read by the session player. */
    @Volatile var runClock: com.levi.pocketdj.playback.album.RunClockSource? = null

    /** P2-ALB-5: the service's RAW engine (file-relative clock, no song mapping) for the run engine glue's own seeks/reads. */
    @Volatile var rawPlayer: androidx.media3.common.Player? = null

    /** P2-ALB-5: the song under the playhead changed in place - the session player re-announces its clock. */
    @Volatile var clockChanged: (() -> Unit)? = null
}

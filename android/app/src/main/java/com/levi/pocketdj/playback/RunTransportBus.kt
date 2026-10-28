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
}

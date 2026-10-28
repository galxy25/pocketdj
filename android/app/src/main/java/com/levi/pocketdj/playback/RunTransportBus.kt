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
}

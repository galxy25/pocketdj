package com.levi.pocketdj.data.pockets

import com.levi.pocketdj.data.history.PlayHistoryStore

/**
 * Glue between playback/history and the listening-pockets service:
 *  - stamps `carPlay` on every NEW play via the history store's probe (the car-projection signal, null = unknown);
 *  - [onBackgrounded] requests a debounced flush (iOS scenePhase .background hook) so the last plays of a session
 *    reach the server even if the 10-minute loop never ticks again.
 * Plays themselves are never uploaded from here: outcomes land after the row is appended, so the service's
 * fingerprint diff (not an append event) decides what goes out.
 */
class PocketsPlayListener(
    private val service: ListeningPocketsService,
    private val carConnected: () -> Boolean?,
) {
    /** Wire the probe into [history]. Idempotent; a null probe answer leaves the field null. */
    fun attach(history: PlayHistoryStore) {
        history.carPlayProbe = carConnected
    }

    /** App moved to the background: debounced flush when the gate is open (service no-ops otherwise). */
    fun onBackgrounded() {
        if (service.isEnabled) service.flushSoon()
    }
}

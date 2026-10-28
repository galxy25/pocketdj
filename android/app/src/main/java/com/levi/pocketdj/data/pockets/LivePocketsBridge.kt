package com.levi.pocketdj.data.pockets

import com.levi.pocketdj.data.games.inthepocket.InThePocketRoundWire
import kotlinx.coroutines.flow.StateFlow

/**
 * The real [PocketsBridge] (GM-7 contract) over [ListeningPocketsService]. Games reads the privacy gate + latest
 * results, asks for a flush when a round finishes, and registers its finished rounds through [roundsProvider];
 * the service's own flush uploads them AFTER the plays they reference (so [flushesRounds] is true and games runs
 * no fallback timer).
 *
 * Inert by construction: [credentials] is null whenever the gate is closed, so a caller that forgot its own
 * check still cannot reach the network.
 */
class LivePocketsBridge(
    private val service: ListeningPocketsService,
    /** The rec-engine credentials seam (null until enrolled). Gated on the privacy switch here. */
    private val credentialsSource: () -> PocketsCredentials?,
    private val installIdSource: () -> String,
    /** Uploads rounds (InThePocketRoundsClient.flush); null => the service never uploads rounds. */
    private val roundsUploader: (suspend (PocketsCredentials, List<InThePocketRoundWire>, String) -> Boolean)? = null,
) : PocketsBridge {
    override val isEnabled: StateFlow<Boolean> get() = service.enabled
    override val results: StateFlow<ListeningPocketsResults?> get() = service.results

    @Volatile override var roundsProvider: ((String) -> List<InThePocketRoundWire>)? = null

    override val installId: String get() = installIdSource()
    override val flushesRounds: Boolean get() = roundsUploader != null

    init {
        val uploader = roundsUploader
        if (uploader != null) {
            service.roundsFlusher = { creds, id ->
                val wires = roundsProvider?.invoke(id).orEmpty()
                wires.isNotEmpty() && uploader(creds, wires, id)
            }
        }
    }

    override suspend fun refreshIfStale() {
        if (!service.isEnabled) return
        service.refreshIfStale()
    }

    override fun flushSoon() {
        if (!service.isEnabled) return
        service.flushSoon()
    }

    override suspend fun credentials(): PocketsCredentials? =
        if (service.isEnabled) credentialsSource() else null
}

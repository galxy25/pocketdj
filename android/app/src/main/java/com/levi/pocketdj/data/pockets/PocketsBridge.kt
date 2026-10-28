package com.levi.pocketdj.data.pockets

import com.levi.pocketdj.data.games.inthepocket.InThePocketRoundWire
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.asStateFlow

/** Rec-engine bearer key + the rec-engine-SCOPED profile id (never the broadcast one). */
data class PocketsCredentials(
    val key: String,
    val profileId: String,
    /** `X-PocketDJ-Enroll` value; empty ⇒ header omitted (the iOS rule). */
    val enrollSecret: String = "",
)

/**
 * The seam between the games area and the listening-pockets SERVICE (shared contract; the
 * services area implements it). Games reads the privacy gate + the latest results, asks for a
 * flush when a round finishes, and exposes its finished rounds through [roundsProvider] so the
 * service's flush can upload them after the plays (a round's songs are plays).
 *
 * PRIVACY GATE: [isEnabled] = rec engine ON and "Find my listening pockets" ON. The game never
 * builds a cloud-mode round or uploads while it is false.
 */
interface PocketsBridge {
    val isEnabled: StateFlow<Boolean>
    val results: StateFlow<ListeningPocketsResults?>

    /** Fetch results when the cache is stale (no-op when disabled). */
    suspend fun refreshIfStale()

    /** Debounced upload request (plays, collections, rounds). */
    fun flushSoon()

    /** Finished-round upload rows for [installId]; set by the game store, read by the service flush. */
    var roundsProvider: ((installId: String) -> List<InThePocketRoundWire>)?

    suspend fun credentials(): PocketsCredentials?

    /** This install's history id (the rounds' `originInstallId`). */
    val installId: String

    /**
     * True when the service's OWN flush uploads [roundsProvider] rows (via InThePocketRoundsClient.flush)
     * AFTER the plays they reference. Games then runs no fallback rounds timer of its own.
     */
    val flushesRounds: Boolean get() = false
}

/** Default until the services wave wires the real bridge: disabled, empty, never networks. */
object NoPocketsBridge : PocketsBridge {
    private val off = MutableStateFlow(false).asStateFlow()
    private val none = MutableStateFlow<ListeningPocketsResults?>(null).asStateFlow()
    override val isEnabled: StateFlow<Boolean> get() = off
    override val results: StateFlow<ListeningPocketsResults?> get() = none
    override suspend fun refreshIfStale() = Unit
    override fun flushSoon() = Unit
    override var roundsProvider: ((String) -> List<InThePocketRoundWire>)? = null
    override suspend fun credentials(): PocketsCredentials? = null
    override val installId: String get() = ""
}

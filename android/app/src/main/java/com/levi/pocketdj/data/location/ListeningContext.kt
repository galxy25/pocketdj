package com.levi.pocketdj.data.location

import com.levi.pocketdj.data.pockets.ListeningContextTag

// LISTENING CONTEXT - the contract between a (future) on-device location engine and the play-history ->
// listening-pockets pipeline (port of apple Location/ListeningContext.swift). Opaque ids only: never
// coordinates, never a name. The tag type itself lives with the wire models (pockets package).
// Android ships NO location engine yet, so [NoopListeningContextProvider] is the only implementation.

/** The answer to "what was the listening context at time T?". */
sealed interface ListeningContextLookup {
    /** Never stamp: no location on this platform, feature off, permission missing, or T predates tracking. */
    data object Unavailable : ListeningContextLookup

    /** Not decidable YET (mid-trip, or a back-dated visit could still claim T). Ask again later. */
    data object Pending : ListeningContextLookup

    /** Final. May be [ListeningContextTag.NONE]. */
    data class Settled(val tag: ListeningContextTag) : ListeningContextLookup
}

object ListeningContextConstants {
    /** A T older than this before now is NEVER [ListeningContextLookup.Pending]. */
    const val PENDING_HORIZON_MS: Long = 6L * 60 * 60 * 1000
}

/** A place as the UI shows it (rank computed at display time; the id is stable forever). */
data class ListeningPlaceLabel(val id: String, val rank: Int, val label: String, val shareOfTime: Double)

/** A recurring trip as the UI shows it. */
data class ListeningTripLabel(
    val id: String,
    val origin: String,
    val destination: String?,
    val label: String,
    val occurrences: Int,
)

/** The location engine as the rest of the app sees it. */
interface ListeningContextProviding {
    /** This platform can produce context at all. */
    val isSupported: Boolean

    /** Supported AND the user opted in AND permission granted. */
    val isActive: Boolean
    fun context(atMs: Double): ListeningContextLookup
    fun placeLabels(): List<ListeningPlaceLabel>
    fun tripLabels(): List<ListeningTripLabel>
    fun label(tag: ListeningContextTag): String?
    fun currentContextGuess(): ListeningContextTag? = null
}

/** The provider for platforms/tests with no location: always unavailable. */
object NoopListeningContextProvider : ListeningContextProviding {
    override val isSupported: Boolean get() = false
    override val isActive: Boolean get() = false
    override fun context(atMs: Double): ListeningContextLookup = ListeningContextLookup.Unavailable
    override fun placeLabels(): List<ListeningPlaceLabel> = emptyList()
    override fun tripLabels(): List<ListeningTripLabel> = emptyList()
    override fun label(tag: ListeningContextTag): String? = null
}

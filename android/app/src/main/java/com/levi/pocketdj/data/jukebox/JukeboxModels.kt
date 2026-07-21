package com.levi.pocketdj.data.jukebox

import kotlinx.serialization.Serializable

/**
 * Wire + persisted types for Jukebox Hero, DJ side (specs/jukebox.md §3).
 *
 * ADDITIVE-OPTIONAL iron law: every field that can be absent has a default so a
 * later broker/field addition never breaks a decode of a live response or a
 * persisted session doc. Decode with [com.levi.pocketdj.data.PdjJson] only.
 */

/**
 * A live session as returned by `POST /jukebox` and persisted locally
 * (jukebox.md §3.1). [requiresToken] is a LOCAL intent stamp — the server
 * neither mints nor enforces it today and does not echo it back (§9).
 */
@Serializable
data class JukeboxSessionInfo(
    val jukeboxId: String,
    /** Host-only credential — never render, never log, never show to guests. */
    val hostKey: String,
    val name: String = "",
    /** The guest page URL — the QR payload, verbatim. */
    val url: String = "",
    val requiresToken: Boolean? = null,
    /** Older/absent decodes as off; Android P1 always creates timeless:false. */
    val timeless: Boolean? = null,
    /** Epoch ms; null on a timeless session. */
    val expiresAt: Double? = null,
)

/**
 * One guest request (jukebox.md §3.2). The host poll also carries `clientId`,
 * which iOS ignores — the lenient decode drops it here too.
 */
@Serializable
data class JukeboxRequest(
    val id: String,
    val seq: Long = 0,
    val title: String = "",
    /** May be "" — guests can request by title alone. */
    val artist: String = "",
    /** Epoch ms. */
    val createdAt: Double = 0.0,
    /**
     * "pending" | "queued" | "denied" — plain String, tolerating unknown values
     * ("played" is documented but never set by broker v2, jukebox.md §2.5).
     */
    val status: String = STATUS_PENDING,
) {
    companion object {
        const val STATUS_PENDING = "pending"
    }
}

/** `GET /jukebox/{id}/requests?since=` page (jukebox.md §2.3 #4). */
@Serializable
data class JukeboxRequestsPage(
    val requests: List<JukeboxRequest> = emptyList(),
    /** High-water mark for the next `?since=` poll. */
    val seq: Long = 0,
)

/**
 * The host → broker player-state snapshot (jukebox.md §3.3). Posting honest
 * snapshots IS how played history happens — the server derives the played log
 * from now-playing transitions across these posts (§1).
 */
@Serializable
data class JukeboxStatePayload(
    val hear: Boolean = false,
    val nowPlaying: NowPlaying? = null,
    val upNext: List<Track> = emptyList(),
) {
    @Serializable
    data class NowPlaying(
        val title: String,
        val artist: String,
        val lengthMs: Long? = null,
        /** Position at snapshot time; the guest page interpolates from it. */
        val positionMs: Long? = null,
        /** Hear mode only — a public https rips-bucket mp3, or null. */
        val streamUrl: String? = null,
    )

    @Serializable
    data class Track(val title: String, val artist: String)
}

/**
 * Host decision on a request (jukebox.md §3.4). All three placements report
 * "queued" to guests; only [DENIED] shows as denied.
 */
enum class JukeboxDecisionAction(val wire: String, val label: String) {
    DENIED("denied", "Deny"),
    NEXT("next", "Play Next"),
    END("end", "Play Last"),
    RANDOM("random", "Surprise Slot");

    val isPlacement: Boolean get() = this != DENIED
}

/** `GET /health` — decode just these three, all optional (jukebox.md §7). */
@Serializable
data class JukeboxHealth(
    val ok: Boolean? = null,
    val service: String? = null,
    val version: Int? = null,
)

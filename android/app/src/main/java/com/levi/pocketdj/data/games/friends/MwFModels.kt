package com.levi.pocketdj.data.games.friends

import kotlinx.serialization.Serializable

// Music with Friends wire types. ALL fields optional (lenient decode): a newer server's extras
// or an older server's gaps must never break the app. Names match the iOS JSON exactly.

@Serializable
data class MwFSettings(
    val turnSeconds: Int? = null,
    val acceptOutsideTurn: Boolean? = null,
    val turnEndsOnFirstSuggestion: Boolean? = null,
)

@Serializable
data class MwFMember(
    val memberId: String? = null,
    val name: String? = null,
    val joinedAt: Double? = null,
    val score: Int? = null,
    val isLeader: Boolean? = null,
)

@Serializable
data class MwFMatch(
    val songId: String? = null,
    val appleMusicId: String? = null,
    val title: String? = null,
    val artist: String? = null,
    val lengthMs: Long? = null,
)

@Serializable
data class MwFSuggestion(
    val id: String? = null,
    val seq: Int? = null,
    val memberId: String? = null,
    val title: String? = null,
    val artist: String? = null,
    val createdAt: Double? = null,
    /** pending | accepted | rejected */
    val status: String? = null,
    val decidedAt: Double? = null,
    val plusOnes: List<String>? = null,
    val match: MwFMatch? = null,
)

@Serializable
data class MwFCollectionEntry(
    val songId: String? = null,
    val appleMusicId: String? = null,
    val title: String? = null,
    val artist: String? = null,
    val lengthMs: Long? = null,
    val suggestedBy: String? = null,
    val acceptedAt: Double? = null,
)

@Serializable
data class MwFTurn(
    val memberId: String? = null,
    val index: Int? = null,
    /** Epoch ms the current turn expires. */
    val deadline: Double? = null,
)

@Serializable
data class MwFYou(val memberId: String? = null)

/** Member-state payload (`GET /mwf/:id/state`); the public `state.json` is the same minus `you`. */
@Serializable
data class MwFState(
    val v: Int? = null,
    val sessionId: String? = null,
    val name: String? = null,
    val theme: String? = null,
    val updatedAt: Double? = null,
    val ended: Boolean? = null,
    val expiresAt: Double? = null,
    val settings: MwFSettings? = null,
    val members: List<MwFMember>? = null,
    val turn: MwFTurn? = null,
    val suggestions: List<MwFSuggestion>? = null,
    val collection: List<MwFCollectionEntry>? = null,
    val you: MwFYou? = null,
    /** The broker's public request base: lets a scanned link join with no configured server. */
    val apiBase: String? = null,
) {
    fun score(of: String?): Int =
        if (of == null) 0 else members?.firstOrNull { it.memberId == of }?.score ?: 0
}

/** One persisted shape for leader + joined sessions. `leaderKey != null` => this device leads. */
@Serializable
data class MwFSessionEntry(
    val id: String,
    val memberId: String = "",
    val memberKey: String = "",
    val leaderKey: String? = null,
    val name: String? = null,
    val theme: String? = null,
    val url: String? = null,
    val apiBase: String? = null,
    val expiresAt: Double? = null,
    val pocketId: String? = null,
    val joinedAt: Double = 0.0,
) {
    val isLeader: Boolean get() = leaderKey != null
}

// ---- Reply shapes ----

@Serializable
data class MwFCreateResult(
    val sessionId: String? = null,
    val leaderKey: String? = null,
    val memberId: String? = null,
    val memberKey: String? = null,
    val name: String? = null,
    val theme: String? = null,
    val url: String? = null,
    val expiresAt: Double? = null,
    val settings: MwFSettings? = null,
)

@Serializable
data class MwFJoinResult(
    val memberId: String? = null,
    val memberKey: String? = null,
    val name: String? = null,
    val theme: String? = null,
    val settings: MwFSettings? = null,
    val expiresAt: Double? = null,
    val sessionName: String? = null,
)

@Serializable
data class MwFSuggestResult(
    val suggestionId: String? = null,
    val status: String? = null,
    val turnAdvanced: Boolean? = null,
)

@Serializable
data class MwFHealth(val ok: Boolean? = null, val version: Int? = null, val mwf: Boolean? = null)

package com.levi.pocketdj.data.jukebox

import kotlinx.serialization.Serializable
import kotlinx.serialization.json.Json
import kotlinx.serialization.json.JsonArray
import kotlinx.serialization.json.JsonElement
import kotlinx.serialization.json.JsonObject
import kotlinx.serialization.json.jsonObject

/**
 * The public guest view of a jukebox: the `state.json` the broker publishes (iOS `JukeboxGuestState`).
 * Every field is optional/defaulted so a partial or older payload never crashes the guest
 * (durable-JSON doctrine); a missing or malformed array decodes to an empty list.
 */
@Serializable
data class JukeboxGuestState(
    val jukeboxId: String? = null,
    val name: String? = null,
    val ended: Boolean? = null,
    /** View+Hear: guests may tune in to `nowPlaying.streamUrl`. */
    val hear: Boolean? = null,
    /** Server `Date.now()` when the snapshot was composed (ms); anchors the tune-in seek. */
    val updatedAt: Double? = null,
    val nowPlaying: NowPlaying? = null,
    val upNext: List<Track> = emptyList(),
    val played: List<PlayedTrack> = emptyList(),
    val requests: List<GuestRequest> = emptyList(),
    /** The broker's public request-endpoint base; absent on older brokers. */
    val apiBase: String? = null,
) {
    @Serializable
    data class NowPlaying(
        val title: String? = null,
        val artist: String? = null,
        val lengthMs: Long? = null,
        val positionMs: Long? = null,
        val streamUrl: String? = null,
    ) {
        val hasContent: Boolean get() = !title.isNullOrEmpty() || !artist.isNullOrEmpty()
    }

    @Serializable
    data class Track(val title: String? = null, val artist: String? = null)

    @Serializable
    data class PlayedTrack(
        val title: String? = null,
        val artist: String? = null,
        val endedAt: Double? = null,
    )

    @Serializable
    data class GuestRequest(
        val id: String = "",
        val title: String? = null,
        val artist: String? = null,
        /** pending | queued | denied | played */
        val status: String? = null,
        /** Not published by today's broker (it never leaks clientId); honoured if present. */
        val clientId: String? = null,
    )

    val isEnded: Boolean get() = ended == true

    /** Tune In is offered only for View+Hear with an https stream. */
    val canTuneIn: Boolean
        get() = hear == true && TuneInSeekMath.isPlayableStream(nowPlaying?.streamUrl)

    fun markEnded(): JukeboxGuestState = copy(ended = true)

    /**
     * Is [r] one of this guest's own requests? A published `clientId` match wins; otherwise the
     * ids returned by our own successful submits, then a case-insensitive title|artist key (iOS).
     */
    fun isMine(r: GuestRequest, clientId: String, myRequestIds: Set<String>, myKeys: Set<String>): Boolean {
        if (!r.clientId.isNullOrEmpty() && r.clientId == clientId) return true
        if (r.id.isNotEmpty() && r.id in myRequestIds) return true
        return requestKey(r.title, r.artist) in myKeys
    }

    companion object {
        val EMPTY = JukeboxGuestState()

        fun requestKey(title: String?, artist: String?): String =
            (title ?: "").trim().lowercase() + "|" + (artist ?: "").trim().lowercase()

        /** Lenient decode: a missing / null / malformed array becomes `[]`, unknown keys are ignored. */
        fun decode(json: Json, text: String): JukeboxGuestState {
            val root = json.parseToJsonElement(text).jsonObject
            fun <T> list(key: String, decode: (JsonElement) -> T?): List<T> =
                (root[key] as? JsonArray)?.mapNotNull { runCatching { decode(it) }.getOrNull() }.orEmpty()
            return JukeboxGuestState(
                jukeboxId = root.str("jukeboxId"),
                name = root.str("name"),
                ended = root.bool("ended"),
                hear = root.bool("hear"),
                updatedAt = root.num("updatedAt"),
                nowPlaying = (root["nowPlaying"] as? JsonObject)?.let {
                    runCatching { json.decodeFromJsonElement(NowPlaying.serializer(), it) }.getOrNull()
                },
                upNext = list("upNext") { json.decodeFromJsonElement(Track.serializer(), it) },
                played = list("played") { json.decodeFromJsonElement(PlayedTrack.serializer(), it) },
                requests = list("requests") { json.decodeFromJsonElement(GuestRequest.serializer(), it) },
                apiBase = root.str("apiBase"),
            )
        }

        private fun JsonObject.str(k: String): String? =
            (this[k] as? kotlinx.serialization.json.JsonPrimitive)?.takeIf { it.isString }?.content

        private fun JsonObject.bool(k: String): Boolean? =
            (this[k] as? kotlinx.serialization.json.JsonPrimitive)?.content?.toBooleanStrictOrNull()

        private fun JsonObject.num(k: String): Double? =
            (this[k] as? kotlinx.serialization.json.JsonPrimitive)?.content?.toDoubleOrNull()
    }
}

/** Pure Tune-In helpers (shared by the join panel and its tests). */
object TuneInSeekMath {
    /** Only https streams (the broker already filters, but never trust a public payload). */
    fun isPlayableStream(url: String?): Boolean =
        url != null && url.startsWith("https://", ignoreCase = true) && url.length > "https://".length

    /** Cap on the elapsed term (host posts every ~4 s + 1 s debounce; heartbeats bump updatedAt). */
    const val MAX_ELAPSED_MS = 5_000L

    /**
     * Where to seek the stream: the host's reported `positionMs` plus the time elapsed since the
     * snapshot was composed (`now - updatedAt`), clamped to `[0, lengthMs]` so clock skew or a stale
     * snapshot can't seek past the end. Unknown position -> 0.
     */
    fun seekMs(positionMs: Long?, updatedAtMs: Double?, nowMs: Long, lengthMs: Long? = null): Long {
        // Unknown position (Mix/broadcast now-playing) starts at 0, as iOS does: no phantom elapsed.
        if (positionMs == null) return 0L
        val base = positionMs.coerceAtLeast(0L)
        val elapsed = if (updatedAtMs != null && updatedAtMs > 0) {
            // updatedAt is the broker's compose time (also bumped by the 15 s heartbeat), so cap it.
            (nowMs - updatedAtMs.toLong()).coerceIn(0L, MAX_ELAPSED_MS)
        } else {
            0L
        }
        val target = base + elapsed
        return if (lengthMs != null && lengthMs > 0) target.coerceAtMost(lengthMs) else target
    }

    /** Identity of the track being heard; a change while tuned in triggers a re-tune. */
    fun trackKey(np: JukeboxGuestState.NowPlaying?): String =
        if (np == null) "" else "${np.title.orEmpty()}|${np.artist.orEmpty()}|${np.streamUrl.orEmpty()}"
}

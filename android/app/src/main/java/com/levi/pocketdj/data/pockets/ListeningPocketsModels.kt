package com.levi.pocketdj.data.pockets

import kotlinx.serialization.json.JsonArray
import kotlinx.serialization.json.JsonElement
import kotlinx.serialization.json.JsonNull
import kotlinx.serialization.json.JsonObject
import kotlinx.serialization.json.JsonPrimitive

// ─────────────────────────────────────────────────────────────────────────────────────────────
// LISTENING POCKETS — UPLOAD wire types (port of the upload half of apple
// Services/ListeningPockets/ListeningPocketsModels.swift; the lenient RESULTS decoder shipped
// with GM-5 in PocketsModels.kt). `POST /pockets/events` body v1, encoded exactly as the iOS
// Codable output: nullable event fields encode an explicit `null`, the batch/place/trip/collection
// optionals are OMITTED when nil, `ctx` is `null` when absent, and `contextId`/`contextKind` are
// absent (never null) when unknown so a context-free event is byte-identical to before.
// ─────────────────────────────────────────────────────────────────────────────────────────────


private fun String?.jn(): JsonElement = if (this == null) JsonNull else JsonPrimitive(this)

/** One collection's flattened membership as uploaded (ids only — NEVER a name). */
data class ListeningPocketsCollectionWire(
    val id: String,
    /** pocket | playlist | source */
    val kind: String,
    val songIds: List<String>,
    /** When each CURRENT member was last added (unknowns omitted). */
    val adds: List<Add>,
) {
    data class Add(val songId: String, val atMs: Long)

    fun toJson(): JsonObject = JsonObject(
        linkedMapOf(
            "id" to JsonPrimitive(id),
            "kind" to JsonPrimitive(kind),
            "songIds" to JsonArray(songIds.map { JsonPrimitive(it) }),
            "adds" to JsonArray(adds.map {
                JsonObject(linkedMapOf("songId" to JsonPrimitive(it.songId), "atMs" to JsonPrimitive(it.atMs)))
            }),
        ),
    )
}

/** One song-level add/remove. */
data class ListeningPocketsAddEventWire(
    val songId: String,
    val collectionId: String,
    val atMs: Long,
    /** add | remove */
    val kind: String,
) {
    fun toJson(): JsonObject = JsonObject(
        linkedMapOf(
            "songId" to JsonPrimitive(songId),
            "collectionId" to JsonPrimitive(collectionId),
            "atMs" to JsonPrimitive(atMs),
            "kind" to JsonPrimitive(kind),
        ),
    )
}

fun ListeningPocketsPlaceWire.toJson(): JsonObject {
    val m = linkedMapOf<String, JsonElement>(
        "id" to JsonPrimitive(id), "rank" to JsonPrimitive(rank), "label" to JsonPrimitive(label),
    )
    share?.let { m["share"] = JsonPrimitive(it) }
    return JsonObject(m)
}

/** `destination` is nullable on the wire (explicit null); `occurrences` omitted when nil. */
fun ListeningPocketsTripWire.toJson(): JsonObject {
    val m = linkedMapOf<String, JsonElement>(
        "id" to JsonPrimitive(id), "origin" to JsonPrimitive(origin),
        "destination" to destination.jn(), "label" to JsonPrimitive(label),
    )
    occurrences?.let { m["occurrences"] = JsonPrimitive(it) }
    return JsonObject(m)
}

/** One play as uploaded. */
data class ListeningPocketsUploadEvent(
    val id: String,
    val songId: String,
    /** Play START, epoch ms FLOORED to the minute (see [floorToMinute]). */
    val atMs: Long,
    /** Order among plays sharing `atMs` + stream (originInstallId ?: installId). */
    val ord: Int,
    val tzOffsetMin: Int?,
    val source: String?,
    /** completed | skipped | partial | unknown */
    val outcome: String,
    val fraction: Double?,
    val originInstallId: String?,
    val artist: String?,
    val carPlay: Boolean?,
    val ctx: ListeningContextTag?,
    /** Opaque collection id the play started from + its kind (pocket|playlist|setlist|source). */
    val contextId: String? = null,
    val contextKind: String? = null,
) {
    fun toJson(): JsonObject {
        val m = linkedMapOf<String, JsonElement>()
        m["id"] = JsonPrimitive(id)
        m["songId"] = JsonPrimitive(songId)
        m["atMs"] = JsonPrimitive(atMs)
        m["ord"] = JsonPrimitive(ord)
        m["tzOffsetMin"] = tzOffsetMin?.let { JsonPrimitive(it) } ?: JsonNull
        m["source"] = source.jn()
        m["outcome"] = JsonPrimitive(outcome)
        m["fraction"] = fraction?.let { JsonPrimitive(it) } ?: JsonNull
        m["originInstallId"] = originInstallId.jn()
        m["artist"] = artist.jn()
        m["carPlay"] = carPlay?.let { JsonPrimitive(it) } ?: JsonNull
        m["ctx"] = ctx?.toJson() ?: JsonNull   // only the ids the kind uses
        if (contextId != null && contextKind != null) {
            m["contextId"] = JsonPrimitive(contextId)
            m["contextKind"] = JsonPrimitive(contextKind)
        }
        return JsonObject(m)
    }

    companion object {
        /** Coarse time on the wire: floor epoch ms to the minute. */
        fun floorToMinute(ms: Long): Long = Math.floorDiv(ms, 60_000L) * 60_000L
    }
}

/** `POST /pockets/events` body. */
data class ListeningPocketsUploadBatch(
    val deviceId: String?,
    val installId: String,
    val sentAtMs: Long,
    val events: List<ListeningPocketsUploadEvent>,
    /** Only while location is ACTIVE; omitted otherwise. */
    val places: List<ListeningPocketsPlaceWire>? = null,
    val trips: List<ListeningPocketsTripWire>? = null,
    /** Membership snapshot (ids only) — rides its OWN batch (`events: []`). */
    val collections: List<ListeningPocketsCollectionWire>? = null,
    val addEvents: List<ListeningPocketsAddEventWire>? = null,
    val v: Int = 1,
) {
    fun toJson(): JsonObject {
        val m = linkedMapOf<String, JsonElement>()
        m["v"] = JsonPrimitive(v)
        deviceId?.let { m["deviceId"] = JsonPrimitive(it) }
        m["installId"] = JsonPrimitive(installId)
        m["sentAtMs"] = JsonPrimitive(sentAtMs)
        m["events"] = JsonArray(events.map { it.toJson() })
        places?.let { p -> m["places"] = JsonArray(p.map { it.toJson() }) }
        trips?.let { t -> m["trips"] = JsonArray(t.map { it.toJson() }) }
        collections?.let { c -> m["collections"] = JsonArray(c.map { it.toJson() }) }
        addEvents?.let { a -> m["addEvents"] = JsonArray(a.map { it.toJson() }) }
        return JsonObject(m)
    }
}

/** `200 {"ok":true,"accepted":…}` — every count optional (only the 2xx matters to the client). */
data class ListeningPocketsUploadResponse(
    val ok: Boolean? = null,
    val accepted: Int? = null,
    val updated: Int? = null,
    val unchanged: Int? = null,
    val rejected: Int? = null,
    val total: Int? = null,
    val dirty: Boolean? = null,
) {
    companion object {
        fun parse(e: JsonElement?): ListeningPocketsUploadResponse {
            val o = e as? JsonObject ?: return ListeningPocketsUploadResponse()
            return ListeningPocketsUploadResponse(
                ok = o.lpBool("ok"), accepted = o.lpInt("accepted"), updated = o.lpInt("updated"),
                unchanged = o.lpInt("unchanged"), rejected = o.lpInt("rejected"),
                total = o.lpInt("total"), dirty = o.lpBool("dirty"),
            )
        }
    }
}

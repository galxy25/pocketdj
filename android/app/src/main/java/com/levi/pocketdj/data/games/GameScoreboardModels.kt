package com.levi.pocketdj.data.games

import java.util.UUID
import kotlinx.serialization.Serializable
import kotlinx.serialization.json.Json
import kotlinx.serialization.json.JsonArray
import kotlinx.serialization.json.JsonElement
import kotlinx.serialization.json.JsonObject
import kotlinx.serialization.json.JsonPrimitive
import kotlinx.serialization.json.contentOrNull
import kotlinx.serialization.json.doubleOrNull
import kotlinx.serialization.json.intOrNull

const val GAME_SCOREBOARD_SCHEMA_VERSION = 1

/**
 * One finished run. [game] stays a STRING on the wire (a newer build's unknown game kind must
 * never break an older build's decode). [id] is an uppercase UUID string (iOS shape); [at] is
 * epoch ms.
 */
@Serializable
data class RunRecord(
    val id: String,
    val game: String,
    val score: Int,
    val at: Double,
    val settingsSummary: String? = null,
    val detail: Map<String, String>? = null,
    val originInstallId: String? = null,
)

/**
 * A DELETED run, by id. [at] orders EVICTION only; it is never a merge tie-break beyond
 * "earliest wins" (a tombstone is a fact, not a value).
 */
@Serializable
data class Tombstone(
    val id: String,
    val at: Double,
    val byInstallId: String? = null,
)

/** On-disk document. `deleted` is omitted when null (store with no deletions = pre-tombstone bytes). */
@Serializable
data class ScoreboardDocument(
    val schemaVersion: Int = GAME_SCOREBOARD_SCHEMA_VERSION,
    val installId: String,
    val runs: List<RunRecord> = emptyList(),
    val deleted: List<Tombstone>? = null,
)

/** "In the Pocket" stats derived from the run log. */
data class InThePocketStats(
    val rounds: Int,
    val pockets: Int,
    val pocketRate: Double?,
    val bestStreak: Int,
    val currentStreak: Int,
) {
    /** "12 rounds · 58% in the pocket · best streak 3". */
    fun summary(): String {
        if (rounds <= 0) return "No rounds yet"
        val parts = mutableListOf("$rounds round${if (rounds == 1) "" else "s"}")
        pocketRate?.let { parts += "${Math.round(it * 100)}% in the pocket" }
        parts += "best streak $bestStreak"
        return parts.joinToString(" · ")
    }
}

/** Pure helpers: lenient decode and the union merge, kept free of IO so they unit-test directly. */
object ScoreboardCodec {
    private val UUID_RE = Regex("^[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}$")

    val json: Json = Json {
        ignoreUnknownKeys = true
        explicitNulls = false
        encodeDefaults = true
    }

    fun newId(): String = UUID.randomUUID().toString().uppercase()

    fun encode(doc: ScoreboardDocument): String = json.encodeToString(ScoreboardDocument.serializer(), doc)

    /**
     * Lenient decode: a malformed document is null; a per-element corrupt run or tombstone is
     * dropped, the rest load. A non-array `runs`/`deleted` reads as empty (iOS `try?` doctrine).
     */
    fun decode(text: String): ScoreboardDocument? {
        val root = runCatching { json.parseToJsonElement(text) as? JsonObject }.getOrNull() ?: return null
        val version = (root["schemaVersion"] as? JsonPrimitive)?.takeIf { !it.isString }?.intOrNull
            ?: GAME_SCOREBOARD_SCHEMA_VERSION
        val install = (root["installId"] as? JsonPrimitive)?.takeIf { it.isString }?.contentOrNull
            ?: newId()
        val runs = (root["runs"] as? JsonArray).orEmpty().mapNotNull { decodeRun(it) }
        val deleted = (root["deleted"] as? JsonArray).orEmpty().mapNotNull { decodeTombstone(it) }
        return ScoreboardDocument(version, install, runs, deleted.ifEmpty { null })
    }

    private fun JsonArray?.orEmpty(): List<JsonElement> = this?.toList() ?: emptyList()

    private fun validId(el: JsonElement?): String? =
        (el as? JsonPrimitive)?.takeIf { it.isString }?.content?.takeIf { UUID_RE.matches(it) }

    private fun decodeRun(el: JsonElement): RunRecord? {
        val o = el as? JsonObject ?: return null
        val id = validId(o["id"]) ?: return null
        val game = (o["game"] as? JsonPrimitive)?.takeIf { it.isString }?.content ?: return null
        val score = (o["score"] as? JsonPrimitive)?.takeIf { !it.isString }?.intOrNull ?: return null
        val at = (o["at"] as? JsonPrimitive)?.takeIf { !it.isString }?.doubleOrNull ?: return null
        val summary = optString(o, "settingsSummary") ?: if (o["settingsSummary"].isBad()) return null else null
        val origin = optString(o, "originInstallId") ?: if (o["originInstallId"].isBad()) return null else null
        var detail: Map<String, String>? = null
        when (val d = o["detail"]) {
            null -> Unit
            is JsonObject -> {
                if (d.isEmpty()) {
                    detail = emptyMap()
                } else {
                    val m = LinkedHashMap<String, String>()
                    for ((k, v) in d) {
                        val p = v as? JsonPrimitive ?: return null
                        if (!p.isString) return null
                        m[k] = p.content
                    }
                    detail = m
                }
            }
            is JsonPrimitive -> if (d.contentOrNull != null) return null
            else -> return null
        }
        return RunRecord(id.uppercase(), game, score, at, summary, detail, origin)
    }

    private fun decodeTombstone(el: JsonElement): Tombstone? {
        val o = el as? JsonObject ?: return null
        val id = validId(o["id"]) ?: return null
        val at = (o["at"] as? JsonPrimitive)?.takeIf { !it.isString }?.doubleOrNull ?: return null
        val by = optString(o, "byInstallId") ?: if (o["byInstallId"].isBad()) return null else null
        return Tombstone(id.uppercase(), at, by)
    }

    private fun optString(o: JsonObject, key: String): String? =
        (o[key] as? JsonPrimitive)?.takeIf { it.isString }?.content

    /** Present, non-null and not a string: a type mismatch that drops the row (Swift `String?`). */
    private fun JsonElement?.isBad(): Boolean =
        this != null && !(this is JsonPrimitive && this.contentOrNull == null)

    /**
     * Union tombstones by id (earliest `at` wins), oldest-first by (at, id), capped at
     * [GameScoreboardStore.MAX_TOMBSTONES] (oldest evicted first).
     */
    fun unionTombstones(incoming: List<Tombstone>): List<Tombstone> {
        val byId = LinkedHashMap<String, Tombstone>()
        for (t in incoming) {
            val key = t.id.uppercase()
            val have = byId[key]
            if (have == null || t.at < have.at) byId[key] = t.copy(id = key)
        }
        val merged = byId.values.sortedWith(compareBy<Tombstone>({ it.at }, { it.id }))
        return if (merged.size > GameScoreboardStore.MAX_TOMBSTONES) {
            merged.subList(merged.size - GameScoreboardStore.MAX_TOMBSTONES, merged.size).toList()
        } else {
            merged
        }
    }
}

package com.levi.pocketdj.data.games.puzzle

import com.levi.pocketdj.screens.browse.Genre
import kotlinx.serialization.KSerializer
import kotlinx.serialization.Serializable
import kotlinx.serialization.descriptors.SerialDescriptor
import kotlinx.serialization.encoding.Decoder
import kotlinx.serialization.encoding.Encoder
import kotlinx.serialization.json.Json
import kotlinx.serialization.json.JsonArray
import kotlinx.serialization.json.JsonElement
import kotlinx.serialization.json.JsonNull
import kotlinx.serialization.json.JsonObject
import kotlinx.serialization.json.JsonPrimitive
import kotlinx.serialization.json.buildJsonObject
import kotlinx.serialization.json.contentOrNull
import kotlinx.serialization.json.int
import kotlinx.serialization.json.put

/**
 * The Gem Collector round configuration — filters, weighting, and the 0–3 target
 * collections. Port of iOS `PuzzleSettings`. Every field decodes leniently (absent,
 * null or wrong-typed ⇒ the default) so a blob written by any build always loads;
 * unknown keys are ignored. Wire tokens are the iOS raw values and never rename.
 */
@Serializable(with = PuzzleSettingsSerializer::class)
data class PuzzleSettings(
    /** 60 / 120 / 180 / 300. */
    val roundSeconds: Int = 120,
    /** LIFETIME plays only; favor = most-played up-weighted, avoid = never/least-played. */
    val playCountBias: Bias = Bias.OFF,
    /** favor = recently-played up-weighted; avoid = long-unplayed/never-played. */
    val recencyBias: Bias = Bias.OFF,
    /** favor = ♥ up-weighted; avoid = non-♥ up-weighted. */
    val favoriteBias: Bias = Bias.OFF,
    /** Empty = all genres; else HARD filter to these `Genre.category` names. */
    val genreCategories: Set<String> = emptySet(),
    /** HARD year filter when set (nil-year songs drop only when a bound is set). */
    val yearMin: Int? = null,
    val yearMax: Int? = null,
    val membershipMode: MembershipMode = MembershipMode.OFF,
    /** pls_/pkt_ ids. */
    val membershipCollectionIds: Set<String> = emptySet(),
    /** 0–3 target collections; order = assign-button order. */
    val targetCollectionIds: List<String> = emptyList(),
    /** Ignored when there are no targets. */
    val similarity: Similarity = Similarity.ON,
) {
    enum class Bias(val wire: String) { OFF("off"), FAVOR("favor"), AVOID("avoid") }

    enum class MembershipMode(val wire: String) {
        OFF("off"), IN_ANY("inAny"), NOT_IN_ANY("notInAny")
    }

    enum class Similarity(val wire: String) { OFF("off"), ON("on"), STRICT("strict") }

    /** mm:ss render of the round length ("2:00"). */
    val roundLengthLabel: String
        get() = "%d:%02d".format(roundSeconds / 60, roundSeconds % 60)

    /** One-line human summary for the scoreboard: "2:00 · ♥ favor · hip-hop · 1990–1999 · 3 targets". */
    val summaryLine: String
        get() {
            val parts = mutableListOf(roundLengthLabel)
            when (favoriteBias) {
                Bias.FAVOR -> parts += "♥ favor"
                Bias.AVOID -> parts += "♥ avoid"
                Bias.OFF -> Unit
            }
            when (playCountBias) {
                Bias.FAVOR -> parts += "most played"
                Bias.AVOID -> parts += "least played"
                Bias.OFF -> Unit
            }
            // A SEPARATE clause: "most played" and "recently played" are different claims.
            when (recencyBias) {
                Bias.FAVOR -> parts += "recently played"
                Bias.AVOID -> parts += "not played lately"
                Bias.OFF -> Unit
            }
            if (genreCategories.isNotEmpty()) {
                parts += genreCategories.sortedBy { Genre.order(it) }.joinToString("+")
            }
            val lo = yearMin
            val hi = yearMax
            when {
                lo != null && hi != null -> parts += "$lo–$hi"
                lo != null -> parts += "$lo+"
                hi != null -> parts += "–$hi"
            }
            when (membershipMode) {
                MembershipMode.IN_ANY -> parts += "in ${membershipCollectionIds.size}"
                MembershipMode.NOT_IN_ANY -> parts += "not-in ${membershipCollectionIds.size}"
                MembershipMode.OFF -> Unit
            }
            // Targets are OPTIONAL: no targets = the free-file mode.
            when (val n = targetCollectionIds.size) {
                0 -> parts += "free file"
                1 -> parts += "1 target"
                else -> parts += "$n targets"
            }
            if (targetCollectionIds.isNotEmpty()) {
                when (similarity) {
                    Similarity.STRICT -> parts += "similar+"
                    Similarity.OFF -> parts += "any"
                    Similarity.ON -> Unit
                }
            }
            return parts.joinToString(" · ")
        }

    /** Encode to the iOS-shaped JSON string. */
    fun toJson(json: Json = Json): String = json.encodeToString(PuzzleSettingsSerializer, this)

    companion object {
        /** Lenient decode of a stored blob; never throws (garbage ⇒ defaults). */
        fun fromJson(text: String?, json: Json = Json): PuzzleSettings {
            if (text.isNullOrBlank()) return PuzzleSettings()
            return runCatching { json.decodeFromString(PuzzleSettingsSerializer, text) }
                .getOrDefault(PuzzleSettings())
        }
    }
}

/** Per-field lenient (de)serializer — the Kotlin form of iOS's `try? c.decode(...) ?? default`. */
object PuzzleSettingsSerializer : KSerializer<PuzzleSettings> {
    override val descriptor: SerialDescriptor = JsonElement.serializer().descriptor

    override fun serialize(encoder: Encoder, value: PuzzleSettings) {
        val obj = buildJsonObject {
            put("roundSeconds", value.roundSeconds)
            put("playCountBias", value.playCountBias.wire)
            put("recencyBias", value.recencyBias.wire)
            put("favoriteBias", value.favoriteBias.wire)
            put("genreCategories", JsonArray(value.genreCategories.sorted().map { JsonPrimitive(it) }))
            value.yearMin?.let { put("yearMin", it) }
            value.yearMax?.let { put("yearMax", it) }
            put("membershipMode", value.membershipMode.wire)
            put("membershipCollectionIds",
                JsonArray(value.membershipCollectionIds.sorted().map { JsonPrimitive(it) }))
            put("targetCollectionIds", JsonArray(value.targetCollectionIds.map { JsonPrimitive(it) }))
            put("similarity", value.similarity.wire)
        }
        encoder.encodeSerializableValue(JsonElement.serializer(), obj)
    }

    override fun deserialize(decoder: Decoder): PuzzleSettings {
        val el = decoder.decodeSerializableValue(JsonElement.serializer())
        val o = el as? JsonObject ?: return PuzzleSettings()
        val d = PuzzleSettings()
        return PuzzleSettings(
            roundSeconds = int(o["roundSeconds"]) ?: d.roundSeconds,
            playCountBias = enumOf(o["playCountBias"], PuzzleSettings.Bias.entries, { it.wire }) ?: d.playCountBias,
            recencyBias = enumOf(o["recencyBias"], PuzzleSettings.Bias.entries, { it.wire }) ?: d.recencyBias,
            favoriteBias = enumOf(o["favoriteBias"], PuzzleSettings.Bias.entries, { it.wire }) ?: d.favoriteBias,
            genreCategories = strings(o["genreCategories"])?.toSet() ?: d.genreCategories,
            yearMin = int(o["yearMin"]),
            yearMax = int(o["yearMax"]),
            membershipMode = enumOf(o["membershipMode"], PuzzleSettings.MembershipMode.entries, { it.wire })
                ?: d.membershipMode,
            membershipCollectionIds = strings(o["membershipCollectionIds"])?.toSet() ?: d.membershipCollectionIds,
            targetCollectionIds = strings(o["targetCollectionIds"]) ?: d.targetCollectionIds,
            // Lenient decode IS the migration: a pre-similarity blob decodes to ON.
            similarity = enumOf(o["similarity"], PuzzleSettings.Similarity.entries, { it.wire }) ?: d.similarity,
        )
    }

    private fun int(e: JsonElement?): Int? {
        val p = e as? JsonPrimitive ?: return null
        if (p is JsonNull || p.isString) return null
        return runCatching { p.int }.getOrNull()
    }

    private fun strings(e: JsonElement?): List<String>? {
        val arr = e as? JsonArray ?: return null
        val out = ArrayList<String>(arr.size)
        for (x in arr) {
            val p = x as? JsonPrimitive ?: return null
            if (p is JsonNull || !p.isString) return null
            out += p.contentOrNull ?: return null
        }
        return out
    }

    private fun <E> enumOf(e: JsonElement?, all: List<E>, wire: (E) -> String): E? {
        val p = e as? JsonPrimitive ?: return null
        if (p is JsonNull || !p.isString) return null
        val s = p.contentOrNull ?: return null
        return all.firstOrNull { wire(it) == s }
    }
}

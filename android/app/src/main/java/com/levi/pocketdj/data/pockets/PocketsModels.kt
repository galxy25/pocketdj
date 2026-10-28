package com.levi.pocketdj.data.pockets

import kotlinx.serialization.Serializable
import kotlinx.serialization.json.Json
import kotlinx.serialization.json.JsonArray
import kotlinx.serialization.json.JsonElement
import kotlinx.serialization.json.JsonNull
import kotlinx.serialization.json.JsonObject
import kotlinx.serialization.json.JsonPrimitive
import kotlinx.serialization.json.booleanOrNull
import kotlinx.serialization.json.doubleOrNull
import kotlinx.serialization.json.longOrNull

// ─────────────────────────────────────────────────────────────────────────────────────────────
// LISTENING POCKETS — wire types for `GET /pockets/results` (results v1). Port of
// apple/PocketDJ/Services/ListeningPockets/ListeningPocketsModels.swift (results half).
//
// Decoding is LENIENT by contract: a bad ARRAY ELEMENT is dropped (never the document), numbers
// may be integral or not (`3.0` reads as an Int), unknown keys are ignored, an unknown feature
// `dim` stays a raw string, a numeric map drops its bad keys one by one, and a missing `rounds`
// section means no round learning. Hand-walked over JsonElement (not @Serializable) because the
// rules are per-field/per-element, exactly the iOS `lp*` helpers.
// ─────────────────────────────────────────────────────────────────────────────────────────────

/** `place` / `trip` / `none` — the opaque listening-context tag stamped on plays and rounds. */
@Serializable
data class ListeningContextTag(
    val kind: String = KIND_NONE,
    val placeId: String? = null,
    val tripId: String? = null,
    val origin: String? = null,
    val destination: String? = null,
) {
    val isPlace: Boolean get() = kind == KIND_PLACE && placeId != null
    val isTrip: Boolean get() = kind == KIND_TRIP && tripId != null && origin != null

    /** Wire shape: only the ids the kind uses (never an empty id the server rejects). */
    fun toJson(): JsonObject = JsonObject(buildMap {
        put("kind", JsonPrimitive(kind))
        placeId?.let { put("placeId", JsonPrimitive(it)) }
        tripId?.let { put("tripId", JsonPrimitive(it)) }
        origin?.let { put("origin", JsonPrimitive(it)) }
        destination?.let { put("destination", JsonPrimitive(it)) }
    })

    companion object {
        const val KIND_PLACE = "place"
        const val KIND_TRIP = "trip"
        const val KIND_NONE = "none"
        val NONE = ListeningContextTag(KIND_NONE)
        fun place(id: String) = ListeningContextTag(KIND_PLACE, placeId = id)
        fun trip(id: String, origin: String, destination: String?) =
            ListeningContextTag(KIND_TRIP, tripId = id, origin = origin, destination = destination)

        /** Lenient decode (kind falls back to none, bad id fields to null). null for a non-object. */
        fun fromJson(e: JsonElement?): ListeningContextTag? {
            val o = e as? JsonObject ?: return null
            return ListeningContextTag(
                kind = o.lpString("kind") ?: KIND_NONE,
                placeId = o.lpString("placeId"), tripId = o.lpString("tripId"),
                origin = o.lpString("origin"), destination = o.lpString("destination"),
            )
        }
    }
}

/** The one-place wire place label (the cloud titles pockets with it). */
data class ListeningPocketsPlaceWire(val id: String, val rank: Int, val label: String, val share: Double?)

data class ListeningPocketsTripWire(
    val id: String, val origin: String, val destination: String?, val label: String, val occurrences: Int?,
)

/** The dimensions the analysis can call DEFINING; an open set (unknown stays a raw string). */
enum class ListeningPocketDim(val raw: String) {
    ARTIST("artist"), GENRE("genre"), MOOD("mood"), CAMELOT("camelot"), SOURCE("source"),
    TIME_BUCKET("timeBucket"), DAY_TYPE("dayType"), DOW("dow"), PLACE("place"), TRIP("trip"),
    CAR_PLAY("carPlay"), COLLECTION("collection"), PLAY_CONTEXT("playContext");

    val isMusical: Boolean get() = this == ARTIST || this == GENRE || this == MOOD || this == CAMELOT

    companion object {
        fun of(raw: String): ListeningPocketDim? = entries.firstOrNull { it.raw == raw }
    }
}

data class ListeningPocketFeature(
    val dim: String, val value: String, val label: String, val share: Double,
    val baselineShare: Double? = null, val lift: Double, val score: Double, val count: Int? = null,
) {
    val kind: ListeningPocketDim? get() = ListeningPocketDim.of(dim)

    /** The location tag this feature names (place / trip), for on-device re-labelling. */
    val contextTag: ListeningContextTag?
        get() = when (kind) {
            ListeningPocketDim.PLACE -> ListeningContextTag.place(value)
            ListeningPocketDim.TRIP -> ListeningContextTag(ListeningContextTag.KIND_TRIP, tripId = value)
            else -> null
        }

    companion object {
        fun parse(e: JsonElement): ListeningPocketFeature? {
            val o = e as? JsonObject ?: return null
            val dim = o.lpString("dim") ?: return null
            val value = o.lpString("value") ?: return null
            return ListeningPocketFeature(
                dim, value, o.lpString("label") ?: value, o.lpDouble("share") ?: 0.0,
                o.lpDouble("baselineShare"), o.lpDouble("lift") ?: 1.0, o.lpDouble("score") ?: 0.0, o.lpInt("count"),
            )
        }
    }
}

/** A numeric dimension (bpm / energy / year): the pocket's range vs the baseline spread. */
data class ListeningPocketNumeric(
    val center: Double, val lo: Double, val hi: Double, val coverage: Double,
    val dispersionRatio: Double?, val baselineCenter: Double?, val defining: Boolean,
) {
    companion object {
        fun parse(e: JsonElement): ListeningPocketNumeric? {
            val o = e as? JsonObject ?: return null
            val center = o.lpDouble("center") ?: return null
            return ListeningPocketNumeric(
                center, o.lpDouble("lo") ?: center, o.lpDouble("hi") ?: center, o.lpDouble("coverage") ?: 0.0,
                o.lpDouble("dispersionRatio"), o.lpDouble("baselineCenter"), o.lpBool("defining") ?: false,
            )
        }
    }
}

data class ListeningPocketHarmonic(val rate: Double, val baselineRate: Double?, val pairs: Int?, val defining: Boolean) {
    companion object {
        fun parse(e: JsonElement?): ListeningPocketHarmonic? {
            val o = e as? JsonObject ?: return null
            val rate = o.lpDouble("rate") ?: return null
            return ListeningPocketHarmonic(rate, o.lpDouble("baselineRate"), o.lpInt("pairs"), o.lpBool("defining") ?: false)
        }
    }
}

data class ListeningPocketMember(val eventId: String, val songId: String, val atMs: Double, val outcome: String?) {
    companion object {
        fun parse(e: JsonElement): ListeningPocketMember? {
            val o = e as? JsonObject ?: return null
            val songId = o.lpString("songId") ?: return null
            return ListeningPocketMember(o.lpString("eventId") ?: "", songId, o.lpDouble("atMs") ?: 0.0, o.lpString("outcome"))
        }
    }
}

/** One entry of a membership vector: an opaque collection id and its weight. */
data class ListeningPocketMembershipWeight(val collectionId: String, val weight: Double) {
    companion object {
        fun parse(e: JsonElement): ListeningPocketMembershipWeight? {
            val o = e as? JsonObject ?: return null
            val id = o.lpString("collectionId") ?: return null
            val w = o.lpDouble("weight") ?: return null
            return ListeningPocketMembershipWeight(id, w)
        }
    }
}

/** A pattern's collection candidate: a song the pattern's collections suggest. */
data class ListeningPocketCollectionCandidate(val songId: String, val score: Double, val via: List<String> = emptyList()) {
    companion object {
        fun parse(e: JsonElement): ListeningPocketCollectionCandidate? {
            val o = e as? JsonObject ?: return null
            val id = o.lpString("songId") ?: return null
            return ListeningPocketCollectionCandidate(id, o.lpDouble("score") ?: 0.0, o.lpArray("via") { (it as? JsonPrimitive)?.takeIf { p -> p.isString }?.content })
        }
    }
}

/** One detected pocket: ≥3 un-skipped plays in a row, and what defines them. */
data class ListeningPocket(
    val id: String,
    val startMs: Double,
    val endMs: Double,
    val tzOffsetMin: Int?,
    val localDate: String?,
    val localStartHour: Double?,
    val dow: Int?,
    val dayType: String?,
    val timeBucket: String?,
    val installId: String?,
    val memberCount: Int,
    val skippedCount: Int,
    val sessionPlays: Int?,
    val members: List<ListeningPocketMember>,
    val ctx: ListeningContextTag?,
    val features: List<ListeningPocketFeature>,
    val numeric: Map<String, ListeningPocketNumeric>,
    val harmonic: ListeningPocketHarmonic?,
    val title: String,
    val patternId: String?,
    /** M(P): the pocket's collection-membership vector (top 12, desc). Empty from older servers. */
    val membership: List<ListeningPocketMembershipWeight> = emptyList(),
) {
    /** Member song ids in play order. */
    val songIds: List<String> get() = members.map { it.songId }

    companion object {
        fun parse(e: JsonElement): ListeningPocket? {
            val o = e as? JsonObject ?: return null
            val id = o.lpString("id") ?: return null
            val start = o.lpDouble("startMs") ?: 0.0
            val members = o.lpArray("members", ListeningPocketMember::parse)
            return ListeningPocket(
                id = id, startMs = start, endMs = o.lpDouble("endMs") ?: start,
                tzOffsetMin = o.lpInt("tzOffsetMin"), localDate = o.lpString("localDate"),
                localStartHour = o.lpDouble("localStartHour"), dow = o.lpInt("dow"),
                dayType = o.lpString("dayType"), timeBucket = o.lpString("timeBucket"),
                installId = o.lpString("installId"),
                memberCount = o.lpInt("memberCount") ?: members.size,
                skippedCount = o.lpInt("skippedCount") ?: 0,
                sessionPlays = o.lpInt("sessionPlays"), members = members,
                ctx = o.lpContext("ctx"),
                features = o.lpArray("features", ListeningPocketFeature::parse),
                numeric = o.lpNumericMap("numeric"),
                harmonic = ListeningPocketHarmonic.parse(o["harmonic"]),
                title = o.lpString("title") ?: "Listening pocket",
                patternId = o.lpString("patternId"),
                membership = o.lpArray("membership", ListeningPocketMembershipWeight::parse),
            )
        }
    }
}

/** A recurring pocket: pockets that share day type, time bucket, context and genre across days. */
data class ListeningPocketPattern(
    val id: String,
    val key: String,
    val title: String,
    val pocketIds: List<String>,
    val occurrences: Int,
    val distinctDays: Int,
    val firstMs: Double?,
    val lastMs: Double?,
    val dayType: String?,
    val timeBucket: String?,
    val ctx: ListeningContextTag?,
    val features: List<ListeningPocketFeature>,
    val numeric: Map<String, ListeningPocketNumeric>,
    val harmonic: ListeningPocketHarmonic?,
    val topSongs: List<TopSong>,
    val membership: List<ListeningPocketMembershipWeight> = emptyList(),
    /** Songs from the pattern's collections that are NOT in `topSongs` (≤ 40). */
    val collectionCandidates: List<ListeningPocketCollectionCandidate> = emptyList(),
) {
    data class TopSong(val songId: String, val plays: Int) {
        companion object {
            fun parse(e: JsonElement): TopSong? {
                val o = e as? JsonObject ?: return null
                val id = o.lpString("songId") ?: return null
                return TopSong(id, o.lpInt("plays") ?: 0)
            }
        }
    }

    val songIds: List<String> get() = topSongs.map { it.songId }

    companion object {
        fun parse(e: JsonElement): ListeningPocketPattern? {
            val o = e as? JsonObject ?: return null
            val id = o.lpString("id") ?: return null
            val pocketIds = o.lpArray("pocketIds") { (it as? JsonPrimitive)?.takeIf { p -> p.isString }?.content }
            val occurrences = o.lpInt("occurrences") ?: pocketIds.size
            return ListeningPocketPattern(
                id = id, key = o.lpString("key") ?: id, title = o.lpString("title") ?: "Recurring pocket",
                pocketIds = pocketIds, occurrences = occurrences, distinctDays = o.lpInt("distinctDays") ?: occurrences,
                firstMs = o.lpDouble("firstMs"), lastMs = o.lpDouble("lastMs"),
                dayType = o.lpString("dayType"), timeBucket = o.lpString("timeBucket"),
                ctx = o.lpContext("ctx"),
                features = o.lpArray("features", ListeningPocketFeature::parse),
                numeric = o.lpNumericMap("numeric"),
                harmonic = ListeningPocketHarmonic.parse(o["harmonic"]),
                topSongs = o.lpArray("topSongs", TopSong::parse),
                membership = o.lpArray("membership", ListeningPocketMembershipWeight::parse),
                collectionCandidates = o.lpArray("collectionCandidates", ListeningPocketCollectionCandidate::parse),
            )
        }
    }
}

/**
 * The `rounds` section of results: how "In the Pocket" rounds have gone, and per context which
 * scorer targets predicted well (multiplier > 1) or badly (< 1).
 */
data class ListeningPocketsRoundLearning(
    val total: Int = 0, val pocket: Int = 0, val broke: Int = 0, val abandoned: Int = 0,
    val pocketRate: Double? = null, val contexts: List<Context>,
) {
    data class Context(val key: String, val rounds: Int, val weights: List<Weight>) {
        companion object {
            fun parse(e: JsonElement): Context? {
                val o = e as? JsonObject ?: return null
                val key = o.lpString("key") ?: return null
                return Context(key, o.lpInt("rounds") ?: 0, o.lpArray("weights", Weight::parse))
            }
        }
    }

    data class Weight(val dim: String, val value: String, val pos: Int, val neg: Int, val multiplier: Double) {
        companion object {
            fun parse(e: JsonElement): Weight? {
                val o = e as? JsonObject ?: return null
                val dim = o.lpString("dim") ?: return null
                val value = o.lpString("value") ?: return null
                val m = o.lpDouble("multiplier") ?: return null
                return Weight(dim, value, o.lpInt("pos") ?: 0, o.lpInt("neg") ?: 0, m)
            }
        }
    }

    companion object {
        fun parse(e: JsonElement?): ListeningPocketsRoundLearning? {
            val o = e as? JsonObject ?: return null
            return ListeningPocketsRoundLearning(
                total = o.lpInt("total") ?: 0, pocket = o.lpInt("pocket") ?: 0, broke = o.lpInt("broke") ?: 0,
                abandoned = o.lpInt("abandoned") ?: 0, pocketRate = o.lpDouble("pocketRate"),
                contexts = o.lpArray("contexts", Context::parse),
            )
        }
    }
}

/** `GET /pockets/results`. A profile with no state is the EMPTY shape (`generatedAtMs == null`). */
data class ListeningPocketsResults(
    val v: Int,
    val generatedAtMs: Double?,
    /** Events changed since this compute (a recompute is queued). */
    val stale: Boolean,
    val algoVersion: Int?,
    val baseline: Baseline?,
    val labels: Labels?,
    val pockets: List<ListeningPocket>,
    val patterns: List<ListeningPocketPattern>,
    /** Present only once the profile has played the game; null ⇒ no round learning. */
    val roundLearning: ListeningPocketsRoundLearning? = null,
    val collectionsSeen: Int? = null,
) {
    data class Baseline(val plays: Int?, val windowDays: Double?, val thin: Boolean?)

    /** The label snapshot the server last received (echo). */
    data class Labels(val places: List<ListeningPocketsPlaceWire>, val trips: List<ListeningPocketsTripWire>)

    /** Server-side label for a place/trip id (the uploaded snapshot), if it has one. */
    fun snapshotLabel(tag: ListeningContextTag): String? {
        if (tag.kind == ListeningContextTag.KIND_PLACE && tag.placeId != null) {
            return labels?.places?.firstOrNull { it.id == tag.placeId }?.label
        }
        if (tag.kind == ListeningContextTag.KIND_TRIP && tag.tripId != null) {
            return labels?.trips?.firstOrNull { it.id == tag.tripId }?.label
        }
        return null
    }

    companion object {
        val EMPTY = ListeningPocketsResults(1, null, false, null, null, null, emptyList(), emptyList())

        /** null when the document is not even a JSON object (the iOS decode throws). */
        fun parse(json: String): ListeningPocketsResults? =
            runCatching { fromElement(Json.parseToJsonElement(json)) }.getOrNull()

        fun fromElement(e: JsonElement): ListeningPocketsResults? {
            val o = e as? JsonObject ?: return null
            return ListeningPocketsResults(
                v = o.lpInt("v") ?: 1,
                generatedAtMs = o.lpDouble("generatedAtMs"),
                stale = o.lpBool("stale") ?: false,
                algoVersion = (o["algo"] as? JsonObject)?.lpInt("version"),
                baseline = (o["baseline"] as? JsonObject)?.let {
                    Baseline(it.lpInt("plays"), it.lpDouble("windowDays"), it.lpBool("thin"))
                },
                labels = (o["labels"] as? JsonObject)?.let {
                    Labels(
                        it.lpArray("places") { p -> parsePlaceWire(p) },
                        it.lpArray("trips") { t -> parseTripWire(t) },
                    )
                },
                pockets = o.lpArray("pockets", ListeningPocket::parse),
                patterns = o.lpArray("patterns", ListeningPocketPattern::parse),
                roundLearning = ListeningPocketsRoundLearning.parse(o["rounds"]),
                collectionsSeen = o.lpInt("collectionsSeen"),
            )
        }

        private fun parsePlaceWire(e: JsonElement): ListeningPocketsPlaceWire? {
            val o = e as? JsonObject ?: return null
            // Codable (synthesised) on iOS: id/rank/label are required.
            val id = o.lpString("id") ?: return null
            val rank = o.lpIntStrict("rank") ?: return null
            val label = o.lpString("label") ?: return null
            return ListeningPocketsPlaceWire(id, rank, label, o.lpDouble("share"))
        }

        private fun parseTripWire(e: JsonElement): ListeningPocketsTripWire? {
            val o = e as? JsonObject ?: return null
            val id = o.lpString("id") ?: return null
            val origin = o.lpString("origin") ?: return null
            val label = o.lpString("label") ?: return null
            return ListeningPocketsTripWire(id, origin, o.lpString("destination"), label, o.lpIntStrict("occurrences"))
        }
    }
}

// MARK: - Lenient field helpers (the iOS `lp*` container extensions)

internal fun JsonObject.lpString(k: String): String? =
    (this[k] as? JsonPrimitive)?.takeIf { it.isString }?.content

internal fun JsonObject.lpDouble(k: String): Double? {
    val p = this[k] as? JsonPrimitive ?: return null
    if (p is JsonNull || p.isString) return null
    return p.doubleOrNull?.takeIf { it.isFinite() }
}

/** Integral on the wire, but a `3.0` (or `3.2`) still reads rather than dropping the row. */
internal fun JsonObject.lpInt(k: String): Int? {
    val p = this[k] as? JsonPrimitive ?: return null
    if (p is JsonNull || p.isString) return null
    p.longOrNull?.let { if (it in Int.MIN_VALUE..Int.MAX_VALUE) return it.toInt() }
    val d = lpDouble(k) ?: return null
    if (kotlin.math.abs(d) >= 9e15) return null
    val r = Math.round(d)   // half-up; matches Swift .rounded() for the non-negative values on the wire
    return if (r in Int.MIN_VALUE..Int.MAX_VALUE) r.toInt() else null
}

/** A strictly integral number (synthesised Codable `Int`): `3.0` is accepted, `3.2` is not. */
internal fun JsonObject.lpIntStrict(k: String): Int? {
    val p = this[k] as? JsonPrimitive ?: return null
    if (p is JsonNull || p.isString) return null
    p.longOrNull?.let { return if (it in Int.MIN_VALUE..Int.MAX_VALUE) it.toInt() else null }
    val d = p.doubleOrNull ?: return null
    if (d.isNaN() || d.isInfinite() || d != Math.floor(d) || d < Int.MIN_VALUE || d > Int.MAX_VALUE) return null
    return d.toInt()
}

internal fun JsonObject.lpBool(k: String): Boolean? {
    val p = this[k] as? JsonPrimitive ?: return null
    if (p is JsonNull || p.isString) return null
    return p.booleanOrNull
}

/** Per-element tolerant array: a bad element yields nothing; a non-array field is empty. */
internal fun <T : Any> JsonObject.lpArray(k: String, parse: (JsonElement) -> T?): List<T> {
    val a = this[k] as? JsonArray ?: return emptyList()
    return a.mapNotNull { runCatching { parse(it) }.getOrNull() }
}

/** `{ "bpm": {...}, "energy": {...} }` — each value lenient on its own. */
internal fun JsonObject.lpNumericMap(k: String): Map<String, ListeningPocketNumeric> {
    val o = this[k] as? JsonObject ?: return emptyMap()
    val out = LinkedHashMap<String, ListeningPocketNumeric>()
    for ((key, v) in o) ListeningPocketNumeric.parse(v)?.let { out[key] = it }
    return out
}

/** A ctx object, or null for `null` / garbage / `kind: "none"`. */
internal fun JsonObject.lpContext(k: String): ListeningContextTag? {
    val tag = ListeningContextTag.fromJson(this[k]) ?: return null
    return tag.takeIf { it.isPlace || it.isTrip }
}

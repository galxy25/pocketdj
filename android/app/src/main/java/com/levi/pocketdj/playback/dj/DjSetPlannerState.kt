package com.levi.pocketdj.playback.dj

import com.levi.pocketdj.data.games.inthepocket.InThePocketScorer
import com.levi.pocketdj.screens.browse.Genre
import kotlinx.serialization.json.Json
import kotlinx.serialization.json.JsonArray
import kotlinx.serialization.json.JsonElement
import kotlinx.serialization.json.JsonNull
import kotlinx.serialization.json.JsonObject
import kotlinx.serialization.json.JsonPrimitive
import kotlinx.serialization.json.JsonUnquotedLiteral
import kotlinx.serialization.json.contentOrNull
import kotlinx.serialization.json.doubleOrNull
import kotlinx.serialization.json.intOrNull
import kotlinx.serialization.json.jsonArray
import kotlinx.serialization.json.jsonObject
import kotlinx.serialization.json.jsonPrimitive
import java.util.UUID

/**
 * Wave + pocket state machine of the PocketDJ selector, ported bit-for-bit from iOS
 * `DJSetPlanner.State` / `Features` (Playback/DJSetPlanner.swift). JSON is the iOS Codable shape.
 */

/** The normalized, all-optional features of one song (see iOS `DJSetPlanner.Features`). */
data class DjFeatures(
    /** Folded into [80, 160). */
    val bpm: Double? = null,
    /** Normalized ("8A"), null when unparseable. */
    val camelot: String? = null,
    /** Lower-cased category, null when unknown / "other". */
    val genre: String? = null,
    val year: Int? = null,
    val collections: Set<String> = emptySet(),
) {
    /** The 10-BPM band's lower bound (`floor(bpm/10)*10`), null without a tempo. */
    val band: Int? get() = bpm?.let { Math.floor(it / 10).toInt() * 10 }

    /** Has anything a pocket can compare. */
    val hasPocketData: Boolean get() = genre != null || year != null || collections.isNotEmpty()

    companion object {
        /** iOS `Features.init(bpm:camelot:genre:year:collections:)`: folds / normalizes raw values. */
        fun of(
            bpm: Double? = null,
            camelot: String? = null,
            genre: String? = null,
            year: Int? = null,
            collections: Set<String> = emptySet(),
        ): DjFeatures {
            val g = genre?.trim()?.lowercase()
            return DjFeatures(
                bpm = InThePocketScorer.foldBpm(bpm),
                camelot = camelot?.let { DjSetPlanner.normalizedCamelot(it) },
                genre = if (g.isNullOrEmpty() || g == Genre.OTHER.lowercase()) null else g,
                year = if ((year ?: 0) > 0) year else null,
                collections = collections,
            )
        }
    }
}

enum class DjDirection(val raw: Int) {
    UP(1), DOWN(-1);

    val flipped: DjDirection get() = if (this == UP) DOWN else UP

    companion object {
        fun fromRaw(r: Int): DjDirection = if (r == -1) DOWN else UP
    }
}

/** The session's wave + pocket position. Persist it with the session; start with `DjPlannerState(seed)`. */
data class DjPlannerState(
    /** The session seed (wave + pocket lengths derive from it). Full unsigned 64-bit range. */
    var seed: ULong,
    var band: Int? = null,
    var playedInBand: Int = 0,
    var direction: DjDirection = DjDirection.UP,
    var bandSteps: Int = 0,
    var waveIndex: Int = 0,
    var waveLength: Int = DjSetPlanner.waveLength(seed, 0),
    var pocketAnchor: DjFeatures? = null,
    var pocketCount: Int = 0,
    var pocketIndex: Int = 0,
    var pocketLength: Int = DjSetPlanner.pocketLength(seed, 0),
    var lastAccountedUid: UUID? = null,
) {
    /** The pocket is full (or none yet). */
    val needsNewPocket: Boolean get() = pocketAnchor == null || pocketCount >= pocketLength

    /** Advances the state as if a song with [f] had just played. Idempotent per uid. */
    fun account(f: DjFeatures, uid: UUID, options: DjSetPlanner.Options) {
        if (lastAccountedUid == uid) return
        lastAccountedUid = uid

        val b = f.band
        if (b != null) {
            val cur = band
            if (cur != null && cur != b) {
                val moved = if (b > cur) DjDirection.UP else DjDirection.DOWN
                if (moved == direction) {
                    bandSteps += 1
                } else {
                    startWave(moved)
                    bandSteps = 1
                }
                band = b
                playedInBand = 1
            } else {
                band = b
                playedInBand += 1
            }
        }

        if (options.pockets && f.hasPocketData) {
            if (needsNewPocket) {
                if (pocketAnchor != null) {
                    pocketIndex += 1
                    pocketLength = DjSetPlanner.pocketLength(seed, pocketIndex)
                }
                pocketAnchor = f
                pocketCount = 1
            } else {
                pocketCount += 1
            }
        }
    }

    /** A LISTENER-CHOSEN song plays: the set re-anchors on it. Idempotent per uid. */
    fun reanchor(f: DjFeatures, uid: UUID, options: DjSetPlanner.Options) {
        if (lastAccountedUid == uid) return
        lastAccountedUid = uid
        val b = f.band
        if (b != null) {
            val was = band
            if (was != null && Math.abs(b - was) >= 2 * DjSetPlanner.BAND_WIDTH) {
                startWave(if (b > was) DjDirection.DOWN else DjDirection.UP)
            }
            band = b
            playedInBand = 1
        }
        if (options.pockets && f.hasPocketData) {
            if (pocketAnchor != null) {
                pocketIndex += 1
                pocketLength = DjSetPlanner.pocketLength(seed, pocketIndex)
            }
            pocketAnchor = f
            pocketCount = 1
        }
    }

    private fun startWave(d: DjDirection) {
        direction = d
        bandSteps = 0
        waveIndex += 1
        waveLength = DjSetPlanner.waveLength(seed, waveIndex)
    }

    /**
     * The band the next song should come from, given the bands of the free candidates. Flips the
     * wave when it has run its length, or EARLY at the pool edge. null => no band target.
     */
    fun resolveTarget(freeBands: List<Int>): Int? {
        val cur = band ?: return null
        if (freeBands.isEmpty()) return null
        val counts = HashMap<Int, Int>()
        for (b in freeBands) counts[b] = (counts[b] ?: 0) + 1
        val minPer = DjSetPlanner.MIN_PER_BAND

        if (playedInBand < minPer && (counts[cur] ?: 0) > 0) return cur

        fun nearest(d: DjDirection, need: Int): Int? =
            counts.filter { (b, c) -> c >= need && (b - cur) * d.raw > 0 }
                .keys.minWithOrNull(compareBy({ Math.abs(it - cur) }, { it }))

        if (bandSteps >= waveLength) startWave(direction.flipped)
        nearest(direction, minPer)?.let { return it }
        nearest(direction.flipped, minPer)?.let { startWave(direction.flipped); return it }
        nearest(direction, 1)?.let { return it }
        nearest(direction.flipped, 1)?.let { startWave(direction.flipped); return it }
        return if ((counts[cur] ?: 0) > 0) cur else null
    }

    /** iOS Codable-shaped JSON (nil optionals omitted; `seed` an unsigned JSON number). */
    fun toJson(): JsonObject = JsonObject(buildMap {
        put("seed", JsonUnquotedLiteral(seed.toString()))
        band?.let { put("band", JsonPrimitive(it)) }
        put("playedInBand", JsonPrimitive(playedInBand))
        put("direction", JsonPrimitive(direction.raw))
        put("bandSteps", JsonPrimitive(bandSteps))
        put("waveIndex", JsonPrimitive(waveIndex))
        put("waveLength", JsonPrimitive(waveLength))
        pocketAnchor?.let { put("pocketAnchor", featuresToJson(it)) }
        put("pocketCount", JsonPrimitive(pocketCount))
        put("pocketIndex", JsonPrimitive(pocketIndex))
        put("pocketLength", JsonPrimitive(pocketLength))
        lastAccountedUid?.let { put("lastAccountedUid", JsonPrimitive(it.toString().uppercase())) }
    })

    fun encode(): String = toJson().toString()

    companion object {
        fun featuresToJson(f: DjFeatures): JsonObject = JsonObject(buildMap {
            f.bpm?.let { put("bpm", JsonPrimitive(it)) }
            f.camelot?.let { put("camelot", JsonPrimitive(it)) }
            f.genre?.let { put("genre", JsonPrimitive(it)) }
            f.year?.let { put("year", JsonPrimitive(it)) }
            put("collections", JsonArray(f.collections.sorted().map { JsonPrimitive(it) }))
        })

        fun featuresFromJson(o: JsonObject): DjFeatures = DjFeatures(
            bpm = o["bpm"].dbl(),
            camelot = o["camelot"].str(),
            genre = o["genre"].str(),
            year = o["year"].int(),
            collections = (o["collections"] as? JsonArray)
                ?.mapNotNull { (it as? JsonPrimitive)?.contentOrNull }?.toSet() ?: emptySet(),
        )

        private fun JsonElement?.prim(): JsonPrimitive? =
            if (this == null || this is JsonNull) null else this as? JsonPrimitive
        private fun JsonElement?.str(): String? = prim()?.contentOrNull
        private fun JsonElement?.dbl(): Double? = prim()?.doubleOrNull
        private fun JsonElement?.int(): Int? = prim()?.let { it.intOrNull ?: it.doubleOrNull?.toInt() }

        /** Null when [s] is not a decodable state (missing/invalid seed). Lenient on other fields. */
        fun decode(s: String): DjPlannerState? = runCatching {
            fromJson(Json.parseToJsonElement(s).jsonObject)
        }.getOrNull()

        fun fromJson(o: JsonObject): DjPlannerState? {
            val seed = o["seed"].prim()?.content?.toULongOrNull() ?: return null
            val st = DjPlannerState(seed)
            o["band"].int()?.let { st.band = it }
            o["playedInBand"].int()?.let { st.playedInBand = it }
            o["direction"].int()?.let { st.direction = DjDirection.fromRaw(it) }
            o["bandSteps"].int()?.let { st.bandSteps = it }
            o["waveIndex"].int()?.let { st.waveIndex = it }
            o["waveLength"].int()?.let { st.waveLength = it }
            (o["pocketAnchor"] as? JsonObject)?.let { st.pocketAnchor = featuresFromJson(it) }
            o["pocketCount"].int()?.let { st.pocketCount = it }
            o["pocketIndex"].int()?.let { st.pocketIndex = it }
            o["pocketLength"].int()?.let { st.pocketLength = it }
            st.lastAccountedUid = o["lastAccountedUid"].str()?.let { runCatching { UUID.fromString(it) }.getOrNull() }
            return st
        }
    }
}

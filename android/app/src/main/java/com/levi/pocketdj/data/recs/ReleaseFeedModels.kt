package com.levi.pocketdj.data.recs

import com.levi.pocketdj.data.history.PlayEvent
import java.time.LocalDate
import java.time.ZoneOffset
import kotlin.math.exp
import kotlin.math.ln
import kotlin.math.max
import kotlin.math.min
import kotlinx.serialization.EncodeDefault
import kotlinx.serialization.ExperimentalSerializationApi
import kotlinx.serialization.Serializable
import kotlinx.serialization.json.Json
import kotlinx.serialization.json.JsonArray
import kotlinx.serialization.json.JsonElement
import kotlinx.serialization.json.JsonObject
import kotlinx.serialization.json.JsonPrimitive
import kotlinx.serialization.json.contentOrNull
import kotlinx.serialization.json.doubleOrNull
import kotlinx.serialization.json.intOrNull

/**
 * When to re-ask Apple Music what an artist has released, and what counts as "new" (port of iOS
 * `ReleaseFeedPolicy`). Pure.
 *
 * TTL_max (14 d) MUST stay strictly below [WINDOW_DAYS] (30 d): otherwise an artist could release on
 * day 0, go unplayed, be played on day 29 with a still-"fresh" cache entry, and the release would fall
 * out of the window before the next check ever fired - it would NEVER surface. 14 guarantees at least
 * one check inside every 30-day window. The decay is a FRESHNESS knob, not a cost knob (steady state is
 * about one batched request a day whatever the curve).
 */
object ReleaseFeedPolicy {
    const val WINDOW_DAYS = 30.0
    const val MAX_RELEASE_TTL_DAYS = 14.0
    const val MIN_RELEASE_TTL_DAYS = 2.0
    const val MIN_SIMILAR_TTL_DAYS = 30.0
    const val MAX_SIMILAR_TTL_DAYS = 180.0
    /** Play count treated as "the top of the library" when normalising popularity (saturates above). */
    const val REFERENCE_MAX_PLAYS = 2860.0
    /** Hard cap measured on the endpoint: 100 ids returns HTTP 400. */
    const val IDS_PER_REQUEST = 50
    /** The edge limiter is bursty (a 40-way fan-out returned 24 x 429); two in flight is stable. */
    const val MAX_CONCURRENT_REQUESTS = 2
    private const val DAY_MS = 86_400_000.0

    private fun log2(x: Double) = ln(x) / ln(2.0)

    /** Normalised popularity in [0, 1] (logarithmic: play counts are heavy-tailed). */
    fun popularity(plays: Int, reference: Double = REFERENCE_MAX_PLAYS): Double {
        if (plays <= 0) return 0.0
        return min(1.0, max(0.0, log2(1.0 + plays) / log2(1.0 + reference)))
    }

    /** Days before this artist's LATEST RELEASE is re-fetched - the TTL that triggers network I/O. */
    fun releaseTtlDays(plays: Int): Double {
        val pop = popularity(plays)
        val raw = MAX_RELEASE_TTL_DAYS * exp(-ln(7.0) * pop)
        return min(MAX_RELEASE_TTL_DAYS, max(MIN_RELEASE_TTL_DAYS, raw))
    }

    /** Similar-list staleness: a LABEL only, it never triggers a fetch of its own. */
    fun similarTtlDays(plays: Int): Double =
        min(MAX_SIMILAR_TTL_DAYS, max(MIN_SIMILAR_TTL_DAYS, 4 * releaseTtlDays(plays)))

    fun isDue(lastCheckedAtMs: Double?, plays: Int, nowMs: Double): Boolean {
        val last = lastCheckedAtMs ?: return true
        return (nowMs - last) / DAY_MS >= releaseTtlDays(plays)
    }

    /**
     * Where a release sits relative to today; null = not in the feed. Future-dated is Coming soon with
     * NO upper bound (a pre-order announced 90 d out is still the artist's next release); past is Out
     * now only within [WINDOW_DAYS].
     */
    fun classify(releaseAtMs: Double, nowMs: Double): ReleaseStatus? {
        val ageDays = (nowMs - releaseAtMs) / DAY_MS
        if (ageDays < 0) return ReleaseStatus.COMING_SOON
        return if (ageDays <= WINDOW_DAYS) ReleaseStatus.OUT_NOW else null
    }

    /** Defined via [classify] so there is exactly ONE definition of the window. */
    fun isWithinWindow(releaseAtMs: Double, nowMs: Double): Boolean = classify(releaseAtMs, nowMs) != null
}

/** Pure over a play-event snapshot: which artists the feed is first populated from. */
object ReleaseFeedSeed {
    /**
     * Distinct artist names played inside the window, MOST RECENTLY PLAYED FIRST. Uses the append-only
     * play events (not a last-play-per-track library), so repeat listening is counted.
     */
    fun recentArtistNames(
        events: List<PlayEvent>,
        nowMs: Double,
        days: Double = ReleaseFeedPolicy.WINDOW_DAYS,
        limit: Int = 2000,
    ): List<String> {
        val cutoff = nowMs - days * 86_400_000.0
        val latest = HashMap<String, Double>()
        val display = HashMap<String, String>()
        for (e in events) {
            if (e.playedAt < cutoff) continue
            val raw = e.artist?.trim().orEmpty()
            if (raw.isEmpty()) continue
            val key = RecVersionIdentity.fold(raw)
            val at = latest[key]
            if (at != null && at >= e.playedAt) continue
            latest[key] = e.playedAt
            display[key] = raw
        }
        return latest.entries.sortedByDescending { it.value }.take(limit).mapNotNull { display[it.key] }
    }
}

/** Out now, or still ahead. First-class (not an `isFuture` Bool) so sectioning, copy and tests agree. */
enum class ReleaseStatus(val raw: String, val title: String) {
    OUT_NOW("outNow", "Out now"),
    COMING_SOON("comingSoon", "Coming soon"),
}

/** One artist's cached release answer. PERSONAL (derived from play history); never the shared index. */
@OptIn(ExperimentalSerializationApi::class)
@Serializable
data class ArtistReleaseEntry(
    val artistId: Int,
    /** Always encoded: iOS decodes these as non-optional, one missing key empties its whole cache. */
    @EncodeDefault val artistName: String = "",
    /** Epoch ms of the last successful check - the TTL clock. */
    @EncodeDefault val checkedAtMs: Double = 0.0,
    val releaseId: String? = null,
    val releaseName: String? = null,
    /** Epoch ms of the release date; null when Apple returned no parsable full date. */
    val releaseAtMs: Double? = null,
    val releaseArtworkUrl: String? = null,
    /** "album" | "single" | "compilation" - passed through for the tile subtitle. */
    val releaseKind: String? = null,
    val trackCount: Int? = null,
    val explicit: Boolean? = null,
    val similarArtistIds: List<Int>? = null,
    val similarCheckedAtMs: Double? = null,
)

/** Every identity one release carries, handed to the ownership filter together. */
data class ReleaseIdentity(
    val storeId: String,
    val artistId: Int,
    val artistName: String,
    val title: String?,
)

/**
 * One row of the feed. The status is computed at READ time, never stored: a cached entry silently ages
 * from "coming soon" into "out now" as the calendar moves.
 */
data class ReleaseFeedItem(val entry: ArtistReleaseEntry, val status: ReleaseStatus) {
    val id: Int get() = entry.artistId

    /**
     * The id a thumb on this row is filed under. A release is not a catalog song, so the RELEASE's store
     * id is used (`rel:`), else the artist (`relartist:`) - prefixed so a rejected release can never
     * collide with a rejected song.
     */
    val feedbackId: String get() = entry.releaseId?.let { "rel:$it" } ?: "relartist:${entry.artistId}"
}

/** Persisted document (iOS shape: `schemaVersion`, `entries`, additive-optional `seededAtMs`). */
data class ReleaseFeedDocument(
    val entries: List<ArtistReleaseEntry> = emptyList(),
    val seededAtMs: Double? = null,
    val schemaVersion: Int = 1,
)

/** Codec for [ReleaseFeedDocument]: per-entry lenient so one bad row never wipes the cache. */
object ReleaseFeedDocumentCodec {
    private val json = Json {
        ignoreUnknownKeys = true
        coerceInputValues = true
        encodeDefaults = false
        explicitNulls = false
    }

    fun encode(doc: ReleaseFeedDocument): String {
        val obj = buildMap<String, JsonElement> {
            put("schemaVersion", JsonPrimitive(doc.schemaVersion))
            put("entries", JsonArray(doc.entries.map { json.encodeToJsonElement(ArtistReleaseEntry.serializer(), it) }))
            doc.seededAtMs?.let { put("seededAtMs", JsonPrimitive(it)) }
        }
        return json.encodeToString(JsonElement.serializer(), JsonObject(obj))
    }

    fun decode(text: String): ReleaseFeedDocument? {
        val root = runCatching { json.parseToJsonElement(text) as? JsonObject }.getOrNull() ?: return null
        val entries = (root["entries"] as? JsonArray).orEmpty().mapNotNull {
            runCatching { json.decodeFromJsonElement(ArtistReleaseEntry.serializer(), it) }.getOrNull()
        }
        val seeded = (root["seededAtMs"] as? JsonPrimitive)?.takeIf { !it.isString }?.doubleOrNull
        val version = (root["schemaVersion"] as? JsonPrimitive)?.intOrNull ?: 1
        return ReleaseFeedDocument(entries, seeded, version)
    }

    private fun JsonArray?.orEmpty(): JsonArray = this ?: JsonArray(emptyList())
}

/**
 * Wire shape of the ONE endpoint the feed calls:
 * `GET /v1/catalog/us/artists?ids=<=50&views=latest-release,similar-artists`.
 * Parsed loosely on purpose - every nested container is optional, because a sparse artist returns an
 * empty (or absent) view and a strict parse would throw the whole batch away.
 */
object ArtistsCatalogResponse {
    private val json = Json { ignoreUnknownKeys = true; isLenient = true }

    /**
     * Null when the body is not this endpoint's: an error envelope has no `data`, and treating that as a
     * good answer would stamp fifty artists' TTL clocks off a response that contained no artists.
     */
    fun parse(body: String, checkedAtMs: Double): List<ArtistReleaseEntry>? {
        val root = runCatching { json.parseToJsonElement(body) as? JsonObject }.getOrNull() ?: return null
        val data = root["data"] as? JsonArray ?: return null
        return data.mapNotNull { entry(it, checkedAtMs) }
    }

    private fun entry(row: JsonElement, checkedAtMs: Double): ArtistReleaseEntry? {
        val o = row as? JsonObject ?: return null
        val artistId = str(o["id"])?.toIntOrNull() ?: return null
        val views = o["views"] as? JsonObject
        val release = ((views?.get("latest-release") as? JsonObject)?.get("data") as? JsonArray)?.firstOrNull() as? JsonObject
        val attrs = release?.get("attributes") as? JsonObject
        val kind = when {
            attrs == null -> null
            bool(attrs["isSingle"]) == true -> "single"
            bool(attrs["isCompilation"]) == true -> "compilation"
            else -> "album"
        }
        val similar = ((views?.get("similar-artists") as? JsonObject)?.get("data") as? JsonArray).orEmpty()
            .mapNotNull { str((it as? JsonObject)?.get("id"))?.toIntOrNull() }
        return ArtistReleaseEntry(
            artistId = artistId,
            artistName = str((o["attributes"] as? JsonObject)?.get("name")).orEmpty(),
            checkedAtMs = checkedAtMs,
            releaseId = str(release?.get("id")),
            releaseName = str(attrs?.get("name")),
            releaseAtMs = parseReleaseDate(str(attrs?.get("releaseDate"))),
            releaseArtworkUrl = str((attrs?.get("artwork") as? JsonObject)?.get("url")),
            releaseKind = kind,
            trackCount = (attrs?.get("trackCount") as? JsonPrimitive)?.intOrNull,
            explicit = str(attrs?.get("contentRating"))?.let { it == "explicit" },
            similarArtistIds = similar.takeIf { it.isNotEmpty() },
            similarCheckedAtMs = if (similar.isEmpty()) null else checkedAtMs,
        )
    }

    /**
     * Apple returns either a full date or a bare year. A bare year is NOT usable for a 30-day window
     * (2026 -> 2026-01-01 would make every January release look months old), so it parses to null.
     */
    fun parseReleaseDate(raw: String?): Double? {
        if (raw == null || raw.length < 10) return null
        val parts = raw.take(10).split('-')
        if (parts.size != 3) return null
        val y = parts[0].toIntOrNull() ?: return null
        val m = parts[1].toIntOrNull() ?: return null
        val d = parts[2].toIntOrNull() ?: return null
        return runCatching {
            LocalDate.of(y, m, d).atStartOfDay(ZoneOffset.UTC).toInstant().toEpochMilli().toDouble()
        }.getOrNull()
    }

    private fun str(e: JsonElement?): String? = (e as? JsonPrimitive)?.takeIf { it.isString }?.contentOrNull
    private fun bool(e: JsonElement?): Boolean? = (e as? JsonPrimitive)?.contentOrNull?.toBooleanStrictOrNull()
    private fun JsonArray?.orEmpty(): JsonArray = this ?: JsonArray(emptyList())

}

/** Pure glue the launch wiring uses (kept out of the graph so it is unit-tested). */
object ReleaseFeedWiring {
    private val creditSplit = Regex("""\s*[,&;/]\s*|\s+(?:feat\.?|ft\.?|featuring|with|x)\s+""", RegexOption.IGNORE_CASE)

    private val ws = Regex("\\s+")

    private fun norm(raw: String): String = raw.trim().lowercase().split(ws).filter { it.isNotEmpty() }.joinToString(" ")

    /**
     * Apple Music artist id for a played artist name from the indexed name table (keys already normalised):
     * the whole credit first, then each name inside it in order ("A & B" is filed under A).
     */
    fun resolveArtistId(name: String, idByNormalizedName: Map<String, Int>): Int? {
        idByNormalizedName[norm(name)]?.let { return it }
        for (piece in name.split(creditSplit)) {
            val k = norm(piece)
            if (k.isNotEmpty()) idByNormalizedName[k]?.let { return it }
        }
        return null
    }

    /**
     * Index of the first event that is NEW since the one with id [seenLastId]. Unknown id (a synced rewrite of
     * the log) = nothing new: a replayed history is not a play; no previous event = all new.
     */
    fun newEventsStart(ids: List<String>, seenLastId: String?): Int {
        if (seenLastId == null) return 0
        val i = ids.lastIndexOf(seenLastId)
        return if (i < 0) ids.size else i + 1
    }
}

/**
 * Played-artist-name -> Apple Music artist id, memoised against the IDENTITY of the source list so the
 * name table (12k+ rows) is normalised once per catalog, not once per lookup.
 */
class ArtistIdResolver(private val source: () -> List<com.levi.pocketdj.data.catalog.IndexArtist>) {
    @Volatile private var memo: Pair<List<com.levi.pocketdj.data.catalog.IndexArtist>, Map<String, Int>>? = null

    /** Test seam: how many times the map was (re)built. */
    @Volatile var buildCount = 0
        private set

    fun resolve(name: String): Int? {
        val artists = source()
        if (artists.isEmpty()) return null
        val cur = memo
        val map = if (cur != null && cur.first === artists) cur.second else {
            val m = HashMap<String, Int>()
            for (a in artists) if (a.valid) a.id?.toInt()?.let { m.putIfAbsent(com.levi.pocketdj.data.catalog.IndexArtist.normalize(a.key), it) }
            buildCount++
            memo = artists to m
            m
        }
        return ReleaseFeedWiring.resolveArtistId(name, map)
    }
}

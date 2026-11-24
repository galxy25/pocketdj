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
    /** Apple's CREDIT for this release ("Future, Drake & Metro Boomin"); null on rows from before the feed kept every release. */
    val releaseArtistName: String? = null,
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
data class ReleaseFeedItem(
    val entry: ArtistReleaseEntry,
    val status: ReleaseStatus,
    /** Store ids of the editions / clean-explicit twins folded into this row (never shown). */
    val alternateReleaseIds: List<String> = emptyList(),
) {
    /** One row per release: unique across the feed (see [ReleaseFeedDedupe.acrossArtists]). */
    val id: String get() = feedbackId

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
    /** 2 = one row per RELEASE, grouped by artist, head first. A v1 file (one row per artist) is a valid v2 file. */
    val schemaVersion: Int = 2,
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
 * Wire shape of the feed's ONE batch request (docs/design/new-feed-all-releases.md):
 * `GET /v1/catalog/us/artists?ids=<=50&include=albums&limit[albums]=25&sort[albums]=-releaseDate
 *  &fields[artists]=name&fields[albums]=...`. `relationships.albums` is each artist's release list, newest
 * first. `views.latest-release` / `views.similar-artists` are still read when present (fixtures, old bodies):
 * releases are the union, deduped by id. Parsed loosely on purpose - every nested container is optional,
 * because a sparse artist returns an empty (or absent) `data` and a strict parse would throw the whole batch away.
 */
object ArtistsCatalogResponse {
    private val json = Json { ignoreUnknownKeys = true; isLenient = true }

    /**
     * Null when the body is not this endpoint's: an error envelope has no `data`, and treating that as a
     * good answer would stamp fifty artists' TTL clocks off a response that contained no artists.
     * Returns every release row of every artist (an artist with none is one bare row).
     */
    fun parse(body: String, checkedAtMs: Double): List<ArtistReleaseEntry>? {
        val root = runCatching { json.parseToJsonElement(body) as? JsonObject }.getOrNull() ?: return null
        val data = root["data"] as? JsonArray ?: return null
        return data.flatMap { rows(it, checkedAtMs) }
    }

    /**
     * Artists whose relationship came back FULL ([limit]), whose oldest release is still in the window,
     * and which have a `next` page: the rare overflow follow-up candidates.
     */
    fun saturatedArtistIds(body: String, limit: Int, nowMs: Double): List<Int> {
        val root = runCatching { json.parseToJsonElement(body) as? JsonObject }.getOrNull() ?: return emptyList()
        val data = root["data"] as? JsonArray ?: return emptyList()
        return data.mapNotNull { el ->
            val o = el as? JsonObject ?: return@mapNotNull null
            val id = str(o["id"])?.toIntOrNull() ?: return@mapNotNull null
            val rel = (o["relationships"] as? JsonObject)?.get("albums") as? JsonObject ?: return@mapNotNull null
            if (rel["next"] == null) return@mapNotNull null
            val items = rel["data"] as? JsonArray ?: return@mapNotNull null
            if (items.size < limit) return@mapNotNull null
            val oldest = items.mapNotNull {
                parseReleaseDate(str(((it as? JsonObject)?.get("attributes") as? JsonObject)?.get("releaseDate")))
            }.minOrNull() ?: return@mapNotNull null
            if (ReleaseFeedPolicy.isWithinWindow(oldest, nowMs)) id else null
        }
    }

    /** One `/artists/{id}/albums` page as rows for [artistId]; null when the body is not a page. */
    fun parseAlbumsPage(body: String, artistId: Int, artistName: String, checkedAtMs: Double): List<ArtistReleaseEntry>? {
        val root = runCatching { json.parseToJsonElement(body) as? JsonObject }.getOrNull() ?: return null
        val data = root["data"] as? JsonArray ?: return null
        return data.mapNotNull { release(it as? JsonObject, artistId, artistName, checkedAtMs) }
    }

    private fun release(r: JsonObject?, artistId: Int, artistName: String, checkedAtMs: Double): ArtistReleaseEntry? {
        r ?: return null
        val id = str(r["id"]) ?: return null
        val attrs = r["attributes"] as? JsonObject
        val kind = when {
            attrs == null -> null
            bool(attrs["isSingle"]) == true -> "single"
            bool(attrs["isCompilation"]) == true -> "compilation"
            else -> "album"
        }
        return ArtistReleaseEntry(
            artistId = artistId,
            artistName = artistName,
            checkedAtMs = checkedAtMs,
            releaseId = id,
            releaseName = str(attrs?.get("name")),
            releaseAtMs = parseReleaseDate(str(attrs?.get("releaseDate"))),
            releaseArtworkUrl = str((attrs?.get("artwork") as? JsonObject)?.get("url")),
            releaseKind = kind,
            trackCount = (attrs?.get("trackCount") as? JsonPrimitive)?.intOrNull,
            explicit = str(attrs?.get("contentRating"))?.let { it == "explicit" },
            releaseArtistName = str(attrs?.get("artistName")),
        )
    }

    private fun rows(row: JsonElement, checkedAtMs: Double): List<ArtistReleaseEntry> {
        val o = row as? JsonObject ?: return emptyList()
        val artistId = str(o["id"])?.toIntOrNull() ?: return emptyList()
        val name = str((o["attributes"] as? JsonObject)?.get("name")).orEmpty()
        val views = o["views"] as? JsonObject
        val fromAlbums = (((o["relationships"] as? JsonObject)?.get("albums") as? JsonObject)?.get("data") as? JsonArray).orEmpty()
        val fromLatest = ((views?.get("latest-release") as? JsonObject)?.get("data") as? JsonArray).orEmpty()
        val seen = HashSet<String>()
        val out = ArrayList<ArtistReleaseEntry>()
        for (r in fromAlbums + fromLatest) {
            val e = release(r as? JsonObject, artistId, name, checkedAtMs) ?: continue
            if (seen.add(e.releaseId!!)) out += e
        }
        val similar = ((views?.get("similar-artists") as? JsonObject)?.get("data") as? JsonArray).orEmpty()
            .mapNotNull { str((it as? JsonObject)?.get("id"))?.toIntOrNull() }
        if (out.isEmpty()) out += ArtistReleaseEntry(artistId = artistId, artistName = name, checkedAtMs = checkedAtMs)
        out[0] = out[0].copy(
            similarArtistIds = similar.takeIf { it.isNotEmpty() },
            similarCheckedAtMs = if (similar.isEmpty()) null else checkedAtMs,
        )
        return out
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

/** The cache's invariants for ONE artist's rows, enforced in one place (mirror of iOS `ReleaseFeedCache`). */
object ReleaseFeedCache {
    /** Rows beyond the head are kept this far back (the window plus a day of slack). */
    const val KEEP_DAYS = ReleaseFeedPolicy.WINDOW_DAYS + 1
    const val MAX_EXTRA_ROWS = 125

    /**
     * Normalize one artist's rows; `rows[0]` is the SOURCE of the artist-level fields (name, check clock,
     * similar data), made identical on every row. Newest first (undated last), one row per release id, bare
     * rows only when there is nothing else, the head always kept, the rest only if future-dated or within
     * [KEEP_DAYS], capped.
     */
    fun normalize(rows: List<ArtistReleaseEntry>, nowMs: Double): List<ArtistReleaseEntry> {
        val meta = rows.firstOrNull() ?: return emptyList()
        val seen = HashSet<String>()
        val real = rows.filter { it.releaseId != null && seen.add(it.releaseId) }
        fun withMeta(r: ArtistReleaseEntry) = r.copy(
            artistId = meta.artistId, artistName = meta.artistName, checkedAtMs = meta.checkedAtMs,
            similarArtistIds = meta.similarArtistIds, similarCheckedAtMs = meta.similarCheckedAtMs,
        )
        if (real.isEmpty()) {
            return listOf(ArtistReleaseEntry(meta.artistId, meta.artistName, meta.checkedAtMs,
                similarArtistIds = meta.similarArtistIds, similarCheckedAtMs = meta.similarCheckedAtMs))
        }
        // sortedByDescending is stable: newest first, undated (-inf) last.
        val sorted = real.sortedByDescending { it.releaseAtMs ?: Double.NEGATIVE_INFINITY }
        val cutoff = nowMs - KEEP_DAYS * 86_400_000.0
        val out = ArrayList<ArtistReleaseEntry>()
        out += withMeta(sorted[0])
        for (r in sorted.drop(1)) {
            val at = r.releaseAtMs ?: continue
            if (at > nowMs || at >= cutoff) out += withMeta(r)
            if (out.size >= 1 + MAX_EXTRA_ROWS) break
        }
        return out
    }

    /** Group a flat row list by artist, preserving each artist's row order (a file written head-first keeps its heads). */
    fun group(rows: List<ArtistReleaseEntry>): LinkedHashMap<Int, List<ArtistReleaseEntry>> {
        val out = LinkedHashMap<Int, MutableList<ArtistReleaseEntry>>()
        for (r in rows) out.getOrPut(r.artistId) { ArrayList() }.add(r)
        return LinkedHashMap<Int, List<ArtistReleaseEntry>>().also { m -> out.forEach { (k, v) -> m[k] = v } }
    }
}

/** One displayed record: the representative row and the rows it absorbed. */
data class ReleaseGroup(val rep: ArtistReleaseEntry, val alternates: List<ArtistReleaseEntry>) {
    val members: List<ArtistReleaseEntry> get() = listOf(rep) + alternates
}

/** Pure dedupe rules (mirror of iOS `ReleaseFeedDedupe`); see docs/design/new-feed-all-releases.md section 3. */
object ReleaseFeedDedupe {
    private val kindSuffixes = listOf(" - single", " – single", " - ep", " – ep")

    /** Appears-on filter (apply time): keep a release only if the artist is in its credit; no credit fails open. */
    fun ownReleases(rows: List<ArtistReleaseEntry>, artistName: String): List<ArtistReleaseEntry> {
        val me = RecVersionIdentity.artistKey(artistName)
        if (me.isEmpty()) return rows
        return rows.filter { r ->
            val credit = r.releaseArtistName?.trim().orEmpty()
            if (credit.isEmpty()) return@filter true
            val keys = RecVersionIdentity.creditArtistKeys(credit)
            keys.isEmpty() || me in keys
        }
    }

    /** One row per release id ACROSS artists: the first-credited artist wins, then the lower artist id. */
    fun acrossArtists(rows: List<ArtistReleaseEntry>): List<ArtistReleaseEntry> {
        fun position(r: ArtistReleaseEntry): Int {
            val credit = r.releaseArtistName ?: return Int.MAX_VALUE
            val i = RecVersionIdentity.creditArtistKeys(credit).indexOf(RecVersionIdentity.artistKey(r.artistName))
            return if (i < 0) Int.MAX_VALUE else i
        }
        val best = LinkedHashMap<String, ArtistReleaseEntry>()
        for (r in rows) {
            val id = r.releaseId ?: continue
            val cur = best[id]
            if (cur == null) best[id] = r
            else {
                val (pa, pb) = position(r) to position(cur)
                if (pa < pb || (pa == pb && r.artistId < cur.artistId)) best[id] = r
            }
        }
        return best.values.toList()
    }

    fun stripKindSuffix(name: String): String {
        val n = name.trim()
        val lower = n.lowercase()
        for (suffix in kindSuffixes) if (lower.endsWith(suffix)) return n.dropLast(suffix.length)
        return n
    }

    fun baseTitle(name: String): String? = RecVersionIdentity.parse(stripKindSuffix(name)).base.takeIf { it.isNotEmpty() }

    private fun idLess(a: String?, b: String?): Int {
        val x = a?.toLongOrNull(); val y = b?.toLongOrNull()
        return if (x != null && y != null) x.compareTo(y) else (a ?: "").compareTo(b ?: "")
    }

    /**
     * Collapse editions and clean/explicit twins (read time). Group = (artist, album-or-single bucket, base
     * title); collapsed only when every member parses STANDARD or COSMETIC. Representative: the member he has
     * a verdict on, then the explicit preference (unset prefers clean), then newest, then lowest id.
     */
    fun collapse(
        rows: List<ArtistReleaseEntry>,
        hasVerdict: ((String) -> Boolean)?,
        prefersExplicit: (() -> Boolean)?,
        isAlbumBucket: (ArtistReleaseEntry) -> Boolean,
    ): List<ReleaseGroup> {
        data class Key(val artist: Int, val albumBucket: Boolean, val base: String)
        val buckets = LinkedHashMap<Key, MutableList<ArtistReleaseEntry>>()
        val slots = ArrayList<Any>() // Key (a bucket slot) or ArtistReleaseEntry (un-groupable)
        for (r in rows) {
            val base = r.releaseName?.let { baseTitle(it) }
            if (base == null) { slots += r; continue }
            val k = Key(r.artistId, isAlbumBucket(r), base)
            if (k !in buckets) { buckets[k] = ArrayList(); slots += k }
            buckets[k]!!.add(r)
        }
        val preferExplicit = prefersExplicit?.invoke() ?: false
        val out = ArrayList<ReleaseGroup>()
        for (slot in slots) {
            if (slot is ArtistReleaseEntry) { out += ReleaseGroup(slot, emptyList()); continue }
            val members = buckets[slot as Key]!!
            val collapsible = members.size > 1 && members.all {
                val k = RecVersionIdentity.parse(stripKindSuffix(it.releaseName.orEmpty())).klass
                k == RecVersionIdentity.VersionClass.STANDARD || k == RecVersionIdentity.VersionClass.COSMETIC
            }
            if (!collapsible) { members.forEach { out += ReleaseGroup(it, emptyList()) }; continue }
            fun verdict(r: ArtistReleaseEntry) = r.releaseId?.let { hasVerdict?.invoke("rel:$it") } ?: false
            val sorted = members.sortedWith { a, b ->
                val (va, vb) = verdict(a) to verdict(b)
                if (va != vb) return@sortedWith if (va) -1 else 1
                val (ea, eb) = (a.explicit == true) to (b.explicit == true)
                if (ea != eb) return@sortedWith if (ea == preferExplicit) -1 else 1
                val (ta, tb) = (a.releaseAtMs ?: Double.NEGATIVE_INFINITY) to (b.releaseAtMs ?: Double.NEGATIVE_INFINITY)
                if (ta != tb) return@sortedWith tb.compareTo(ta)
                idLess(a.releaseId, b.releaseId)
            }
            out += ReleaseGroup(sorted[0], sorted.drop(1))
        }
        return out
    }
}

package com.levi.pocketdj.data.recs

import com.levi.pocketdj.data.discover.DiscoverAddsStore
import kotlin.math.min
import kotlin.math.pow
import kotlinx.coroutines.CancellationException
import kotlinx.coroutines.delay
import kotlinx.serialization.json.Json
import kotlinx.serialization.json.JsonArray
import kotlinx.serialization.json.JsonElement
import kotlinx.serialization.json.JsonNull
import kotlinx.serialization.json.JsonObject
import kotlinx.serialization.json.JsonPrimitive
import kotlinx.serialization.json.booleanOrNull
import kotlinx.serialization.json.contentOrNull
import kotlinx.serialization.json.doubleOrNull
import kotlinx.serialization.json.intOrNull
import java.io.IOException

// ============================================================================
// Liked releases (For You > New: a thumbs-up adds the record)
// ============================================================================
//
// Port of iOS `Services/Recommendations/LikedReleases.swift` - same rules, same JSON.
//
// WHY THIS FILE EXISTS. A thumbs-up on a New row used to be PURE FEEDBACK: it wrote a `rel:<albumId>`
// verdict, `offered()` then removed the release from both sections, and nothing was ever added - Levi:
// "otherwise it's training the algo which is good but not building my collection". Two things follow and
// both live here as PURE values, unit-testable with no store, network or UI:
//
//   1. what we remember about a liked release ([LikedRelease]) - the verdict log only stores an id, and the
//      feed cache keeps only each artist's LATEST release, so a liked record drops out of the cache the
//      moment its artist puts out something newer. Resurfacing needs its own metadata.
//   2. which liked releases still need adding ([LikedReleaseSelection]) - "resurface any ones previously
//      liked but not added so I can actually add them".
//
// The verdict log ([RecFeedbackStore]) stays the synced source of truth for WHAT HE LIKED and
// `DiscoverAddsStore` for WHAT WAS ADDED. Nothing here is synced: a per-install cache that hydration can
// always rebuild from the verdict ids.

/** Where a like-add stands. Stored as a STRING (the never-rename-a-shipped-value rule). */
enum class LikeAddState(val raw: String) {
    /** In flight. NEVER trusted across a launch: on load it becomes [OFFLINE]. */
    ADDING("adding"),
    /** Recorded (and the Apple Music write proven). */
    ADDED("added"),
    /** A real failure - waits for his Retry tap, never auto-retried. */
    FAILED("failed"),
    /** Nothing recorded because nothing could be reached. The sweep retries it. */
    OFFLINE("offline"),
    /** A pre-order: tried now, re-run on release day. */
    AWAITING_RELEASE("awaitingRelease");

    companion object {
        fun from(raw: String?): LikeAddState? = entries.firstOrNull { it.raw == raw }
    }
}

/** The last add attempt for one liked release. */
data class LikeAddAttempt(
    val atMs: Double,
    val state: LikeAddState,
    val message: String? = null,
    /** The library-write token ("confirmed (web)" / "Apple Music write failed: ..."), so "proven" survives a relaunch. */
    val writeToken: String? = null,
    /** Whether the provisional album was recorded - decides whether Retry re-runs the add or only the write. */
    val recorded: Boolean? = null,
) {
    val writeProven: Boolean get() = DiscoverAddsStore.provenByToken(writeToken)
}

/** One release he thumbed up, as much as we need to show it and add it later. */
data class LikedRelease(
    val storeId: String,
    val artistId: Int? = null,
    val artistName: String = "",
    val title: String? = null,
    val artworkUrl: String? = null,
    val releaseAtMs: Double? = null,
    /** "album" | "single" | "ep" | "compilation" - Apple's wording as the feed carries it. */
    val kind: String? = null,
    val trackCount: Int? = null,
    val explicit: Boolean? = null,
    val likedAtMs: Double? = null,
    val attempt: LikeAddAttempt? = null,
    /** Apple didn't return this id from the catalog (pulled). Never asked about again. */
    val tombstoned: Boolean? = null,
) {
    /** The identity the feed's ownership probes take - the SAME predicates, so "owned by any path" removes the row. */
    val identity: ReleaseIdentity get() = ReleaseIdentity(storeId, artistId ?: 0, artistName, title)

    fun isUpcoming(nowMs: Double): Boolean = (releaseAtMs ?: 0.0) > nowMs

    companion object {
        /** Captured at like time from the feed row in hand (no network). Null without a release id. */
        fun from(entry: ArtistReleaseEntry, likedAtMs: Double): LikedRelease? {
            val id = entry.releaseId ?: return null
            return LikedRelease(
                storeId = id, artistId = entry.artistId, artistName = entry.artistName, title = entry.releaseName,
                artworkUrl = entry.releaseArtworkUrl, releaseAtMs = entry.releaseAtMs, kind = entry.releaseKind,
                trackCount = entry.trackCount, explicit = entry.explicit, likedAtMs = likedAtMs,
            )
        }
    }
}

/** The same JSON as iOS `liked-releases.json`, decoded leniently: a bad row is skipped, never the file. */
object LikedReleasesCodec {
    private val json = Json { ignoreUnknownKeys = true; isLenient = true }

    fun encode(list: List<LikedRelease>): String {
        val rows = list.sortedBy { it.storeId }.map { r ->
            buildMap<String, JsonElement> {
                put("storeId", JsonPrimitive(r.storeId))
                r.artistId?.let { put("artistId", JsonPrimitive(it)) }
                put("artistName", JsonPrimitive(r.artistName))
                r.title?.let { put("title", JsonPrimitive(it)) }
                r.artworkUrl?.let { put("artworkUrl", JsonPrimitive(it)) }
                r.releaseAtMs?.let { put("releaseAtMs", JsonPrimitive(it)) }
                r.kind?.let { put("kind", JsonPrimitive(it)) }
                r.trackCount?.let { put("trackCount", JsonPrimitive(it)) }
                r.explicit?.let { put("explicit", JsonPrimitive(it)) }
                r.likedAtMs?.let { put("likedAtMs", JsonPrimitive(it)) }
                r.tombstoned?.let { put("tombstoned", JsonPrimitive(it)) }
                r.attempt?.let { a ->
                    put("attempt", JsonObject(buildMap {
                        put("atMs", JsonPrimitive(a.atMs))
                        put("state", JsonPrimitive(a.state.raw))
                        a.message?.let { put("message", JsonPrimitive(it)) }
                        a.writeToken?.let { put("writeToken", JsonPrimitive(it)) }
                        a.recorded?.let { put("recorded", JsonPrimitive(it)) }
                    }))
                }
            }.let(::JsonObject)
        }
        return JsonObject(mapOf("schemaVersion" to JsonPrimitive(1), "releases" to JsonArray(rows))).toString()
    }

    /** Null when the text isn't a JSON object at all. `adding` -> `offline` is the STORE's job, not the codec's. */
    fun decode(text: String): List<LikedRelease>? {
        val root = runCatching { json.parseToJsonElement(text) as? JsonObject }.getOrNull() ?: return null
        return (root["releases"] as? JsonArray).orEmpty().mapNotNull { row ->
            val o = row as? JsonObject ?: return@mapNotNull null
            val id = str(o["storeId"])?.takeIf { it.isNotEmpty() } ?: return@mapNotNull null
            // An unknown `state` string drops the ATTEMPT only - the release itself survives.
            val attempt = (o["attempt"] as? JsonObject)?.let { a ->
                val state = LikeAddState.from(str(a["state"])) ?: return@let null
                LikeAddAttempt(
                    atMs = dbl(a["atMs"]) ?: 0.0, state = state, message = str(a["message"]),
                    writeToken = str(a["writeToken"]), recorded = bool(a["recorded"]),
                )
            }
            LikedRelease(
                storeId = id, artistId = int(o["artistId"]), artistName = str(o["artistName"]).orEmpty(),
                title = str(o["title"]), artworkUrl = str(o["artworkUrl"]), releaseAtMs = dbl(o["releaseAtMs"]),
                kind = str(o["kind"]), trackCount = int(o["trackCount"]), explicit = bool(o["explicit"]),
                likedAtMs = dbl(o["likedAtMs"]), attempt = attempt, tombstoned = bool(o["tombstoned"]),
            )
        }
    }

    private fun JsonArray?.orEmpty(): JsonArray = this ?: JsonArray(emptyList())
    private fun str(e: JsonElement?): String? = (e as? JsonPrimitive)?.takeIf { it.isString }?.contentOrNull
    private fun dbl(e: JsonElement?): Double? = (e as? JsonPrimitive)?.takeIf { it !is JsonNull && !it.isString }?.doubleOrNull
    private fun int(e: JsonElement?): Int? = (e as? JsonPrimitive)?.takeIf { it !is JsonNull && !it.isString }?.intOrNull
    private fun bool(e: JsonElement?): Boolean? = (e as? JsonPrimitive)?.takeIf { it !is JsonNull && !it.isString }?.booleanOrNull
}

// ============================================================================
// Selection (pure - the heart of "resurface what I liked but never added")
// ============================================================================

/** One row of the "Liked - not added" section. */
data class LikedRow(
    val release: LikedRelease,
    /** When he gave the thumbs-up (the ordering key). */
    val acceptedAtMs: Double,
    /** An add is running (or queued) for it right now. */
    val inFlight: Boolean,
    /** The album IS recorded (owned) but the Apple Music write isn't proven: the row offers "Retry Apple Music". */
    val retryWriteOnly: Boolean,
    val message: String?,
) {
    val id: String get() = release.storeId
    val state: LikeAddState? get() = release.attempt?.state
}

object LikedReleaseSelection {
    /** `added` stays hidden this long even if the ownership probes haven't caught up (catalog rebuild / sync lag). */
    const val ADDED_GRACE_MS = 24 * 3_600_000.0
    /** A proven pre-add comes back into Liked this long after release day if it still isn't owned. */
    const val PRE_ADD_RETURN_MS = 3 * 86_400_000.0

    /** `rel:<storeId>` -> `<storeId>`; null for `relartist:` (no release to add) and anything else. */
    fun storeId(feedbackId: String): String? =
        if (feedbackId.startsWith("rel:")) feedbackId.removePrefix("rel:").takeIf { it.isNotEmpty() } else null

    data class Result(
        val rows: List<LikedRow>,
        /** Accepted `rel:` ids we hold no metadata for: older likes, another device's, a lost cache. */
        val needsHydration: List<String>,
    )

    /**
     * @param accepted `RecFeedbackStore.acceptedInScope("new")` - feedbackId to accepted-at ms.
     * @param meta [LikedReleasesStore] rows by storeId; their `attempt` is the add history.
     * @param owns / [ownsVersion] the SAME probes `ReleaseFeedService.feed` applies.
     * @param writeNeedsRetry a note when the release's provisional album exists but its Apple Music write isn't
     *   proven and this device can write (null otherwise).
     * @param inFlight storeIds with an add running (or queued) now.
     */
    fun likedNotAdded(
        accepted: Map<String, Double>,
        meta: Map<String, LikedRelease>,
        owns: (ReleaseIdentity) -> Boolean,
        ownsVersion: (Int, String, String) -> Boolean,
        writeNeedsRetry: (String) -> String?,
        inFlight: Set<String>,
        nowMs: Double,
    ): Result {
        val rows = ArrayList<LikedRow>()
        val hydrate = ArrayList<String>()
        for ((feedbackId, at) in accepted) {
            // 1. Only releases. A `relartist:` like is pure feedback - nothing to add.
            val sid = storeId(feedbackId) ?: continue
            // 2. No metadata -> can't render or add it yet. (A tombstoned id is never re-asked.)
            val rel = meta[sid]
            if (rel == null) { hydrate += sid; continue }
            if (rel.tombstoned == true) continue

            val working = sid in inFlight
            // 3. Owned by ANY path -> gone, unless the Apple Music write is unproven.
            val owned = owns(rel.identity) || (rel.title?.let { ownsVersion(rel.artistId ?: 0, rel.artistName, it) } ?: false)
            if (owned) {
                writeNeedsRetry(sid)?.let { note ->
                    rows += LikedRow(rel, at, working, retryWriteOnly = true, message = note)
                }
                continue
            }
            if (working) {
                rows += LikedRow(rel, at, inFlight = true, retryWriteOnly = false, message = null)
                continue
            }
            val a = rel.attempt
            if (a != null) {
                // 4. Just added: hide while the catalog / sync catch up.
                if (a.state == LikeAddState.ADDED && nowMs - a.atMs < ADDED_GRACE_MS) continue
                // 5. A proven pre-add lives in Coming soon ("Pre-added") until well past release.
                if (a.state == LikeAddState.AWAITING_RELEASE && a.writeProven) {
                    val releaseAt = rel.releaseAtMs
                    if (releaseAt == null || nowMs < releaseAt + PRE_ADD_RETURN_MS) continue
                }
            }
            // 6. No age limit: a like from six months ago that was never added still shows.
            rows += LikedRow(rel, at, inFlight = false, retryWriteOnly = false, message = a?.message)
        }
        // 7. In-flight and errors first, then most recently liked first.
        fun urgent(r: LikedRow) = r.inFlight || r.retryWriteOnly ||
            r.state == LikeAddState.ADDING || r.state == LikeAddState.FAILED || r.state == LikeAddState.OFFLINE
        val sorted = rows.sortedWith(
            compareByDescending<LikedRow> { urgent(it) }.thenByDescending { it.acceptedAtMs }.thenBy { it.id },
        )
        return Result(sorted, hydrate.sorted())
    }

    /** Releases pre-added with a PROVEN write and not yet owned - what Coming soon badges "Pre-added". */
    fun preAdded(meta: Map<String, LikedRelease>): Set<String> =
        meta.values.filter { it.attempt?.state == LikeAddState.AWAITING_RELEASE && it.attempt.writeProven }
            .map { it.storeId }.toSet()
}

// ============================================================================
// Hydration decode: GET /v1/catalog/us/albums?ids=
// ============================================================================

/**
 * The album lookup used to rebuild metadata for a liked id the cache has never seen. Parsed as loosely as
 * [ArtistsCatalogResponse], for the same reason: a sparse album must not throw the whole batch away.
 */
object AlbumsCatalogParser {
    private val json = Json { ignoreUnknownKeys = true; isLenient = true }

    /**
     * Releases for the ids that came back, plus the ids Apple did NOT return (pulled from the catalog) as
     * tombstones so they are never asked about again. Null when the body is not this endpoint's: an error
     * envelope has no `data`, and reading that as "no albums" would permanently forget real likes.
     */
    fun parse(body: String, requested: List<String>, likedAtMs: (String) -> Double?): List<LikedRelease>? {
        val root = runCatching { json.parseToJsonElement(body) as? JsonObject }.getOrNull() ?: return null
        val data = root["data"] as? JsonArray ?: return null
        val seen = HashSet<String>()
        val out = ArrayList<LikedRelease>()
        for (row in data) {
            val o = row as? JsonObject ?: continue
            val id = str(o["id"])?.takeIf { it.isNotEmpty() } ?: continue
            seen += id
            val attrs = o["attributes"] as? JsonObject
            val kind = when {
                attrs == null -> null
                bool(attrs["isSingle"]) == true -> "single"
                bool(attrs["isCompilation"]) == true -> "compilation"
                else -> "album"
            }
            val artistId = (((o["relationships"] as? JsonObject)?.get("artists") as? JsonObject)?.get("data") as? JsonArray)
                ?.firstOrNull()?.let { str((it as? JsonObject)?.get("id")) }?.toIntOrNull()
            out += LikedRelease(
                storeId = id, artistId = artistId, artistName = str(attrs?.get("artistName")).orEmpty(),
                title = str(attrs?.get("name")),
                artworkUrl = str((attrs?.get("artwork") as? JsonObject)?.get("url")),
                releaseAtMs = ArtistsCatalogResponse.parseReleaseDate(str(attrs?.get("releaseDate"))),
                kind = kind, trackCount = (attrs?.get("trackCount") as? JsonPrimitive)?.intOrNull,
                explicit = str(attrs?.get("contentRating"))?.let { it == "explicit" },
                likedAtMs = likedAtMs(id),
            )
        }
        for (id in requested) if (id !in seen) out += LikedRelease(storeId = id, likedAtMs = likedAtMs(id), tombstoned = true)
        return out
    }

    private fun str(e: JsonElement?): String? = (e as? JsonPrimitive)?.takeIf { it.isString }?.contentOrNull
    private fun bool(e: JsonElement?): Boolean? = (e as? JsonPrimitive)?.contentOrNull?.toBooleanStrictOrNull()
}

/** Batched album lookup on the transport the feed already uses (with the feed's backoff policy). */
object LikedReleaseHydration {
    /** At most 50 ids per request - the cap the artists endpoint measured. */
    const val IDS_PER_REQUEST = ReleaseFeedPolicy.IDS_PER_REQUEST
    private const val MAX_ATTEMPTS = 4

    fun requestUrl(ids: List<String>, base: String = "https://api.music.apple.com"): String =
        "$base/v1/catalog/us/albums?ids=${ids.joinToString(",")}"

    /** Null on any failure (the ids stay un-hydrated and are asked about again later). */
    suspend fun fetch(
        ids: List<String>,
        transport: ReleaseFeedTransport,
        likedAtMs: (String) -> Double?,
        sleep: suspend (Double) -> Unit = { delay((it * 1000).toLong().coerceAtLeast(0)) },
        random: () -> Double = { Math.random() },
    ): List<LikedRelease>? {
        if (ids.isEmpty()) return emptyList()
        val url = requestUrl(ids)
        for (attempt in 0 until MAX_ATTEMPTS) {
            try {
                return AlbumsCatalogParser.parse(transport.fetch(url), ids, likedAtMs)
            } catch (e: CancellationException) {
                throw e
            } catch (e: Exception) {
                val retryable = when (e) {
                    is ReleaseFeedTransportError -> e.isRetryable
                    is IOException -> true
                    else -> false
                }
                if (!retryable || attempt >= MAX_ATTEMPTS - 1) return null
                val base = min(30.0, 2.0.pow(attempt + 1))
                sleep(base + random() * (base / 2))
            }
        }
        return null
    }
}

package com.levi.pocketdj.data.search

import com.levi.pocketdj.net.SigV4
import com.levi.pocketdj.screens.browse.BrowseKind
import com.levi.pocketdj.screens.browse.Clause
import com.levi.pocketdj.screens.browse.FieldKind
import com.levi.pocketdj.screens.browse.FilterOp
import com.levi.pocketdj.screens.browse.Fields
import com.levi.pocketdj.screens.browse.SortKey
import java.io.IOException
import java.util.Locale
import kotlin.coroutines.resume
import kotlin.coroutines.resumeWithException
import kotlinx.coroutines.suspendCancellableCoroutine
import kotlinx.serialization.json.Json
import kotlinx.serialization.json.JsonArray
import kotlinx.serialization.json.JsonElement
import kotlinx.serialization.json.JsonNull
import kotlinx.serialization.json.JsonObject
import kotlinx.serialization.json.JsonPrimitive
import kotlinx.serialization.json.booleanOrNull
import kotlinx.serialization.json.buildJsonArray
import kotlinx.serialization.json.buildJsonObject
import kotlinx.serialization.json.contentOrNull
import kotlinx.serialization.json.doubleOrNull
import kotlinx.serialization.json.intOrNull
import kotlinx.serialization.json.jsonObject
import kotlinx.serialization.json.longOrNull
import kotlinx.serialization.json.put
import okhttp3.Call
import okhttp3.Callback
import okhttp3.MediaType.Companion.toMediaType
import okhttp3.OkHttpClient
import okhttp3.Request
import okhttp3.RequestBody.Companion.toRequestBody
import okhttp3.Response

/** One OpenSearch hit, flattened from `{ _id, _source }`. */
data class SearchHit(
    val id: String,
    val type: String, // "album" | "song"
    val title: String? = null,
    val artist: String? = null,
    val album: String? = null,
    val albumId: String? = null,
    val genre: String? = null,
    val year: Int? = null,
    val bpm: Double? = null,
    val key: String? = null,
    val camelot: String? = null,
    val explicit: Boolean? = null,
    val trackNumber: Int? = null,
    val source: String? = null,
)

/** One page plus the exact TOTAL match count (`hits.total.value`). */
data class SearchResults(val hits: List<SearchHit>, val total: Int)

/** Seam so the paging model is unit-testable without the network. */
interface Searching {
    suspend fun search(
        query: String,
        kind: BrowseKind?,
        clauses: List<Clause>,
        sortKeys: List<SortKey>,
        creds: SigV4.Creds,
        from: Int,
        size: Int,
    ): SearchResults
}

class SearchFailedException(val code: Int, message: String) : IOException(message)

/**
 * Online search against the `pocketdj` OpenSearch Serverless collection: same query the PWA
 * issues, SigV4-signed (service `aoss`) with the user's read-only key, straight to the
 * collection host (no CORS proxy natively). Port of iOS `SearchService`.
 */
class SearchService(
    private val http: OkHttpClient,
    private val config: SearchConfig,
    private val now: () -> Long = System::currentTimeMillis,
    /** Test seam: base URL for a resolved config (production = https://<host>). */
    private val baseUrl: (ResolvedSearchConfig) -> String = { "https://${it.host}" },
) : Searching {

    override suspend fun search(
        query: String,
        kind: BrowseKind?,
        clauses: List<Clause>,
        sortKeys: List<SortKey>,
        creds: SigV4.Creds,
        from: Int,
        size: Int,
    ): SearchResults {
        val cfg = config.resolved()
        val path = "/${cfg.index}/_search"
        val body = buildBody(query, kind, clauses, sortKeys, from, size).toString().toByteArray(Charsets.UTF_8)
        val signed = SigV4.sign(
            method = "POST", host = cfg.host, path = path, body = body,
            region = cfg.region, service = SERVICE, creds = creds, epochMs = now(),
        )
        val req = Request.Builder().url(baseUrl(cfg) + path)
            .post(body.toRequestBody(JSON_TYPE))
            .apply { signed.headers.forEach { (k, v) -> header(k, v) } }
            .build()
        val client = http.newBuilder().callTimeout(15, java.util.concurrent.TimeUnit.SECONDS).build()
        val (code, text) = client.newCall(req).await()
        if (code !in 200..299) {
            throw SearchFailedException(code, "Search failed ($code): ${text.take(180)}")
        }
        return parse(text)
    }

    companion object {
        const val SERVICE = "aoss"

        /** OpenSearch's default `index.max_result_window`: `from + size` may not exceed it. */
        const val MAX_RESULT_WINDOW = 10_000

        private val JSON_TYPE = "application/json".toMediaType()
        private val parser = Json { ignoreUnknownKeys = true }

        private val MULTI_MATCH_FIELDS = listOf("title^3", "artist^2", "album^1.5", "lyrics", "sentiment^2")

        /** Browse field id -> indexed field used for SORTING (keyword / numeric). */
        val SORT_DOC_FIELD: Map<String, String> = mapOf(
            "name" to "title.kw", "artist" to "artist.kw", "sentiment" to "sentiment.kw",
            "genre" to "genreCategory", "year" to "year", "bpm" to "bpm", "length" to "length",
            "trackNumber" to "trackNumber", "trackCount" to "trackCount", "key" to "key",
            "camelot" to "camelot", "source" to "source", "fileType" to "fileType", "country" to "country",
        )

        fun kindWire(kind: BrowseKind?): String? = when (kind) {
            BrowseKind.ALBUMS -> "album"
            BrowseKind.SONGS -> "song"
            else -> null
        }

        fun buildBody(
            query: String,
            kind: BrowseKind?,
            clauses: List<Clause>,
            sortKeys: List<SortKey>,
            from: Int,
            size: Int,
        ): JsonObject {
            val trimmed = query.trim()
            val must: JsonElement = if (trimmed.isEmpty()) {
                buildJsonArray { add(buildJsonObject { put("match_all", buildJsonObject { }) }) }
            } else {
                buildJsonArray {
                    add(buildJsonObject {
                        put("multi_match", buildJsonObject {
                            put("query", trimmed)
                            put("fields", buildJsonArray { MULTI_MATCH_FIELDS.forEach { add(JsonPrimitive(it)) } })
                            put("type", "best_fields")
                            put("fuzziness", "AUTO")
                            put("operator", "and")
                        })
                    })
                }
            }
            val filter = mutableListOf<JsonObject>()
            val mustNot = mutableListOf<JsonObject>()
            kindWire(kind)?.let { k -> filter += buildJsonObject { put("term", buildJsonObject { put("type", k) }) } }
            clauses.forEach { FilterQuery.append(it, filter, mustNot) }
            return buildJsonObject {
                put("from", from)
                put("size", size)
                put("track_total_hits", true)
                put("query", buildJsonObject {
                    put("bool", buildJsonObject {
                        put("must", must)
                        put("filter", JsonArray(filter))
                        if (mustNot.isNotEmpty()) put("must_not", JsonArray(mustNot))
                    })
                })
                put("sort", sortBody(sortKeys))
            }
        }

        /**
         * Multi-key sort -> OpenSearch `sort`, ALWAYS ending with `{"id":{"order":"asc"}}` so
         * from/size paging is stable. Unresolvable fields are dropped.
         */
        fun sortBody(keys: List<SortKey>): JsonArray = buildJsonArray {
            for (k in keys) {
                val f = SORT_DOC_FIELD[k.field.id] ?: continue
                add(buildJsonObject {
                    put(f, buildJsonObject { put("order", if (k.ascending) "asc" else "desc") })
                })
            }
            add(buildJsonObject { put("id", buildJsonObject { put("order", "asc") }) })
        }

        fun parse(text: String): SearchResults {
            val root = parser.parseToJsonElement(text).jsonObject
            val hitsObj = root["hits"]?.jsonObject ?: throw IOException("Malformed search response")
            val total = hitsObj["total"].let { t ->
                when (t) {
                    is JsonObject -> (t["value"] as? JsonPrimitive)?.intOrNull
                    is JsonPrimitive -> t.intOrNull
                    else -> null
                }
            } ?: 0
            val hits = (hitsObj["hits"] as? JsonArray).orEmpty().mapNotNull { h ->
                val o = h as? JsonObject ?: return@mapNotNull null
                val id = (o["_id"] as? JsonPrimitive)?.contentOrNull ?: return@mapNotNull null
                val s = o["_source"] as? JsonObject ?: JsonObject(emptyMap())
                fun str(k: String) = (s[k] as? JsonPrimitive)?.takeIf { it.isString }?.content
                fun int(k: String) = (s[k] as? JsonPrimitive)?.takeIf { !it.isString }?.let { it.intOrNull ?: it.doubleOrNull?.toInt() }
                SearchHit(
                    id = id,
                    type = str("type") ?: "song",
                    title = str("title"), artist = str("artist"), album = str("album"),
                    albumId = str("albumId"), genre = str("genre"), year = int("year"),
                    bpm = (s["bpm"] as? JsonPrimitive)?.takeIf { !it.isString }?.doubleOrNull,
                    key = str("key"), camelot = str("camelot"),
                    explicit = (s["explicit"] as? JsonPrimitive)?.booleanOrNull,
                    trackNumber = int("trackNumber"), source = str("source"),
                )
            }
            return SearchResults(hits, total)
        }
    }
}

private suspend fun Call.await(): Pair<Int, String> = suspendCancellableCoroutine { cont ->
    cont.invokeOnCancellation { runCatching { cancel() } }
    enqueue(object : Callback {
        override fun onFailure(call: Call, e: IOException) {
            if (cont.isActive) cont.resumeWithException(e)
        }

        override fun onResponse(call: Call, response: Response) {
            response.use { r ->
                val text = runCatching { r.body?.string().orEmpty() }.getOrDefault("")
                if (cont.isActive) cont.resume(r.code to text)
            }
        }
    })
}

/**
 * Translates the app's [Clause] model into OpenSearch bool clauses (term/terms/range, with
 * must_not for neq/none-of). Table identical to iOS `FilterQuery` (SearchService.swift:288-304).
 */
object FilterQuery {
    /** Browse field id -> indexed doc field (genre -> precomputed genreCategory; text -> .kw). */
    val DOC_FIELD: Map<String, String> = mapOf(
        "artist" to "artist.kw", "name" to "title.kw", "year" to "year", "genre" to "genreCategory",
        "fileType" to "fileType", "source" to "source", "country" to "country",
        "trackCount" to "trackCount", "trackNumber" to "trackNumber", "length" to "length",
        "bpm" to "bpm", "key" to "key", "camelot" to "camelot", "explicit" to "explicit",
        "sentiment" to "sentiment.kw",
    )

    fun append(c: Clause, filter: MutableList<JsonObject>, mustNot: MutableList<JsonObject>) {
        if (c.isIncomplete) return
        val field = DOC_FIELD[c.field] ?: return
        val f = Fields.byId[c.field] ?: return
        fun leaf(op: String, v: JsonElement) = buildJsonObject { put(op, buildJsonObject { put(field, v) }) }
        // Android clauses carry in-lists in `values`; EQ/NEQ may also be set via `values` (first).
        val single = c.value.ifEmpty { c.values.firstOrNull().orEmpty() }

        when (f.kind) {
            FieldKind.BOOL -> if (c.op == FilterOp.EQ) filter += leaf("term", JsonPrimitive(single == "true"))
            FieldKind.NUMBER -> when (c.op) {
                FilterOp.EQ -> single.toDoubleOrNull()?.let { filter += leaf("term", numJson(it)) }
                FilterOp.NEQ -> single.toDoubleOrNull()?.let { mustNot += leaf("term", numJson(it)) }
                FilterOp.IN_LIST -> nums(c)?.let { filter += leaf("terms", it) }
                FilterOp.NOT_IN_LIST -> nums(c)?.let { mustNot += leaf("terms", it) }
                FilterOp.BETWEEN -> {
                    val r = buildJsonObject {
                        c.min?.let { put("gte", numJson(it)) }
                        c.max?.let { put("lte", numJson(it)) }
                    }
                    if (r.isNotEmpty()) filter += leaf("range", r)
                }
            }
            FieldKind.STRING, FieldKind.STRING_ARRAY -> when (c.op) {
                FilterOp.EQ -> if (single.isNotEmpty()) filter += leaf("term", JsonPrimitive(lc(single)))
                FilterOp.NEQ -> if (single.isNotEmpty()) mustNot += leaf("term", JsonPrimitive(lc(single)))
                FilterOp.IN_LIST -> strs(c)?.let { filter += leaf("terms", it) }
                FilterOp.NOT_IN_LIST -> strs(c)?.let { mustNot += leaf("terms", it) }
                FilterOp.BETWEEN -> Unit
            }
        }
    }

    private fun nums(c: Clause): JsonArray? =
        c.values.mapNotNull { it.toDoubleOrNull() }.map(::numJson).takeIf { it.isNotEmpty() }
            ?.let { JsonArray(it) }

    private fun strs(c: Clause): JsonArray? =
        c.values.map(::lc).filter { it.isNotEmpty() }.takeIf { it.isNotEmpty() }
            ?.let { l -> JsonArray(l.map { JsonPrimitive(it) }) }

    /** Doc numeric fields are integers; emit an Int/Long when whole to match the mapping. */
    fun numJson(n: Double): JsonPrimitive =
        if (n == Math.rint(n) && Math.abs(n) < 9.0e15) JsonPrimitive(n.toLong()) else JsonPrimitive(n)

    /** Lowercase + trim to match the index's `lc` keyword normalizer. */
    fun lc(s: String): String = s.trim().lowercase(Locale.ROOT)
}

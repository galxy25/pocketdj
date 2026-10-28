package com.levi.pocketdj.data.applemusic

import java.io.IOException
import kotlinx.coroutines.CancellationException
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.delay
import kotlinx.coroutines.withContext
import kotlinx.serialization.json.JsonArray
import kotlinx.serialization.json.JsonObject
import kotlinx.serialization.json.JsonPrimitive
import kotlinx.serialization.json.buildJsonObject
import kotlinx.serialization.json.put
import okhttp3.HttpUrl
import okhttp3.HttpUrl.Companion.toHttpUrl
import okhttp3.MediaType.Companion.toMediaType
import okhttp3.OkHttpClient
import okhttp3.Request
import okhttp3.RequestBody
import okhttp3.RequestBody.Companion.toRequestBody

/** Outcome of an Apple Music Web API call (decision D12). Never throws for HTTP/IO errors. */
sealed interface AmResult<out T> {
    data class Ok<T>(val value: T) : AmResult<T>

    /** No Music-User-Token, or the API answered 401/403 to a user-scoped call. */
    data object NeedsUserToken : AmResult<Nothing>

    /** 429 persisted after backoff. [retryAfterSec] is the last Retry-After hint, if any. */
    data class RateLimited(val retryAfterSec: Long?) : AmResult<Nothing>

    /** Anything else: [status] null for IO/token/decode failures. */
    data class Failure(val status: Int?, val message: String) : AmResult<Nothing>
}

inline fun <T, R> AmResult<T>.map(f: (T) -> R): AmResult<R> = when (this) {
    is AmResult.Ok -> AmResult.Ok(f(value))
    AmResult.NeedsUserToken -> AmResult.NeedsUserToken
    is AmResult.RateLimited -> this
    is AmResult.Failure -> this
}

fun <T> AmResult<T>.getOrNull(): T? = (this as? AmResult.Ok)?.value

/**
 * The one Apple Music Web API client (decision D12): catalog search, library
 * playlists CRUD, library add, favorites (star + ratings) and artist latest
 * releases. Port of iOS `AppleMusicWebAPI` + `AppleMusicFavorites` + the
 * `ReleaseFeedService` fetch.
 *
 * Headers: `Authorization: Bearer <dev token>` always; `Music-User-Token` only
 * when signed in. User-scoped calls without a MUT short-circuit to
 * [AmResult.NeedsUserToken] with NO network request. 401/403 on a user-scoped
 * call -> NeedsUserToken; 429 -> exponential backoff honouring Retry-After, then
 * [AmResult.RateLimited].
 */
class AppleMusicApi(
    http: OkHttpClient,
    private val tokens: AppleMusicTokens,
    private val baseUrl: String = "https://api.music.apple.com",
    private val defaultStorefront: String = "us",
    private val maxAttempts: Int = 4,
    /** Injectable for tests; production sleeps. */
    private val sleeper: suspend (Long) -> Unit = { delay(it) },
) {
    private val client: OkHttpClient = http.newBuilder()
        .callTimeout(20, java.util.concurrent.TimeUnit.SECONDS).build()

    // ---- Catalog (developer token only) ---------------------------------------

    suspend fun searchCatalog(
        term: String,
        types: Set<AmSearchType> = setOf(AmSearchType.SONGS),
        limit: Int = 10,
        offset: Int = 0,
        storefront: String = defaultStorefront,
    ): AmResult<AmCatalogSearch> {
        if (term.isBlank()) return AmResult.Failure(null, "Empty search term")
        val url = url("v1", "catalog", storefront, "search") {
            addQueryParameter("types", types.map { it.wire }.sorted().joinToString(","))
            addQueryParameter("term", term)
            addQueryParameter("limit", limit.toString())
            if (offset > 0) addQueryParameter("offset", offset.toString())
        }
        return call(get(url), userScoped = false) { AppleMusicApiModels.parseCatalogSearch(it) }
    }

    /** `GET /v1/catalog/{sf}/artists?ids=&views=latest-release,similar-artists` (<= 50 ids). */
    suspend fun artistsLatestRelease(
        artistIds: List<String>,
        storefront: String = defaultStorefront,
    ): AmResult<List<AmArtist>> {
        if (artistIds.isEmpty()) return AmResult.Ok(emptyList())
        val url = url("v1", "catalog", storefront, "artists") {
            addQueryParameter("ids", artistIds.take(MAX_ARTIST_IDS).joinToString(","))
            addQueryParameter("views", "latest-release,similar-artists")
        }
        return call(get(url), userScoped = false) { AppleMusicApiModels.parseArtists(it) }
    }

    // ---- User ----------------------------------------------------------------

    suspend fun userStorefront(): AmResult<String> =
        call(get(url("v1", "me", "storefront")), userScoped = true) { AppleMusicApiModels.parseStorefront(it) }

    // ---- Library playlists -----------------------------------------------------

    suspend fun libraryPlaylists(offset: Int = 0, limit: Int = 100): AmResult<AmPage<AmLibraryPlaylist>> =
        call(get(url("v1", "me", "library", "playlists") { paging(offset, limit) }), userScoped = true) {
            AppleMusicApiModels.parseLibraryPlaylists(it)
        }

    /** Walks every page (bounded by [maxPages]); first non-Ok result aborts. */
    suspend fun allLibraryPlaylists(pageSize: Int = 100, maxPages: Int = 100): AmResult<List<AmLibraryPlaylist>> {
        val out = ArrayList<AmLibraryPlaylist>()
        var offset = 0
        repeat(maxPages) {
            when (val r = libraryPlaylists(offset, pageSize)) {
                is AmResult.Ok -> {
                    out += r.value.items
                    offset = r.value.nextOffset ?: return AmResult.Ok(out)
                }
                else -> return r.map { out }
            }
        }
        return AmResult.Ok(out)
    }

    suspend fun playlistTracks(playlistId: String, offset: Int = 0, limit: Int = 100): AmResult<AmTrackPage> =
        call(
            get(url("v1", "me", "library", "playlists", playlistId, "tracks") { paging(offset, limit) }),
            userScoped = true,
        ) { AppleMusicApiModels.parseTrackPage(it) }

    /** `POST /v1/me/library/playlists` -> the new playlist's library id. */
    suspend fun createPlaylist(
        name: String,
        description: String? = null,
        catalogSongIds: List<String> = emptyList(),
    ): AmResult<String> {
        val body = buildJsonObject {
            put("attributes", buildJsonObject {
                put("name", name)
                if (!description.isNullOrBlank()) put("description", description)
            })
            if (catalogSongIds.isNotEmpty()) {
                put("relationships", buildJsonObject {
                    put("tracks", buildJsonObject { put("data", trackRefs(catalogSongIds)) })
                })
            }
        }
        return call(post(url("v1", "me", "library", "playlists"), jsonBody(body)), userScoped = true) {
            AppleMusicApiModels.parseFirstId(it)
        }
    }

    /** `POST .../playlists/{id}/tracks` (catalog `songs` refs; 204 No Content on success). */
    suspend fun addTracksToPlaylist(playlistId: String, catalogSongIds: List<String>): AmResult<Unit> {
        if (catalogSongIds.isEmpty()) return AmResult.Ok(Unit)
        val body = buildJsonObject { put("data", trackRefs(catalogSongIds)) }
        return call(
            post(url("v1", "me", "library", "playlists", playlistId, "tracks"), jsonBody(body)),
            userScoped = true,
        ) { Unit }
    }

    /**
     * `DELETE .../playlists/{id}/tracks?ids[library-songs]=` — NOT in Apple's
     * published API (no remove endpoint is documented); issued best-effort and a
     * 4xx surfaces as [AmResult.Failure] so callers fall back to local state.
     */
    suspend fun removeTracksFromPlaylist(playlistId: String, libraryTrackIds: List<String>): AmResult<Unit> {
        if (libraryTrackIds.isEmpty()) return AmResult.Ok(Unit)
        val url = url("v1", "me", "library", "playlists", playlistId, "tracks") {
            addQueryParameter("ids[library-songs]", libraryTrackIds.joinToString(","))
        }
        return call(Request.Builder().url(url).delete().build(), userScoped = true) { Unit }
    }

    /** `POST /v1/me/library?ids[albums|songs]=` (202, empty body). */
    suspend fun addToLibrary(kind: AmLibraryKind, ids: List<String>): AmResult<Unit> {
        if (ids.isEmpty()) return AmResult.Ok(Unit)
        val url = url("v1", "me", "library") { addQueryParameter("ids[${kind.wire}]", ids.joinToString(",")) }
        return call(post(url, EMPTY_BODY), userScoped = true) { Unit }
    }

    // ---- Favorites ---------------------------------------------------------------

    /** `PUT /v1/me/ratings/songs/{id}` value 1 (loved). Reversible via [unrateSong]. */
    suspend fun rateSong(catalogId: String, value: Int = 1): AmResult<Unit> {
        val body = buildJsonObject {
            put("type", "rating")
            put("attributes", buildJsonObject { put("value", value) })
        }
        val req = Request.Builder().url(url("v1", "me", "ratings", "songs", catalogId)).put(jsonBody(body)).build()
        return call(req, userScoped = true) { Unit }
    }

    suspend fun unrateSong(catalogId: String): AmResult<Unit> =
        call(
            Request.Builder().url(url("v1", "me", "ratings", "songs", catalogId)).delete().build(),
            userScoped = true,
        ) { Unit }

    /**
     * `POST /v1/me/favorites?ids[songs]=…` (the ★; irreversible — Apple ships no
     * delete). Chunked at [BATCH_SIZE]; stops at the first non-Ok chunk.
     */
    suspend fun starSongs(catalogIds: List<String>): AmResult<Unit> {
        for (chunk in batches(catalogIds)) {
            val url = url("v1", "me", "favorites") { addQueryParameter("ids[songs]", chunk.joinToString(",")) }
            val r = call(post(url, EMPTY_BODY), userScoped = true) { Unit }
            if (r !is AmResult.Ok) return r
        }
        return AmResult.Ok(Unit)
    }

    /**
     * Which of [catalogIds] the account LOVES, batched at [BATCH_SIZE]. Any
     * unreadable batch fails the whole call (never a partial set): the caller
     * reconciles by unfavoriting what is omitted.
     */
    suspend fun lovedSongIds(catalogIds: List<String>): AmResult<Set<String>> {
        val loved = LinkedHashSet<String>()
        for (chunk in batches(catalogIds)) {
            val url = url("v1", "me", "ratings", "songs") { addQueryParameter("ids", chunk.joinToString(",")) }
            when (val r = call(get(url), userScoped = true) { AppleMusicApiModels.parseLovedIds(it) }) {
                is AmResult.Ok -> loved += r.value
                else -> return r.map { loved }
            }
        }
        return AmResult.Ok(loved)
    }

    // ---- plumbing ------------------------------------------------------------------

    private fun url(vararg segments: String, extra: HttpUrl.Builder.() -> Unit = {}): HttpUrl {
        val b = baseUrl.toHttpUrl().newBuilder()
        // addPathSegment percent-escapes, so an opaque id can never splice extra segments.
        segments.forEach { b.addPathSegment(it) }
        b.extra()
        return b.build()
    }

    private fun HttpUrl.Builder.paging(offset: Int, limit: Int) {
        addQueryParameter("limit", limit.toString())
        addQueryParameter("offset", offset.toString())
    }

    private fun get(url: HttpUrl) = Request.Builder().url(url).get().build()
    private fun post(url: HttpUrl, body: RequestBody) = Request.Builder().url(url).post(body).build()
    private fun jsonBody(o: JsonObject): RequestBody = o.toString().toRequestBody(JSON)

    private fun trackRefs(ids: List<String>) = JsonArray(ids.map { id ->
        buildJsonObject { put("id", id); put("type", "songs") }
    })

    private suspend fun <T> call(
        base: Request,
        userScoped: Boolean,
        parse: (String) -> T?,
    ): AmResult<T> {
        val mut = try { tokens.musicUserToken() } catch (e: CancellationException) { throw e } catch (_: Throwable) { null }
        if (userScoped && mut == null) return AmResult.NeedsUserToken
        val dev = try {
            tokens.developerToken()
        } catch (e: CancellationException) {
            throw e
        } catch (t: Throwable) {
            return AmResult.Failure(null, t.message ?: "No Apple Music developer token")
        }
        val request = base.newBuilder()
            .header("Authorization", "Bearer $dev")
            .apply { if (mut != null) header("Music-User-Token", mut) }
            .build()

        var lastRetryAfter: Long? = null
        for (attempt in 0 until maxAttempts) {
            val outcome = try {
                withContext(Dispatchers.IO) {
                    client.newCall(request).execute().use { r ->
                        Raw(r.code, r.body?.string().orEmpty(), r.header("Retry-After")?.trim()?.toLongOrNull())
                    }
                }
            } catch (e: CancellationException) {
                throw e
            } catch (e: IOException) {
                return AmResult.Failure(null, e.message ?: "Network error")
            }
            when {
                outcome.code == 429 -> {
                    lastRetryAfter = outcome.retryAfter
                    if (attempt < maxAttempts - 1) {
                        sleeper(backoffMs(attempt, outcome.retryAfter))
                        continue
                    }
                    return AmResult.RateLimited(lastRetryAfter)
                }
                outcome.code == 401 || outcome.code == 403 -> {
                    if (userScoped) return AmResult.NeedsUserToken
                    tokens.invalidateDeveloperToken()
                    return AmResult.Failure(outcome.code, "Apple Music rejected the developer token")
                }
                outcome.code !in 200..299 ->
                    return AmResult.Failure(outcome.code, "Apple Music API error (${outcome.code})")
                else -> {
                    val value = parse(outcome.body)
                        ?: return AmResult.Failure(outcome.code, "Undecodable Apple Music response")
                    return AmResult.Ok(value)
                }
            }
        }
        return AmResult.RateLimited(lastRetryAfter)
    }

    private class Raw(val code: Int, val body: String, val retryAfter: Long?)

    companion object {
        const val BATCH_SIZE = 250
        const val MAX_ARTIST_IDS = 50
        private val JSON = "application/json".toMediaType()
        private val EMPTY_BODY = ByteArray(0).toRequestBody(null)

        /** Honour Retry-After (capped 60 s), else exponential 1,2,4,… s capped at 30 s. */
        fun backoffMs(attempt: Int, retryAfterSec: Long?): Long =
            if (retryAfterSec != null && retryAfterSec >= 0) minOf(retryAfterSec, 60L) * 1000
            else minOf(30L, 1L shl attempt.coerceAtMost(5)) * 1000

        fun batches(ids: List<String>, size: Int = BATCH_SIZE): List<List<String>> =
            if (ids.isEmpty() || size <= 0) emptyList() else ids.chunked(size)
    }
}

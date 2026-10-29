package com.levi.pocketdj.data.applemusic

import java.util.Base64
import kotlinx.serialization.json.Json
import kotlinx.serialization.json.jsonObject
import kotlinx.serialization.json.jsonPrimitive
import kotlinx.serialization.json.longOrNull

/**
 * DEBUG-only live probe for Android QUESTIONS Q25 (SVC-15): drives the REAL Apple Music Web API
 * with a developer token + Music-User-Token injected through the DEBUG launch extras
 * (`pdj.amDevToken`, `pdj.amMut`; see android/specs/parity/status/Q25-am-tokens.md).
 *
 * Writes are kept reversible / idempotent against the real account:
 *  - library add targets [probeSongId] (pass a song ALREADY in the library so the add is a no-op);
 *  - the love rating is restored (unrated) afterwards unless the song was already loved;
 *  - the irreversible ★ (`/v1/me/favorites`) runs only when [star] is set.
 *
 * Returns one line per step; never includes token values.
 */
object AppleMusicLiveProbe {

    suspend fun run(
        api: AppleMusicApi,
        term: String = "daft punk",
        probeSongId: String? = null,
        star: Boolean = false,
    ): List<String> {
        val out = ArrayList<String>()
        val cat = api.searchCatalog(term, setOf(AmSearchType.SONGS, AmSearchType.ALBUMS), limit = 10)
        val songs = cat.getOrNull()?.songs?.items.orEmpty()
        out += "catalog=${describe(cat)} term='$term' songs=${songs.size} albums=${cat.getOrNull()?.albums?.items?.size ?: 0}" +
            (songs.firstOrNull()?.let { " first='${it.title}' by '${it.artist}' id=${it.id}" } ?: "")
        val sf = api.userStorefront()
        out += "storefront=${describe(sf)}" + (sf.getOrNull()?.let { " value=$it" } ?: "")
        val pl = api.libraryPlaylists(limit = 25)
        out += "libraryPlaylists=${describe(pl)} count=${pl.getOrNull()?.items?.size ?: 0}"

        val id = probeSongId?.takeIf { it.isNotBlank() } ?: songs.firstOrNull()?.id
        if (id == null) {
            out += "writes=skipped (no song id)"
            return out
        }
        val loved = api.lovedSongIds(listOf(id))
        val wasLoved = loved.getOrNull()?.contains(id) == true
        out += "ratingsRead=${describe(loved)} id=$id wasLoved=$wasLoved"
        out += "libraryAdd=${describe(api.addToLibrary(AmLibraryKind.SONGS, listOf(id)))} id=$id"
        out += "rateLove=${describe(api.rateSong(id, 1))} id=$id"
        val after = api.lovedSongIds(listOf(id))
        out += "ratingsReadBack=${describe(after)} lovedNow=${after.getOrNull()?.contains(id) == true}"
        if (!wasLoved) out += "unrate(restore)=${describe(api.unrateSong(id))} id=$id"
        out += if (star) "star=${describe(api.starSongs(listOf(id)))} id=$id" else "star=skipped (irreversible; pdj.amProbeStar=1 to run)"
        return out
    }

    fun describe(r: AmResult<*>): String = when (r) {
        is AmResult.Ok -> "Ok"
        AmResult.NeedsUserToken -> "NeedsUserToken"
        is AmResult.RateLimited -> "RateLimited(${r.retryAfterSec})"
        is AmResult.Failure -> "Failure(${r.status}: ${r.message})"
    }

    /** Epoch-ms `exp` of a JWT (the developer token), or null when unreadable. */
    fun jwtExpiryMs(token: String): Long? = runCatching {
        val payload = token.trim().split('.')[1]
        val json = String(Base64.getUrlDecoder().decode(payload.padEnd((payload.length + 3) / 4 * 4, '=')))
        Json.parseToJsonElement(json).jsonObject["exp"]?.jsonPrimitive?.longOrNull?.times(1000)
    }.getOrNull()
}

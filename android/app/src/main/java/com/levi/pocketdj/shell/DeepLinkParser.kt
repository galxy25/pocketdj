package com.levi.pocketdj.shell

import java.net.URI
import java.net.URLDecoder

/** A parsed incoming URL / file open. Pure data: [DeepLinkDispatcher] decides what to do. */
sealed interface DeepLink {
    /** Join a jukebox as a guest (iOS `JukeboxLink`). [guestBase] is null for the custom scheme. */
    data class JukeboxJoin(val id: String, val guestBase: String?) : DeepLink

    /** Music with Friends (iOS `MwFLink`); consumed by the Games area. */
    data class Mwf(val id: String, val guestBase: String?) : DeepLink

    /** `pocketdj://play/<kind>/<id>[?shuffle=1]` — start playback of a collection item. */
    data class Play(val kind: PlayKind, val id: String, val shuffle: Boolean) : DeepLink

    /** `pocketdj://{album,artist,playlist,pocket,setlist,search}/...` — open a screen. */
    data class Navigate(val route: ShellRoute) : DeepLink

    /** A `.pdjcollection` / `.pocketdj.zip` / legacy `.zip` handed over by Files, a mail app, AirDrop. */
    data class CollectionFile(val uri: String) : DeepLink

    /** A `.pdjdiagkey` file; SVC-5's own handler consumes it, the dispatcher ignores it. */
    data class DiagKey(val uri: String) : DeepLink

    /** Not ours (OAuth redirects, unrelated https URLs, garbage). */
    data object None : DeepLink
}

enum class PlayKind(val token: String) {
    Playlist("playlist"), Pocket("pocket"), Setlist("setlist"), Album("album");

    companion object {
        fun fromToken(t: String): PlayKind? = entries.firstOrNull { it.token == t.lowercase() }
    }
}

/**
 * URL → [DeepLink], with the precedence of iOS `PocketDJApp.onOpenURL`: diag key file, then
 * Music with Friends, then jukebox, then everything else. Pure JVM (java.net.URI), no Android types.
 */
object DeepLinkParser {
    const val SCHEME = "pocketdj"
    const val UNIVERSAL_HOST = "jukebox.pocket-dj.com"
    const val GUEST_BASE = "https://$UNIVERSAL_HOST"
    const val COLLECTION_MIME = "application/x-pocketdj-collection"

    /** The server's session-id shape (`genId`, jukebox-server.mjs): base32, 4–32 chars. */
    private val ID_RE = Regex("^[a-z2-7]{4,32}$")

    fun isValidId(s: String): Boolean = ID_RE.matches(s)

    /**
     * @param url the intent data string.
     * @param displayName OpenableColumns.DISPLAY_NAME for opaque content:// URIs (null when unknown).
     * @param mimeType the intent type, if any.
     */
    fun parse(url: String?, displayName: String? = null, mimeType: String? = null): DeepLink {
        if (url.isNullOrBlank()) return DeepLink.None
        val uri = try { URI(url.trim()) } catch (_: Exception) { return DeepLink.None }
        val scheme = uri.scheme?.lowercase() ?: return DeepLink.None
        return when (scheme) {
            SCHEME -> parseCustom(uri)
            "https", "http" -> parseUniversal(uri)
            "content", "file" -> parseFile(url.trim(), uri, displayName, mimeType)
            else -> DeepLink.None // musicsdk:// (Apple Music SDK redirect), etc.
        }
    }

    private fun segments(uri: URI): List<String> =
        (uri.rawPath ?: "").split('/').filter { it.isNotEmpty() }.map(::percentDecode)

    /** Percent-decoding only: '+' stays '+' (not form decoding). */
    private fun percentDecode(s: String): String {
        if ('%' !in s) return s
        return runCatching { URLDecoder.decode(s.replace("+", "%2B"), "UTF-8") }.getOrDefault(s)
    }

    private fun host(uri: URI): String =
        (uri.host ?: uri.authority ?: "").lowercase()

    private fun parseCustom(uri: URI): DeepLink {
        // `pocketdj://jukebox/<id>` (host = verb) and `pocketdj:///jukebox/<id>` (verb in path)
        // normalise to the same parts list.
        val h = host(uri)
        val parts = (if (h.isNotEmpty()) listOf(h) else emptyList()) + segments(uri)
        val verb = parts.firstOrNull()?.lowercase() ?: return DeepLink.None
        val arg = parts.getOrNull(1)
        val query = queryParams(uri)
        return when (verb) {
            "jukebox" -> arg?.takeIf(::isValidId)?.let { DeepLink.JukeboxJoin(it, null) } ?: DeepLink.None
            "mwf" -> arg?.takeIf(::isValidId)?.let { DeepLink.Mwf(it, null) } ?: DeepLink.None
            "play" -> {
                val kind = arg?.let(PlayKind::fromToken) ?: return DeepLink.None
                val id = parts.getOrNull(2)?.takeIf { it.isNotBlank() } ?: return DeepLink.None
                DeepLink.Play(kind, id, truthy(query["shuffle"]))
            }
            "album" -> nav(arg) { ShellRoute.Album(it) }
            "artist" -> nav(arg) { ShellRoute.Artist(it) }
            "playlist" -> nav(arg) { ShellRoute.Playlist(it) }
            "pocket" -> nav(arg) { ShellRoute.Pocket(it) }
            "setlist" -> nav(arg) { ShellRoute.Setlist(it, autoplay = truthy(query["autoplay"])) }
            "search" -> {
                val q = (query["q"] ?: arg)?.trim().orEmpty()
                if (q.isEmpty()) DeepLink.None else DeepLink.Navigate(ShellRoute.BrowseSearch(q))
            }
            else -> DeepLink.None
        }
    }

    private inline fun nav(arg: String?, make: (String) -> ShellRoute): DeepLink =
        if (arg.isNullOrBlank()) DeepLink.None else DeepLink.Navigate(make(arg))

    private fun parseUniversal(uri: URI): DeepLink {
        if (host(uri) != UNIVERSAL_HOST) return DeepLink.None
        val segs = segments(uri)
        // MwF first: the literal `mwf` segment can never be a jukebox id (3 chars), the order
        // just documents precedence (iOS).
        if (segs.firstOrNull()?.lowercase() == "mwf") {
            val id = segs.getOrNull(1)?.takeIf(::isValidId) ?: return DeepLink.None
            return DeepLink.Mwf(id, GUEST_BASE)
        }
        val id = segs.firstOrNull()?.takeIf(::isValidId) ?: return DeepLink.None
        return DeepLink.JukeboxJoin(id, GUEST_BASE)
    }

    private fun parseFile(raw: String, uri: URI, displayName: String?, mimeType: String?): DeepLink {
        // content:// URIs are opaque; the display name is authoritative, the path a fallback.
        val name = (displayName?.takeIf { it.isNotBlank() } ?: segments(uri).lastOrNull().orEmpty()).lowercase()
        return when {
            name.endsWith(".pdjdiagkey") -> DeepLink.DiagKey(raw)
            name.endsWith(".pdjcollection") || name.endsWith(".pocketdj.zip") || name.endsWith(".zip") ->
                DeepLink.CollectionFile(raw)
            mimeType == COLLECTION_MIME -> DeepLink.CollectionFile(raw)
            else -> DeepLink.None
        }
    }

    private fun truthy(v: String?): Boolean = v == "1" || v.equals("true", ignoreCase = true)

    private fun queryParams(uri: URI): Map<String, String> {
        val q = uri.rawQuery ?: return emptyMap()
        return q.split('&').filter { it.isNotEmpty() }.associate { kv ->
            val i = kv.indexOf('=')
            val k = if (i < 0) kv else kv.substring(0, i)
            val v = if (i < 0) "" else kv.substring(i + 1)
            decode(k) to decode(v)
        }
    }

    private fun decode(s: String) = runCatching { URLDecoder.decode(s, "UTF-8") }.getOrDefault(s)
}

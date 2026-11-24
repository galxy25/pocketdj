package com.levi.pocketdj.shell

import com.levi.pocketdj.navigation.PocketDjDestination
import java.net.URI
import java.net.URLDecoder

/** A parsed incoming URL / file open. Pure data: [DeepLinkDispatcher] decides what to do. */
sealed interface DeepLink {
    /** Join a jukebox as a guest (iOS `JukeboxLink`). [guestBase] is null for the custom scheme. */
    data class JukeboxJoin(val id: String, val guestBase: String?) : DeepLink

    /** Music with Friends (iOS `MwFLink`); consumed by the Games area. */
    data class Mwf(val id: String, val guestBase: String?) : DeepLink

    /** `pocketdj://games/{puzzle,inthepocket}` — open a game inside the Games area (Q43). */
    data class Game(val kind: GameLink) : DeepLink

    /** `pocketdj://play/<kind>/<id>[?shuffle=1]` — start playback of a collection item. */
    data class Play(val kind: PlayKind, val id: String, val shuffle: Boolean) : DeepLink

    /** `pocketdj://remote` / `pocketdj://remote/join/<code>` — the Jukebox panel's Remote half, optionally joining [code]. */
    data class Remote(val code: String?) : DeepLink

    /** `pocketdj://pocket/now` — play the Pocket Wheel's best match for right now (P2-POC-16). */
    data object PocketNow : DeepLink

    /** `pocketdj://add?collection=<pocket:id|playlist:id>[&song=<id>]` — add a song (default: the one playing) to a collection. */
    data class AddToCollection(val collectionId: String, val songId: String?) : DeepLink

    /** `pocketdj://automix/<pocket|playlist|setlist>/<id>[?shuffle=1]` — start an Auto-DJ mix of a source. */
    data class AutoMix(val source: MixSource, val shuffle: Boolean) : DeepLink

    /** `pocketdj://np/mixmode?on=1|0` — Now Playing's Mix Mode on/off (P2-SURF-10). */
    data class NowPlayingMixMode(val on: Boolean) : DeepLink

    /** `pocketdj://np/stem/<name>?mute=1|0` — mute / unmute one stem of the playing track (P2-SURF-10). */
    data class NowPlayingStem(val stem: StemPart, val muted: Boolean) : DeepLink

    /** `pocketdj://{album,artist,playlist,pocket,setlist,search}/...` — open a screen. */
    data class Navigate(val route: ShellRoute) : DeepLink

    /** A `.pdjcollection` / `.pocketdj.zip` / legacy `.zip` handed over by Files, a mail app, AirDrop. */
    data class CollectionFile(val uri: String) : DeepLink

    /** A `.pdjdiagkey` file; SVC-5's own handler consumes it, the dispatcher ignores it. */
    data class DiagKey(val uri: String) : DeepLink

    /** P2-REM-9: `pocketdj://remote/join/<token>` (the Nearby invite QR). */
    data class RemoteJoin(val token: String) : DeepLink

    /** `pocketdj://create-pocket[?brief=...]` — build a pocket from a brief; no brief opens the Collections "Create pocket" sheet. */
    data class CreatePocket(val brief: String?) : DeepLink

    /** One of our add/automix links whose target couldn't be resolved (e.g. a spoken name): surfaces [message]. */
    data class Unresolved(val message: String) : DeepLink

    /** `pocketdj://link/<code>` / `pocketdj://link?code=<code>` — fill Settings > Link a device with a (checksum-valid) [code]. */
    data class LinkDevice(val code: String) : DeepLink

    /** Not ours (OAuth redirects, unrelated https URLs, garbage). */
    data object None : DeepLink
}

enum class PlayKind(val token: String) {
    Playlist("playlist"), Pocket("pocket"), Setlist("setlist"), Album("album");

    companion object {
        fun fromToken(t: String): PlayKind? = entries.firstOrNull { it.token == t.lowercase() }
    }
}

/** Which game a `pocketdj://games/...` link opens. Shell-local so the shell never imports games code. */
enum class GameLink {
    Puzzle, InThePocket;

    companion object {
        /** Lenient tokens: `puzzle|gem|gems|collector(s)`, `inthepocket|in-the-pocket|itp`. */
        fun fromToken(t: String?): GameLink? = when (t?.lowercase()?.replace("_", "-")) {
            "puzzle", "gem", "gems", "collector", "collectors", "collectors-puzzle", "collectorspuzzle",
            "gem-collector", "gemcollector" -> Puzzle
            "inthepocket", "in-the-pocket", "itp" -> InThePocket
            else -> null
        }
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

    /** A Remote join code / invite token (short code or long token). */
    private val REMOTE_TOKEN_RE = Regex("^[A-Za-z0-9_-]{4,64}$")

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
            "add" -> {
                val collection = query["collection"]?.trim().orEmpty()
                if (collection.isEmpty()) DeepLink.None
                else if (CollectionRef.target(collection) == null)
                    DeepLink.Unresolved("Couldn't find a pocket or playlist called \"$collection\" — open it in the app and add from there.")
                else DeepLink.AddToCollection(collection, query["song"]?.trim()?.takeIf { it.isNotEmpty() })
            }
            "automix" -> {
                val unresolved = DeepLink.Unresolved("Couldn't tell which pocket, playlist or setlist to auto-mix — start it from the app.")
                if (arg == null) return DeepLink.None
                val id = parts.getOrNull(2)?.takeIf { it.isNotBlank() } ?: return unresolved
                val source = when (arg.lowercase()) {
                    "pocket" -> MixSource.Pocket(id)
                    "playlist" -> MixSource.Playlist(id)
                    "setlist" -> MixSource.Setlist(id)
                    else -> return unresolved
                }
                DeepLink.AutoMix(source, truthy(query["shuffle"]))
            }
            "link" -> {
                val raw = query["code"] ?: arg
                val code = com.levi.pocketdj.screens.settings.LinkScan.extract("pocketdj://link" + (raw?.let { "?code=$it" } ?: ""))
                if (raw == null) DeepLink.None
                else code?.let { DeepLink.LinkDevice(it) } ?: DeepLink.Unresolved("That link code isn't valid. Check it and try again.")
            }
            "np" -> parseNowPlaying(parts, query)
            "create-pocket", "createpocket" ->
                DeepLink.CreatePocket((query["brief"] ?: query["q"])?.trim()?.takeIf { it.isNotEmpty() })
            "remote" -> when {
                arg == null -> DeepLink.Remote(null)
                arg.equals("join", ignoreCase = true) ->
                    parts.getOrNull(2)?.trim()?.takeIf { REMOTE_TOKEN_RE.matches(it) }
                        ?.let { DeepLink.RemoteJoin(if (it.length <= 8) it.uppercase() else it) }
                        ?: if (parts.getOrNull(2) == null) DeepLink.Remote(null) else DeepLink.None
                else -> DeepLink.None
            }
            "games" -> when {
                arg.isNullOrBlank() -> DeepLink.Navigate(ShellRoute.Tab(PocketDjDestination.Games))
                else -> GameLink.fromToken(arg)?.let { DeepLink.Game(it) } ?: DeepLink.None
            }
            "album" -> nav(arg) { ShellRoute.Album(it) }
            "artist" -> nav(arg) { ShellRoute.Artist(it) }
            "playlist" -> nav(arg) { ShellRoute.Playlist(it) }
            "pocket" -> if (arg.equals("now", ignoreCase = true)) DeepLink.PocketNow else nav(arg) { ShellRoute.Pocket(it) }
            "setlist" -> nav(arg) { ShellRoute.Setlist(it, autoplay = truthy(query["autoplay"])) }
            "search" -> {
                val q = (query["q"] ?: arg)?.trim().orEmpty()
                if (q.isEmpty()) DeepLink.None else DeepLink.Navigate(ShellRoute.BrowseSearch(q))
            }
            else -> DeepLink.None
        }
    }

    /** `np/mixmode?on=` and `np/stem/<name>?mute=`; a missing flag defaults to on / mute (the iOS intent defaults). */
    private fun parseNowPlaying(parts: List<String>, query: Map<String, String>): DeepLink {
        return when (parts.getOrNull(1)?.lowercase()) {
            "mixmode" -> DeepLink.NowPlayingMixMode(
                flag(query["on"], default = true) ?: return DeepLink.Unresolved("Couldn't tell whether to turn Mix Mode on or off."),
            )
            "stem" -> {
                val raw = parts.getOrNull(2) ?: return DeepLink.None
                val stem = StemPart.parse(raw)
                    ?: return DeepLink.Unresolved("Couldn't tell which stem you meant — try vocals, drums, bass or other.")
                DeepLink.NowPlayingStem(
                    stem,
                    flag(query["mute"], default = true) ?: return DeepLink.Unresolved("Couldn't tell whether to mute or unmute."),
                )
            }
            else -> DeepLink.None
        }
    }

    /** Explicit on/off synonyms only; anything unrecognized is null (never silently "on"). */
    private fun flag(v: String?, default: Boolean): Boolean? = when (v?.trim()?.lowercase()) {
        null, "" -> default
        "0", "false", "off", "no", "disable", "disabled", "stop", "unmute" -> false
        "1", "true", "on", "yes", "enable", "enabled", "start", "mute" -> true
        else -> null
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

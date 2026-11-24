package com.levi.pocketdj.assistant

import android.content.Intent
import com.levi.pocketdj.data.jukebox.JukeboxMatcher
import com.levi.pocketdj.navigation.PocketDjDestination
import com.levi.pocketdj.shell.DeepLinkHandler
import com.levi.pocketdj.shell.ShellActionException
import com.levi.pocketdj.shell.ShellRoute
import com.levi.pocketdj.shell.pocketPlayingLine
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.launch

/** The play operations Assistant resolution needs (implemented by `ShellActions`). */
interface MediaPlayActions {
    suspend fun playPlaylist(id: String, shuffle: Boolean = false): String
    suspend fun playPocket(id: String, shuffle: Boolean = false): String
    suspend fun playAlbum(id: String, shuffle: Boolean = false): String
    suspend fun playSong(id: String): String

    /** P2-POC-16: the Pocket Wheel's best match for now; returns the spoken caption. */
    suspend fun playPocketForNow(): String = throw ShellActionException.NoPocketFits
}

/** What kind of thing the voice request named (`android.intent.extra.focus` MIME). */
enum class MediaFocus {
    /** No focus / unstructured ("play warmup"). */
    Any,
    Playlist,
    Album,
    Artist,
    Song,
    Genre,
    ;

    companion object {
        fun fromMime(mime: String?): MediaFocus {
            val m = mime?.lowercase()?.trim().orEmpty()
            return when {
                m.endsWith("/playlist") -> Playlist
                m.endsWith("/album") -> Album
                m.endsWith("/artist") -> Artist
                m.endsWith("/audio") || m.endsWith("/song") -> Song
                m.endsWith("/genre") -> Genre
                else -> Any
            }
        }
    }
}

/** A parsed `MEDIA_PLAY_FROM_SEARCH` request. Pure data (extras are read through [from]). */
data class MediaSearchRequest(
    val query: String,
    val focus: MediaFocus = MediaFocus.Any,
    val title: String? = null,
    val artist: String? = null,
    val album: String? = null,
    val playlist: String? = null,
) {
    /** The string to match against names, chosen by focus (structured extras beat the raw query). */
    val effectiveQuery: String
        get() {
            val structured = when (focus) {
                MediaFocus.Playlist -> playlist
                MediaFocus.Album -> album
                MediaFocus.Artist -> artist
                MediaFocus.Song -> title
                else -> null
            }
            return (structured?.takeIf { it.isNotBlank() } ?: query).trim()
        }

    companion object {
        const val ACTION = "android.media.action.MEDIA_PLAY_FROM_SEARCH"
        const val EXTRA_QUERY = "query"
        const val EXTRA_FOCUS = "android.intent.extra.focus"
        const val EXTRA_TITLE = "android.intent.extra.title"
        const val EXTRA_ARTIST = "android.intent.extra.artist"
        const val EXTRA_ALBUM = "android.intent.extra.album"
        const val EXTRA_PLAYLIST = "android.intent.extra.playlist"

        /** [extra] reads a string extra by key (null when absent) — keeps this JVM-testable. */
        fun from(extra: (String) -> String?): MediaSearchRequest = MediaSearchRequest(
            query = extra(EXTRA_QUERY).orEmpty(),
            focus = MediaFocus.fromMime(extra(EXTRA_FOCUS)),
            title = extra(EXTRA_TITLE),
            artist = extra(EXTRA_ARTIST),
            album = extra(EXTRA_ALBUM),
            playlist = extra(EXTRA_PLAYLIST),
        )
    }
}

/** One name the Assistant could mean. [lastPlayedAt] (epoch ms) breaks ties toward "what I just played". */
data class MediaCandidate(
    val kind: Kind,
    val id: String,
    val name: String,
    val lastPlayedAt: Double? = null,
    /** Song/album artist, for agreement with a structured `EXTRA_ARTIST`. */
    val artist: String? = null,
) {
    enum class Kind { Playlist, Pocket, Album, Song }
}

sealed interface MediaSearchResult {
    data class Play(val candidate: MediaCandidate, val shuffle: Boolean) : MediaSearchResult

    /** No confident match: land on Browse with [query] in the search field. */
    data class Browse(val query: String) : MediaSearchResult

    /** "play my pocket" / "pocket for now" / "something that fits": the Pocket Wheel's best match (P2-POC-16). */
    data object PocketForNow : MediaSearchResult

    /** Nothing was asked for (blank query): just bring the app up. */
    data object Empty : MediaSearchResult
}

/**
 * Pure name resolution (iOS parity, P2-SURF-4). Collections / albums match STRICTLY
 * ([CollectionNameMatcher]: literal equals > prefix > contains, typo only when nothing literal,
 * never initials); songs match through [IntentSongMatcher] (whole phrase and "<title> by <artist>").
 * `MediaFocus.Any` order: strict collection -> unique top-tier song -> Browse search. (A "pocket
 * phrase" door is reserved for P2-POC-16 ahead of the collection step.)
 */
object MediaSearchResolver {
    fun kindsFor(focus: MediaFocus): Set<MediaCandidate.Kind> = when (focus) {
        MediaFocus.Any, MediaFocus.Playlist -> setOf(MediaCandidate.Kind.Playlist, MediaCandidate.Kind.Pocket)
        MediaFocus.Album -> setOf(MediaCandidate.Kind.Album)
        MediaFocus.Song -> setOf(MediaCandidate.Kind.Song)
        MediaFocus.Artist, MediaFocus.Genre -> emptySet() // no collection to play: Browse handles it
    }

    /**
     * Loose match tier for Android Auto's browse search box (3 exact, 2 normalized-equal, 1 every
     * query token covered, 0 none). NOT used for voice resolution, which is strict ([resolve]).
     */
    fun tier(query: String, name: String): Int {
        val q = query.trim()
        if (q.isEmpty()) return 0
        if (name.trim().equals(q, ignoreCase = true)) return 3
        val nq = JukeboxMatcher.normalize(q)
        val nn = JukeboxMatcher.normalize(name)
        if (nq.isEmpty() || nn.isEmpty()) return 0
        if (nq == nn) return 2
        val nameTokens = nn.split(' ').toSet()
        return if (nq.split(' ').all { it in nameTokens }) 1 else 0
    }

    private val POCKET_NOW_PHRASES = setOf(
        "my pocket", "my pockets", "pocket for now", "my pocket for now", "pocket for right now", "my pocket right now",
        "something that fits", "something that fits now", "something that fits right now", "something that fits my pocket",
        "what fits right now", "whatever fits",
    )

    /**
     * Step 1 of the voice order (P2-SURF / S-1): a pocket-for-now PHRASE, matched as the whole cleaned utterance (so
     * "play my pocket", "play my pocket on PocketDJ" and "my pocket please" qualify but "my pocket of sunshine" does
     * not). Case, punctuation and a leading "the" are ignored.
     */
    fun isPocketForNowPhrase(raw: String): Boolean {
        val words = cleanSpoken(raw).lowercase().split(Regex("[^\\p{L}\\p{N}]+")).filter { it.isNotEmpty() }
        val norm = words.dropWhile { it == "the" }.joinToString(" ")
        return norm in POCKET_NOW_PHRASES
    }

    private val LEADING = listOf("play ", "please ", "shuffle ", "shuffled ", "listen to ", "put on ")
    private val TRAILING = listOf(
        " please", " on pocketdj", " in pocketdj", " with pocketdj", " using pocketdj",
        " on pocket dj", " in pocket dj", " with pocket dj",
    )

    /** Drops only the trailing "please" / "on PocketDJ" filler. */
    fun stripTail(raw: String): String {
        var q = raw.trim()
        var changed = true
        while (changed) {
            changed = false
            val l = q.lowercase()
            TRAILING.firstOrNull { l.endsWith(it) }?.let { q = q.substring(0, q.length - it.length).trim(); changed = true }
        }
        return q
    }

    /** Drops spoken filler around the thing named ("play X on PocketDJ", "shuffle X please"). */
    fun cleanSpoken(raw: String): String {
        var q = raw.trim()
        var changed = true
        while (changed) {
            changed = false
            val l = q.lowercase()
            LEADING.firstOrNull { l.startsWith(it) }?.let { q = q.substring(it.length).trim(); changed = true }
            val l2 = q.lowercase()
            TRAILING.firstOrNull { l2.endsWith(it) }?.let { q = q.substring(0, q.length - it.length).trim(); changed = true }
        }
        return q
    }

    private class Tied(val candidate: MediaCandidate, val hinted: Boolean, val artistMatch: Boolean)

    fun resolve(
        request: MediaSearchRequest,
        /** Pre-normalized song rows (cached per catalog by the caller); default derives them from [candidates]. */
        songRows: (() -> List<IntentSongMatcher.Row>)? = null,
        /** Songs that win ties: the playing one, ones already in a collection. */
        preferSong: (String) -> Boolean = { false },
        candidates: (Set<MediaCandidate.Kind>) -> List<MediaCandidate>,
    ): MediaSearchResult {
        val raw = request.effectiveQuery
        if (raw.isBlank() && request.query.isBlank()) return MediaSearchResult.Empty
        val browse = MediaSearchResult.Browse(request.query.ifBlank { raw }.trim())
        val kinds = kindsFor(request.focus)
        if (kinds.isEmpty()) return browse
        if ((request.focus == MediaFocus.Any || request.focus == MediaFocus.Playlist) &&
            (isPocketForNowPhrase(raw) || isPocketForNowPhrase(request.query))
        ) return MediaSearchResult.PocketForNow

        // Hint + shuffle come from BOTH the raw spoken query and the structured match string.
        val words = (raw + " " + request.query).lowercase().split(Regex("[^\\p{L}\\p{N}]+")).filter { it.isNotEmpty() }
        val shuffle = "shuffle" in words || "shuffled" in words
        val hint = when {
            "pocket" in words || "pockets" in words -> MediaCandidate.Kind.Pocket
            "playlist" in words || "playlists" in words -> MediaCandidate.Kind.Playlist
            else -> null
        }
        val wantedArtist = request.artist?.let { IntentSongMatcher.compact(it) }?.takeIf { it.isNotEmpty() }
        val cleaned = cleanSpoken(raw)
        // A title may itself start with a filler word ("Play Date", "Please Mr. Postman"), so the
        // query minus only the PocketDJ tail is ranked too; the higher tier wins, unstripped on ties.
        val tailOnly = stripTail(raw)
        val queries = if (tailOnly.isNotBlank() && !tailOnly.equals(cleaned, ignoreCase = true)) listOf(tailOnly, cleaned) else listOf(cleaned)

        // 1. Strict collection / album names.
        val named = kinds - MediaCandidate.Kind.Song
        if (named.isNotEmpty()) {
            val pool = candidates(named)
            val ranked = queries.map { CollectionNameMatcher.rankScored(it, pool) { c -> c.name } }
                .filter { it.isNotEmpty() }
                .reduceOrNull { a, b -> if (b.first().second > a.first().second) b else a }
                .orEmpty()
            if (ranked.isNotEmpty()) {
                val top = ranked.first().second
                val best = ranked.filter { it.second == top }.map { (c, _) ->
                    Tied(
                        c,
                        hint != null && c.kind == hint,
                        wantedArtist != null && c.artist != null && IntentSongMatcher.compact(c.artist).let { a ->
                            a == wantedArtist || a.contains(wantedArtist) || wantedArtist.contains(a)
                        },
                    )
                }.sortedWith(
                    compareByDescending<Tied> { it.artistMatch }
                        .thenByDescending { it.hinted }
                        .thenByDescending { it.candidate.lastPlayedAt ?: Double.NEGATIVE_INFINITY }
                        .thenBy { it.candidate.name.length }
                        .thenBy { it.candidate.name.lowercase() },
                ).first()
                return MediaSearchResult.Play(best.candidate, shuffle)
            }
        }

        // 2. Songs: explicit Song focus plays the best; unstructured plays only a clear top-tier winner.
        val songFocus = request.focus == MediaFocus.Song
        if (songFocus || request.focus == MediaFocus.Any) {
            val rows = songRows?.invoke() ?: candidates(setOf(MediaCandidate.Kind.Song))
                .map { IntentSongMatcher.Row(it.id, it.name, it.artist.orEmpty()) }
            val query = when {
                songFocus && !request.title.isNullOrBlank() && !request.artist.isNullOrBlank() ->
                    "${request.title!!.trim()} by ${request.artist.trim()}"
                else -> cleaned
            }
            val matches = (if (songFocus && query !== cleaned) listOf(query) else queries)
                .map { IntentSongMatcher.rank(it, rows, preferSong) }
                .filter { it.isNotEmpty() }
                .reduceOrNull { a, b -> if (b.first().score > a.first().score) b else a }
                .orEmpty()
            // Unstructured: play only a clear winner (strictly higher score, or the preferred copy).
            val pick = matches.firstOrNull()?.takeIf { top ->
                songFocus || matches.size == 1 || top.score > matches[1].score ||
                    (preferSong(top.id) && !preferSong(matches[1].id))
            }
            if (pick != null) {
                val row = rows.first { it.id == pick.id }
                return MediaSearchResult.Play(
                    MediaCandidate(MediaCandidate.Kind.Song, row.id, row.name, artist = row.artist.ifEmpty { null }),
                    shuffle,
                )
            }
        }
        return browse
    }
}

/**
 * Plays what an Assistant search resolved to, else lands on Browse with the query. Failures
 * become the speakable message (never a silent drop).
 */
class MediaSearchHandler(
    private val actions: MediaPlayActions,
    private val candidates: (Set<MediaCandidate.Kind>) -> List<MediaCandidate>,
    private val openRoute: (ShellRoute) -> Unit,
    private val message: (String) -> Unit,
    private val songRows: (() -> List<IntentSongMatcher.Row>)? = null,
    private val preferSong: (String) -> Boolean = { false },
) {
    /** @return the spoken/display name that started playing, or null when it navigated or failed. */
    suspend fun handle(request: MediaSearchRequest): String? {
        return when (val r = MediaSearchResolver.resolve(request, songRows, preferSong, candidates)) {
            MediaSearchResult.Empty -> null
            is MediaSearchResult.Browse -> {
                openRoute(ShellRoute.BrowseSearch(r.query))
                null
            }
            MediaSearchResult.PocketForNow -> try {
                val caption = actions.playPocketForNow()
                message(pocketPlayingLine(caption))
                caption
            } catch (e: ShellActionException) {
                message(e.message.orEmpty())
                null
            }
            is MediaSearchResult.Play -> try {
                val c = r.candidate
                when (c.kind) {
                    MediaCandidate.Kind.Playlist -> actions.playPlaylist(c.id, r.shuffle)
                    MediaCandidate.Kind.Pocket -> actions.playPocket(c.id, r.shuffle)
                    MediaCandidate.Kind.Album -> actions.playAlbum(c.id, r.shuffle)
                    MediaCandidate.Kind.Song -> actions.playSong(c.id)
                }
            } catch (e: ShellActionException) {
                message(e.message.orEmpty())
                null
            }
        }
    }
}

/**
 * Process-wide hook for `PlaybackService.onSetMediaItems`: a MediaController search request
 * (Assistant / Android Auto voice) lands here. Assigned by `ShellGraph`.
 */
object SearchPlayBridge {
    @Volatile var handler: ((request: MediaSearchRequest) -> Unit)? = null
}

/**
 * Intent adapter registered through `FeatureModule.deepLinkHandlers`:
 *  - `android.media.action.MEDIA_PLAY_FROM_SEARCH` (Assistant, adb)
 *  - [ACTION_OPEN_TAB] with string extra [EXTRA_TAB] (static launcher shortcuts)
 */
class MediaSearchIntentHandler(
    private val scope: CoroutineScope,
    private val handler: () -> MediaSearchHandler,
    private val openRoute: (ShellRoute) -> Unit,
) : DeepLinkHandler {
    override fun handle(intent: Intent): Boolean {
        when (intent.action) {
            MediaSearchRequest.ACTION -> {
                val request = MediaSearchRequest.from { intent.getStringExtra(it) }
                scope.launch { handler().handle(request) }
                return true
            }
            ACTION_OPEN_TAB -> {
                val dest = PocketDjDestination.entries.firstOrNull { it.route == intent.getStringExtra(EXTRA_TAB) }
                    ?: return false
                openRoute(ShellRoute.Tab(dest))
                return true
            }
        }
        return false
    }

    companion object {
        const val ACTION_OPEN_TAB = "com.levi.pocketdj.action.OPEN_TAB"
        const val EXTRA_TAB = "tab"
    }
}

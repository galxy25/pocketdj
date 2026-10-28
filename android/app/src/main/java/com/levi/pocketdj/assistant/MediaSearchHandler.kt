package com.levi.pocketdj.assistant

import android.content.Intent
import com.levi.pocketdj.data.jukebox.JukeboxMatcher
import com.levi.pocketdj.navigation.PocketDjDestination
import com.levi.pocketdj.shell.DeepLinkHandler
import com.levi.pocketdj.shell.ShellActionException
import com.levi.pocketdj.shell.ShellRoute
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.launch

/** The play operations Assistant resolution needs (implemented by `ShellActions`). */
interface MediaPlayActions {
    suspend fun playPlaylist(id: String, shuffle: Boolean = false): String
    suspend fun playPocket(id: String, shuffle: Boolean = false): String
    suspend fun playAlbum(id: String, shuffle: Boolean = false): String
    suspend fun playSong(id: String): String
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

    /** Nothing was asked for (blank query): just bring the app up. */
    data object Empty : MediaSearchResult
}

/** Pure name resolution: exact → normalized → token coverage, ties → most recently played. */
object MediaSearchResolver {
    /** Spoken filler that is never part of a collection's name. */
    private val NOISE = setOf("play", "please", "listen", "to", "some", "music", "my", "the", "a", "playlist", "playlists", "pocket", "pockets", "pocketdj", "on", "shuffle", "shuffled")

    fun kindsFor(focus: MediaFocus): Set<MediaCandidate.Kind> = when (focus) {
        MediaFocus.Any, MediaFocus.Playlist -> setOf(MediaCandidate.Kind.Playlist, MediaCandidate.Kind.Pocket)
        MediaFocus.Album -> setOf(MediaCandidate.Kind.Album)
        MediaFocus.Song -> setOf(MediaCandidate.Kind.Song)
        MediaFocus.Artist, MediaFocus.Genre -> emptySet() // no collection to play: Browse handles it
    }

    /** Match tier of [name] for [query]: 3 exact, 2 normalized-equal, 1 every query token covered, 0 none. */
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

    private data class Scored(val candidate: MediaCandidate, val tier: Int, val hinted: Boolean, val artistMatch: Boolean)

    fun resolve(
        request: MediaSearchRequest,
        candidates: (Set<MediaCandidate.Kind>) -> List<MediaCandidate>,
    ): MediaSearchResult {
        val raw = request.effectiveQuery
        if (raw.isBlank() && request.query.isBlank()) return MediaSearchResult.Empty
        val browse = MediaSearchResult.Browse(request.query.ifBlank { raw }.trim())
        val kinds = kindsFor(request.focus)
        if (kinds.isEmpty()) return browse

        // Hint + shuffle come from BOTH the raw spoken query and the structured match string.
        val words = (JukeboxMatcher.normalize(raw) + " " + JukeboxMatcher.normalize(request.query))
            .split(' ').filter { it.isNotEmpty() }
        val wantedArtist = request.artist?.let { JukeboxMatcher.normalize(it) }?.takeIf { it.isNotEmpty() }
        val shuffle = "shuffle" in words || "shuffled" in words
        val stripped = words.filterNot { it in NOISE }.joinToString(" ")
        val hint = when {
            "pocket" in words || "pockets" in words -> MediaCandidate.Kind.Pocket
            "playlist" in words || "playlists" in words -> MediaCandidate.Kind.Playlist
            else -> null
        }
        val pool = candidates(kinds)
        val queries = listOfNotNull(raw, stripped.takeIf { it.isNotEmpty() && it != raw }).distinct()

        val best = pool.map { c ->
            Scored(
                c,
                queries.maxOf { tier(it, c.name) },
                hint != null && c.kind == hint,
                wantedArtist != null && c.artist != null && JukeboxMatcher.normalize(c.artist).let { a ->
                    a == wantedArtist || a.contains(wantedArtist) || wantedArtist.contains(a)
                },
            )
        }.filter { it.tier > 0 }
            .sortedWith(
                compareByDescending<Scored> { it.tier }
                    .thenByDescending { it.artistMatch }
                    .thenByDescending { it.hinted }
                    .thenByDescending { it.candidate.lastPlayedAt ?: Double.NEGATIVE_INFINITY }
                    .thenBy { it.candidate.name.length }
                    .thenBy { it.candidate.name.lowercase() },
            ).firstOrNull() ?: return browse
        return MediaSearchResult.Play(best.candidate, shuffle)
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
) {
    /** @return the spoken/display name that started playing, or null when it navigated or failed. */
    suspend fun handle(request: MediaSearchRequest): String? {
        return when (val r = MediaSearchResolver.resolve(request, candidates)) {
            MediaSearchResult.Empty -> null
            is MediaSearchResult.Browse -> {
                openRoute(ShellRoute.BrowseSearch(r.query))
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

package com.levi.pocketdj.screens.discover

import com.levi.pocketdj.data.applemusic.AmAlbum
import com.levi.pocketdj.data.applemusic.AmSong
import java.text.Normalizer
import java.util.Locale
import kotlinx.serialization.Serializable

/**
 * Discover (iOS `RipsStore.DiscoverHit`): one Apple Music catalog SONG hit, METADATA only.
 * `songId` is the ad-hoc `amrec_<storeId>` id; `ripped`/`url` reflect the rips manifest.
 * Every field past `songId` is optional-with-default so an older rip server still decodes.
 */
@Serializable
data class DiscoverHit(
    val appleMusicId: String,
    val title: String,
    val artist: String = "",
    val album: String? = null,
    val artworkUrl: String? = null,
    val durationMs: Int? = null,
    val songId: String = "",
    val ripped: Boolean? = null,
    val url: String? = null,
    val explicit: Boolean? = null,
    val albumAppleMusicId: String? = null,
    val albumArtworkUrl: String? = null,
    val trackNumber: Int? = null,
    val discNumber: Int? = null,
    val year: Int? = null,
) {
    val id: String get() = songId.ifEmpty { "amrec_$appleMusicId" }
}

/** iOS `DiscoverAlbumHit`: `albumId` is the provisional catalog album id `amrec_album_<collectionId>`. */
@Serializable
data class DiscoverAlbumHit(
    val appleMusicId: String,
    val albumId: String = "",
    val title: String,
    val artist: String = "",
    val artworkUrl: String? = null,
    val trackCount: Int? = null,
    val year: Int? = null,
    val url: String? = null,
    val releaseDate: String? = null,
) {
    val id: String get() = albumId.ifEmpty { "amrec_album_$appleMusicId" }
}

/** One `GET /album-tracks` row (server order = disc, track). */
@Serializable
data class DiscoverAlbumTrack(
    val id: String,
    val title: String = "",
    val artist: String = "",
    val discNumber: Int? = null,
    val trackNumber: Int? = null,
    val durationMs: Int? = null,
)

/** Both halves of one `/album-tracks` round trip; [album] is absent on servers that predate it. */
data class DiscoverAlbumExpansion(val album: DiscoverAlbumHit?, val tracks: List<DiscoverAlbumTrack>) {
    companion object { val EMPTY = DiscoverAlbumExpansion(null, emptyList()) }
}

/** `/search` envelope. */
@Serializable internal data class DiscoverSongsEnvelope(val results: List<DiscoverHit> = emptyList())
@Serializable internal data class DiscoverAlbumsEnvelope(val results: List<DiscoverAlbumHit> = emptyList())

/** `/album-tracks` envelope; `album` OPTIONAL. */
@Serializable
internal data class DiscoverAlbumTracksEnvelope(
    val tracks: List<DiscoverAlbumTrack> = emptyList(),
    val album: DiscoverAlbumHit? = null,
)

/** Nested scope under the Discover segment. */
enum class DiscoverScope { SONGS, ALBUMS }

/** Capability-aware help text for a Discover ＋ Add (iOS `DiscoverAddWording`). */
object DiscoverAddWording {
    /** iOS `discoverError` for a rejected add. */
    const val ADD_FAILED = "Add failed — the import server didn’t accept the request."

    fun addHelp(noun: String, canAddToLibrary: Boolean, opensInMusic: Boolean = false): String = when {
        canAddToLibrary -> "Save this $noun to your Apple Music library and prepare your copy"
        opensInMusic -> "Open this $noun in Music and prepare your copy"
        else -> "Prepare your copy"
    }
}

/** The trailing control of a Discover song row (iOS `DiscoverRow.trailing`, in precedence order). */
enum class DiscoverTrailing { PLAY, PAUSE, WORKING, ADDED, ADD }

/** Pure row-state rules for Discover (iOS BrowseDiscover.swift `ripped` / `trailing`). */
object DiscoverRowState {
    /** Ripped = the server said so at search time OR the manifest has flipped since (add-completion refresh). */
    fun ripped(hit: DiscoverHit, manifestIds: Set<String>): Boolean = hit.ripped == true || hit.id in manifestIds

    /** Ripped wins over everything (play/pause); then an in-flight rip, then a recorded add, else the + control. */
    fun trailing(ripped: Boolean, isPlayingThisSong: Boolean, working: Boolean, added: Boolean): DiscoverTrailing = when {
        ripped && isPlayingThisSong -> DiscoverTrailing.PAUSE
        ripped -> DiscoverTrailing.PLAY
        working -> DiscoverTrailing.WORKING
        added -> DiscoverTrailing.ADDED
        else -> DiscoverTrailing.ADD
    }

    /**
     * The album + needs only a TRACK source (catalog REST is developer-token only; `/album-tracks` is
     * subscription-free). A row existing at all proves one answered, so it is enabled whenever results show;
     * the Apple Music library write degrades to "skipped" without a Music-User-Token.
     */
    fun albumAddEnabled(hasAnyTrackSource: Boolean = true): Boolean = hasAnyTrackSource
}

/**
 * iOS `DiscoverExplicitRanking`: stable re-rank by edition. Same title+artist groups anchor at first
 * appearance; within a group the preferred edition leads (null `explicit` is never preferred).
 */
object DiscoverExplicitRanking {
    fun rank(hits: List<DiscoverHit>, preferExplicit: Boolean): List<DiscoverHit> {
        val groups = LinkedHashMap<String, MutableList<DiscoverHit>>()
        for (h in hits) {
            groups.getOrPut(DiscoverMerge.normalize(h.title) + "\u0000" + DiscoverMerge.normalize(h.artist)) { mutableListOf() } += h
        }
        return groups.values.flatMap { g -> g.filter { it.explicit == preferExplicit } + g.filter { it.explicit != preferExplicit } }
    }
}

/** Pure merge / term / refine helpers shared by the song and album models. */
object DiscoverMerge {

    /** Title + artist joined (either alone is a valid way in). Null = nothing to search. */
    fun term(title: String, artist: String): String? =
        listOf(title.trim(), artist.trim()).filter { it.isNotEmpty() }.joinToString(" ").ifEmpty { null }

    /** Case + diacritic folded, trimmed. */
    fun normalize(s: String): String =
        Normalizer.normalize(s, Normalizer.Form.NFD).replace(Regex("\\p{Mn}+"), "")
            .lowercase(Locale.ROOT).trim()

    private fun containsArtist(hitArtist: String, refine: String): Boolean =
        normalize(hitArtist).contains(refine)

    fun refineSongs(hits: List<DiscoverHit>, artist: String): List<DiscoverHit> {
        val a = normalize(artist)
        return if (a.isEmpty()) hits else hits.filter { containsArtist(it.artist, a) }
    }

    fun refineAlbums(hits: List<DiscoverAlbumHit>, artist: String): List<DiscoverAlbumHit> {
        val a = normalize(artist)
        return if (a.isEmpty()) hits else hits.filter { containsArtist(it.artist, a) }
    }

    /**
     * REST (catalog) ranking leads; where the rip server knows the same track its ROW wins
     * (the manifest is the authority on ripped/url); server-only hits follow. Dedup by store id.
     */
    fun mergeSongs(rest: List<DiscoverHit>, server: List<DiscoverHit>): List<DiscoverHit> {
        val serverById = LinkedHashMap<String, DiscoverHit>()
        for (h in server) serverById.putIfAbsent(h.appleMusicId, h)
        val seen = HashSet<String>()
        val out = ArrayList<DiscoverHit>()
        for (h in rest) if (seen.add(h.appleMusicId)) out += serverById[h.appleMusicId] ?: h
        for (h in server) if (seen.add(h.appleMusicId)) out += h
        return out
    }

    /** Albums have no ripped/url authority: the REST row simply wins a tie. */
    fun mergeAlbums(rest: List<DiscoverAlbumHit>, server: List<DiscoverAlbumHit>): List<DiscoverAlbumHit> {
        val seen = HashSet<String>()
        val out = ArrayList<DiscoverAlbumHit>()
        for (h in rest) if (seen.add(h.appleMusicId)) out += h
        for (h in server) if (seen.add(h.appleMusicId)) out += h
        return out
    }

    /** Apple Music Web API song -> Discover row (the `amrec_` ad-hoc id convention). */
    fun hit(song: AmSong, ripUrl: String? = null): DiscoverHit = DiscoverHit(
        appleMusicId = song.id,
        title = song.title,
        artist = song.artist,
        album = song.album,
        artworkUrl = song.artworkUrl,
        durationMs = song.durationSec?.let { (it * 1000).toInt() },
        songId = "amrec_${song.id}",
        ripped = ripUrl != null,
        url = ripUrl,
        explicit = song.explicit,
    )

    fun hit(album: AmAlbum): DiscoverAlbumHit = DiscoverAlbumHit(
        appleMusicId = album.id,
        albumId = "amrec_album_${album.id}",
        title = album.title,
        artist = album.artist,
        artworkUrl = album.artworkUrl,
        trackCount = album.trackCount,
        year = album.releaseDate?.take(4)?.toIntOrNull(),
        releaseDate = album.releaseDate,
    )
}

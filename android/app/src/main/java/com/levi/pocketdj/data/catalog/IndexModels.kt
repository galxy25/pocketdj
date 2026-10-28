package com.levi.pocketdj.data.catalog

import com.levi.pocketdj.data.config.Endpoints
import kotlinx.serialization.Serializable

/**
 * Lean models for the catalog index documents (specs/catalog.md §2–§4).
 *
 * Deliberately models ONLY the fields the client consumes — the live documents
 * carry far more (`pointer`, `enrichment`, `indexing`, `cloudReindex`, …) and
 * dropping those unmodelled subtrees during parse is most of the decode win on
 * the 33 MB Apple Music index. Decode with [com.levi.pocketdj.data.PdjJson]:
 * unknown keys ignored, `"bpm": null` and an absent `bpm` both become `null`.
 */
@Serializable
data class IndexJson(
    val manifest: IndexManifest = IndexManifest(),
    val albums: List<IndexAlbum> = emptyList(),
    val songs: List<IndexSong> = emptyList(),
    /** Apple Music user-playlist mirrors; absent on vinyl/digital documents. */
    val playlists: List<IndexPlaylist>? = null,
    /** Apple Music name->artist-id join table; absent elsewhere. */
    val artists: List<IndexArtist>? = null,
)

/**
 * Artist-name -> Apple Music artist id table row. Lenient: every field defaulted so a
 * malformed row never fails the whole document. [key] is [normalize]d name.
 */
@Serializable
data class IndexArtist(
    val key: String = "",
    val name: String = "",
    val id: Long? = null,
    /** Advisory only — never branch on it. */
    val songs: Int? = null,
    val alt: List<Long>? = null,
) {
    companion object {
        /** trim, lowercase, collapse whitespace runs — must match the indexer's norm(). */
        fun normalize(raw: String): String =
            raw.trim().lowercase().split(Regex("\\s+")).filter { it.isNotEmpty() }.joinToString(" ")
    }
}

@Serializable
data class IndexManifest(
    val source: String? = null,
    val generatedAt: String? = null,
    val sourceName: String? = null,
    val counts: IndexCounts? = null,
) {
    /** Display name; iOS falls back to "Collection" (catalog.md §2). */
    val displayName: String get() = sourceName ?: FALLBACK_SOURCE_NAME

    companion object {
        const val FALLBACK_SOURCE_NAME = "Collection"
    }
}

@Serializable
data class IndexCounts(
    val albums: Int? = null,
    val songs: Int? = null,
)

@Serializable
data class IndexPlaylist(
    val id: String,
    val name: String,
    val songIds: List<String> = emptyList(),
)

@Serializable
data class ArtSource(
    val type: String? = null, // "cdn" | "remote"
    val url: String,
    val cors: Boolean? = null,
)

/** Vinyl audio segmentation — all fields optional (catalog.md §3). */
@Serializable
data class AudioTrack(
    val trackNumber: Int? = null,
    val startMs: Long? = null,
    val endMs: Long? = null,
    val durationMs: Long? = null,
    val bpm: Double? = null,
    val key: String? = null,
    val camelot: String? = null,
    val keyStrength: Double? = null,
)

@Serializable
data class IndexAlbum(
    val id: String,
    val artist: String,
    val name: String,
    val coverArt: String? = null,
    val coverArtSources: List<ArtSource>? = null,
    val genre: String? = null,
    val year: Int? = null,
    val country: String? = null,
    /** Ordered IndexSong.id refs. Required in the schema; defaulted for lenience. */
    val trackList: List<String> = emptyList(),
    val fileType: String? = null,
    val audioTracks: List<AudioTrack>? = null,
    val audioDurationSec: Double? = null,
    val appleMusicId: String? = null,
    val appleMusicUrl: String? = null,
    val spotifyUrl: String? = null,
    val youtubeUrl: String? = null,
) {
    /**
     * Ordered candidate art URLs, resolved and ready for Coil — every
     * `coverArtSources` entry in array order (indexer puts cdn first), then
     * `coverArt` as the final fallback (catalog.md §1).
     */
    fun artCandidates(): List<String> =
        (coverArtSources.orEmpty().map { it.url } + listOfNotNull(coverArt))
            .map(Endpoints::artUrl)
}

@Serializable
data class IndexSong(
    val id: String,
    val albumId: String? = null,
    val artist: String,
    val name: String,
    val trackNumber: Int? = null,
    val year: Int? = null,
    val sentimentKeywords: List<String>? = null,
    val explicit: Boolean? = null,
    /** `null` means "not analyzed yet" — the pipeline emits explicit nulls. */
    val bpm: Double? = null,
    val key: String? = null,
    val camelot: String? = null,
    /** MILLISECONDS (catalog.md §4). */
    val length: Long? = null,
    val fileType: String? = null,
    /** "found" | "notfound" | "error" — the only gate for fetching lyrics. */
    val lyricsStatus: String? = null,
    /** Metadata/join-key only on Android — never a playback path (no MusicKit). */
    val appleMusicId: String? = null,
    val appleMusicUrl: String? = null,
    val spotifyUrl: String? = null,
    val youtubeUrl: String? = null,
    /** Sibling edition catalog ids (resolve-explicit-variants); the primary is never rewritten. */
    val appleMusicIdExplicit: String? = null,
    val appleMusicIdClean: String? = null,
    /** Epoch ms the track was added to the source library. */
    val dateAdded: Double? = null,
) {
    /** Catalog id of the given edition, falling back to the primary when its explicitness matches. */
    fun appleMusicId(edition: com.levi.pocketdj.data.edition.SongVariant): String? = when (edition) {
        com.levi.pocketdj.data.edition.SongVariant.CLEAN ->
            appleMusicIdClean ?: if (explicit == false) appleMusicId else null
        com.levi.pocketdj.data.edition.SongVariant.EXPLICIT ->
            appleMusicIdExplicit ?: if (explicit == true) appleMusicId else null
    }
}

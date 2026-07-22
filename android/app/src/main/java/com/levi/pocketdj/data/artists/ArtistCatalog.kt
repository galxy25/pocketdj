package com.levi.pocketdj.data.artists

import com.levi.pocketdj.data.catalog.IndexAlbum
import com.levi.pocketdj.data.catalog.MergedCatalog
import java.text.Normalizer
import java.util.Locale

/**
 * One derived Artist row (specs/artists.md §3.1) — a group of consecutive
 * same-artist albums from the browse-ordered catalog.
 *
 * Field derivation is bit-for-bit iOS `AppModel.buildEffective`
 * (`AppModel.swift:483-499`):
 * - [name] = the FIRST grouped album's casing (the display name).
 * - [albumCount] = number of albums in the group.
 * - [songCount] = Σ over grouped albums of `trackList.size` — counts raw track
 *   ids (INCLUDING ids absent from the catalog and repeated ids), NOT resolved
 *   tracks. This is the same number the detail header shows (§3.2, §6.2), so the
 *   two never disagree. Never use [MergedCatalog.tracks] here.
 * - [artworkAlbumId] = the FIRST grouped album's id — the representative art,
 *   resolved lazily at render via `catalog.albumsById[artworkAlbumId]`.
 * - [searchKey] = folded artist NAME only (diacritic/case-insensitive), matching
 *   iOS `searchKey(artist)` (`AppModel.swift:497`) — search is name-scoped.
 */
data class Artist(
    val name: String,
    val albumCount: Int,
    val songCount: Int,
    val artworkAlbumId: String?,
    val searchKey: String,
)

/**
 * Derives the Artists browse kind from a [MergedCatalog] — the data-layer core
 * the Browse UI consumes (specs/artists.md §3, §6). Built once per catalog off
 * the main thread via the identity-keyed [of] memo, alongside `BrowseRows`.
 *
 * Grouping is single-pass and order-preserving: `catalog.albums` is already
 * sorted artist › name **case-insensitively** (`MergedCatalog.kt:98-101`), so
 * consecutive same-artist albums are adjacent and one linear pass groups them
 * WITHOUT a dictionary. The grouping predicate is `equals(ignoreCase = true)` —
 * the SAME case-insensitivity the sort uses — so a merged catalog whose sources
 * disagree on casing ("OutKast" vs "Outkast") fuses into ONE row (a
 * case-sensitive split would emit two rows with a duplicate LazyColumn key and
 * crash — specs/artists.md §12 trap 1).
 */
class ArtistCatalog private constructor(private val catalog: MergedCatalog) {

    /** All artist rows in catalog artist-order (no re-sort — §3.3). */
    val artists: List<Artist> = build(catalog.albums)

    /**
     * Name-scoped filter (specs/artists.md §3.3). Folds the query the same way
     * the search keys are folded (diacritic/case-insensitive) and strips
     * newlines so a query can't match across the row boundary (browse.md §4.1).
     * An empty query returns every artist.
     */
    fun filtered(query: String): List<Artist> {
        val folded = fold(query).replace("\n", "")
        return if (folded.isEmpty()) artists
        else artists.filter { it.searchKey.contains(folded) }
    }

    /**
     * One artist's discography, re-derived from the live catalog by display name
     * (specs/artists.md §6.1). Case-INSENSITIVE match — the SAME predicate as the
     * grouping — so a mixed-casing merged catalog gathers the whole discography,
     * not a subset of what the row's counts promised. Pre-sorted artist › name by
     * the merge, so no re-sort is needed.
     */
    fun albumsOf(artistName: String): List<IndexAlbum> =
        catalog.albums.filter { it.artist.equals(artistName, ignoreCase = true) }

    /**
     * The flat concatenation of each discography album's `trackList`, album by
     * album in track order (specs/artists.md §6.1). NOT deduped and NOT resolved
     * (raw ids) — the play funnel (`CollectionsStore.playNow`) drops the
     * unresolvable ones. Its size equals the row's [Artist.songCount] for the
     * matching name (same flat `trackList` total).
     */
    fun songIdsOf(artistName: String): List<String> =
        albumsOf(artistName).flatMap { it.trackList }

    companion object {
        @Volatile
        private var cached: Pair<MergedCatalog, ArtistCatalog>? = null

        /** One ArtistCatalog per catalog instance (identity-keyed memo). */
        fun of(catalog: MergedCatalog): ArtistCatalog =
            cached?.takeIf { it.first === catalog }?.second
                ?: ArtistCatalog(catalog).also { cached = catalog to it }

        /**
         * The single-pass grouping (specs/artists.md §3.2). Exposed for unit tests
         * that build rows directly from an album list.
         */
        fun build(albums: List<IndexAlbum>): List<Artist> {
            val out = ArrayList<Artist>()
            var i = 0
            while (i < albums.size) {
                val artist = albums[i].artist // group's first album → display casing
                var j = i
                var songCount = 0
                while (j < albums.size && albums[j].artist.equals(artist, ignoreCase = true)) {
                    songCount += albums[j].trackList.size // raw trackList, NOT resolved (§3.2)
                    j++
                }
                out.add(
                    Artist(
                        name = artist,
                        albumCount = j - i,
                        songCount = songCount,
                        artworkAlbumId = albums[i].id,
                        searchKey = fold(artist),
                    ),
                )
                i = j
            }
            return out
        }

        private val combiningMarks = Regex("""\p{Mn}+""")

        /**
         * Search fold — mirrors `screens/browse/Fmt.fold` (browse.md §4.1) exactly:
         * NFD-normalize, strip combining marks, lowercase locale-independently.
         * Reproduced here (rather than importing the screens layer) so the data
         * module stays independent of `screens.*`.
         */
        fun fold(value: String): String =
            combiningMarks
                .replace(Normalizer.normalize(value, Normalizer.Form.NFD), "")
                .lowercase(Locale.ROOT)
    }
}

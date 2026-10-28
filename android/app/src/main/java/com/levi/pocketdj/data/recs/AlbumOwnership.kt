package com.levi.pocketdj.data.recs

import com.levi.pocketdj.data.catalog.IndexAlbum
import com.levi.pocketdj.data.catalog.IndexArtist
import com.levi.pocketdj.data.catalog.IndexSong
import com.levi.pocketdj.data.catalog.MergedCatalog
import java.util.concurrent.ConcurrentHashMap

/**
 * How much of an album the user already has (port of iOS `AlbumOwnership`). PURE on purpose: a view that
 * decides this inline can only be checked by driving the UI, and "the button said the wrong thing" is the
 * defect class that ships green.
 */
sealed interface AlbumOwnership {
    data class None(val total: Int) : AlbumOwnership
    data class Partial(val owned: Int, val total: Int) : AlbumOwnership
    data class Owned(val total: Int) : AlbumOwnership

    /** The add button's title. "Add remaining (n)" is the honest wording for a part-owned album. */
    val addTitle: String
        get() = when (this) {
            is None -> "Add album to your library"
            is Partial -> "Add remaining (${total - owned})"
            is Owned -> "In your library"
        }

    val isFullyOwned: Boolean get() = this is Owned

    companion object {
        const val TRACK_PREFIX = "amrec_"
        const val ALBUM_PREFIX = "amrec_album_"

        /**
         * Whether the user has THIS store id, by any route it can arrive:
         *  - the provisional Discover/recognizer id (`<adHocPrefix><storeId>`) is in the catalog,
         *  - some catalog item claims that Apple Music id,
         *  - the rips manifest holds a prepared copy,
         *  - [localRecordMatch]: the FOURTH route and the only one that is not an id - the caller resolved
         *    the release to a record already in the library by artist + title. It is a parameter (not a
         *    forged synthetic id) so this stays the ONE place ownership is decided.
         * [adHocPrefix] is the only difference between a track and a whole album (`amrec_album_<id>`).
         */
        fun owns(
            storeId: String,
            catalogSongIds: Set<String>,
            catalogAppleMusicIds: Set<String>,
            rippedSongIds: Set<String>,
            adHocPrefix: String = TRACK_PREFIX,
            localRecordMatch: Boolean = false,
        ): Boolean {
            val adHoc = adHocPrefix + storeId
            return adHoc in catalogSongIds || storeId in catalogAppleMusicIds || adHoc in rippedSongIds || localRecordMatch
        }

        /** Roll the per-track answer up. No known tracks = None(0): "you own all zero" would hide the add. */
        fun of(
            trackStoreIds: List<String>,
            catalogSongIds: Set<String>,
            catalogAppleMusicIds: Set<String>,
            rippedSongIds: Set<String>,
        ): AlbumOwnership {
            val total = trackStoreIds.size
            if (total == 0) return None(0)
            val owned = trackStoreIds.count { owns(it, catalogSongIds, catalogAppleMusicIds, rippedSongIds) }
            return when {
                owned == 0 -> None(total)
                owned >= total -> Owned(total)
                else -> Partial(owned, total)
            }
        }
    }
}

/**
 * The catalog joins the New feed's ownership filter reads (port of `AppModel.ownedAlbumRecordIndex` /
 * `ownedVersionIndex` / `artistKeysByAppleArtistId`), built once per catalog off the main thread and memoised
 * per asked-about artist so a read on the render path is a map hit plus that artist's own title parses.
 *
 * Apple ships several store ids for one record, a pre-order has no resolvable id at all, and the live Apple
 * Music library source emits no album id - so an id comparison alone misses albums he already has (26% of a
 * real library's albums carry no appleMusicId). The record route compares artist + base title instead.
 */
class OwnedCatalogIndex(private val catalog: MergedCatalog, artists: List<IndexArtist>? = null) {

    /** Every artist key an album is credited to (collaboration credits are filed under each name). */
    private val albumsByArtistKey: Map<String, List<IndexAlbum>> = HashMap<String, MutableList<IndexAlbum>>().also { m ->
        for (a in catalog.albums) for (k in RecVersionIdentity.creditArtistKeys(a.artist)) m.getOrPut(k) { ArrayList() }.add(a)
    }

    private val songsByArtistKey: Map<String, List<IndexSong>> by lazy {
        HashMap<String, MutableList<IndexSong>>().also { m ->
            for (s in catalog.songs) for (k in RecVersionIdentity.creditArtistKeys(s.artist)) m.getOrPut(k) { ArrayList() }.add(s)
        }
    }

    /** Apple artist id -> the artist keys the index files that artist under (incl. `alt` ids). */
    private val artistKeysByAppleId: Map<Long, List<String>> = artistKeysByAppleId(artists.orEmpty())

    private val albumIdByAppleMusicId: Map<String, String> = HashMap<String, String>().also { m ->
        for (a in catalog.albums) a.appleMusicId?.takeIf { it.isNotBlank() }?.let { m.putIfAbsent(it, a.id) }
    }
    private val songIdByAppleMusicId: Map<String, String> by lazy {
        HashMap<String, String>().also { m ->
            for (s in catalog.songs) {
                for (id in listOfNotNull(s.appleMusicId, s.appleMusicIdExplicit, s.appleMusicIdClean)) {
                    if (id.isNotBlank()) m.putIfAbsent(id, s.id)
                }
            }
        }
    }

    private val recordCache = ConcurrentHashMap<String, RecVersionIndex>()
    private val versionCache = ConcurrentHashMap<String, RecVersionIndex>()

    fun albumId(forAppleMusicId: String): String? = albumIdByAppleMusicId[forAppleMusicId]
    fun songId(forAppleMusicId: String): String? = songIdByAppleMusicId[forAppleMusicId]
    fun hasAlbum(id: String): Boolean = catalog.albumsById.containsKey(id)

    private fun aliasKeys(artistId: Int?, exclude: String): List<String> =
        artistId?.let { artistKeysByAppleId[it.toLong()] }.orEmpty().filter { it != exclude }

    /**
     * WHICH ALBUMS BY THIS ARTIST HE ALREADY HAS, in version space. ALBUMS ONLY - that is how the
     * no-over-suppression line is held (owning one album never hides a different album by the artist).
     * Route 1: the artist key and every album crediting it. Route 2: whatever his index calls the artist
     * this release is filed under (UNIONED, not a fallback - the two reach different albums). Re-keyed under
     * the ASKED artist so what is compared is title against title.
     */
    fun ownedAlbumRecordIndex(artistName: String, artistId: Int? = null): RecVersionIndex {
        val artistKey = RecVersionIdentity.ownershipArtistKey(artistName)
        if (artistKey.isEmpty()) return RecVersionIndex.EMPTY
        val memo = artistKey + "\u0001" + (artistId?.toString() ?: "")
        return recordCache.getOrPut(memo) {
            val albums = LinkedHashMap<String, IndexAlbum>()
            albumsByArtistKey[artistKey]?.forEach { albums.putIfAbsent(it.id, it) }
            for (alias in aliasKeys(artistId, artistKey)) albumsByArtistKey[alias]?.forEach { albums.putIfAbsent(it.id, it) }
            val keys = ArrayList<RecVersionIdentity.Key>()
            for (a in albums.values) {
                val k = RecVersionIdentity.keyWithArtistKey(a.name, artistKey) ?: continue
                keys += k
                RecVersionIdentity.spacelessKey(k)?.let { keys += it }
            }
            RecVersionIndex(keys)
        }
    }

    /**
     * Everything he has by this artist (songs AND albums) as version keys: a Deluxe reissue is a NEW album in
     * Apple's catalog with a NEW store id, so the store-id probe says "new" - correctly and uselessly.
     * Albums are keyed by the ALBUM's own credit, so a compilation track by this artist does not file
     * "Now That's What I Call Music 42" under his name.
     */
    fun ownedVersionIndex(artistName: String, artistId: Int? = null): RecVersionIndex {
        val artistKey = RecVersionIdentity.ownershipArtistKey(artistName)
        if (artistKey.isEmpty()) return RecVersionIndex.EMPTY
        val memo = artistKey + "\u0001" + (artistId?.toString() ?: "")
        return versionCache.getOrPut(memo) {
            val songs = LinkedHashMap<String, IndexSong>()
            songsByArtistKey[artistKey]?.forEach { songs.putIfAbsent(it.id, it) }
            for (alias in aliasKeys(artistId, artistKey)) songsByArtistKey[alias]?.forEach { songs.putIfAbsent(it.id, it) }
            val keys = ArrayList<RecVersionIdentity.Key>()
            val seenAlbums = HashSet<String>()
            for (s in songs.values) {
                RecVersionIdentity.key(s.name, s.artist)?.let { keys += it }
                val aid = s.albumId ?: continue
                if (!seenAlbums.add(aid)) continue
                val album = catalog.albumsById[aid] ?: continue
                RecVersionIdentity.key(album.name, album.artist)?.let { keys += it }
            }
            RecVersionIndex(keys)
        }
    }

    companion object {
        /** `AppModel.artistKeysByAppleId`: id and every alt id -> ownership artist key of the indexed name. */
        fun artistKeysByAppleId(artists: List<IndexArtist>): Map<Long, List<String>> {
            val map = HashMap<Long, MutableList<String>>()
            for (a in artists) {
                val id = a.id ?: continue
                val key = RecVersionIdentity.ownershipArtistKey(a.name.ifEmpty { a.key })
                if (key.isEmpty()) continue
                for (i in listOf(id) + a.alt.orEmpty()) {
                    val list = map.getOrPut(i) { ArrayList() }
                    if (key !in list) list += key
                }
            }
            return map
        }
    }
}

/** The two probes the release feed injects, composed against a live [OwnedCatalogIndex]. */
object ReleaseOwnershipProbes {

    /**
     * Given everything a release is known by, does the owner already have that album? `AlbumOwnership.owns`
     * stays the ONLY thing that decides; the release is resolved to a local album by any of three routes
     * (provisional `amrec_album_<id>`, a real album claiming that Apple Music id, or a same-record title
     * match) and what it compares is the claim that produced. A `.distinct` performance (Live / Acoustic) fails
     * OPEN unless the titles are letter-for-letter identical, so a live album of a record he owns is still new.
     * [ripped] is always empty: an album is never in the rips manifest (that is keyed by song).
     */
    fun ownership(indexProvider: () -> OwnedCatalogIndex?): (ReleaseIdentity) -> Boolean = { release ->
        val index = indexProvider()
        if (index == null) false else {
            val adHocId = AlbumOwnership.ALBUM_PREFIX + release.storeId
            // Minimal singleton sets, never the whole catalog's ids (O(90k) per row is the perf trap).
            val provisional = if (index.hasAlbum(adHocId)) setOf(adHocId) else emptySet()
            val claimed = if (index.albumId(release.storeId) != null) setOf(release.storeId) else emptySet()
            val byRecord = release.title?.let {
                index.ownedAlbumRecordIndex(release.artistName, release.artistId).hasRecord(it, release.artistName)
            } ?: false
            AlbumOwnership.owns(
                storeId = release.storeId,
                catalogSongIds = provisional,
                catalogAppleMusicIds = claimed,
                rippedSongIds = emptySet(),
                adHocPrefix = AlbumOwnership.ALBUM_PREFIX,
                localRecordMatch = byRecord,
            )
        }
    }

    /** Does he already have this record in another edition or reworking? Empty index suppresses nothing. */
    fun version(indexProvider: () -> OwnedCatalogIndex?): (Int, String, String) -> Boolean = { artistId, artistName, title ->
        val index = indexProvider()
        if (index == null) false else {
            val owned = index.ownedVersionIndex(artistName, artistId)
            !owned.isEmpty && owned.supersedes(title, artistName)
        }
    }
}

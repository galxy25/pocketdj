package com.levi.pocketdj.data.catalog

import com.levi.pocketdj.data.PdjJson
import com.levi.pocketdj.data.collections.io.PortableItems
import java.io.File
import kotlinx.serialization.Serializable
import kotlinx.serialization.encodeToString

/**
 * PROVISIONAL catalog entries for IMPORTED collections (iOS `ImportedSongsStore`). A playlist/pocket zip
 * from another profile can reference songs outside this device's enabled sources; the import
 * materializes them as the synthetic "Imported" source so they browse/add/play by id (the rips manifest
 * keys on the song id, which travels verbatim).
 *
 * SUPERSEDE DOCTRINE: the synthetic document is appended AFTER every real source in the merge, so a real
 * source carrying the same id shadows the provisional entry by merge order alone; the entry is KEPT (never
 * pruned) so disabling that source later restores the durable fallback. Only `amrec_` ids (per-device ad-hoc
 * captures) are ever remapped onto an indexed twin ([supersedePairs]).
 *
 * Persists to `pocketdj-imported-songs.json`; the decode is lenient (a missing/corrupt/foreign document is an
 * empty store, never a crash) and every field defaults so an older/newer doc round-trips.
 */
class ImportedSongsStore(private val file: File) {
    @Serializable
    data class SongEntry(
        val songId: String,
        val title: String = "",
        val artist: String = "",
        val albumId: String? = null,
        val album: String? = null,
        val artworkUrl: String? = null,
        val durationMs: Long? = null,
        val bpm: Double? = null,
        val key: String? = null,
        val camelot: String? = null,
        val year: Int? = null,
        val appleMusicId: String? = null,
        val addedAtMs: Double = 0.0,
    )

    @Serializable
    data class AlbumEntry(
        val albumId: String,
        val name: String = "",
        val artist: String = "",
        val trackIds: List<String> = emptyList(),
        val artworkUrl: String? = null,
        val genre: String? = null,
        val year: Int? = null,
        val addedAtMs: Double = 0.0,
    )

    @Serializable
    internal data class Document(
        val schemaVersion: Int = 1,
        val songs: List<SongEntry> = emptyList(),
        val albums: List<AlbumEntry> = emptyList(),
    )

    private val lock = Any()
    private var songs: List<SongEntry>
    private var albums: List<AlbumEntry>

    /** Cached synthetic document: the SAME instance until the entries change (keeps CatalogRepository's no-op-merge check cheap). */
    private var cachedDoc: IndexJson? = null

    /** Fired (outside the lock) after a USER/import batch added NEW rows - the app refreshes the catalog. */
    @Volatile var onChanged: (() -> Unit)? = null

    init {
        val doc = decode(file)
        songs = doc.songs.distinctBy { it.songId }
        albums = doc.albums.distinctBy { it.albumId }
    }

    fun songs(): List<SongEntry> = synchronized(lock) { songs }
    fun albums(): List<AlbumEntry> = synchronized(lock) { albums }

    /** Idempotent per id (first wins). Returns the number of NEW rows. */
    fun add(newSongs: List<SongEntry>, newAlbums: List<AlbumEntry> = emptyList()): Int {
        val added: Int
        synchronized(lock) {
            val songIds = songs.mapTo(HashSet()) { it.songId }
            val albumIds = albums.mapTo(HashSet()) { it.albumId }
            val freshSongs = newSongs.distinctBy { it.songId }.filter { songIds.add(it.songId) == true }
            val freshAlbums = newAlbums.distinctBy { it.albumId }.filter { albumIds.add(it.albumId) == true }
            added = freshSongs.size + freshAlbums.size
            if (added == 0) return 0
            songs = songs + freshSongs
            albums = albums + freshAlbums
            cachedDoc = null
            save()
        }
        onChanged?.invoke()
        return added
    }

    /** Materialize a portable snapshot's items (COL-14 seam payload). */
    fun addPortable(payload: PortableItems.Payload, nowMs: Double = System.currentTimeMillis().toDouble()): Int {
        val (s, a) = entriesFor(payload, nowMs)
        return add(s, a)
    }

    /** Drop remapped (amrec_ supersede) entries. */
    fun remove(songIds: Collection<String>) {
        if (songIds.isEmpty()) return
        synchronized(lock) {
            val gone = songIds.toSet()
            val next = songs.filterNot { it.songId in gone }
            if (next.size == songs.size) return
            songs = next
            cachedDoc = null
            save()
        }
        onChanged?.invoke()
    }

    /**
     * A cloud pull rewrote [file] (iOS `reloadFromDisk`, key `imported-songs`): re-adopt it and refresh the
     * catalog so pulled imports flow into the merge. Returns false (the pulled bytes stay as written).
     */
    fun reloadFromDisk(): Boolean {
        val doc = decode(file)
        val changed: Boolean
        synchronized(lock) { changed = adopt(doc) }
        if (changed) onChanged?.invoke()
        return false
    }

    /** SyncEntry.applyPayload seam: write the pulled bytes + re-adopt under [lock] so a concurrent add()/remove() cannot interleave. */
    fun writePulled(bytes: ByteArray) {
        val changed: Boolean
        synchronized(lock) {
            file.parentFile?.mkdirs()
            val tmp = File(file.parentFile, file.name + ".tmp")
            tmp.writeBytes(bytes)
            if (!tmp.renameTo(file)) { file.writeBytes(bytes); tmp.delete() }
            changed = adopt(decode(file))
        }
        if (changed) onChanged?.invoke()
    }

    /** Caller holds [lock]. True when the song/album id sets changed. */
    private fun adopt(doc: Document): Boolean {
        val s = doc.songs.distinctBy { it.songId }
        val a = doc.albums.distinctBy { it.albumId }
        val same = s.map { it.songId }.toSet() == songs.map { it.songId }.toSet() &&
            a.map { it.albumId }.toSet() == albums.map { it.albumId }.toSet()
        songs = s; albums = a; cachedDoc = null
        return !same
    }

    fun clear() {
        synchronized(lock) {
            songs = emptyList(); albums = emptyList(); cachedDoc = null
            runCatching { file.delete() }
        }
        onChanged?.invoke()
    }

    /**
     * Resolve against this merge's REAL documents (first-seen claimant per Apple Music id wins, as iOS
     * `withProvisionalSources`): remapped `amrec_` rows leave the document and come back as pairs.
     */
    fun resolve(realDocs: List<IndexJson>): Resolution {
        val (s, a) = synchronized(lock) { songs to albums }
        if (s.isEmpty() && a.isEmpty()) return Resolution.EMPTY
        // Memoized on the identity of the entries + real docs so CatalogRepository's identity-based
        // sameInputs no-op check still short-circuits unchanged refreshes.
        synchronized(lock) {
            val m = memo
            if (m != null && m.songs === s && m.albums === a && m.real.size == realDocs.size &&
                m.real.indices.all { m.real[it] === realDocs[it] }
            ) return m.result
        }
        val r = resolveEntries(s, a, realDocs)
        synchronized(lock) { memo = Memo(s, a, realDocs.toList(), r) }
        return r
    }

    private class Memo(val songs: List<SongEntry>, val albums: List<AlbumEntry>, val real: List<IndexJson>, val result: Resolution)
    private var memo: Memo? = null

    /** The synthetic source for the catalog merge; null when empty. Stable instance between changes. */
    fun syntheticDocument(): IndexJson? = synchronized(lock) {
        if (songs.isEmpty() && albums.isEmpty()) return null
        cachedDoc ?: syntheticIndex(songs, albums).also { cachedDoc = it }
    }

    private fun save() {
        runCatching {
            val bytes = PdjJson.lenient.encodeToString(Document(songs = songs, albums = albums)).toByteArray()
            val tmp = File(file.parentFile, file.name + ".tmp")
            tmp.writeBytes(bytes)
            if (!tmp.renameTo(file)) { file.writeBytes(bytes); tmp.delete() }
        }
    }

    class Resolution(val documents: List<IndexJson>, val pairs: List<Pair<String, String>>) {
        companion object { val EMPTY = Resolution(emptyList(), emptyList()) }
    }

    companion object {
        /**
         * Land a supersede. Durability deviation from iOS order (documented): remap collections + favorites
         * FIRST (idempotent), then prune the imported rows, because the pair is only derivable while the
         * amrec_ row exists on disk; a kill mid-sequence re-derives the pair on the next merge.
         * A throwing step never blocks the following ones.
         */
        fun landSupersede(
            pairs: List<Pair<String, String>>,
            removeImported: (List<String>) -> Unit,
            remapCollections: (List<Pair<String, String>>) -> Unit,
            remapFavorites: (List<Pair<String, String>>) -> Unit,
        ) {
            if (pairs.isEmpty()) return
            runCatching { remapCollections(pairs) }
            runCatching { remapFavorites(pairs) }
            runCatching { removeImported(pairs.map { it.first }) }
        }

        /** Pure core of [resolve]. */
        fun resolveEntries(songs: List<SongEntry>, albums: List<AlbumEntry>, realDocs: List<IndexJson>): Resolution {
            val byAm = HashMap<String, String>()
            for (d in realDocs) for (x in d.songs) x.appleMusicId?.takeIf { it.isNotEmpty() }?.let { byAm.putIfAbsent(it, x.id) }
            val pairs = supersedePairs(songs, byAm)
            val gone = pairs.mapTo(HashSet()) { it.first }
            val kept = songs.filterNot { it.songId in gone }
            val doc = if (kept.isEmpty() && albums.isEmpty()) emptyList() else listOf(syntheticIndex(kept, albums))
            return Resolution(doc, pairs)
        }

        const val FILE_NAME = "pocketdj-imported-songs.json"
        /** Cloud-sync document key (iOS `imported-songs`). */
        const val SYNC_KEY = "imported-songs"
        const val SOURCE_NAME = "Imported"

        internal fun decode(file: File): Document =
            runCatching { PdjJson.lenient.decodeFromString(Document.serializer(), file.readText()) }
                .getOrDefault(Document())

        /** Lenient document decode from raw text (cloud pull / tests). */
        fun decodeText(text: String): Pair<List<SongEntry>, List<AlbumEntry>> =
            runCatching { PdjJson.lenient.decodeFromString(Document.serializer(), text) }
                .getOrDefault(Document()).let { it.songs to it.albums }

        fun entriesFor(payload: PortableItems.Payload, nowMs: Double): Pair<List<SongEntry>, List<AlbumEntry>> {
            val albumNameById = payload.albums.associate { it.id to it.name }
            val albumCoverById = payload.albums.mapNotNull { a -> a.coverArtUrl?.let { a.id to it } }.toMap()
            val songs = payload.songs.map { s ->
                SongEntry(
                    songId = s.id, title = s.name, artist = s.artist, albumId = s.albumId,
                    album = s.albumId?.let(albumNameById::get), durationMs = s.lengthMs, bpm = s.bpm,
                    key = s.key, camelot = s.camelot, year = s.year, appleMusicId = s.appleMusicId, addedAtMs = nowMs,
                    artworkUrl = s.albumId?.let { id -> albumCoverById[id] },
                )
            }
            val albums = payload.albums.map { a ->
                AlbumEntry(a.id, a.name, a.artist, a.trackIds, a.coverArtUrl, a.genre, a.year, nowMs)
            }
            return songs to albums
        }

        fun indexSong(e: SongEntry) = IndexSong(
            id = e.songId, albumId = e.albumId, artist = e.artist, name = e.title, year = e.year,
            bpm = e.bpm, key = e.key, camelot = e.camelot, length = e.durationMs, appleMusicId = e.appleMusicId,
        )

        fun indexAlbum(e: AlbumEntry) = IndexAlbum(
            id = e.albumId, artist = e.artist, name = e.name, coverArt = e.artworkUrl,
            genre = e.genre, year = e.year, trackList = e.trackIds,
        )

        fun syntheticIndex(songs: List<SongEntry>, albums: List<AlbumEntry>) = IndexJson(
            manifest = IndexManifest(source = "imported-songs", sourceName = SOURCE_NAME),
            albums = albums.map(::indexAlbum), songs = songs.map(::indexSong),
        )

        /**
         * amrec_-ONLY remap split: an imported ad-hoc capture whose Apple Music id is claimed by an indexed song
         * yields to it; everything else keeps its exact id (tight-matching doctrine).
         */
        fun supersedePairs(entries: List<SongEntry>, indexedByAppleMusicId: Map<String, String>): List<Pair<String, String>> =
            entries.mapNotNull { e ->
                if (!e.songId.startsWith("amrec_")) return@mapNotNull null
                val am = e.appleMusicId ?: return@mapNotNull null
                val idx = indexedByAppleMusicId[am] ?: return@mapNotNull null
                if (idx == e.songId) null else e.songId to idx
            }
    }
}

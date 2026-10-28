package com.levi.pocketdj.data.discover

import com.levi.pocketdj.data.PdjJson
import com.levi.pocketdj.data.catalog.IndexAlbum
import com.levi.pocketdj.data.catalog.IndexJson
import com.levi.pocketdj.data.catalog.IndexManifest
import com.levi.pocketdj.data.catalog.IndexSong
import java.io.File
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.asStateFlow
import kotlinx.serialization.Serializable
import kotlinx.serialization.encodeToString

/**
 * PROVISIONAL catalog entries for Discover adds (iOS `DiscoverAddsStore`) - the eventual-consistency half
 * of "+ Add": the tap makes the song a first-class catalog citizen IMMEDIATELY (browsable, collectable,
 * playable off the server's queued `amrec_` capture) while the nightly Apple Music indexer stays the source
 * of truth; once it lands the track as a real library entry the INDEXED version supersedes the provisional
 * one and collection references are remapped onto it ([ProvisionalSource]).
 *
 * Persists to `pocketdj-discover-adds.json` (same name as iOS so the profile sync unions it). HARD RULE
 * (the schema-wipe lesson): every field past the identity is OPTIONAL and APPENDED, `schemaVersion` stays 1,
 * and the decode is lenient - an OLD peer's copy (no `albums`, no richer metadata) must round-trip unharmed.
 */
class DiscoverAddsStore(private val file: File) {

    @Serializable
    data class Entry(
        /** Ad-hoc rip id (`amrec_<storeId>`) - the id the rips manifest, stream path and burn/stem flows key on. */
        val songId: String = "",
        /** Apple Music store id - the SUPERSEDE join key against indexed songs. */
        val appleMusicId: String = "",
        val title: String = "",
        val artist: String = "",
        val album: String? = null,
        val artworkUrl: String? = null,
        val durationMs: Int? = null,
        val addedAtMs: Double = 0.0,
        /** Provisional album id (`amrec_album_<collectionId>`) - set ONLY by an album-scope add. */
        val albumId: String? = null,
        val albumAppleMusicId: String? = null,
        val albumArtworkUrl: String? = null,
        val trackNumber: Int? = null,
        val discNumber: Int? = null,
        val year: Int? = null,
        val genre: String? = null,
        val explicit: Boolean? = null,
        /** Library-write outcome token ("confirmed" or an annotation); null = legacy, NOT proof of a write. */
        val libraryWrite: String? = null,
    )

    @Serializable
    data class AlbumEntry(
        val albumId: String = "",
        /** Apple Music album store id (iTunes collectionId) - the SUPERSEDE join key. */
        val appleMusicId: String = "",
        val title: String = "",
        val artist: String = "",
        /** Per-track provisional song ids this album expanded into. */
        val trackIds: List<String>? = null,
        val artworkUrl: String? = null,
        val year: Int? = null,
        val addedAtMs: Double = 0.0,
        val trackCount: Int? = null,
        val genre: String? = null,
        val url: String? = null,
        /** Whether the add ALSO asked the rip server for per-track copies; null = pre-split document. */
        val preparedCopies: Boolean? = null,
        val libraryWrite: String? = null,
        val releaseDateMs: Double? = null,
        val lastRefreshAtMs: Double? = null,
        /** Track ids whose rip reached a terminal error - persisted so a relaunch still settles to Partial. */
        val failedTrackIds: List<String>? = null,
    )

    @Serializable
    internal data class Document(
        val schemaVersion: Int = 1,
        val entries: List<Entry> = emptyList(),
        /** OPTIONAL by design: an old document with no `albums` key decodes with null. */
        val albums: List<AlbumEntry>? = null,
    )

    /** One immutable snapshot (the controller's progress flow keys off it). */
    data class Snapshot(val entries: List<Entry>, val albums: List<AlbumEntry>)

    /** A user catalog add/remove item for the History activity log. */
    data class CatalogItem(val id: String, val title: String, val artist: String? = null)

    private val lock = Any()
    private val _state: MutableStateFlow<Snapshot>
    val state: StateFlow<Snapshot>

    /** Cached synthetic resolution: the SAME [IndexJson] instance while the surviving rows are unchanged. */
    private var cachedKey: Pair<List<Entry>, List<AlbumEntry>>? = null
    private var cachedDoc: IndexJson? = null

    /** Fired (outside the lock) when the provisional rows changed and the live catalog must be rebuilt. */
    @Volatile var onChanged: (() -> Unit)? = null

    /**
     * Fired ONLY from USER add gestures (never from a cloud pull) with the item(s) to log as `catalogAdd`:
     * a single song for a track add, the ALBUM itself for an album add. Second arg = library-write token.
     */
    @Volatile var onUserCatalogAdd: ((items: List<CatalogItem>, libraryWrite: String?) -> Unit)? = null

    init {
        val doc = decode(file)
        _state = MutableStateFlow(Snapshot(doc.entries.clean(), (doc.albums ?: emptyList()).cleanAlbums()))
        state = _state.asStateFlow()
    }

    val entries: List<Entry> get() = _state.value.entries
    val albums: List<AlbumEntry> get() = _state.value.albums

    fun entry(songId: String): Entry? = _state.value.entries.firstOrNull { it.songId == songId }
    fun albumEntry(albumId: String): AlbumEntry? = _state.value.albums.firstOrNull { it.albumId == albumId }
    fun albumByAppleMusicId(id: String): AlbumEntry? = _state.value.albums.firstOrNull { it.appleMusicId == id }

    /** Record a song add (idempotent per songId). Returns true when a NEW row was recorded. */
    fun add(entry: Entry): Boolean {
        val fresh = entry.copy(addedAtMs = if (entry.addedAtMs > 0) entry.addedAtMs else now())
        if (fresh.songId.isBlank()) return false
        synchronized(lock) {
            if (_state.value.entries.any { it.songId == fresh.songId }) return false
            publish(_state.value.copy(entries = _state.value.entries + fresh))
            save()
        }
        onUserCatalogAdd?.invoke(listOf(CatalogItem(fresh.songId, fresh.title, fresh.artist)), fresh.libraryWrite)
        onChanged?.invoke()
        return true
    }

    /**
     * Batched ALBUM add (the perf path for a fan-out): record every provisional track (idempotent per
     * songId) PLUS the album (idempotent per albumId), persist ONCE and fire ONE [onChanged] so the app
     * rebuilds the catalog exactly once for the album, never once per track. [songs] are gated by the
     * caller (only tracks whose rip was ACCEPTED arrive - no dead rows).
     */
    fun addAlbumBatch(album: AlbumEntry, songs: List<Entry>): Boolean {
        val albumEntry: AlbumEntry?
        synchronized(lock) {
            val have = _state.value.entries.mapTo(HashSet()) { it.songId }
            val fresh = songs.filter { it.songId.isNotBlank() }.distinctBy { it.songId }.filter { it.songId !in have }
            val albumIsNew = _state.value.albums.none { it.albumId == album.albumId }
            if (fresh.isEmpty() && !albumIsNew) return false
            albumEntry = if (albumIsNew) album.copy(addedAtMs = if (album.addedAtMs > 0) album.addedAtMs else now()) else null
            publish(
                Snapshot(
                    _state.value.entries + fresh,
                    if (albumEntry != null) _state.value.albums + albumEntry else _state.value.albums,
                ),
            )
            save()
        }
        // One album-level catalog-add for the whole batch, only when the album is genuinely new.
        albumEntry?.let { onUserCatalogAdd?.invoke(listOf(CatalogItem(it.albumId, it.title, it.artist)), it.libraryWrite) }
        onChanged?.invoke()
        return true
    }

    /**
     * Replace the stored library-write outcome of a provisional album (the retry heal). A token that newly
     * PROVES the write logs a truthful catalogAdd; idempotent for an unchanged token.
     */
    fun recordAlbumLibraryWrite(albumId: String, token: String) {
        var log: AlbumEntry? = null
        synchronized(lock) {
            val i = _state.value.albums.indexOfFirst { it.albumId == albumId }
            if (i < 0 || _state.value.albums[i].libraryWrite == token) return
            val old = _state.value.albums[i]
            val updated = old.copy(libraryWrite = token)
            publish(_state.value.copy(albums = _state.value.albums.toMutableList().also { it[i] = updated }))
            save()
            if (provenByToken(token) && !provenByToken(old.libraryWrite)) log = updated
        }
        log?.let { onUserCatalogAdd?.invoke(listOf(CatalogItem(it.albumId, it.title, it.artist)), it.libraryWrite) }
    }

    /** Drop SUPERSEDED entries (their indexed replacements own the ids now). Never fires [onChanged]. */
    fun remove(ids: Collection<String>) {
        if (ids.isEmpty()) return
        synchronized(lock) {
            val gone = ids.toSet()
            val next = _state.value.entries.filterNot { it.songId in gone }
            if (next.size == _state.value.entries.size) return
            publish(_state.value.copy(entries = next))
            save()
        }
    }

    /** Drop SUPERSEDED album entries. Never fires [onChanged]. */
    fun removeAlbums(albumIds: Collection<String>) {
        if (albumIds.isEmpty()) return
        synchronized(lock) {
            val gone = albumIds.toSet()
            val next = _state.value.albums.filterNot { it.albumId in gone }
            if (next.size == _state.value.albums.size) return
            publish(_state.value.copy(albums = next))
            save()
        }
    }

    /**
     * Supersede ALBUMS (provisional album id -> indexed album id): persist the remapped albumId on surviving
     * song entries, then drop the provisional album rows. Never fires [onChanged].
     */
    fun supersedeAlbums(pairs: List<Pair<String, String>>) {
        if (pairs.isEmpty()) return
        synchronized(lock) {
            val map = pairs.toMap()
            val snap = _state.value
            val entries = snap.entries.map { e -> e.albumId?.let(map::get)?.let { e.copy(albumId = it) } ?: e }
            val albums = snap.albums.filterNot { it.albumId in map }
            if (entries == snap.entries && albums.size == snap.albums.size) return
            publish(Snapshot(entries, albums))
            save()
        }
    }

    /** Persist terminal-error track ids onto the albums that own them. Never fires [onChanged]. */
    fun recordFailedTracks(failed: Set<String>) {
        if (failed.isEmpty()) return
        synchronized(lock) {
            var changed = false
            val albums = _state.value.albums.map { a ->
                val fresh = a.trackIds.orEmpty().filter { it in failed && it !in a.failedTrackIds.orEmpty() }
                if (fresh.isEmpty()) a else { changed = true; a.copy(failedTrackIds = a.failedTrackIds.orEmpty() + fresh) }
            }
            if (!changed) return
            publish(_state.value.copy(albums = albums))
            save()
        }
    }

    /**
     * USER "Remove from Library" for a provisional Discover SONG - DISTINCT from the supersede [remove]
     * (which yields the id to its real indexed replacement). Drops the entry, refreshes the catalog and
     * returns its item so the caller can log `catalogRemove`. Idempotent (null when absent).
     */
    fun userRemove(songId: String): CatalogItem? {
        val removed: Entry
        synchronized(lock) {
            removed = _state.value.entries.firstOrNull { it.songId == songId } ?: return null
            publish(
                _state.value.copy(
                    entries = _state.value.entries.filterNot { it.songId == songId },
                    // A removed track must not pin its album's n/m forever.
                    albums = _state.value.albums.map { a ->
                        if (a.trackIds?.contains(songId) == true) {
                            a.copy(
                                trackIds = a.trackIds.filterNot { it == songId },
                                failedTrackIds = a.failedTrackIds?.filterNot { it == songId },
                            )
                        } else a
                    },
                ),
            )
            save()
        }
        onChanged?.invoke()
        return CatalogItem(removed.songId, removed.title, removed.artist)
    }

    fun clear() {
        synchronized(lock) {
            publish(Snapshot(emptyList(), emptyList()))
            runCatching { file.delete() }
        }
        onChanged?.invoke()
    }

    /** Re-decode after a profile-sync pull rewrote the file; refreshes the catalog when rows changed. */
    fun reloadFromDisk(): Boolean {
        val doc = decode(file)
        val next = Snapshot(doc.entries.clean(), (doc.albums ?: emptyList()).cleanAlbums())
        val changed = synchronized(lock) {
            val c = next != _state.value
            if (c) publish(next)
            c
        }
        if (changed) onChanged?.invoke()
        return false // nothing re-saved
    }

    /**
     * The provisional source for a catalog merge over [realDocs] (every REAL source, in merge order):
     * rows whose Apple Music id a real row claims are superseded (excluded from the document and reported
     * as remap pairs). The document instance is stable while the surviving rows are unchanged.
     */
    fun resolve(realDocs: List<IndexJson>): ProvisionalSource.Result = synchronized(lock) {
        val snap = _state.value
        val r = ProvisionalSource.resolve(snap.entries, snap.albums, realDocs)
        val key = r.keptEntries to r.keptAlbums
        if (cachedKey == key && cachedDoc != null) {
            r.copy(documents = listOfNotNull(cachedDoc.takeIf { r.documents.isNotEmpty() }))
        } else {
            cachedKey = key
            cachedDoc = r.documents.firstOrNull()
            r
        }
    }

    private fun publish(next: Snapshot) { _state.value = next }

    private fun save() {
        runCatching {
            val s = _state.value
            val doc = Document(entries = s.entries, albums = s.albums.ifEmpty { null })
            val bytes = PdjJson.lenient.encodeToString(doc).toByteArray()
            val tmp = File(file.parentFile, file.name + ".tmp")
            tmp.writeBytes(bytes)
            if (!tmp.renameTo(file)) { file.writeBytes(bytes); tmp.delete() }
        }
    }

    private fun List<Entry>.clean() = filter { it.songId.isNotBlank() }.distinctBy { it.songId }
    private fun List<AlbumEntry>.cleanAlbums() = filter { it.albumId.isNotBlank() }.distinctBy { it.albumId }

    companion object {
        const val FILE_NAME = "pocketdj-discover-adds.json"
        const val SYNC_KEY = "discover-adds"

        /** The synthetic source's name (song source tags + the Browse source filter). */
        const val SOURCE_NAME = "Discover"

        private fun now() = System.currentTimeMillis().toDouble()

        /** Mirror of iOS `AppleMusicLibraryWriteOutcome.provenByToken`: only a probe-verified write is proof. */
        fun provenByToken(token: String?): Boolean = token != null && token.startsWith("confirmed")

        internal fun decode(file: File): Document =
            runCatching { PdjJson.lenient.decodeFromString(Document.serializer(), file.readText()) }
                .getOrDefault(Document())

        fun decodeText(text: String): Pair<List<Entry>, List<AlbumEntry>> =
            runCatching { PdjJson.lenient.decodeFromString(Document.serializer(), text) }
                .getOrDefault(Document()).let { it.entries to (it.albums ?: emptyList()) }

        /** Entry -> catalog row: every field the entry knows (`albumId` only when an album row exists). */
        fun indexSong(e: Entry) = IndexSong(
            id = e.songId, albumId = e.albumId, artist = e.artist, name = e.title, trackNumber = e.trackNumber,
            year = e.year, explicit = e.explicit, length = e.durationMs?.toLong(), appleMusicId = e.appleMusicId,
            dateAdded = e.addedAtMs,
        )

        fun indexAlbum(e: AlbumEntry) = IndexAlbum(
            id = e.albumId, artist = e.artist, name = e.title, coverArt = e.artworkUrl, genre = e.genre,
            year = e.year, trackList = e.trackIds.orEmpty(), appleMusicId = e.appleMusicId,
        )

        fun syntheticIndex(entries: List<Entry>, albums: List<AlbumEntry> = emptyList()) = IndexJson(
            manifest = IndexManifest(source = "discover-adds", sourceName = SOURCE_NAME),
            albums = albums.map(::indexAlbum), songs = entries.map(::indexSong),
        )

        /**
         * The SUPERSEDE split (pure): entries whose Apple Music id is claimed by an INDEXED song yield to it -
         * the survivors plus the (provisional -> indexed) id pairs the collections remap applies.
         */
        fun split(
            entries: List<Entry>,
            indexedByAppleMusicId: Map<String, String>,
        ): Pair<List<Entry>, List<Pair<String, String>>> {
            val keep = ArrayList<Entry>()
            val pairs = ArrayList<Pair<String, String>>()
            for (e in entries) {
                val idx = indexedByAppleMusicId[e.appleMusicId]
                if (idx != null && idx != e.songId) pairs += e.songId to idx else keep += e
            }
            return keep to pairs
        }

        /** The album twin of [split]; an album claiming ITSELF never self-supersedes. */
        fun splitAlbums(
            albums: List<AlbumEntry>,
            indexedByAppleMusicId: Map<String, String>,
        ): Pair<List<AlbumEntry>, List<Pair<String, String>>> {
            val keep = ArrayList<AlbumEntry>()
            val pairs = ArrayList<Pair<String, String>>()
            for (a in albums) {
                val idx = indexedByAppleMusicId[a.appleMusicId]
                if (idx != null && idx != a.albumId) pairs += a.albumId to idx else keep += a
            }
            return keep to pairs
        }
    }
}

package com.levi.pocketdj.data.catalog

import com.levi.pocketdj.data.store.VersionedJsonWriter
import java.io.File
import java.util.concurrent.atomic.AtomicLong
import kotlinx.serialization.encodeToString
import kotlinx.serialization.json.Json
import kotlinx.serialization.json.JsonObject
import kotlinx.serialization.json.buildJsonObject
import kotlinx.serialization.json.put

/**
 * Writable on-device edits document (iOS `State/EditsStore.swift`), persisted as `pocketdj-edits.json` in the iOS
 * `EditsDocument` shape `{schemaVersion, albums, songs}` and synced under key "edits" (whole-document LWW).
 *
 * The FILE is the source of truth: reads go through [CatalogEditsFile] (stamp-cached), every mutation is a
 * read-modify-write under [lock] and lands through the version-ordered [VersionedJsonWriter] (inline, so the reader's
 * cache is invalidated only after the bytes are on disk). Only DELTAS are stored (null fields are never written) and
 * an edit that overrides nothing removes its entry (iOS `setAlbum` / `setSong`). A pull ([writePulled] +
 * [reloadFromDisk]) writes the cloud bytes verbatim and NEVER writes anything back.
 *
 * [onChanged] fires after every successful change (local write, restore, pull) so the catalog repository re-applies
 * the overlay and re-derives `SegmentOverrides`.
 */
class EditsStore(
    private val reader: CatalogEditsFile,
    private val writer: VersionedJsonWriter,
    private val onChanged: () -> Unit = {},
) {
    private val lock = Any()
    private val version = AtomicLong(0)
    private val file: File get() = reader.file

    val count: Int get() = reader.current().let { it.albums.size + it.songs.size }
    fun albumEdit(id: String): AlbumEdit? = reader.current().albums[id]
    fun songEdit(id: String): SongEdit? = reader.current().songs[id]

    /** Replace (an empty [edit] removes) the album's edit. */
    fun setAlbumEdit(id: String, edit: AlbumEdit) = mutate { cur ->
        CatalogEdits(
            cur.albums.toMutableMap().also { if (edit.isEmpty) it.remove(id) else it[id] = edit },
            cur.songs,
        )
    }

    /** Replace (an empty [edit] removes) the song's edit. */
    fun setSongEdit(id: String, edit: SongEdit) = mutate { cur ->
        CatalogEdits(
            cur.albums,
            cur.songs.toMutableMap().also { if (edit.isEmpty) it.remove(id) else it[id] = edit },
        )
    }

    fun removeAlbumEdit(id: String) = mutate { cur -> CatalogEdits(cur.albums - id, cur.songs) }
    fun removeSongEdit(id: String) = mutate { cur -> CatalogEdits(cur.albums, cur.songs - id) }

    private fun mutate(change: (CatalogEdits) -> CatalogEdits) {
        val changed = synchronized(lock) {
            val cur = reader.current()
            val next = change(cur)
            if (next.albums == cur.albums && next.songs == cur.songs) return@synchronized false
            writeLocked(encode(next))
            true
        }
        if (changed) onChanged()
    }

    /**
     * Backup restore (`BackupEditsStore.importMerging`): the already-merged document bytes, written verbatim so
     * unknown/future fields survive, through the same ordered writer as every other mutation.
     */
    fun replaceRaw(bytes: ByteArray) {
        synchronized(lock) { writeLocked(bytes.toString(Charsets.UTF_8)) }
        onChanged()
    }

    /** `SyncEntry.applyPayload`: write the pulled cloud bytes verbatim (no re-encode, no re-save - never pushes back). */
    fun writePulled(bytes: ByteArray) {
        synchronized(lock) { writeLocked(bytes.toString(Charsets.UTF_8)) }
    }

    /** `SyncEntry.onPulled`: re-read the pulled file and re-apply the overlay. Returns false: nothing was re-saved. */
    fun reloadFromDisk(): Boolean {
        reader.invalidate()
        onChanged()
        return false
    }

    /** Reset / account deletion: drop the document (and any un-migrated legacy file) and un-apply the overlay. */
    fun clearAll() {
        synchronized(lock) {
            writer.deleteNow(version.incrementAndGet())
            runCatching { legacyFile(file).delete() }
            reader.invalidate()
        }
        onChanged()
    }

    private fun writeLocked(text: String) {
        writer.flushNow(version.incrementAndGet()) { text }
        reader.invalidate()
    }

    companion object {
        const val SCHEMA_VERSION = 2

        /** Deltas only: null fields (and defaults) are omitted, exactly the iOS Codable shape. */
        private val json = Json { encodeDefaults = false; explicitNulls = false }

        fun legacyFile(current: File) = File(current.parentFile, CatalogEditsFile.LEGACY_FILE_NAME)

        /** Encode the iOS `EditsDocument` (no `meta`: that is stamped on export only, like iOS). */
        fun encode(e: CatalogEdits): String {
            val out: JsonObject = buildJsonObject {
                put("schemaVersion", SCHEMA_VERSION)
                put("albums", JsonObject(e.albums.mapValues { (_, v) -> json.encodeToJsonElement(AlbumEdit.serializer(), v) }))
                put("songs", JsonObject(e.songs.mapValues { (_, v) -> json.encodeToJsonElement(SongEdit.serializer(), v) }))
            }
            return out.toString()
        }

        /**
         * One-time `backup-edits.json` -> `pocketdj-edits.json`. The legacy bytes become the new file only when the
         * new file is absent (a synced/pulled document always wins); the legacy file is removed either way.
         */
        fun migrateLegacy(current: File): Boolean {
            val legacy = legacyFile(current)
            if (!legacy.exists()) return false
            var moved = false
            if (!current.exists()) {
                current.parentFile?.mkdirs()
                moved = legacy.renameTo(current) || runCatching { legacy.copyTo(current); true }.getOrDefault(false)
            }
            runCatching { legacy.delete() }
            return moved
        }
    }
}

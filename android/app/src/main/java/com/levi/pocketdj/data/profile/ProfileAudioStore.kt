package com.levi.pocketdj.data.profile

import com.levi.pocketdj.data.burns.BurnFileNames
import com.levi.pocketdj.data.profile.ProfileSourceStore.Kind
import com.levi.pocketdj.data.profile.ProfileSourceStore.SongEntry
import java.io.File
import java.util.UUID
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.withContext

/**
 * The DEVICE-LOCAL durable audio layer behind the "Pocket DJ" profile source (iOS `ProfileAudioStore` /
 * `ProfileAudioFolders`). A saved item keeps its ORIGINAL full mix (primary, always playable) plus, when available, its
 * 4 stems (progressive enhancement). All app-managed (never a user-picked folder, so no SAF lease to hold).
 *
 * Layout, deterministic from the item's `pdj_` id:
 * - `profile-audio/<songId>.<ext>` - the original (bare name stored in [SongEntry.fileName])
 * - `profile-audio/stems/<songId>/<stem>.<ext>` - optional stems, one folder per item
 *
 * Read paths never create directories or mutate the filesystem. No launch prune: with no cloud sync a record is only
 * ever created together with its file, and playback resolving to null simply skips the row.
 */
class ProfileAudioStore(private val store: ProfileSourceStore) {
    private val root: File get() = store.audioDir

    fun stemsDir(songId: String): File =
        File(File(root, "stems"), songId.replace(':', '_').replace('/', '_'))

    /** Original for playback, or null when gone. Bare names only: separators / "." / ".." never escape [root]. */
    fun resolveOriginal(fileName: String): File? {
        if (fileName.isEmpty() || fileName.contains('/') || fileName.contains('\\') || fileName == "." || fileName == "..") return null
        val f = File(root, fileName)
        return f.takeIf { it.isFile }
    }

    fun originalFor(id: String): File? = store.entry(id)?.let { resolveOriginal(it.fileName) }

    /** All four stems (extension-agnostic basename match), or null if ANY is missing (all-or-nothing). */
    fun stemFiles(songId: String): Map<String, File>? {
        val listing = stemsDir(songId).listFiles() ?: return null
        val out = LinkedHashMap<String, File>()
        for (name in BurnFileNames.STEM_NAMES) {
            out[name] = listing.firstOrNull { it.isFile && it.nameWithoutExtension == name } ?: return null
        }
        return out
    }

    /** In-memory record check (no disk): safe on Main for the stall-hop probe. */
    fun hasRecord(id: String): Boolean = ProfileSourceStore.isProfileSongId(id) && store.entry(id) != null

    fun hasLocalAsset(id: String): Boolean = ProfileSourceStore.isProfileSongId(id) && originalFor(id) != null

    /**
     * Persist custom audio as a NEW item: copy FILE-FIRST (own the bytes - the caller's source may be a purgeable cache),
     * BYTE-EXACT, then file the record (artist = profile name, derived). Stems are all-or-nothing: any copy failure
     * removes the original and the stems folder. Returns null on copy failure.
     */
    suspend fun ingest(
        kind: Kind,
        title: String,
        original: File,
        durationMs: Long? = null,
        stems: Map<String, File>? = null,
        bpm: Double? = null,
        key: String? = null,
        camelot: String? = null,
        nowMs: Double = System.currentTimeMillis().toDouble(),
    ): SongEntry? {
        val id = ProfileSourceStore.SONG_ID_PREFIX + UUID.randomUUID().toString().lowercase()
        val ext = original.extension.ifEmpty { "m4a" }
        val fileName = "$id.$ext"
        val entry = SongEntry(id, title, kind, fileName, durationMs, bpm, key, camelot, nowMs)
        return withContext(Dispatchers.IO) {
            if (!copyAll(id, fileName, original, stems)) null else { store.add(listOf(entry)); entry }
        }
    }

    private fun copyAll(id: String, fileName: String, original: File, stems: Map<String, File>?): Boolean {
        val dest = File(root, fileName)
        val sdir = stemsDir(id)
        fun cleanup(): Boolean { runCatching { sdir.deleteRecursively() }; runCatching { dest.delete() }; return false }
        return try {
            root.mkdirs()
            original.copyTo(dest, overwrite = true)
            if (stems == null) return true
            sdir.mkdirs()
            for (name in BurnFileNames.STEM_NAMES) {
                val src = stems[name] ?: return cleanup()
                src.copyTo(File(sdir, "$name.${src.extension.ifEmpty { "m4a" }}"), overwrite = true)
            }
            true
        } catch (_: Exception) { cleanup() }
    }

    /** Delete an item's audio (original + stems) AND its record. Does disk IO: call OFF Main (StorageService.clear already runs on Default). */
    fun deleteAsset(id: String) {
        originalFor(id)?.let { runCatching { it.delete() } }
        runCatching { stemsDir(id).deleteRecursively() }
        store.remove(listOf(id))
    }

    /** Bytes on disk under [ProfileSourceStore.audioDir] (Settings > Storage). */
    fun usageBytes(): Long = root.takeIf { it.exists() }?.walkBottomUp()?.filter { it.isFile }?.sumOf { it.length() } ?: 0L

    /** Storage "delete all" (disk IO: call OFF Main): the audio AND the records (a record without its file is unplayable). */
    fun deleteAll() = store.clear()
}

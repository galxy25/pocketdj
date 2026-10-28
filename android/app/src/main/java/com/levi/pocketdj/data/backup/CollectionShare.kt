package com.levi.pocketdj.data.backup

import android.content.ContentResolver
import android.net.Uri
import com.levi.pocketdj.data.collections.CollectionsStore
import com.levi.pocketdj.data.collections.io.ImportKind
import com.levi.pocketdj.data.collections.io.ImportSummary
import com.levi.pocketdj.data.collections.io.PlaylistZip
import com.levi.pocketdj.data.collections.io.PocketZip

/**
 * Pure naming / messaging / byte-IO helpers behind the export-import UI (kept free of Compose so the JVM
 * suite can pin them). Android's `CreateDocument` does NOT reliably append a custom extension, so every
 * export hands the picker a FULL file name that already ends in the explicit `.pdjcollection` tail.
 */
object CollectionShare {
    /** Archive MIME for exported zips (the system picker offers Drive/Downloads for it). */
    const val ZIP_MIME = "application/zip"
    const val CSV_MIME = "text/csv"
    const val MAX_IMPORT_BYTES = 256L * 1024 * 1024

    enum class Kind(val suffix: String) {
        PLAYLIST(PlaylistZip.COLLECTION_SUFFIX),
        POCKET(PocketZip.COLLECTION_SUFFIX),
        BACKUP(BackupZip.FILENAME_SUFFIX),
        CSV(".csv"),
    }

    /** File-system-safe stem: path separators / reserved characters removed, whitespace collapsed, never blank. */
    fun safeStem(name: String, fallback: String = "Untitled"): String {
        val cleaned = name.replace(Regex("[\\\\/:*?\"<>|\\p{Cntrl}]"), " ")
            .replace(Regex("\\s+"), " ").trim().trim('.').take(80).trim()
        return cleaned.ifEmpty { fallback }
    }

    /** `<name>.playlist.pdjcollection` / `<name>.pocket.pdjcollection` / `<name>.pocketdj.zip` / `<name>.csv`. */
    fun exportFilename(kind: Kind, name: String): String = safeStem(name) + kind.suffix

    fun backupFilename(dateStamp: String): String = "PocketDJ-Backup-$dateStamp${Kind.BACKUP.suffix}"

    /** One-line import result for the snackbar (iOS wording family: counts, or "already up to date"). */
    fun summaryMessage(s: ImportSummary): String {
        // A "JSON" import that processed nothing is a foreign file (a PDF / another app's settings.json decodes
        // leniently to an empty document), not a PocketDJ file that happens to be current.
        if (s.kind == ImportKind.COLLECTIONS_JSON && s.added + s.merged + s.unchanged == 0) return NOT_POCKETDJ
        if (s.alreadyUpToDate) return "Already up to date - nothing new to import"
        val parts = ArrayList<String>()
        fun add(n: Int, one: String, many: String) { if (n > 0) parts += "$n ${if (n == 1) one else many}" }
        add(s.playlists, "playlist", "playlists")
        add(s.pockets, "pocket", "pockets")
        add(s.setlists, "setlist", "setlists")
        add(s.folders, "folder", "folders")
        val what = if (parts.isEmpty()) "${s.added + s.merged} item(s)" else parts.joinToString(", ")
        val verb = if (s.kind == ImportKind.BACKUP) "Restored" else "Imported"
        return "$verb $what"
    }

    const val NOT_POCKETDJ = "That isn't a PocketDJ file"

    /** Full-backup restore result (iOS `importBackup`): collection counts + sources + favorites. */
    fun restoreMessage(s: ImportSummary, sourcesAdded: Int, favoritesAdded: Int, skippedItems: Int = 0): String {
        val parts = ArrayList<String>()
        fun add(n: Int, one: String, many: String) { if (n > 0) parts += "$n ${if (n == 1) one else many}" }
        add(s.pockets, "pocket", "pockets")
        add(s.playlists, "playlist", "playlists")
        add(s.setlists, "setlist", "setlists")
        add(s.folders, "folder", "folders")
        add(sourcesAdded, "source", "sources")
        add(favoritesAdded, "favorite", "favorites")
        val base = when {
            parts.isNotEmpty() && (s.added + s.merged > 0 || sourcesAdded > 0 || favoritesAdded > 0) ->
                "Restored " + parts.joinToString(", ")
            s.added + s.merged > 0 -> "Restored ${s.added + s.merged} item(s)"
            else -> "Already up to date - nothing new to import"
        }
        return if (skippedItems > 0) "$base ($skippedItems catalog items not bundled)" else base
    }

    /** User-facing text for a failed import (unreadable file / not a PocketDJ file). */
    fun failureMessage(t: Throwable): String = when {
        t is BackupZipException && t.notABackup -> NOT_POCKETDJ
        // kotlinx SerializationException extends IllegalArgumentException: non-JSON / foreign bytes
        t is kotlinx.serialization.SerializationException || t is IllegalArgumentException -> NOT_POCKETDJ
        t is OutOfMemoryError -> "That file is too large to import"
        else -> "Couldn't import: ${t.message?.take(80) ?: "unreadable file"}"
    }

    /** Read a content/file Uri fully (bounded). Null when it can't be opened. Blocking: call off-main. */
    fun readUri(resolver: ContentResolver, uri: Uri, maxBytes: Long = MAX_IMPORT_BYTES): ByteArray? =
        runCatching {
            resolver.openInputStream(uri)?.use { readBounded(it, maxBytes) }
        }.getOrNull()

    fun readBounded(input: java.io.InputStream, maxBytes: Long): ByteArray {
        val out = java.io.ByteArrayOutputStream()
        val buf = ByteArray(64 * 1024)
        var total = 0L
        while (true) {
            val n = input.read(buf)
            if (n < 0) break
            total += n
            if (total > maxBytes) throw java.io.IOException("file exceeds ${maxBytes / (1024 * 1024)} MB")
            out.write(buf, 0, n)
        }
        return out.toByteArray()
    }

    /** Write [data] to a CreateDocument Uri (truncating). Blocking. */
    fun writeUri(resolver: ContentResolver, uri: Uri, data: ByteArray): Boolean =
        runCatching { resolver.openOutputStream(uri, "wt")?.use { it.write(data); true } ?: false }.getOrDefault(false)

    /** Import raw picked/opened bytes through the store's content router. */
    fun importBytes(store: CollectionsStore, data: ByteArray): ImportSummary = store.importAny(data)
}

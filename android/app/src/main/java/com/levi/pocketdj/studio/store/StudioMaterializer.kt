package com.levi.pocketdj.studio.store

import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.withContext
import java.io.File
import java.io.InputStream

/** A usable local [file] for a [StudioFileRef]; [release] is idempotent (a no-op for a directly-held file). */
class StudioLease internal constructor(val file: File, private val onRelease: () -> Unit) {
    private var released = false
    @Synchronized fun release() {
        if (released) return
        released = true
        onRelease()
    }
}

/** Identity + staleness fingerprint of a content:// document. */
data class SafStat(val size: Long, val mtime: Long)

/**
 * Turns a [StudioFileRef] into a `java.io.File` for the many consumers that need one (decoder, key detection, sample
 * import, clip bake). A ref that already holds a file is returned directly; a SAF `content://` ref is copied into
 * `<cacheDir>/studio-saf/` keyed by uri+size+mtime (so an edited document re-copies), with an LRU cap on total bytes.
 * Leased entries are pinned and never evicted. A revoked / unreadable uri yields null (never a half-copied file).
 */
class StudioMaterializer(
    private val cacheRoot: File,
    private val stat: (String) -> SafStat?,
    private val open: (String) -> InputStream?,
    private val maxBytes: Long = DEFAULT_MAX_BYTES,
) {
    private class Entry(val file: File, var size: Long, var lastUsed: Long, var pins: Int)

    private val entries = LinkedHashMap<String, Entry>()
    private var tick = 0L
    private val dir get() = File(cacheRoot, DIR_NAME)

    suspend fun lease(ref: StudioFileRef): StudioLease? {
        ref.file?.takeIf { it.isFile }?.let { return StudioLease(it) {} }
        if (!ref.uri.startsWith("content://")) return null
        return withContext(Dispatchers.IO) { leaseUri(ref.uri) }
    }

    private fun leaseUri(uri: String): StudioLease? {
        val st = try { stat(uri) } catch (_: Exception) { null } ?: return null
        val key = cacheKey(uri, st)
        synchronized(this) {
            val hit = entries[key]
            if (hit != null && hit.file.isFile && hit.file.length() == hit.size) return pin(key, hit)
            entries.remove(key)
        }
        dir.mkdirs()
        val dest = File(dir, key)
        val part = File(dir, "$key.part")
        val copied = try {
            val input = open(uri) ?: return null
            input.use { i -> part.outputStream().use { o -> i.copyTo(o) } }
            part.renameTo(dest)
        } catch (_: Exception) { false }
        if (!copied) { part.delete(); return null }
        synchronized(this) {
            val e = Entry(dest, dest.length(), 0, 0)
            entries[key] = e
            val lease = pin(key, e)
            evict()
            return lease
        }
    }

    private fun pin(key: String, e: Entry): StudioLease {
        e.pins++; e.lastUsed = ++tick
        return StudioLease(e.file) { synchronized(this) { entries[key]?.let { if (it.pins > 0) it.pins-- }; evict() } }
    }

    /** Drop least-recently-used UNPINNED entries until under the byte cap. */
    private fun evict() {
        var total = entries.values.sumOf { it.size }
        if (total <= maxBytes) return
        for ((k, e) in entries.entries.filter { it.value.pins == 0 }.sortedBy { it.value.lastUsed }) {
            if (total <= maxBytes) break
            e.file.delete(); entries.remove(k); total -= e.size
        }
    }

    /** Number of cached copies (tests / diagnostics). */
    @Synchronized fun cachedCount() = entries.size

    companion object {
        /** Passthrough instance: files only (a content:// ref yields null). */
        val FILES_ONLY = StudioMaterializer(File(System.getProperty("java.io.tmpdir") ?: "."), { null }, { null })

        const val DIR_NAME = "studio-saf"
        const val DEFAULT_MAX_BYTES = 256L * 1024 * 1024

        internal fun cacheKey(uri: String, st: SafStat): String {
            val h = Integer.toHexString(uri.hashCode()) + java.lang.Long.toHexString(uri.length.toLong())
            return "$h-${st.size}-${st.mtime}.audio"
        }

        /** Android-backed instance: content resolver stat (size + last-modified) and stream open. */
        fun forContext(context: android.content.Context): StudioMaterializer {
            val cr = context.contentResolver
            return StudioMaterializer(
                cacheRoot = context.cacheDir,
                stat = { u ->
                    cr.query(
                        android.net.Uri.parse(u),
                        arrayOf(android.provider.DocumentsContract.Document.COLUMN_SIZE, android.provider.DocumentsContract.Document.COLUMN_LAST_MODIFIED),
                        null, null, null,
                    )?.use { c -> if (c.moveToFirst()) SafStat(if (c.isNull(0)) 0L else c.getLong(0), if (c.isNull(1)) 0L else c.getLong(1)) else null }
                },
                open = { u -> cr.openInputStream(android.net.Uri.parse(u)) },
            )
        }
    }
}

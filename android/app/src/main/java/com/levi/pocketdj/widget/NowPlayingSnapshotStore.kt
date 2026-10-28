package com.levi.pocketdj.widget

import java.io.File

/**
 * File-backed snapshot + cover (`filesDir/widget/nowplaying.json`, `cover.png`). Writes are
 * atomic (tmp + rename) and SKIPPED when the encoded snapshot is unchanged, so the widget is
 * only refreshed when content changes (no per-second position churn).
 */
class NowPlayingSnapshotStore(private val dir: File) {
    private val snapshotFile get() = File(dir, "nowplaying.json")
    val coverFile: File get() = File(dir, "cover.png")
    private val lock = Any()
    private var lastEncoded: String? = null

    fun read(): NowPlayingSnapshot = synchronized(lock) {
        NowPlayingSnapshotCodec.decode(runCatching { snapshotFile.takeIf { it.exists() }?.readText() }.getOrNull())
    }

    /** Persist [snapshot]; returns true when the file actually changed. */
    fun write(snapshot: NowPlayingSnapshot): Boolean = synchronized(lock) {
        val encoded = NowPlayingSnapshotCodec.encode(snapshot)
        val prior = lastEncoded ?: runCatching { snapshotFile.takeIf { it.exists() }?.readText() }.getOrNull()
        if (prior == encoded) {
            lastEncoded = encoded
            return false
        }
        atomicWrite(snapshotFile, encoded.toByteArray())
        lastEncoded = encoded
        true
    }

    fun writeCover(png: ByteArray) = synchronized(lock) { atomicWrite(coverFile, png) }

    fun clearCover() = synchronized(lock) { runCatching { coverFile.delete() }; Unit }

    fun hasCover(): Boolean = coverFile.isFile && coverFile.length() > 0

    private fun atomicWrite(target: File, bytes: ByteArray) {
        dir.mkdirs()
        val tmp = File(dir, target.name + ".tmp")
        tmp.writeBytes(bytes)
        if (!tmp.renameTo(target)) {
            target.delete()
            tmp.renameTo(target)
        }
    }
}

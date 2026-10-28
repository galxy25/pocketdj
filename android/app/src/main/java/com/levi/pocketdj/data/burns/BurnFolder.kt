package com.levi.pocketdj.data.burns

import java.io.File
import java.io.IOException
import java.util.UUID

/** One physical burn root. */
data class BurnRoot(val dir: File, val isUserFolder: Boolean)

/**
 * The single burn-root resolver (decision D5/D2). v1 = app-private `filesDir/burns`; a SAF
 * user-folder implementation slots in later (destination must be captured onto the transfer
 * record at enqueue time, never read live in a worker).
 */
interface BurnFolder {
    /** Every reachable root, app root first (iOS `forEachBurnRoot`). */
    fun roots(): List<BurnRoot>

    /** The ACTIVE write root, created if needed; null when unusable. */
    fun activeWritable(): BurnRoot?

    /**
     * The dir an item was actually written to: `wasAppStorage` null/true => app root; false =>
     * the user folder, or null while it is unreachable (the item is then skipped, never pruned).
     */
    fun dirFor(wasAppStorage: Boolean?): File? =
        roots().firstOrNull { it.isUserFolder == (wasAppStorage == false) }?.dir

    /** Sentinel write+delete; false on failure (folder unavailable). */
    fun probeWrite(root: BurnRoot): Boolean = try {
        val sentinel = File(root.dir, ".pdj-burn-probe-${UUID.randomUUID()}")
        sentinel.writeText("ok")
        sentinel.delete()
        true
    } catch (_: IOException) {
        false
    }
}

/** `filesDir/burns/`. */
class AppPrivateBurnFolder(private val dir: File) : BurnFolder {
    override fun roots(): List<BurnRoot> = listOf(BurnRoot(dir, isUserFolder = false))

    override fun activeWritable(): BurnRoot? {
        if (!dir.isDirectory && !dir.mkdirs() && !dir.isDirectory) return null
        return BurnRoot(dir, isUserFolder = false)
    }
}

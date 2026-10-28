package com.levi.pocketdj.mix.recording

import java.io.File

/**
 * On-disk layout of mix-session audio: `filesDir/mix-sessions/<sessionId>/recording-N.aac`.
 * Android has no user-picked session folder (iOS bookmark), so every take lives under the app root
 * and `wasUserFolder` is always false.
 */
object SessionFolders {
    const val ROOT_NAME = "mix-sessions"
    const val EXT = "aac"

    fun root(filesDir: File): File = File(filesDir, ROOT_NAME)

    /** Creates the folder when needed. Null when [sessionId] is empty/unsafe or the dir can't be made. */
    fun sessionFolder(root: File, sessionId: String): File? {
        if (sessionId.isEmpty() || sessionId.contains('/') || sessionId.contains("..")) return null
        val dir = File(root, sessionId)
        if (!dir.isDirectory && !dir.mkdirs() && !dir.isDirectory) return null
        return dir
    }

    fun takeName(seq: Int) = "recording-$seq.$EXT"

    /**
     * The next take file name: starts at (filed takes + 1) and is bumped past any file already on
     * disk, so a crash orphan or a take whose metadata was cleared is never truncated.
     */
    fun nextTakeName(filedCount: Int, existing: Collection<String>): String {
        var seq = filedCount + 1
        while (takeName(seq) in existing) seq++
        return takeName(seq)
    }

    fun isTake(file: File) = file.isFile && file.extension.equals(EXT, ignoreCase = true)

    /** Every take file under [root], keyed (sessionId, file). */
    fun allTakes(root: File): List<Pair<String, File>> =
        root.listFiles { f -> f.isDirectory }.orEmpty().sortedBy { it.name }.flatMap { dir ->
            dir.listFiles { f -> isTake(f) }.orEmpty().sortedBy { it.name }.map { dir.name to it }
        }

    fun usageBytes(root: File): Long =
        if (!root.exists()) 0L else root.walkBottomUp().filter { it.isFile }.sumOf { it.length() }

    /** Delete everything under [root] except [keep] (the live take); prunes emptied session dirs. */
    fun deleteAll(root: File, keep: File?) {
        val keepPath = keep?.absoluteFile?.normalize()
        root.listFiles().orEmpty().forEach { dir ->
            if (!dir.isDirectory) return@forEach
            dir.listFiles().orEmpty().forEach { f ->
                if (f.absoluteFile.normalize() != keepPath) f.delete()
            }
            if (dir.listFiles().isNullOrEmpty()) dir.delete()
        }
    }
}

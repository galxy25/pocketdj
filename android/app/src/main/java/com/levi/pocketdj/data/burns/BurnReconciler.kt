package com.levi.pocketdj.data.burns

import java.io.File

/**
 * Launch reconcile (iOS `reconcileOnLaunch`): drop ledger items whose file vanished, and
 * self-heal POISONED items — a <4 KB file starting with an XML/HTML error document that an
 * old build finalized as audio (2026-09-01). An item whose dir is currently unreachable is
 * skipped, never pruned (no data destruction).
 */
object BurnReconciler {
    const val POISON_FLOOR_BYTES = 4_096L
    private val POISON_HEADS = listOf("<?xml", "<Error", "<!DOCT", "<html")

    data class Outcome(val dropped: Set<String>, val deletedFiles: List<File>)

    /** True when [file] is implausibly small AND starts with an error document. */
    fun isPoisoned(file: File): Boolean {
        if (file.length() >= POISON_FLOOR_BYTES) return false
        val head = runCatching { file.inputStream().use { s -> ByteArray(16).let { b -> String(b, 0, maxOf(0, s.read(b)), Charsets.UTF_8) } } }
            .getOrDefault("")
        return POISON_HEADS.any { head.startsWith(it) }
    }

    /** [dirFor] resolves an item's dir (null = unreachable). Deletes poisoned files itself. */
    fun reconcile(items: Collection<BurnItem>, dirFor: (BurnItem) -> File?): Outcome {
        val dropped = LinkedHashSet<String>()
        val deleted = ArrayList<File>()
        for (item in items) {
            if (item.state != BurnState.READY) continue
            val dir = dirFor(item) ?: continue
            val f = File(dir, item.audioFileName)
            if (!f.exists()) {
                dropped += item.songId
                continue
            }
            if (isPoisoned(f)) {
                f.delete()
                deleted += f
                dropped += item.songId
            }
        }
        return Outcome(dropped, deleted)
    }
}

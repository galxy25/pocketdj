package com.levi.pocketdj.data.burns

/** A snapshot of one burn root: every file name -> size in bytes (ONE listing per root). */
data class RootSnapshot(val isUserFolder: Boolean, val files: Map<String, Long>)

/**
 * Pure planner (iOS `planEviction`). Walks [order] (eviction priority), crediting each song the
 * bytes `removeBurns` would actually free — sidecar, cut, stems, beat grid, plus the audio file
 * only once no other ledger item still references it (a shared analog album mp3 frees with its
 * LAST referencing song) — until the footprint fits [capBytes] and the ready count fits
 * [capSongs]. Deletes nothing.
 */
object EvictionPlanner {
    /** Names this app provably wrote: ledger audio/sidecar/cut names. */
    fun ledgerNames(items: Collection<BurnItem>): Set<String> {
        val names = HashSet<String>()
        for (it in items) {
            if (it.audioFileName.isNotEmpty()) names += it.audioFileName
            if (it.sidecarFileName.isNotEmpty()) names += it.sidecarFileName
            it.cutFileName?.let(names::add)
        }
        return names
    }

    /** Counted bytes per root (ledger names + owned aux files). */
    fun counted(root: RootSnapshot, ledger: Set<String>, ownsAux: (String, Boolean) -> Boolean): Map<String, Long> =
        root.files.filter { (n, _) -> n in ledger || ownsAux(n, root.isUserFolder) }

    fun usageBytes(
        items: Collection<BurnItem>,
        roots: List<RootSnapshot>,
        ownsAux: (String, Boolean) -> Boolean,
    ): Long {
        val ledger = ledgerNames(items)
        return roots.sumOf { r -> counted(r, ledger, ownsAux).values.sum() }
    }

    fun plan(
        items: Map<String, BurnItem>,
        roots: List<RootSnapshot>,
        order: List<String>,
        capBytes: Long,
        capSongs: Int,
        ownsAux: (String, Boolean) -> Boolean,
    ): EvictionPlan {
        val ledger = ledgerNames(items.values)
        val audioRefs = HashMap<String, Int>()
        for (it in items.values) if (it.audioFileName.isNotEmpty()) audioRefs.merge(it.audioFileName, 1, Int::plus)

        val appRoot = roots.firstOrNull { !it.isUserFolder }
        val userRoot = roots.firstOrNull { it.isUserFolder }
        val countedByRoot = java.util.IdentityHashMap<RootSnapshot, Map<String, Long>>()
        var usage = 0L
        for (r in roots) {
            val c = counted(r, ledger, ownsAux)
            countedByRoot[r] = c
            usage += c.values.sum()
        }

        var projected = usage
        var songCount = items.values.count { it.state == BurnState.READY }
        val evict = ArrayList<String>()
        val freedById = HashMap<String, Long>()
        for (id in order) {
            if (!(projected > capBytes || songCount > capSongs)) break
            val item = items[id] ?: continue
            val root = (if (item.wasAppStorage ?: true) appRoot else userRoot) ?: continue
            val counted = countedByRoot.getValue(root)
            var freed = 0L
            if (item.sidecarFileName.isNotEmpty()) freed += counted[item.sidecarFileName] ?: 0L
            val cut = item.cutFileName
            if (cut != null && counted[cut] != null) {
                freed += counted.getValue(cut)
            } else if (item.source == "analog") {
                BurnFileNames.cutFileNameAmongst(root.files.keys.toList(), id, item.audioFileName)
                    ?.let { freed += counted[it] ?: 0L }
            }
            if (item.audioFileName.isNotEmpty()) {
                val left = (audioRefs[item.audioFileName] ?: 1) - 1
                audioRefs[item.audioFileName] = left
                if (left <= 0) freed += counted[item.audioFileName] ?: 0L
            }
            val aux = BurnFileNames.STEM_NAMES.map { BurnFileNames.stemFileName(id, it) } +
                BurnFileNames.beatgridFileName(id)
            for (c in countedByRoot.values) for (n in aux) freed += c[n] ?: 0L
            projected -= freed
            freedById[id] = freed
            evict += id
            if (item.state == BurnState.READY) songCount -= 1
        }
        return EvictionPlan(usageBytes = usage, projectedBytes = projected, evict = evict, freedById = freedById)
    }
}

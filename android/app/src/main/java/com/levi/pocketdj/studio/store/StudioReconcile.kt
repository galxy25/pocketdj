package com.levi.pocketdj.studio.store

import com.levi.pocketdj.studio.model.StudioDocument

/**
 * Launch reconcile + per-family storage manager over a [StudioDocument] (iOS
 * `StudioStore.reconcileOnLaunch` / `usageBytes` / `deleteAll`). Pure over ([StudioDocument],
 * [StudioRoots]) so it is fully JVM-testable.
 *
 * Doctrine (BurnStore.reconcileOnLaunch):
 *  - each artifact resolves against the root it was WRITTEN to (`wasUserFolder`);
 *  - an UNREACHABLE user root => SKIP, never prune (nothing is provably gone);
 *  - a provably-gone file in a reachable root => drop the record, EXCEPT derived artifacts:
 *    a lost sample/take render cache just clears the cache fields; a lost pattern bounce clears
 *    `fileName` and re-marks `bounceDirty` (the pattern's DATA is its steps);
 *  - dangling cross-refs (loop->sample, row->target, sample->take) are left alone — flagged at
 *    read time (`sampleExists`/`targetExists`), never deleted.
 */
object StudioReconcile {

    data class Result(
        val doc: StudioDocument,
        val changed: Boolean,
        val prunedSamples: Int = 0,
        val prunedLoops: Int = 0,
        val prunedTakes: Int = 0,
    )

    fun reconcile(doc: StudioDocument, roots: StudioRoots): Result {
        var changed = false
        val reach = HashMap<StudioFamily, Boolean>()
        fun userReachable(f: StudioFamily) = reach.getOrPut(f) { StudioFolders.userRootReachable(roots, f) }

        /** True only when the file is PROVABLY gone: its root resolves and the file isn't there. */
        fun provablyGone(f: StudioFamily, fileName: String, wasUser: Boolean): Boolean {
            if (wasUser && !userReachable(f)) return false   // can't check -> never prune
            return StudioFolders.fileRef(roots, f, fileName, wasUser) == null
        }

        val samplesKept = doc.samples.filterNot { provablyGone(StudioFamily.SAMPLES, it.fileName, it.wasUserFolder) }
        val prunedSamples = doc.samples.size - samplesKept.size
        if (prunedSamples > 0) changed = true
        val samples = samplesKept.map { s ->
            val rf = s.renderedFileName
            if (rf != null && provablyGone(StudioFamily.SAMPLES, rf, s.renderedWasUserFolder ?: false)) {
                changed = true
                s.copy(renderedFileName = null, renderedRevision = null, renderedWasUserFolder = null)
            } else s
        }

        val loops = doc.loops.filterNot { provablyGone(StudioFamily.LOOPS, it.fileName, it.wasUserFolder) }
        val prunedLoops = doc.loops.size - loops.size
        if (prunedLoops > 0) changed = true

        val patterns = doc.patterns.map { p ->
            val f = p.fileName
            if (f != null && provablyGone(StudioFamily.SEQUENCES, f, p.wasUserFolder)) {
                changed = true
                p.copy(fileName = null, bounceDirty = true)
            } else p
        }

        // A take's rendered-audio cache vanished (raw events intact) -> clear the cache fields.
        val takesCleared = doc.takes.map { t ->
            val rf = t.renderedFileName
            if (rf != null && provablyGone(StudioFamily.TAKES, rf, t.renderedWasUserFolder ?: false)) {
                changed = true
                t.copy(renderedFileName = null, renderedWasUserFolder = null)
            } else t
        }
        val takes = takesCleared.filterNot { provablyGone(StudioFamily.TAKES, it.fileName, it.wasUserFolder) }
        val prunedTakes = takesCleared.size - takes.size
        if (prunedTakes > 0) changed = true

        if (!changed) return Result(doc, false)
        return Result(
            doc.copy(samples = samples, loops = loops, patterns = patterns, takes = takes),
            true, prunedSamples, prunedLoops, prunedTakes,
        )
    }

    /** Ids the document knows for a family — the user-root ownership gate. */
    fun documentIds(doc: StudioDocument, family: StudioFamily): Set<String> = when (family) {
        StudioFamily.SAMPLES -> doc.samples.map { it.id }.toSet()
        StudioFamily.LOOPS -> doc.loops.map { it.id }.toSet()
        StudioFamily.SEQUENCES -> doc.patterns.map { it.id }.toSet()
        StudioFamily.TAKES -> doc.takes.map { it.id }.toSet()
        StudioFamily.INSTRUMENTS -> emptySet()   // pack files live in the instrument-pack ledger, app root only
    }

    fun usageBytes(doc: StudioDocument, roots: StudioRoots, family: StudioFamily): Long =
        StudioFolders.usageBytes(roots, family, documentIds(doc, family))

    /**
     * Storage manager: delete EVERYTHING in one family — files in both reachable roots AND the
     * family's records. Safety rules:
     *  - [activeFileName] (the recorder's in-flight capture) is skipped;
     *  - in the user root only exact-shape files with document-known ids are swept;
     *  - records whose user root is UNREACHABLE are KEPT (nothing provably deleted);
     *    a record whose file survived (the skipped active take) is kept too.
     */
    fun deleteAll(doc: StudioDocument, roots: StudioRoots, family: StudioFamily, activeFileName: String? = null): StudioDocument {
        val known = documentIds(doc, family)
        StudioFolders.forEachRoot(roots, family) { dir, isUser ->
            for (n in dir.list()) {
                if (n == activeFileName) continue
                val id = StudioFolders.fileId(family, n) ?: continue
                if (isUser && id !in known) continue
                dir.delete(n)
            }
        }
        val userReachable = StudioFolders.userRootReachable(roots, family)
        fun keep(fileName: String?, wasUser: Boolean): Boolean {
            if (fileName.isNullOrEmpty()) return false
            if (wasUser && !userReachable) return true
            return StudioFolders.fileRef(roots, family, fileName, wasUser) != null
        }
        return when (family) {
            StudioFamily.SAMPLES -> doc.copy(samples = doc.samples.filter { keep(it.fileName, it.wasUserFolder) })
            StudioFamily.LOOPS -> doc.copy(loops = doc.loops.filter { keep(it.fileName, it.wasUserFolder) })
            StudioFamily.SEQUENCES -> doc.copy(patterns = doc.patterns.filter { keep(it.fileName, it.wasUserFolder) })
            StudioFamily.TAKES -> doc.copy(takes = doc.takes.filter { keep(it.fileName, it.wasUserFolder) })
            StudioFamily.INSTRUMENTS -> doc   // records belong to the instrument packs; only files were swept
        }
    }
}

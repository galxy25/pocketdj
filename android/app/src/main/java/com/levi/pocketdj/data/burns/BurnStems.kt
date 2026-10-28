package com.levi.pocketdj.data.burns

import java.io.File

/**
 * Pure, file-system-level rules for burned stems + beat grids (Mix contract names
 * `stem-<id>-{vocals,drums,bass,other}.mp3`, `analysis-<id>.json`). BurnStore owns the network and
 * the ledger; everything decidable from a directory lives here so it is JVM-testable.
 */
object BurnStems {
    fun stemFile(dir: File, songId: String, part: String) = File(dir, BurnFileNames.stemFileName(songId, part))
    fun beatGridFile(dir: File, songId: String) = File(dir, BurnFileNames.beatgridFileName(songId))

    /** All 4 stem files iff EVERY one exists (all-or-nothing); a partial set resolves to null. */
    fun resolveAll(dir: File, songId: String): Map<String, File>? {
        val out = LinkedHashMap<String, File>()
        for (n in BurnFileNames.STEM_NAMES) {
            val f = stemFile(dir, songId, n)
            if (!f.exists()) return null
            out[n] = f
        }
        return out
    }

    /** Any subset of the four parts on disk (Stem Lock reads part by part); null when none. */
    fun resolveParts(dir: File, songId: String): Map<String, File>? {
        val out = LinkedHashMap<String, File>()
        for (n in BurnFileNames.STEM_NAMES) {
            val f = stemFile(dir, songId, n)
            if (f.exists()) out[n] = f
        }
        return out.ifEmpty { null }
    }

    fun allPresent(dir: File, songId: String): Boolean = resolveAll(dir, songId) != null

    /** Stem parts still to download (idempotent: existing files are never re-fetched). */
    fun missingParts(dir: File, songId: String): List<String> =
        BurnFileNames.STEM_NAMES.filterNot { stemFile(dir, songId, it).exists() }

    /** A beat-grid body is cacheable only when it decodes as a sidecar object (truncated/HTML => no). */
    fun isValidBeatGrid(bytes: ByteArray): Boolean =
        BeatGridSidecar.parse(String(bytes, Charsets.UTF_8)) != null

    /** Song ids with all 4 stems in [names] (the dir listing) — the Mix "stems burned" set. */
    fun fullyStemmedIds(names: Collection<String>): List<String> =
        names.filter { BurnFileNames.isStemFile(it) }
            .mapNotNull { BurnFileNames.auxFileSongId(it) }
            .distinct()
            .filter { id -> BurnFileNames.STEM_NAMES.all { BurnFileNames.stemFileName(id, it) in names } }

    /** Delete a song's stems + beat grid from [dir]. Returns the number of files removed. */
    fun removeAux(dir: File, songId: String): Int {
        var n = 0
        for (p in BurnFileNames.STEM_NAMES) if (stemFile(dir, songId, p).delete()) n++
        if (beatGridFile(dir, songId).delete()) n++
        return n
    }

    /** Aux file names in [names] whose song id satisfies [shouldSweep] (orphans: no burned audio). */
    fun auxToSweep(names: Collection<String>, shouldSweep: (String) -> Boolean): List<String> =
        names.filter { n -> BurnFileNames.auxFileSongId(n)?.let(shouldSweep) == true }
}

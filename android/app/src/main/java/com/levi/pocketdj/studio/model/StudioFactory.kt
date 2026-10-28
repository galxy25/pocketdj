package com.levi.pocketdj.studio.model

import java.util.UUID

/**
 * Id minting for the Studio document — mirrors iOS `StudioFactory` (StudioModels.swift).
 *
 * Prefixes `smp_`/`lp_`/`ptn_`/`tk_` ride collections' EXISTING string arrays, so every guard
 * (rip/stemify/CSV/realize, `PlayResolver.STUDIO_ID_PREFIXES`) routes on them. Every other prefix
 * (`cue_`/`slc_`/`sfld_`/`lpfld_`/`ptnfld_`/`tkfld_`/`stf_`/`arr_`/`trk_`/`clip_`/`arrfld_`/`art_`)
 * is container-internal and DELIBERATELY not in [studioPrefixes] — adding one would leak it into
 * the rip/realize guards.
 */
object StudioFactory {
    fun uid(): String = UUID.randomUUID().toString().lowercase()

    fun newSampleId() = "smp_" + uid()
    fun newLoopId() = "lp_" + uid()
    fun newPatternId() = "ptn_" + uid()
    fun newTakeId() = "tk_" + uid()
    fun newCueId() = "cue_" + uid()
    fun newSliceId() = "slc_" + uid()
    fun newSampleFolderId() = "sfld_" + uid()
    fun newArrangementId() = "arr_" + uid()
    fun newTrackId() = "trk_" + uid()
    fun newClipId() = "clip_" + uid()
    fun newArrangementFolderId() = "arrfld_" + uid()
    fun newArtifactId() = "art_" + uid()
    fun newLoopFolderId() = "lpfld_" + uid()
    fun newPatternFolderId() = "ptnfld_" + uid()
    fun newTakeFolderId() = "tkfld_" + uid()
    fun newStaffId() = "stf_" + uid()

    /** The id namespaces that ride collections' string arrays — single source of truth. */
    val studioPrefixes: List<String> = listOf("smp_", "lp_", "ptn_", "tk_")

    /** True when [id] is a studio-namespaced id (sample/loop/pattern/take). */
    fun isStudioId(id: String): Boolean = studioPrefixes.any { id.startsWith(it) }
}

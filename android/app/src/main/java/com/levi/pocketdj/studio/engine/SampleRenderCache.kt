package com.levi.pocketdj.studio.engine

import com.levi.pocketdj.studio.StudioFiles
import com.levi.pocketdj.studio.audio.StudioRender
import com.levi.pocketdj.studio.model.StudioSample
import com.levi.pocketdj.studio.store.StudioFamily
import com.levi.pocketdj.studio.store.StudioFolders
import com.levi.pocketdj.studio.store.StudioRoots
import com.levi.pocketdj.studio.store.StudioStore
import java.io.File

/**
 * The sample render cache (`sample-<id>-r<rev>.m4a`): edits are NEVER baked into the source on Save; a
 * consumer that needs the shaped audio (sequencer, loops) asks for the cache, which is re-rendered only
 * when `renderRevision` moved past `renderedRevision` (or the file vanished). Old revisions are deleted.
 */
class SampleRenderCache(
    private val roots: StudioRoots,
    private val store: StudioStore,
    private val render: StudioRender,
) {
    /** The source file of a sample (raw capture/carve), or null if gone. */
    fun sourceFile(s: StudioSample): File? =
        StudioFolders.fileRef(roots, StudioFamily.SAMPLES, s.fileName, s.wasUserFolder)?.file

    fun cacheFile(s: StudioSample): File? {
        val name = s.renderedFileName ?: return null
        return StudioFolders.fileRef(roots, StudioFamily.SAMPLES, name, s.renderedWasUserFolder ?: false)?.file
    }

    /** True when [s] needs a (re)render: neutral edits never do (the raw file plays as-is). */
    fun needsRender(s: StudioSample): Boolean {
        if (s.edit.isNeutral) return false
        if (!s.isRenderFresh) return true
        return cacheFile(s)?.isFile != true
    }

    /** The file to PLAY for [s]: the fresh cache when edited, else the raw source. Renders when stale. */
    suspend fun playableFile(id: String): File? {
        var s = store.sample(id) ?: return null
        if (needsRender(s)) {
            val src = sourceFile(s) ?: return null
            val rev = s.renderRevision
            val name = StudioFolders.renderedSampleFileName(s.id, rev)
            val dest = StudioFiles.appFile(roots, StudioFamily.SAMPLES, name) ?: return null
            val old = s.renderedFileName
            render.renderSample(s.edit, src.path, dest)
            store.setRenderedSample(s.id, name, false, rev)
            if (old != null && old != name) StudioFiles.appFile(roots, StudioFamily.SAMPLES, old)?.delete()
            s = store.sample(id) ?: return dest
        }
        return if (s.edit.isNeutral) sourceFile(s) else (cacheFile(s) ?: sourceFile(s))
    }
}

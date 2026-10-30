package com.levi.pocketdj.studio.engine

import com.levi.pocketdj.studio.StudioFiles
import com.levi.pocketdj.studio.audio.StudioRender
import com.levi.pocketdj.studio.model.StudioSample
import com.levi.pocketdj.studio.store.StudioFamily
import com.levi.pocketdj.studio.store.StudioFileRef
import com.levi.pocketdj.studio.store.StudioFolders
import com.levi.pocketdj.studio.store.StudioLease
import com.levi.pocketdj.studio.store.StudioMaterializer
import com.levi.pocketdj.studio.store.StudioRoots
import com.levi.pocketdj.studio.store.StudioStore
import java.io.File
import kotlinx.coroutines.runBlocking

/**
 * The sample render cache (`sample-<id>-r<rev>.m4a`): edits are NEVER baked into the source on Save; a
 * consumer that needs the shaped audio (sequencer, loops) asks for the cache, which is re-rendered only
 * when `renderRevision` moved past `renderedRevision` (or the file vanished). Old revisions are deleted.
 *
 * Raw samples (and caches) may live in the user's SAF samples folder; every read goes through the
 * [StudioMaterializer], which hands out a local copy for a `content://` ref. The render cache itself is always
 * written to app storage (derived data).
 */
class SampleRenderCache(
    private val roots: StudioRoots,
    private val store: StudioStore,
    private val render: StudioRender,
    private val materializer: StudioMaterializer = StudioMaterializer.FILES_ONLY,
) {
    private fun sourceRef(s: StudioSample): StudioFileRef? =
        StudioFolders.fileRef(roots, StudioFamily.SAMPLES, s.fileName, s.wasUserFolder)

    private fun cacheRef(s: StudioSample): StudioFileRef? {
        val name = s.renderedFileName ?: return null
        return StudioFolders.fileRef(roots, StudioFamily.SAMPLES, name, s.renderedWasUserFolder ?: false)
    }

    /** A lease on a local copy of the raw source (null if gone / SAF root unreachable). Release when done. */
    suspend fun sourceLease(s: StudioSample): StudioLease? = sourceRef(s)?.let { materializer.lease(it) }

    /**
     * A local file for the raw source, or null if gone. A SAF-resident sample is materialized first (a blocking copy
     * for a `content://` ref, so call it off the main thread, or prefer [sourceFileAsync]); the cached copy is
     * released immediately and stays on disk until the materializer's LRU evicts it.
     */
    fun sourceFile(s: StudioSample): File? {
        val ref = sourceRef(s) ?: return null
        ref.file?.let { return it }
        return runBlocking { materializer.lease(ref)?.let { l -> l.file.also { l.release() } } }
    }

    /** Suspending [sourceFile] for UI coroutines (never blocks the caller's thread). */
    suspend fun sourceFileAsync(s: StudioSample): File? {
        val ref = sourceRef(s) ?: return null
        ref.file?.let { return it }
        return materializer.lease(ref)?.let { l -> l.file.also { l.release() } }
    }

    fun cacheFile(s: StudioSample): File? = cacheRef(s)?.file

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
            val lease = sourceLease(s) ?: return null
            val dest: File
            try {
                val rev = s.renderRevision
                val name = StudioFolders.renderedSampleFileName(s.id, rev)
                dest = StudioFiles.appFile(roots, StudioFamily.SAMPLES, name) ?: return null
                val old = s.renderedFileName
                render.renderSample(s.edit, lease.file.path, dest)
                store.setRenderedSample(s.id, name, false, rev)
                if (old != null && old != name) StudioFiles.appFile(roots, StudioFamily.SAMPLES, old)?.delete()
            } finally { lease.release() }
            s = store.sample(id) ?: return dest
        }
        if (s.edit.isNeutral) return sourceFileAsync(s)
        return cacheFile(s) ?: sourceFileAsync(s)
    }
}

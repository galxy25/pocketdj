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
     * The raw source as a [RawSource] holding its materializer lease until [RawSource.close] (so the LRU cannot evict the
     * copy between hand-out and decode/carve). Null when gone / unreachable. Suspends: a `content://` copy never runs on
     * the caller's thread when the caller is off-main.
     */
    suspend fun sourceRaw(s: StudioSample): RawSource? {
        val ref = sourceRef(s) ?: return null
        ref.file?.let { return RawSource(it) }
        val lease = materializer.lease(ref) ?: return null
        return RawSource(lease.file) { lease.release() }
    }

    /** Run [block] on the raw source file with its lease held (released after, even on failure); null when gone. */
    suspend fun <T> withSource(s: StudioSample, block: suspend (File) -> T): T? {
        val raw = sourceRaw(s) ?: return null
        return raw.use { block(it.file) }
    }

    /** The raw source file with NO lease held (only for the neutral-play handoff to a player that opens it at once). */
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

/** A raw sample file plus the lease keeping it alive; [close] releases (idempotent). */
class RawSource(val file: File, private val onRelease: () -> Unit = {}) : AutoCloseable {
    private var closed = false
    @Synchronized override fun close() { if (closed) return; closed = true; onRelease() }
}

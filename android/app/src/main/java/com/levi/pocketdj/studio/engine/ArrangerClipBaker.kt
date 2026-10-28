package com.levi.pocketdj.studio.engine

import com.levi.pocketdj.studio.audio.StudioRender
import com.levi.pocketdj.studio.model.StudioClip
import com.levi.pocketdj.studio.model.StudioClipSource
import com.levi.pocketdj.studio.model.StudioFactory
import com.levi.pocketdj.studio.store.StudioFileRef
import com.levi.pocketdj.studio.store.StudioPlayable
import com.levi.pocketdj.studio.store.StudioRoots
import com.levi.pocketdj.studio.store.StudioStore
import kotlinx.coroutines.CancellationException
import java.io.File

/**
 * Bakes a studio source (sample / loop / sequence / instrumental) into an IMMUTABLE arranger clip snapshot,
 * `clip-<id>.m4a` in the app-managed arrangements dir (iOS `ArrangerClipBaker`). Order: make the source
 * offline-playable ([prepare] bounces a dirty pattern / renders a stale take, a no-op for samples and loops),
 * resolve its local file, then whole-file import into canonical AAC. The clip owns its audio forever, so
 * later edits to (or deletion of) the source never touch a placed clip.
 */
class ArrangerClipBaker(
    private val roots: StudioRoots,
    private val render: StudioRender,
    /** `StudioPlayback.prepare` — prepare + resolve a studio id to a playable local file. */
    private val prepare: suspend (String) -> StudioPlayable?,
    /**
     * A SAF-backed source has no plain `File`: the host copies it to a temp file and returns it (and
     * deletes it via [release]). Default: the ref's own file.
     */
    private val materialize: suspend (StudioFileRef) -> File? = { it.file },
    private val release: (StudioFileRef, File) -> Unit = { _, _ -> },
    private val now: () -> Double = { System.currentTimeMillis().toDouble() },
) {
    /** A ready-to-file clip (audio already on disk) at [startMs], or null when the source can't be baked. */
    suspend fun bake(sourceId: String, kind: StudioClipSource, startMs: Int): StudioClip? {
        val playable = prepare(sourceId) ?: return null
        val file = materialize(playable.ref) ?: return null
        try {
            return bakeFile(file, playable.title, kind, sourceId, startMs)
        } finally {
            release(playable.ref, file)
        }
    }

    /** Bake from an arbitrary audio file (a live recording, an artifact, a stem): `.recording`/`.stem`, no source id. */
    suspend fun bakeFromFile(source: File, name: String, startMs: Int, kind: StudioClipSource = StudioClipSource.RECORDING): StudioClip? =
        bakeFile(source, name, kind, null, startMs)

    private suspend fun bakeFile(source: File, name: String, kind: StudioClipSource, sourceId: String?, startMs: Int): StudioClip? {
        val clipId = StudioFactory.newClipId()
        val fileName = StudioStore.clipFileName(clipId)
        val dest = File(roots.arrangementsDir(), fileName)
        val baked = try {
            render.importAudioFile(source.path, dest)
        } catch (e: CancellationException) {
            dest.delete(); throw e
        } catch (_: Exception) {
            dest.delete(); return null
        }
        if (baked.durationMs <= 0) { dest.delete(); return null }
        return StudioClip(
            id = clipId, name = name, fileName = fileName, startMs = maxOf(0, startMs), durationMs = baked.durationMs,
            source = kind, sourceId = sourceId, createdAt = now(),
        )
    }
}

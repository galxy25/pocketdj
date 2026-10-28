package com.levi.pocketdj.studio.engine

import com.levi.pocketdj.studio.StudioFiles
import com.levi.pocketdj.studio.audio.LocalAudioCache
import com.levi.pocketdj.studio.audio.LocalSource
import com.levi.pocketdj.studio.audio.StudioRender
import com.levi.pocketdj.studio.audio.StudioRenderException
import com.levi.pocketdj.studio.model.StudioFactory
import com.levi.pocketdj.studio.model.StudioGrid
import com.levi.pocketdj.studio.model.StudioSample
import com.levi.pocketdj.studio.model.StudioSource
import com.levi.pocketdj.studio.store.StudioFamily
import com.levi.pocketdj.studio.store.StudioFolders
import com.levi.pocketdj.studio.store.StudioRoots
import com.levi.pocketdj.studio.store.StudioStore
import java.io.File

/** Why filing a sample failed (the sheets map each to specific copy). */
sealed class SampleFileFailure(val message: String) {
    object Protected : SampleFileFailure("That file is DRM-protected and can’t be imported.")
    object Unreadable : SampleFileFailure("Couldn’t read that audio file.")
    object NoFolder : SampleFileFailure("Your samples folder isn’t reachable right now (Settings ▸ Storage).")
    object Carve : SampleFileFailure("Couldn’t carve this region. Try a slightly different in/out point.")
}

class SampleFileException(val failure: SampleFileFailure) : Exception(failure.message)

/**
 * Turns decoded audio into a filed [StudioSample]: import (DRM rejected) and track-region carve (inherits
 * the offset-shifted grid). Files are written into the app-managed samples root; the record is added only
 * after the audio is atomically on disk.
 */
class SampleFactory(
    private val roots: StudioRoots,
    private val store: StudioStore,
    private val render: StudioRender,
    private val now: () -> Double = { System.currentTimeMillis().toDouble() },
) {
    /** "My Loop.wav" -> "My Loop" (iOS strips the extension for the default name). */
    fun importName(originalName: String): String {
        val base = originalName.substringBeforeLast('.', originalName).trim()
        return base.ifEmpty { "Imported sample" }
    }

    private fun destFor(id: String): Pair<String, File> {
        val name = StudioFolders.fileName(StudioFamily.SAMPLES, id)
        val f = StudioFiles.appFile(roots, StudioFamily.SAMPLES, name) ?: throw SampleFileException(SampleFileFailure.NoFolder)
        f.parentFile?.mkdirs()
        return name to f
    }

    /** Import [source] (an already-local file; the caller copies a SAF uri to cache first). */
    suspend fun importFile(source: File, originalName: String): StudioSample {
        val id = StudioFactory.newSampleId()
        val (name, dest) = destFor(id)
        val res = try {
            render.importAudioFile(source.path, dest)
        } catch (e: StudioRenderException.ProtectedSource) {
            throw SampleFileException(SampleFileFailure.Protected)
        } catch (e: StudioRenderException) {
            dest.delete(); throw SampleFileException(SampleFileFailure.Unreadable)
        }
        return store.addSample(
            StudioSample(id, importName(originalName), name, wasUserFolder = false, createdAt = now(),
                durationMs = res.durationMs, source = StudioSource.File(originalName)),
        )
    }

    /** Carve [startMs, endMs) (SONG-relative) out of [src]. [grid] is the already-inherited region-relative grid. */
    suspend fun carveTrack(songId: String, songName: String, src: LocalSource, startMs: Int, endMs: Int, grid: StudioGrid?): StudioSample {
        val id = StudioFactory.newSampleId()
        val (name, dest) = destFor(id)
        val (fs, fe) = LocalAudioCache.fileWindow(src, startMs, endMs)
        val res = try {
            render.carveTrackRegion(src.file.path, fs, fe, dest)
        } catch (e: StudioRenderException) {
            dest.delete(); throw SampleFileException(SampleFileFailure.Carve)
        }
        return store.addSample(
            StudioSample(id, songName, name, wasUserFolder = false, createdAt = now(), durationMs = res.durationMs,
                source = StudioSource.Track(songId, startMs, endMs), grid = grid),
        )
    }
}

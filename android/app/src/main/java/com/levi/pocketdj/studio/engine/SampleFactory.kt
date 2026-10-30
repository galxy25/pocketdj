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
    object StemCarve : SampleFileFailure("Couldn’t carve those stems. Try a different region or fewer stems.")
    object Carve : SampleFileFailure("Couldn’t carve this region. Try a slightly different in/out point.")
}

class SampleFileException(val failure: SampleFileFailure) : Exception(failure.message)

/**
 * Turns decoded audio into a filed [StudioSample]: import (DRM rejected) and track-region carve (inherits
 * the offset-shifted grid). Files are first written (crash-safe) into the app-managed samples root, then MOVED into the user's SAF samples
 * folder when one is set ([StudioStore.addSampleRelocating]); the record is added only after the audio is on disk.
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

    /** The audio is finalized in app storage above; now move it into the user's samples folder (off the caller's thread). */
    private suspend fun fileRelocating(sample: StudioSample): StudioSample =
        kotlinx.coroutines.withContext(kotlinx.coroutines.Dispatchers.IO) { store.addSampleRelocating(sample) }

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
        return fileRelocating(
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
        return fileRelocating(
            StudioSample(id, songName, name, wasUserFolder = false, createdAt = now(), durationMs = res.durationMs,
                source = StudioSource.Track(songId, startMs, endMs), grid = grid),
        )
    }

    /**
     * Carve a MIX of [enabled] stems over [startMs, endMs) (SONG-relative — stems carry no album offset). The record keeps
     * the same `Track` provenance as a full-mix carve; [grid] is the already-inherited region-relative grid.
     */
    suspend fun carveStems(songId: String, songName: String, stems: Map<String, File>, enabled: Set<String>, startMs: Int, endMs: Int, grid: StudioGrid?): StudioSample {
        val paths = StemCarve.selectedPaths(stems, enabled) ?: throw SampleFileException(SampleFileFailure.StemCarve)
        val id = StudioFactory.newSampleId()
        val (name, dest) = destFor(id)
        val res = try {
            render.carveStemMix(paths, startMs, endMs, dest)
        } catch (e: StudioRenderException) {
            dest.delete(); throw SampleFileException(SampleFileFailure.StemCarve)
        }
        return fileRelocating(
            StudioSample(id, StemCarve.sampleName(songName, enabled), name, wasUserFolder = false, createdAt = now(), durationMs = res.durationMs,
                source = StudioSource.Track(songId, startMs, endMs), grid = grid),
        )
    }
}

package com.levi.pocketdj.studio.engine

import com.levi.pocketdj.studio.demux.DemuxCutMath
import com.levi.pocketdj.studio.demux.DemuxStore
import java.io.File

/**
 * Pure rules for carving a MIX of a song's separated stems into a sample (iOS `carveStems` in
 * StudioNewSampleFromTrackView). Stems are SONG-RELATIVE: the window is `[startMs, endMs]` exactly as the user
 * marked it, with no analog album offset (unlike the single-file track carve).
 */
object StemCarve {
    /** Canonical stem order (vocals, drums, bass, other) — the order the carve sums and names them in. */
    val STEMS: List<String> = DemuxStore.STEM_NAMES

    const val NO_STEMS = "Couldn’t get this track’s stems. Make sure it’s stemmed, then try again."
    const val DOWNLOAD_FAILED = "Couldn’t download the stems to carve — check your connection and try again."

    /** The stem-source toggle shows when the stems are on the device OR stemmed server-side (downloaded on demand). */
    fun available(downloaded: Boolean, stemmedRemotely: Boolean) = downloaded || stemmedRemotely

    fun allEnabled(): Set<String> = STEMS.toSet()

    /** Toggle a chip; the last enabled stem can never be switched off. */
    fun toggle(enabled: Set<String>, stem: String): Set<String> = DemuxCutMath.toggleStem(enabled, stem)

    /** Selected stem files in canonical order. Null when nothing is selected or a selected stem file is missing (mix must be whole). */
    fun selectedPaths(files: Map<String, File>, enabled: Set<String>): List<String>? {
        val wanted = STEMS.filter { it in enabled }
        if (wanted.isEmpty()) return null
        val paths = wanted.mapNotNull { files[it]?.path }
        return paths.takeIf { it.size == wanted.size }
    }

    /** "<song> · stems" for the full set, else the chosen names joined (drums+bass). */
    fun sampleName(songName: String, enabled: Set<String>): String {
        val sel = STEMS.filter { it in enabled }
        val suffix = if (sel.size == STEMS.size) "stems" else sel.joinToString("+")
        return "$songName · $suffix"
    }

    /** The picked stems resolved to files, or why not. */
    sealed class Resolved {
        data class Files(val files: Map<String, File>) : Resolved()
        data class Failed(val message: String) : Resolved()
    }

    /** Local stems first, then an on-demand download (iOS `burnStems`); never carves from a partial set. */
    suspend fun resolve(local: () -> Map<String, File>?, download: suspend () -> Map<String, File>?): Resolved {
        local()?.let { return Resolved.Files(it) }
        val got = try { download() } catch (e: kotlinx.coroutines.CancellationException) { throw e } catch (_: Exception) { null }
        if (got != null && STEMS.all { it in got }) return Resolved.Files(got)
        return Resolved.Failed(NO_STEMS)
    }
}

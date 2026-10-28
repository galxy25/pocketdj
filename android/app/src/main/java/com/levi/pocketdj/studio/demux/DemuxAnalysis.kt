package com.levi.pocketdj.studio.demux

import com.levi.pocketdj.data.burns.BeatGridSidecar
import com.levi.pocketdj.studio.model.StudioGrid
import java.io.File
import kotlinx.coroutines.CancellationException
import kotlinx.coroutines.CoroutineDispatcher
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.Job
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.asStateFlow
import kotlinx.coroutines.flow.update
import kotlinx.coroutines.launch
import kotlinx.coroutines.withContext

/**
 * The bar lattice + instrumental grid derived for ONE source. Keyed by [sourceKey] so a result computed for source A can
 * never be applied (or exported) while source B is open (the "no stale cross-source export" rule).
 */
data class DemuxGridResult(
    val sourceKey: String,
    val bars: List<DrumPatternDetector.Bar>,
    val grid: DemuxInstrumental.Grid,
    val measured: Boolean,
) {
    /** This result only if it belongs to [key]. */
    fun forSource(key: String): DemuxGridResult? = takeIf { sourceKey == key }
}

object DemuxGridResolver {
    /**
     * A catalog song's measured sidecar (real downbeats, tempo drift included) wins; else a constant grid estimated
     * from the audio ([estimate], run lazily and only when needed). Custom sources never hit the network.
     * Null when no tempo could be found (the panel shows a hint instead of bars).
     */
    fun resolve(sourceKey: String, durationMs: Int, sidecar: BeatGridSidecar?, estimate: () -> StudioGrid?): DemuxGridResult? {
        val bpm = sidecar?.beatGridBpm
        if (sidecar != null && bpm != null && bpm > 0) {
            val first = sidecar.firstDownbeatMs ?: 0
            val bars = DrumPatternDetector.bars(sidecar.downbeatsMs, bpm, first, durationMs)
            return DemuxGridResult(sourceKey, bars, DemuxInstrumental.Grid(bpm, first, sidecar.beatsMs), measured = true)
        }
        val g = estimate() ?: return null
        if (g.bpm <= 0) return null
        val bars = DrumPatternDetector.bars(emptyList(), g.bpm, g.firstDownbeatMs, durationMs)
        return DemuxGridResult(sourceKey, bars, DemuxInstrumental.Grid(g.bpm, g.firstDownbeatMs, g.beatsMs), measured = false)
    }
}

/** Which stem a melody is tracked from: VOCALS, else OTHER. Null without either. */
fun melodyStem(stems: Map<String, File>?): File? = stems?.get("vocals") ?: stems?.get("other")

/**
 * Runs the Demuxer's heavy on-device analyses (drum pattern, melody) and the cloud-lyrics fetch, one run per source
 * key, persisting status + results on the source's [DemuxDocument] (the DemuxStore.analyzeChords shape). Results land
 * through `store.update`, which re-reads the CURRENT document, so a concurrent chord/words write is never clobbered.
 */
class DemuxAnalyzers(
    private val scope: CoroutineScope,
    private val store: DemuxStore,
    private val dispatcher: CoroutineDispatcher = Dispatchers.Default,
    private val detectDrums: (drums: String, bass: String?) -> List<DemuxDrumHit> = { d, b -> DrumPatternDetector.detect(d, b) },
    private val detectMelody: (stem: String) -> List<DemuxMelodyNote> = { MelodyTracker.detect(it) },
) {
    private val lock = Any()
    private val _drumRuns = MutableStateFlow<Set<String>>(emptySet())
    val drumRuns: StateFlow<Set<String>> = _drumRuns.asStateFlow()
    private val _melodyRuns = MutableStateFlow<Set<String>>(emptySet())
    val melodyRuns: StateFlow<Set<String>> = _melodyRuns.asStateFlow()
    private val _lyricsFetching = MutableStateFlow<Set<String>>(emptySet())
    val lyricsFetching: StateFlow<Set<String>> = _lyricsFetching.asStateFlow()

    private fun claim(runs: MutableStateFlow<Set<String>>, key: String): Boolean = synchronized(lock) {
        if (key in runs.value) false else { runs.update { it + key }; true }
    }

    /** Extract the classified drum hits; a no-op while a run for the key is in flight or when already DONE (unless [force]). */
    fun analyzeDrums(source: DemuxSource, drumsPath: String, bassPath: String?, durationMs: Int, force: Boolean = false): Job? {
        val key = source.key
        if (!force && store.documentCreating(source).drumStatus == DemuxArtifactStatus.DONE) return null
        if (!claim(_drumRuns, key)) return null
        store.update(source) { it.copy(drumStatus = DemuxArtifactStatus.RUNNING, durationMs = maxOf(it.durationMs, durationMs)) }
        return scope.launch {
            val hits = try {
                withContext(dispatcher) { detectDrums(drumsPath, bassPath) }
            } catch (e: CancellationException) {
                _drumRuns.update { it - key }; throw e
            } catch (_: Throwable) { emptyList() }
            store.update(source) {
                it.copy(drumHits = hits, drumStatus = if (hits.isEmpty()) DemuxArtifactStatus.FAILED else DemuxArtifactStatus.DONE)
            }
            _drumRuns.update { it - key }
        }
    }

    /** Track the melody (monophonic) of the melodic stem and cache the notes (the tracker runs ONCE per source). */
    fun analyzeMelody(source: DemuxSource, stemPath: String, force: Boolean = false): Job? {
        val key = source.key
        val doc = store.documentCreating(source)
        if (!force && doc.melodyStatus == DemuxArtifactStatus.DONE && !doc.melodyNotes.isNullOrEmpty()) return null
        if (!claim(_melodyRuns, key)) return null
        store.update(source) { it.copy(melodyStatus = DemuxArtifactStatus.RUNNING) }
        return scope.launch {
            val notes = try {
                withContext(dispatcher) { detectMelody(stemPath) }
            } catch (e: CancellationException) {
                _melodyRuns.update { it - key }; throw e
            } catch (_: Throwable) { emptyList() }
            store.update(source) {
                it.copy(melodyNotes = notes, melodyStatus = if (notes.isEmpty()) DemuxArtifactStatus.FAILED else DemuxArtifactStatus.DONE)
            }
            _melodyRuns.update { it - key }
        }
    }

    /** Track a melody for a Takes-menu switch: returns the notes (also cached on the document). Null when no stem. */
    suspend fun trackMelodyNow(sourceKey: String, stem: File?): List<DemuxMelodyNote>? {
        stem ?: return null
        return withContext(dispatcher) { detectMelody(stem.path) }
    }

    /** Cache just the melody fields on the CURRENT document (the re-fetch discipline after a long await). */
    fun cacheMelody(sourceKey: String, notes: List<DemuxMelodyNote>) {
        val doc = store.document(sourceKey) ?: return
        store.save(doc.copy(melodyNotes = notes, melodyStatus = DemuxArtifactStatus.DONE))
    }

    /**
     * Fetch the cloud lyrics sidecar via [download] (body text, null on failure) and land it WHOLESALE. Fetched-once
     * dedup: an already-landed cloud transcript is not re-downloaded unless [force]. A failed fetch/decode leaves the
     * document untouched (so it retries next open) and returns false.
     */
    suspend fun fetchCloudLyrics(source: DemuxSource, force: Boolean, download: suspend () -> String?): Boolean {
        val key = source.key
        val doc = store.documentCreating(source)
        if (!force && doc.transcriptStatus == DemuxArtifactStatus.DONE && doc.transcriptEngine == "cloud") return true
        if (!claim(_lyricsFetching, key)) return false
        try {
            val text = download() ?: return false
            val sidecar = TimedLyricsSidecar.parse(text) ?: return false
            store.update(source) { it.withCloudTranscript(sidecar) }
            return true
        } finally {
            _lyricsFetching.update { it - key }
        }
    }
}

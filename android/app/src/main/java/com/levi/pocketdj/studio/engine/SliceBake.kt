package com.levi.pocketdj.studio.engine

import com.levi.pocketdj.studio.StudioFiles
import com.levi.pocketdj.studio.audio.StudioRender
import com.levi.pocketdj.studio.audio.StudioRenderException
import com.levi.pocketdj.studio.demux.BeatGrid
import com.levi.pocketdj.studio.demux.BeatMath
import com.levi.pocketdj.studio.model.StudioFactory
import com.levi.pocketdj.studio.model.StudioGrid
import com.levi.pocketdj.studio.model.StudioPattern
import com.levi.pocketdj.studio.model.StudioPatternRow
import com.levi.pocketdj.studio.model.StudioSample
import com.levi.pocketdj.studio.model.StudioSampleEdit
import com.levi.pocketdj.studio.model.StudioSlice
import com.levi.pocketdj.studio.model.StudioSource
import com.levi.pocketdj.studio.store.StudioFamily
import com.levi.pocketdj.studio.store.StudioFolders
import com.levi.pocketdj.studio.store.StudioRoots
import com.levi.pocketdj.studio.store.StudioStore
import java.io.File

/** Pure slice-editor rules (JVM-tested). Pads are start-markers on the RAW sample; a pad plays until the next start. */
object SliceMath {
    /** ARGB per pad slot (the same hue ring as the cue slots). */
    val SLOT_COLORS: List<Long> = listOf(
        0xFFFF5A5F, 0xFFFFA23A, 0xFFF4D03F, 0xFF4CD964, 0xFF30C9C9, 0xFF4A90E2, 0xFF9B6BFF, 0xFFE86AD0,
    )

    fun slotColor(slot: Int): Long = SLOT_COLORS[((slot % SLOT_COLORS.size) + SLOT_COLORS.size) % SLOT_COLORS.size]

    /**
     * [start, end) of the pad in [slot]: until the NEXT slice start BY TIME (not by slot), else the sample's
     * [durationMs]. Null when the pad is missing or the window is empty.
     */
    fun window(slices: List<StudioSlice>, slot: Int, durationMs: Int): Pair<Int, Int>? {
        val s = slices.firstOrNull { it.slot == slot } ?: return null
        val next = slices.filter { it.startMs > s.startMs }.minOfOrNull { it.startMs }
        val end = next ?: durationMs
        return if (end > s.startMs) s.startMs to end else null
    }

    /** Even chop / beat snap: up to [count] (cap 8) distinct sorted starts, pad 0 always 0; coincident snaps merge. */
    fun autoStarts(count: Int, grid: StudioGrid?, durationMs: Int): List<Int> =
        BeatMath.sliceStarts(count, grid?.let { BeatGrid(it.bpm, it.firstDownbeatMs, it.beatsMs) }, durationMs)

    /** A marker dragged to fraction [frac] of the waveform -> ms, clamped to [0, durationMs]. */
    fun msAt(frac: Float, durationMs: Int): Int = (frac.coerceIn(0f, 1f).toDouble() * durationMs).toInt()

    /** The pad whose marker is nearest a touch at [x] px (within [slop] px) on a [widthPx]-wide waveform; null when none. */
    fun nearestSlot(slices: List<StudioSlice>, durationMs: Int, widthPx: Float, x: Float, slop: Float): Int? {
        if (durationMs <= 0 || widthPx <= 0f) return null
        return slices.map { it.slot to kotlin.math.abs(it.startMs.coerceIn(0, durationMs).toFloat() / durationMs * widthPx - x) }
            .filter { it.second <= slop }.minByOrNull { it.second }?.first
    }

    /** Where a freshly-added pad lands: proportional to its slot so there is something to nudge/drag. */
    fun defaultAddStart(durationMs: Int, slot: Int): Int = maxOf(0, durationMs) * slot / StudioSlice.MAX_SLOTS

    fun padLabel(s: StudioSlice): String = s.name ?: "Pad ${s.slot + 1}"

    fun bakedName(sampleName: String, slot: Int) = "$sampleName · pad ${slot + 1}"

    fun patternName(sampleName: String) = "$sampleName slices"

    /** Pads in time order (the sequencer rows follow the sample's timeline). */
    fun timeOrdered(slices: List<StudioSlice>): List<StudioSlice> = slices.sortedBy { it.startMs }

    /** One default-step row per baked target. */
    fun rowsFor(targets: List<String>): List<StudioPatternRow> = targets.map { StudioPatternRow.of(it) }

    /** The grid a carved pad inherits: the sample's grid shifted so 0:00 is the pad start. */
    fun padGrid(grid: StudioGrid?, startMs: Int, lengthMs: Int): StudioGrid? {
        val g = grid ?: return null
        val s = BeatMath.shifted(BeatGrid(g.bpm, g.firstDownbeatMs, g.beatsMs), startMs, lengthMs)
        return StudioGrid(s.bpm, s.firstDownbeatMs, s.beatsMs)
    }
}

/**
 * Bakes pads into independent `smp_` samples (a neutral carve of the RAW file, never the trim window) and builds
 * the sequencer pattern from them. Files go to the app-managed samples root; the record is added only after the
 * audio is atomically on disk.
 */
class SliceBaker(
    private val roots: StudioRoots,
    private val store: StudioStore,
    private val render: StudioRender,
    private val rawFile: suspend (StudioSample) -> RawSource?,
    private val now: () -> Double = { System.currentTimeMillis().toDouble() },
) {
    /** Bake pad [slot] of [sampleId]; the new sample id, or null on any failure (missing pad/file/folder, empty carve). */
    suspend fun bakePad(sampleId: String, slot: Int): String? {
        val s = store.sample(sampleId) ?: return null
        val (start, end) = SliceMath.window(store.slices(sampleId), slot, s.durationMs) ?: return null
        val src = rawFile(s) ?: return null
        val id = StudioFactory.newSampleId()
        val fileName = StudioFolders.fileName(StudioFamily.SAMPLES, id)
        val dest = StudioFiles.appFile(roots, StudioFamily.SAMPLES, fileName)
        if (dest == null) { src.close(); return null }
        dest.parentFile?.mkdirs()
        val carved = try { render.carveTrackRegion(src.file.path, start, end, dest) } catch (e: kotlinx.coroutines.CancellationException) {
            dest.delete(); throw e
        } catch (e: Exception) {
            dest.delete(); return null
        } finally { src.close() }
        // The SAF copy can be large: never on the caller's (UI) thread.
        kotlinx.coroutines.withContext(kotlinx.coroutines.Dispatchers.IO) { store.addSampleRelocating(
            StudioSample(
                id = id, name = SliceMath.bakedName(s.name, slot), fileName = fileName, wasUserFolder = false, createdAt = now(),
                durationMs = carved.durationMs, source = StudioSource.File("${s.name} pad ${slot + 1}"),
                grid = SliceMath.padGrid(s.grid, start, carved.durationMs), edit = StudioSampleEdit.NEUTRAL,
            ),
        ) }
        return id
    }

    data class SequencerResult(val patternId: String, val baked: Int)

    /** Bake every pad (time-ordered) and file ONE pattern with a row per baked sample; null when nothing baked. */
    suspend fun sendToSequencer(sampleId: String): SequencerResult? {
        val s = store.sample(sampleId) ?: return null
        val targets = SliceMath.timeOrdered(store.slices(sampleId)).mapNotNull { bakePad(sampleId, it.slot) }
        if (targets.isEmpty()) return null
        val p = store.addPattern(
            StudioPattern.of(
                StudioFactory.newPatternId(), SliceMath.patternName(s.name), bpm = s.grid?.bpm ?: 120.0,
                rows = SliceMath.rowsFor(targets), createdAt = now(),
            ),
        )
        return SequencerResult(p.id, targets.size)
    }
}

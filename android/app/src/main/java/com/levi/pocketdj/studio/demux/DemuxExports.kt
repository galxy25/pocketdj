package com.levi.pocketdj.studio.demux

import com.levi.pocketdj.audio.core.PcmBuffer
import com.levi.pocketdj.studio.StudioFiles
import com.levi.pocketdj.studio.audio.StudioRender
import com.levi.pocketdj.studio.engine.ArrangerClipBaker
import com.levi.pocketdj.studio.engine.TakeRenderer
import com.levi.pocketdj.studio.model.InstrumentKey
import com.levi.pocketdj.studio.model.StudioClipSource
import com.levi.pocketdj.studio.model.StudioFactory
import com.levi.pocketdj.studio.model.StudioPattern
import com.levi.pocketdj.studio.model.StudioPatternRow
import com.levi.pocketdj.studio.model.StudioSample
import com.levi.pocketdj.studio.model.StudioSource
import com.levi.pocketdj.studio.model.StudioTake
import com.levi.pocketdj.studio.store.StudioFamily
import com.levi.pocketdj.studio.store.StudioFolders
import com.levi.pocketdj.studio.store.StudioRoots
import com.levi.pocketdj.studio.store.StudioStore
import java.io.File
import kotlinx.coroutines.CancellationException
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.withContext

/** Lane order / labels for the pattern grid + sequencer export (kick at the top, bass at the bottom). */
object DrumLanes {
    val ORDER = listOf(DemuxDrumKind.KICK, DemuxDrumKind.SNARE, DemuxDrumKind.PERCUSSIVE, DemuxDrumKind.OTHER, DemuxDrumKind.BASS)

    fun label(kind: DemuxDrumKind) = when (kind) {
        DemuxDrumKind.KICK -> "Kick"
        DemuxDrumKind.SNARE -> "Snare"
        DemuxDrumKind.PERCUSSIVE -> "Perc"
        DemuxDrumKind.OTHER -> "Other"
        DemuxDrumKind.BASS -> "Bass"
    }

    /** Lanes shown for every bar: classes that occur ANYWHERE in the song (stable rows while flipping bars). */
    fun present(hits: List<DemuxDrumHit>): List<DemuxDrumKind> {
        val s = hits.map { it.kind }.toSet()
        return ORDER.filter { it in s }
    }
}

/** Pure math for the "Send bar N / Send all N bars to Sequencer" export. */
object DrumPatternExport {
    /**
     * The kit-sample region for a class: its STRONGEST hit, cut at the stem's next hit (min 60 ms so a flam doesn't
     * yield a click, max 500 ms so a sparse groove doesn't drag a phrase into a one-shot). Null when the class never hit.
     */
    fun hitRegion(kind: DemuxDrumKind, hits: List<DemuxDrumHit>, durationMs: Int): Pair<Int, Int>? {
        val stemHits = hits.filter { (it.kind == DemuxDrumKind.BASS) == (kind == DemuxDrumKind.BASS) }.sortedBy { it.ms }
        val best = stemHits.filter { it.kind == kind }.maxByOrNull { it.strength } ?: return null
        val next = stemHits.firstOrNull { it.ms > best.ms + 30 }?.ms ?: durationMs
        val end = minOf(minOf(best.ms + 500, durationMs), maxOf(next, best.ms + 60))
        if (end <= best.ms + 20) return null
        return best.ms to end
    }

    /** One lane's concatenated steps across the covered bars + the pattern geometry. */
    data class Plan(val kinds: List<DemuxDrumKind>, val steps: Map<DemuxDrumKind, List<Boolean>>, val stepCount: Int, val bpm: Double, val barCount: Int)

    /**
     * Build the export plan for the bar indices in [range]: classes that fire in ANY covered bar get a lane, each lane
     * concatenates every covered bar's 16 steps (a missing bar = 16 rests); the MEDIAN bar length sets the bpm
     * (240000/barMs, clamped 40..300). Null when nothing hit.
     */
    fun plan(grid: List<Map<DemuxDrumKind, List<Boolean>>>, bars: List<DrumPatternDetector.Bar>, range: List<Int>): Plan? {
        val covered = range.filter { it in grid.indices && it in bars.indices }
        if (covered.isEmpty()) return null
        val kinds = DrumLanes.ORDER.filter { k -> covered.any { grid[it][k]?.contains(true) == true } }
        if (kinds.isEmpty()) return null
        val steps = kinds.associateWith { k -> covered.flatMap { StudioPatternRow.normalized(grid[it][k] ?: emptyList(), 16) } }
        val lens = covered.map { maxOf(1, bars[it].endMs - bars[it].startMs) }.sorted()
        val bpm = (240_000.0 / lens[lens.size / 2]).coerceIn(40.0, 300.0)
        return Plan(kinds, steps, covered.size * 16, bpm, covered.size)
    }

    fun patternName(source: DemuxSource, wholeSong: Boolean, barCount: Int, selectedBar: Int) =
        if (wholeSong) "${source.displayName} · full ($barCount bars)" else "${source.displayName} · bar ${selectedBar + 1}"

    fun notice(lanes: Int, bars: Int) =
        "Sequence created — $lanes lane${if (lanes == 1) "" else "s"} × $bars bar${if (bars == 1) "" else "s"}. " +
            "Open the Sequencer and use each row’s swap menu to morph lanes onto other samples."
}

/** Region math for the Demux cut-sample sheet (pure). */
object DemuxCutMath {
    const val MIN_WINDOW_MS = 50

    /** Move the IN handle: never past out - min window, never below 0. */
    fun setIn(v: Int, endMs: Int): Int = minOf(v, endMs - MIN_WINDOW_MS).coerceAtLeast(0)

    /** Move the OUT handle: never past the file end, never within the min window of in. */
    fun setOut(v: Int, startMs: Int, durationMs: Int): Int = maxOf(minOf(v, durationMs), startMs + MIN_WINDOW_MS)

    /** Toggle a stem chip; the LAST enabled stem can never be switched off (nothing to carve otherwise). */
    fun toggleStem(enabled: Set<String>, stem: String): Set<String> =
        if (stem in enabled) (if (enabled.size > 1) enabled - stem else enabled) else enabled + stem

    /** Stem files in canonical order for the enabled set. */
    fun stemPaths(stems: Map<String, File>, enabled: Set<String>): List<String> =
        DemuxStore.STEM_NAMES.filter { it in enabled }.mapNotNull { stems[it]?.path }

    fun sampleName(source: DemuxSource, stemMode: Boolean, enabled: Set<String>): String =
        source.displayName + if (stemMode) " · " + DemuxStore.STEM_NAMES.filter { it in enabled }.joinToString("+") else ""
}

/** Snapshot / apply / restore of the shared player's mutes + solo so the Cut sheet's audition never leaks into the Demuxer. */
object StemAudition {
    data class Snapshot(val audible: Set<String>, val soloed: String?)

    private fun clearSolo(player: StemPlayer) { player.soloed?.let { player.solo(it) } }

    fun snapshot(player: StemPlayer): Snapshot {
        val solo = player.soloed
        clearSolo(player)
        val audible = DemuxStore.STEM_NAMES.filter { player.isAudible(it) }.toSet()
        solo?.let { player.solo(it) }
        return Snapshot(audible, solo)
    }

    /** Make exactly [audible] play: solo cleared first, then mutes set from the set (not toggled off isAudible while soloed). */
    fun apply(player: StemPlayer, audible: Set<String>) {
        clearSolo(player)
        for (name in DemuxStore.STEM_NAMES) if (player.isAudible(name) != (name in audible)) player.toggleMute(name)
    }

    fun restore(player: StemPlayer, s: Snapshot) {
        apply(player, s.audible)
        s.soloed?.let { player.solo(it) }
    }
}

/** Where "send stems to arrangement" lands. */
sealed class ArrangementTarget {
    data class New(val name: String) : ArrangementTarget()
    data class Existing(val id: String) : ArrangementTarget()
}

data class ExportOutcome(val ok: Boolean, val notice: String)

/**
 * The Demuxer's hand-offs into the rest of Studio: drum pattern -> Sequencer (kit samples + pattern), instrumental ->
 * Takes, cut sample, stems -> arrangement. All file I/O + store writes live here so the panels stay renderers.
 */
class DemuxExporter(
    private val roots: StudioRoots,
    private val store: StudioStore,
    private val render: StudioRender,
    private val takeRenderer: TakeRenderer?,
    private val bankFor: (InstrumentKey) -> File?,
    private val now: () -> Double = { System.currentTimeMillis().toDouble() },
) {
    private fun provenance(source: DemuxSource, startMs: Int, endMs: Int): StudioSource =
        source.songId?.let { StudioSource.Track(it, startMs, endMs) } ?: StudioSource.File(source.displayName)

    private fun sampleDest(id: String): Pair<String, File>? {
        val name = StudioFolders.fileName(StudioFamily.SAMPLES, id)
        val f = StudioFiles.appFile(roots, StudioFamily.SAMPLES, name) ?: return null
        f.parentFile?.mkdirs()
        return name to f
    }

    /** Carve one representative hit per class from the stems into `smp_` kit samples, then file a pattern of rows. */
    suspend fun sendDrumPattern(
        source: DemuxSource, hits: List<DemuxDrumHit>, durationMs: Int, plan: DrumPatternExport.Plan,
        wholeSong: Boolean, selectedBar: Int, drumsPath: String?, bassPath: String?,
    ): ExportOutcome {
        if (drumsPath == null && bassPath == null) return ExportOutcome(false, "The stems aren’t on the device anymore — download them again.")
        val rows = ArrayList<StudioPatternRow>()
        for (kind in plan.kinds) {
            val stem = (if (kind == DemuxDrumKind.BASS) bassPath else drumsPath) ?: continue
            val region = DrumPatternExport.hitRegion(kind, hits, durationMs) ?: continue
            val id = StudioFactory.newSampleId()
            val (fileName, dest) = sampleDest(id) ?: return ExportOutcome(false, "Your samples folder isn’t reachable right now (Settings ▸ Storage).")
            try {
                val carved = render.carveTrackRegion(stem, region.first, region.second, dest)
                store.addSampleRelocating(
                    StudioSample(
                        id, "${source.displayName} · ${DrumLanes.label(kind).lowercase()}", fileName, wasUserFolder = false, createdAt = now(),
                        durationMs = carved.durationMs, source = provenance(source, region.first, region.second),
                    ),
                )
                rows.add(StudioPatternRow.of(id, plan.steps.getValue(kind)))
            } catch (e: CancellationException) {
                dest.delete(); throw e
            } catch (_: Exception) {
                dest.delete()   // one unusable lane never blocks the rest of the kit
            }
        }
        if (rows.isEmpty()) return ExportOutcome(false, "Couldn’t carve any hits from the stems.")
        store.addPattern(
            StudioPattern.of(
                StudioFactory.newPatternId(), DrumPatternExport.patternName(source, wholeSong, plan.barCount, selectedBar),
                bpm = plan.bpm, stepCount = plan.stepCount, rows = rows, createdAt = now(),
            ),
        )
        return ExportOutcome(true, DrumPatternExport.notice(rows.size, plan.barCount))
    }

    /**
     * Mint a StudioTake from the converted events. The real audio is rendered from the pack's bank when it is on the
     * device; otherwise a short silent placeholder keeps the record and `renderRevision = 1` marks it stale so the first
     * play re-renders (and says which pack to download) instead of replaying silence.
     */
    suspend fun saveInstrumental(source: DemuxSource, content: DemuxInstrumentalContent, grid: DemuxInstrumental.Grid): ExportOutcome {
        val built = content.build(grid)
        if (built.events.isEmpty()) {
            return ExportOutcome(false, if (content.isMelody) "No melody to build from." else "No chords to build an instrumental from.")
        }
        val takeId = StudioFactory.newTakeId()
        val fileName = StudioFolders.fileName(StudioFamily.TAKES, takeId)
        val dur = maxOf(500, built.events.maxOf { it.offMs })
        val instrument = InstrumentKey.PIANO
        val bank = bankFor(instrument)
        var rendered = false
        if (bank != null && takeRenderer != null) {
            rendered = try {
                takeRenderer.renderRaw(takeId, built.events, instrument, bank, fileName)
                true
            } catch (e: CancellationException) { throw e } catch (_: Throwable) { false }
        }
        if (!rendered) {
            val dest = StudioFiles.appFile(roots, StudioFamily.TAKES, fileName)
                ?: return ExportOutcome(false, "Couldn’t save — the instrumentals folder isn’t reachable.")
            withContext(Dispatchers.IO) {
                dest.parentFile?.mkdirs()
                runCatching { render.writeSilentPlaceholder(dest) }
            }
        }
        store.addTakeRelocating(
            StudioTake(
                id = takeId, name = "${source.displayName} · ${if (content.isMelody) "melody" else "instrumental"}",
                instrument = instrument, fileName = fileName, bpm = built.bpm, events = built.events, durationMs = dur,
                createdAt = now(), renderRevision = if (rendered) 0 else 1,
                demuxSourceKey = source.key, demuxMode = content.mode,
            ),
        )
        return ExportOutcome(true, "Saved to Instruments ▸ Instrumentals — edit it, change its sound pack, or switch modes there.")
    }

    /** Carve [startMs, endMs) of the audio (or a stem MIX when [stemPaths] is given) into a new `smp_` sample. */
    suspend fun cutSample(source: DemuxSource, audioPath: String, stemPaths: List<String>?, name: String, startMs: Int, endMs: Int): ExportOutcome {
        val id = StudioFactory.newSampleId()
        val (fileName, dest) = sampleDest(id) ?: return ExportOutcome(false, "Your samples folder isn’t reachable right now (Settings ▸ Storage).")
        return try {
            val res = if (stemPaths != null) render.carveStemMix(stemPaths, startMs, endMs, dest) else render.carveTrackRegion(audioPath, startMs, endMs, dest)
            store.addSampleRelocating(
                StudioSample(id, name, fileName, wasUserFolder = false, createdAt = now(), durationMs = res.durationMs, source = provenance(source, startMs, endMs)),
            )
            ExportOutcome(true, "Sample “$name” created.")
        } catch (e: CancellationException) {
            dest.delete(); throw e
        } catch (_: OutOfMemoryError) {
            dest.delete()
            ExportOutcome(false, "Couldn’t carve this region. Try a slightly different in/out point.")
        } catch (_: Exception) {
            dest.delete()
            ExportOutcome(false, "Couldn’t carve this region. Try a slightly different in/out point.")
        }
    }

    /** Bake the four stems into clips on four tracks aligned at 0:00 (drums, bass, other, vocals) of a new/existing arrangement. */
    suspend fun sendStemsToArrangement(target: ArrangementTarget, label: String, stems: Map<String, File>): ExportOutcome {
        val baker = ArrangerClipBaker(roots, render, prepare = { null })
        val arrangementId = when (target) {
            is ArrangementTarget.Existing -> store.arrangement(target.id)?.id ?: return ExportOutcome(false, "That arrangement is gone.")
            is ArrangementTarget.New -> store.createArrangement(target.name.ifBlank { label }).id
        }
        var added = 0
        for (stem in STEM_ORDER) {
            val f = stems[stem] ?: continue
            // Bake first so a failed stem never leaves an empty lane.
            val clip = baker.bakeFromFile(f, "$label — $stem", 0, StudioClipSource.STEM) ?: continue
            val track = store.addTrack(arrangementId, stem.replaceFirstChar { it.uppercase() })
            if (track == null) { File(roots.arrangementsDir(), clip.fileName).delete(); continue }
            store.addClip(arrangementId, track.id, clip)
            added++
        }
        return if (added == 0) ExportOutcome(false, "Couldn’t add the stems.") else ExportOutcome(true, "Added $added stem track${if (added == 1) "" else "s"}.")
    }

    companion object {
        val STEM_ORDER = listOf("drums", "bass", "other", "vocals")
    }
}

/** A short silent AAC so a take record has a file on disk (reconcile keeps it; playback uses the events). */
internal fun StudioRender.writeSilentPlaceholder(dest: File) {
    val sr = PcmBuffer.CANONICAL_RATE
    com.levi.pocketdj.audio.core.AacEncoder.encode(PcmBuffer(sr, 1, FloatArray(sr / 2)), dest, com.levi.pocketdj.audio.core.AacEncoder.Container.M4A, bitrate = 64_000)
}

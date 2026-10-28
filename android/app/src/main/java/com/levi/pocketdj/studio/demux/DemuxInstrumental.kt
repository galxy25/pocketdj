package com.levi.pocketdj.studio.demux

import com.levi.pocketdj.studio.model.StudioNoteEvent

/**
 * Demux -> chord-comping / melody instrumental (port of Studio/Demux/DemuxInstrumental.swift). Pure value math: turns
 * the ALREADY-DETECTED chord blocks (or tracked melody notes) into a beat-quantized [StudioNoteEvent] stream the
 * Instruments tab plays/edits as a plain StudioTake. Two load-bearing rules the score alignment depends on:
 *  - each chord/note holds for the NUMBER OF BEATS it spans on the real grid (measured beats when present, else a
 *    constant grid from bpm), min 1;
 *  - all times RE-ANCHOR to firstDownbeatMs so 0 ms = beat 1 (the anchor ScoreQuantizer snaps to).
 */
object DemuxInstrumental {
    /** Scalar tempo + count-in anchor + the REAL per-beat timestamps (empty = a constant grid synthesized from bpm). */
    data class Grid(val bpm: Double, val firstDownbeatMs: Int, val beatsMs: List<Int> = emptyList())

    /** Beats a [startMs, endMs) region spans: measured beats inside it, else round(len*bpm/60000). Always >= 1. */
    fun beatsSpanned(startMs: Int, endMs: Int, grid: Grid): Int {
        if (grid.beatsMs.isNotEmpty()) {
            val n = grid.beatsMs.count { it in startMs until endMs }
            if (n >= 1) return n
        }
        val bpm = if (grid.bpm > 0) grid.bpm else 120.0
        return maxOf(1, Math.round((endMs - startMs) * bpm / 60_000.0).toInt())
    }

    /** Snap a time to the nearest beat: the closest measured beat, else the nearest constant-grid beat at firstDownbeatMs. */
    fun snapToBeat(ms: Int, grid: Grid): Int {
        if (grid.beatsMs.isNotEmpty()) return grid.beatsMs.minByOrNull { Math.abs(it - ms) } ?: ms
        val bpm = if (grid.bpm > 0) grid.bpm else 120.0
        val beatMs = 60_000.0 / bpm
        val k = Math.rint((ms - grid.firstDownbeatMs) / beatMs)
        return grid.firstDownbeatMs + Math.round(k * beatMs).toInt()
    }

    data class Result(val events: List<StudioNoteEvent>, val bpm: Double)

    /**
     * Chord segments -> beat-quantized chord-comping events: full triad as same-onset events lasting beats*60000/bpm.
     * Two chords snapping to the SAME onset keep only the higher-confidence one (never a union of both triads).
     */
    fun events(chords: List<DemuxChordSegment>, grid: Grid): Result {
        val bpm = if (grid.bpm > 0) grid.bpm else 120.0
        val beatMs = 60_000.0 / bpm
        class Win(val chord: DemuxChordSegment, val offMs: Int)
        val winners = HashMap<Int, Win>()
        val order = ArrayList<Int>()
        for (chord in chords.sortedBy { it.startMs }) {
            val beats = beatsSpanned(chord.startMs, chord.endMs, grid)
            // Snapping can push a short chord's start PAST its own end; clamp so the onset never lands after it.
            val snapped = minOf(snapToBeat(chord.startMs, grid), chord.endMs)
            val onMs = maxOf(0, snapped - grid.firstDownbeatMs)
            val offMs = onMs + Math.round(beats * beatMs).toInt()
            val existing = winners[onMs]
            if (existing != null) {
                if (chord.confidence > existing.chord.confidence) winners[onMs] = Win(chord, offMs)
            } else {
                winners[onMs] = Win(chord, offMs)
                order.add(onMs)
            }
        }
        val out = ArrayList<StudioNoteEvent>()
        for (onMs in order) {
            val w = winners[onMs] ?: continue
            for (note in w.chord.midiNotes(60)) out.add(StudioNoteEvent(onMs, w.offMs, note, 88))
        }
        return Result(out, bpm)
    }

    /**
     * Melody notes -> a beat-quantized single-voice stream: ONE event per note (no triad), MONOPHONIC (on a same-onset
     * collision the LONGER note wins, ties -> the earlier note).
     */
    fun melodyEvents(notes: List<DemuxMelodyNote>, grid: Grid): Result {
        val bpm = if (grid.bpm > 0) grid.bpm else 120.0
        val beatMs = 60_000.0 / bpm
        val winners = HashMap<Int, StudioNoteEvent>()
        val order = ArrayList<Int>()
        for (note in notes.sortedBy { it.startMs }) {
            val beats = beatsSpanned(note.startMs, note.endMs, grid)
            val snapped = minOf(snapToBeat(note.startMs, grid), note.endMs)
            val onMs = maxOf(0, snapped - grid.firstDownbeatMs)
            val offMs = onMs + Math.round(beats * beatMs).toInt()
            val ev = StudioNoteEvent(onMs, offMs, note.midi, 90)
            val existing = winners[onMs]
            if (existing != null) {
                if ((offMs - onMs) > (existing.offMs - existing.onMs)) winners[onMs] = ev
            } else {
                winners[onMs] = ev
                order.add(onMs)
            }
        }
        return Result(order.mapNotNull { winners[it] }, bpm)
    }
}

/** What an instrumental is built from; [mode] is the value stored on the take's `demuxMode`. */
sealed class DemuxInstrumentalContent {
    abstract val mode: String
    abstract val elementCount: Int
    val isMelody: Boolean get() = this is Melody

    data class Comping(val chords: List<DemuxChordSegment>) : DemuxInstrumentalContent() {
        override val mode get() = "comping"
        override val elementCount get() = chords.size
    }
    data class Melody(val notes: List<DemuxMelodyNote>) : DemuxInstrumentalContent() {
        override val mode get() = "melody"
        override val elementCount get() = notes.size
    }

    fun build(grid: DemuxInstrumental.Grid): DemuxInstrumental.Result = when (this) {
        is Comping -> DemuxInstrumental.events(chords, grid)
        is Melody -> DemuxInstrumental.melodyEvents(notes, grid)
    }
}

/** Why a Takes-menu mode switch could not run, with the user-facing copy. */
enum class DemuxSwitchError(val message: String) {
    NO_SOURCE("This instrumental wasn’t made from a Demuxer source."),
    NO_DOC("The Demuxer data for this source is gone — open it in the Demuxer again."),
    NO_CHORDS("No chords were found for this source."),
    NO_MELODY("No melody could be tracked from this source."),
    NEED_STEMS("Melody needs this source’s stems on the device — download them in the Demuxer first."),
}

class DemuxSwitchException(val error: DemuxSwitchError) : Exception(error.message)

/**
 * Takes-menu comping <-> melody switch (iOS DemuxTakeSwitch): re-extract the OTHER mode from the take's demux source and
 * REPLACE its events in place. Environment seams are lambdas so the whole flow is JVM-testable.
 */
object DemuxTakeSwitch {
    fun targetMode(demuxMode: String?): String = if (demuxMode == "melody") "comping" else "melody"

    /** Menu label for the switch action. */
    fun menuLabel(demuxMode: String?): String =
        if (targetMode(demuxMode) == "melody") "Switch to melody" else "Switch to chord comping"

    /** The take's grid: a catalog song's sidecar lattice, else a steady 120-BPM grid at 0 (custom audio, no network). */
    suspend fun resolveGrid(key: String, sidecar: suspend (String) -> com.levi.pocketdj.data.burns.BeatGridSidecar?): DemuxInstrumental.Grid {
        if (!DemuxSource.isSongKey(key)) return DemuxInstrumental.Grid(120.0, 0, emptyList())
        val sc = sidecar(key)
        val bpm = sc?.beatGridBpm
        if (sc != null && bpm != null && bpm > 0) return DemuxInstrumental.Grid(bpm, sc.firstDownbeatMs ?: 0, sc.beatsMs)
        return DemuxInstrumental.Grid(120.0, 0, emptyList())
    }

    /**
     * Compute the replacement events for a switch. [trackMelody] runs the (slow) tracker over the melodic stem and
     * returns null when no stem is on the device; its result is handed back via [cacheMelody] so it runs once.
     */
    suspend fun switchEvents(
        sourceKey: String?, currentMode: String?,
        document: (String) -> DemuxDocument?,
        grid: suspend (String) -> DemuxInstrumental.Grid,
        trackMelody: suspend (String) -> List<DemuxMelodyNote>?,
        cacheMelody: (String, List<DemuxMelodyNote>) -> Unit,
    ): Pair<String, List<com.levi.pocketdj.studio.model.StudioNoteEvent>> {
        val key = sourceKey ?: throw DemuxSwitchException(DemuxSwitchError.NO_SOURCE)
        val doc = document(key) ?: throw DemuxSwitchException(DemuxSwitchError.NO_DOC)
        val target = targetMode(currentMode)
        val g = grid(key)
        val events = if (target == "comping") {
            if (doc.chords.isEmpty()) throw DemuxSwitchException(DemuxSwitchError.NO_CHORDS)
            DemuxInstrumental.events(doc.chords, g).events
        } else {
            val cached = doc.melodyNotes?.takeIf { it.isNotEmpty() }
            val notes = cached ?: run {
                val tracked = trackMelody(key) ?: throw DemuxSwitchException(DemuxSwitchError.NEED_STEMS)
                if (tracked.isEmpty()) throw DemuxSwitchException(DemuxSwitchError.NO_MELODY)
                cacheMelody(key, tracked)
                tracked
            }
            DemuxInstrumental.melodyEvents(notes, g).events
        }
        if (events.isEmpty()) throw DemuxSwitchException(if (target == "comping") DemuxSwitchError.NO_CHORDS else DemuxSwitchError.NO_MELODY)
        return target to events
    }
}

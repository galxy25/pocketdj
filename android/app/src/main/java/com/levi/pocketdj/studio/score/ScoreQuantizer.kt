package com.levi.pocketdj.studio.score

import com.levi.pocketdj.studio.model.Accidental
import com.levi.pocketdj.studio.model.InstrumentKey
import com.levi.pocketdj.studio.model.StudioNoteEvent
import kotlin.math.floor
import kotlin.math.max
import kotlin.math.min

/**
 * Score model + quantizer (iOS `ScoreModel.swift`, spec 7). Pure value types and object functions: the quantizer turns a take's
 * RAW note events into a [ScoreDocument] at render time; quantization is never persisted. Anchor: 0 ms = beat 1 = end of the
 * count-in, shared with the recorder and the MIDI writer. Single voice in 4/4: ONE item sounds at a time (same-onset notes are a
 * chord), rests fill every gap, each measure sums to exactly 16 sixteenths, and there are no ties (a duration that would cross a
 * barline or the next onset is truncated; the raw events keep the true lengths).
 */

/** Swift `.rounded()` (half away from zero) so negatives match iOS. */
internal fun roundHalfAway(d: Double): Double = if (d < 0) -floor(-d + 0.5) else floor(d + 0.5)

/** The only rhythmic values the quantizer emits; [sixteenths] IS the length in 16th-note units. */
enum class NoteDuration(val sixteenths: Int) {
    SIXTEENTH(1), EIGHTH(2), DOTTED_EIGHTH(3), QUARTER(4), DOTTED_QUARTER(6), HALF(8), DOTTED_HALF(12), WHOLE(16);

    val isDotted: Boolean get() = this == DOTTED_EIGHTH || this == DOTTED_QUARTER || this == DOTTED_HALF

    /** The plain value under a dotted one (head/flag shape). */
    val base: NoteDuration
        get() = when (this) {
            DOTTED_EIGHTH -> EIGHTH
            DOTTED_QUARTER -> QUARTER
            DOTTED_HALF -> HALF
            else -> this
        }

    /** Quarter and shorter are filled; half/whole open (decided on the BASE value). */
    val filledHead: Boolean get() = base.sixteenths <= QUARTER.sixteenths
    val flags: Int get() = when (base) { SIXTEENTH -> 2; EIGHTH -> 1; else -> 0 }
    val hasStem: Boolean get() = this != WHOLE

    companion object {
        private val ascending = entries.sortedBy { it.sixteenths }
        val descending: List<NoteDuration> = entries.sortedByDescending { it.sixteenths }

        /** Nearest allowed value; ties round DOWN (never inflate a note). <=0 clamps to a 16th, >=16 caps at a whole. */
        fun snapped(toSixteenths: Int): NoteDuration {
            val n = toSixteenths
            if (n <= 0) return SIXTEENTH
            if (n >= WHOLE.sixteenths) return WHOLE
            var best = SIXTEENTH
            var bestDist = Int.MAX_VALUE
            for (d in ascending) {
                val dist = kotlin.math.abs(d.sixteenths - n)
                if (dist < bestDist) { best = d; bestDist = dist }   // strict < keeps the shortest on a tie
            }
            return best
        }

        /** Largest allowed value that FITS in [n] sixteenths (min a 16th). */
        fun snappedDown(toSixteenths: Int): NoteDuration = descending.firstOrNull { it.sixteenths <= max(1, toSixteenths) } ?: SIXTEENTH

        /** Greedy longest-first decomposition of a gap (1..16) into allowed values (exact for this vocabulary). */
        fun fill(gapSixteenths: Int): List<NoteDuration> {
            var remaining = gapSixteenths
            val out = ArrayList<NoteDuration>()
            while (remaining > 0) {
                val d = snappedDown(remaining)
                out.add(d)
                remaining -= d.sixteenths
            }
            return out
        }
    }
}

/** A chord (1+ simultaneous sorted, de-duplicated MIDI notes) or a rest. */
sealed interface ScoreKind {
    data class Notes(val notes: List<Int>) : ScoreKind
    data object Rest : ScoreKind
}

/** One slot in the single-voice stream. [onset16ths] is measure-RELATIVE (0..15). */
data class ScoreItem(
    val onset16ths: Int,
    val kind: ScoreKind,
    val duration: NoteDuration,
    /** Per-note spelling overrides (MIDI -> accidental); empty => derive. */
    val spellings: Map<Int, Accidental> = emptyMap(),
)

data class ScoreMeasure(val index: Int, val items: List<ScoreItem>)

enum class StaffRole { TREBLE, BASS }

/** The staff configuration for an instrument. Changing a mapping re-typesets every saved take: never "fix" it. */
enum class ClefPlan {
    GRAND_STAFF, TREBLE, BASS;

    /** Grand staff splits at middle C with note 60 => treble; single-staff plans put every note on their one staff. */
    fun staff(forNote: Int): StaffRole = when (this) {
        TREBLE -> StaffRole.TREBLE
        BASS -> StaffRole.BASS
        GRAND_STAFF -> if (forNote >= 60) StaffRole.TREBLE else StaffRole.BASS
    }

    /** The staves this plan draws, top-first. */
    val staves: List<StaffRole>
        get() = when (this) {
            GRAND_STAFF -> listOf(StaffRole.TREBLE, StaffRole.BASS)
            TREBLE -> listOf(StaffRole.TREBLE)
            BASS -> listOf(StaffRole.BASS)
        }

    companion object {
        fun plan(instrument: InstrumentKey): ClefPlan = when (instrument) {
            InstrumentKey.PIANO, InstrumentKey.HARP -> GRAND_STAFF
            InstrumentKey.BASS_GUITAR -> BASS
            InstrumentKey.VIOLIN, InstrumentKey.TRUMPET, InstrumentKey.CLARINET, InstrumentKey.ACOUSTIC_GUITAR -> TREBLE
        }
    }
}

data class ScoreDocument(val measures: List<ScoreMeasure>, val bpm: Double, val clefPlan: ClefPlan)

object ScoreQuantizer {
    /** One 16th in ms at [bpm] (60000/bpm/4); a non-positive bpm guards to 120. */
    fun sixteenthMs(bpm: Double): Double = 15_000.0 / (if (bpm > 0) bpm else 120.0)

    data class FlatItem(val onset: Int, val kind: ScoreKind, val duration: NoteDuration)

    /**
     * Quantize raw events: (1) onsets round to the nearest 16th, early hits clamp to 0; (2) lengths snap to the vocabulary;
     * (3) same-onset events merge into one chord (duration = longest member); (4) truncate at the next onset and barline,
     * snapping DOWN; (5) rests fill every gap, split at barlines. Out-of-range notes are dropped. [minMeasures] pads trailing
     * empty bars for the editor (default 0 keeps exports content-only).
     */
    fun quantize(events: List<StudioNoteEvent>, bpm: Double, instrument: InstrumentKey, minMeasures: Int = 0): ScoreDocument {
        val tempo = if (bpm > 0) bpm else 120.0
        val plan = ClefPlan.plan(instrument)
        val step = sixteenthMs(tempo)

        val chordNotes = HashMap<Int, MutableSet<Int>>()
        val chordDur = HashMap<Int, Int>()
        val chordSpellings = HashMap<Int, MutableMap<Int, Accidental>>()
        for (e in events) {
            if (e.note !in 0..127) continue
            val on16 = max(0, roundHalfAway(e.onMs / step).toInt())
            val raw16 = max(1, roundHalfAway((e.offMs - e.onMs) / step).toInt())
            val snapped = NoteDuration.snapped(raw16).sixteenths
            chordNotes.getOrPut(on16) { HashSet() }.add(e.note)
            chordDur[on16] = max(chordDur[on16] ?: 0, snapped)
            e.accidental?.let { chordSpellings.getOrPut(on16) { HashMap() }[e.note] = it }
        }
        if (chordNotes.isEmpty() && minMeasures <= 0) return ScoreDocument(emptyList(), tempo, plan)

        val onsets = chordNotes.keys.sorted()
        val flat = ArrayList<FlatItem>()
        var cursor = 0
        for ((i, on) in onsets.withIndex()) {
            flat += restItems(cursor, on)
            val next = if (i + 1 < onsets.size) onsets[i + 1] else Int.MAX_VALUE
            val headroom = min(min(chordDur[on]!!, next - on), 16 - on % 16)
            val d = NoteDuration.snappedDown(headroom)
            flat.add(FlatItem(on, ScoreKind.Notes(chordNotes[on]!!.sorted()), d))
            cursor = on + d.sixteenths
        }
        val end = max(((cursor + 15) / 16) * 16, max(0, minMeasures) * 16)
        flat += restItems(cursor, end)

        val buckets = Array(end / 16) { ArrayList<ScoreItem>() }
        for (f in flat) buckets[f.onset / 16].add(ScoreItem(f.onset % 16, f.kind, f.duration, chordSpellings[f.onset]?.toMap() ?: emptyMap()))
        return ScoreDocument(buckets.mapIndexed { i, items -> ScoreMeasure(i, items) }, tempo, plan)
    }

    /** Rest items covering [from, to) in absolute 16ths: split at every barline, then greedily decomposed. */
    fun restItems(from: Int, to: Int): List<FlatItem> {
        val out = ArrayList<FlatItem>()
        var cur = from
        while (cur < to) {
            val measureEnd = min(to, (cur / 16 + 1) * 16)
            for (d in NoteDuration.fill(measureEnd - cur)) {
                out.add(FlatItem(cur, ScoreKind.Rest, d))
                cur += d.sixteenths
            }
        }
        return out
    }
}

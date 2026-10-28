package com.levi.pocketdj.studio.model

import com.levi.pocketdj.data.PdjJson
import kotlinx.serialization.json.JsonArray
import kotlinx.serialization.json.JsonElement
import kotlinx.serialization.json.JsonObject
import kotlinx.serialization.json.JsonPrimitive

/*
 * Studio schema — samples, loops, patterns, takes, cues, slices, arrangements (versioned, lenient).
 * Port of iOS Studio/StudioModels.swift. KEY-COMPATIBLE with `pocketdj-studio.json`:
 *   - schemaVersion = 1 and NEVER bumped; every new field is additive-optional;
 *   - EVERY field decodes leniently (absent / null / wrong type -> default), and every list decodes
 *     per-element lossily — one malformed element drops only itself, at any depth (document ->
 *     samples, pattern -> rows, take -> extraStaffs -> events), never the list or the document.
 */

const val STUDIO_SCHEMA_VERSION = 1
const val STUDIO_CUE_SCHEMA_VERSION = 1

// ---------------------------------------------------------------------------------------------
// Beat grid
// ---------------------------------------------------------------------------------------------

/**
 * A sample's beat grid, in ms from the SAMPLE's 0:00. `beatsMs` empty => a CONSTANT grid
 * synthesized from [bpm] + [firstDownbeatMs]. bpm defaults to 120 (never 0: loop-length math
 * divides by it).
 */
data class StudioGrid(
    val bpm: Double,
    val firstDownbeatMs: Int = 0,
    val beatsMs: List<Int> = emptyList(),
) {
    fun toJson(): JsonObject = jsonObj(
        "bpm" to jsonNum(bpm), "firstDownbeatMs" to JsonPrimitive(firstDownbeatMs), "beatsMs" to jsonInts(beatsMs),
    )

    companion object {
        fun fromJson(el: JsonElement?): StudioGrid? {
            val o = el as? JsonObject ?: return null
            return StudioGrid(o.double("bpm") ?: 120.0, o.int("firstDownbeatMs") ?: 0, o.intList("beatsMs") ?: emptyList())
        }
    }
}

// ---------------------------------------------------------------------------------------------
// Sample edit
// ---------------------------------------------------------------------------------------------

/**
 * Non-destructive edit state. Plain value equality is the edit-revision contract:
 * `StudioStore.updateSampleEdit` bumps `renderRevision` exactly when the clamped value changed.
 * `trimEndMs == 0` means "to the end of the file".
 */
data class StudioSampleEdit(
    val trimStartMs: Int = 0,
    val trimEndMs: Int = 0,
    val gainDb: Double = 0.0,
    val rate: Double = 1.0,
    val pitchSemitones: Double = 0.0,
    val reverbWet: Double = 0.0,
    val delayWet: Double = 0.0,
    val compWet: Double = 0.0,
    val filterAmt: Double = 0.0,
) {
    val isNeutral: Boolean get() = this == NEUTRAL

    /** Pure range clamp; the store applies it on every write. */
    fun clamped(): StudioSampleEdit {
        val s = maxOf(0, trimStartMs)
        var e = maxOf(0, trimEndMs)
        if (e > 0 && e < s) e = s
        return copy(
            trimStartMs = s, trimEndMs = e,
            gainDb = gainDb.coerceIn(-60.0, 12.0), rate = rate.coerceIn(0.5, 10.0),
            pitchSemitones = pitchSemitones.coerceIn(-12.0, 12.0),
            reverbWet = reverbWet.coerceIn(0.0, 1.0), delayWet = delayWet.coerceIn(0.0, 1.0),
            compWet = compWet.coerceIn(0.0, 1.0), filterAmt = filterAmt.coerceIn(0.0, 1.0),
        )
    }

    fun toJson(): JsonObject = jsonObj(
        "trimStartMs" to JsonPrimitive(trimStartMs), "trimEndMs" to JsonPrimitive(trimEndMs),
        "gainDb" to jsonNum(gainDb), "rate" to jsonNum(rate), "pitchSemitones" to jsonNum(pitchSemitones),
        "reverbWet" to jsonNum(reverbWet), "delayWet" to jsonNum(delayWet),
        "compWet" to jsonNum(compWet), "filterAmt" to jsonNum(filterAmt),
    )

    companion object {
        val NEUTRAL = StudioSampleEdit()

        fun fromJson(el: JsonElement?): StudioSampleEdit? {
            val o = el as? JsonObject ?: return null
            return StudioSampleEdit(
                o.int("trimStartMs") ?: 0, o.int("trimEndMs") ?: 0, o.double("gainDb") ?: 0.0,
                o.double("rate") ?: 1.0, o.double("pitchSemitones") ?: 0.0,
                o.double("reverbWet") ?: 0.0, o.double("delayWet") ?: 0.0,
                o.double("compWet") ?: 0.0, o.double("filterAmt") ?: 0.0,
            )
        }
    }
}

// ---------------------------------------------------------------------------------------------
// Sample
// ---------------------------------------------------------------------------------------------

/**
 * A recorded/carved audio sample. The RAW file (`sample-<id>.m4a`) is immutable after capture;
 * edits are metadata on top, baked only into derived artifacts (loops, pattern row buffers) and
 * the render cache (`renderedFileName`, fresh iff `renderedRevision == renderRevision`).
 */
data class StudioSample(
    val id: String,
    val name: String,
    val fileName: String,
    /** true => written to the user-picked (SAF) samples root; false => app-managed root. */
    val wasUserFolder: Boolean = false,
    val createdAt: Double = 0.0,
    val durationMs: Int = 0,
    val source: StudioSource = StudioSource.Mic,
    val grid: StudioGrid? = null,
    val edit: StudioSampleEdit = StudioSampleEdit.NEUTRAL,
    val renderRevision: Int = 0,
    val renderedFileName: String? = null,
    val renderedRevision: Int? = null,
    val renderedWasUserFolder: Boolean? = null,
    val folderId: String? = null,
) {
    val isRenderFresh: Boolean get() = renderedFileName != null && renderedRevision == renderRevision

    /** Length (ms) the sample PLAYS at with its edit applied: trim window over rate. */
    val effectiveDurationMs: Int
        get() {
            val end = if (edit.trimEndMs > 0) minOf(edit.trimEndMs, durationMs) else durationMs
            val window = maxOf(0, end - maxOf(0, edit.trimStartMs))
            val r = if (edit.rate > 0) edit.rate else 1.0
            return Math.round(window.toDouble() / r).toInt()
        }

    fun toJson(): JsonObject = jsonObj(
        "id" to JsonPrimitive(id), "name" to JsonPrimitive(name), "fileName" to JsonPrimitive(fileName),
        "wasUserFolder" to JsonPrimitive(wasUserFolder), "createdAt" to jsonNum(createdAt),
        "durationMs" to JsonPrimitive(durationMs), "source" to StudioSourceSerializer.encode(source),
        "grid" to grid?.toJson(), "edit" to edit.toJson(), "renderRevision" to JsonPrimitive(renderRevision),
        "renderedFileName" to jsonStr(renderedFileName), "renderedRevision" to renderedRevision?.let { JsonPrimitive(it) },
        "renderedWasUserFolder" to renderedWasUserFolder?.let { JsonPrimitive(it) },
        "folderId" to jsonStr(folderId),
    )

    companion object {
        fun fromJson(o: JsonObject) = StudioSample(
            id = o.str("id") ?: StudioFactory.newSampleId(),
            name = o.str("name") ?: "",
            fileName = o.str("fileName") ?: "",
            wasUserFolder = o.bool("wasUserFolder") ?: false,
            createdAt = o.double("createdAt") ?: 0.0,
            durationMs = o.int("durationMs") ?: 0,
            source = StudioSourceSerializer.decode(o["source"]),
            grid = StudioGrid.fromJson(o["grid"]),
            edit = StudioSampleEdit.fromJson(o["edit"]) ?: StudioSampleEdit.NEUTRAL,
            renderRevision = o.int("renderRevision") ?: 0,
            renderedFileName = o.str("renderedFileName"),
            renderedRevision = o.int("renderedRevision"),
            renderedWasUserFolder = o.bool("renderedWasUserFolder"),
            folderId = o.str("folderId"),
        )
    }
}

// ---------------------------------------------------------------------------------------------
// Folders (sample / loop / pattern / take / arrangement)
// ---------------------------------------------------------------------------------------------

/**
 * A flat, named organizational folder. iOS has five identical structs
 * (`StudioSampleFolder`/`LoopFolder`/`PatternFolder`/`TakeFolder`/`ArrangementFolder`); on Android
 * ONE class serves all five lists — the JSON is identical and the id namespace
 * (`sfld_`/`lpfld_`/`ptnfld_`/`tkfld_`/`arrfld_`) is minted by the store per family.
 */
data class StudioFolder(
    val id: String,
    val name: String,
    val createdAt: Double = 0.0,
    val updatedAt: Double = 0.0,
) {
    fun toJson(): JsonObject = jsonObj(
        "id" to JsonPrimitive(id), "name" to JsonPrimitive(name),
        "createdAt" to jsonNum(createdAt), "updatedAt" to jsonNum(updatedAt),
    )

    companion object {
        fun decoder(newId: () -> String): (JsonObject) -> StudioFolder = { o ->
            StudioFolder(o.str("id") ?: newId(), o.str("name") ?: "", o.double("createdAt") ?: 0.0, o.double("updatedAt") ?: 0.0)
        }
    }
}

// ---------------------------------------------------------------------------------------------
// Loop
// ---------------------------------------------------------------------------------------------

/** Beat-window sizes a loop can be sliced at. The value IS the beat count. */
enum class LoopBeats(val beatCount: Double) {
    HALF(0.5), ONE(1.0), TWO(2.0), FOUR(4.0), EIGHT(8.0), SIXTEEN(16.0), THIRTY_TWO(32.0);

    val label: String get() = if (this == HALF) "½" else beatCount.toInt().toString()

    companion object {
        /** Unknown persisted value => [FOUR] (lenient). */
        fun fromBeatCount(d: Double?): LoopBeats = entries.firstOrNull { it.beatCount == d } ?: FOUR
    }
}

/**
 * A beat-grid-synced slice of a sample, RENDERED at save time to LPCM (`loop-<id>.wav` on Android;
 * iOS uses `.caf` — documented divergence, the studio doc is device-local) with the sample's edits
 * baked. SELF-CONTAINED after render: deleting the parent sample leaves it playable.
 */
data class StudioLoop(
    val id: String,
    val name: String,
    val sampleId: String,
    val anchorMs: Int = 0,
    val beats: LoopBeats = LoopBeats.FOUR,
    val bpm: Double = 120.0,
    val lengthMs: Int = 0,
    /** AUTHORITATIVE rendered length in frames (ms-derived counts tick at the seam). */
    val frames: Long = 0,
    val fileName: String,
    val wasUserFolder: Boolean = false,
    val createdAt: Double = 0.0,
    val folderId: String? = null,
) {
    fun toJson(): JsonObject = jsonObj(
        "id" to JsonPrimitive(id), "name" to JsonPrimitive(name), "sampleId" to JsonPrimitive(sampleId),
        "anchorMs" to JsonPrimitive(anchorMs), "beats" to jsonNum(beats.beatCount), "bpm" to jsonNum(bpm),
        "lengthMs" to JsonPrimitive(lengthMs), "frames" to JsonPrimitive(frames),
        "fileName" to JsonPrimitive(fileName), "wasUserFolder" to JsonPrimitive(wasUserFolder),
        "createdAt" to jsonNum(createdAt), "folderId" to jsonStr(folderId),
    )

    companion object {
        fun fromJson(o: JsonObject) = StudioLoop(
            id = o.str("id") ?: StudioFactory.newLoopId(),
            name = o.str("name") ?: "",
            sampleId = o.str("sampleId") ?: "",
            anchorMs = o.int("anchorMs") ?: 0,
            beats = LoopBeats.fromBeatCount(o.double("beats")),
            bpm = o.double("bpm") ?: 120.0,
            lengthMs = o.int("lengthMs") ?: 0,
            frames = o.long("frames") ?: 0L,
            fileName = o.str("fileName") ?: "",
            wasUserFolder = o.bool("wasUserFolder") ?: false,
            createdAt = o.double("createdAt") ?: 0.0,
            folderId = o.str("folderId"),
        )
    }
}

// ---------------------------------------------------------------------------------------------
// Pattern (sequencer)
// ---------------------------------------------------------------------------------------------

/**
 * One sequencer row: a target (`smp_`/`lp_`) + its step toggles + a row gain. A row whose target
 * was deleted stays as a muted "missing" row. Construction through [of]/[fromJson] normalizes to
 * `max(raw.count, 16)` steps and NEVER truncates a long (SEQ4) row; the owning [StudioPattern]
 * then [resized]s every row to its own stepCount.
 */
data class StudioPatternRow(
    val targetId: String,
    val steps: List<Boolean>,
    val gainDb: Double = 0.0,
    /** Per-step trigger mode: true = LOOP, false = one-shot. */
    val loopSteps: List<Boolean>,
    /** Per-step stretch span: 0 = natural, n >= 1 = tempo-fit to EXACTLY n steps. */
    val stepSpans: List<Int>,
    val label: String? = null,
) {
    /** A row with no sounding step. */
    val isSilent: Boolean get() = !steps.contains(true)

    fun resized(count: Int): StudioPatternRow = copy(
        steps = normalized(steps, count), loopSteps = normalized(loopSteps, count),
        stepSpans = normalizedSpans(stepSpans, count),
    )

    fun toJson(): JsonObject = jsonObj(
        "targetId" to JsonPrimitive(targetId), "steps" to jsonBools(steps), "gainDb" to jsonNum(gainDb),
        "loopSteps" to jsonBools(loopSteps), "stepSpans" to jsonInts(stepSpans), "label" to jsonStr(label),
    )

    companion object {
        /** Mirror of the iOS memberwise init: length-preserving (>= 16), default row = 16 steps. */
        fun of(
            targetId: String,
            steps: List<Boolean> = List(StudioPattern.DEFAULT_STEP_COUNT) { false },
            gainDb: Double = 0.0,
            loopSteps: List<Boolean> = List(StudioPattern.DEFAULT_STEP_COUNT) { false },
            stepSpans: List<Int> = List(StudioPattern.DEFAULT_STEP_COUNT) { 0 },
            label: String? = null,
        ): StudioPatternRow {
            val n = maxOf(steps.size, StudioPattern.DEFAULT_STEP_COUNT)
            return StudioPatternRow(targetId, normalized(steps, n), gainDb, normalized(loopSteps, n), normalizedSpans(stepSpans, n), label)
        }

        fun fromJson(o: JsonObject): StudioPatternRow {
            val raw = o.boolList("steps") ?: emptyList()
            // Pad short/legacy arrays to 16 but PRESERVE longer ones: truncating here would
            // silently lose steps 16+ of a long SEQ4 pattern on load.
            val n = maxOf(raw.size, StudioPattern.DEFAULT_STEP_COUNT)
            return StudioPatternRow(
                targetId = o.str("targetId") ?: "",
                steps = normalized(raw, n),
                gainDb = o.double("gainDb") ?: 0.0,
                loopSteps = normalized(o.boolList("loopSteps") ?: emptyList(), n),
                stepSpans = normalizedSpans(o.intList("stepSpans") ?: emptyList(), n),
                label = o.str("label"),
            )
        }

        /** Pad/truncate a bool array to exactly [count]. */
        fun normalized(steps: List<Boolean>, count: Int = StudioPattern.DEFAULT_STEP_COUNT): List<Boolean> {
            val s = steps.take(count)
            return if (s.size < count) s + List(count - s.size) { false } else s
        }

        /** [normalized] for spans, also clamping each span to 0...count. */
        fun normalizedSpans(spans: List<Int>, count: Int = StudioPattern.DEFAULT_STEP_COUNT): List<Int> {
            val s = spans.take(count).map { it.coerceIn(0, count) }
            return if (s.size < count) s + List(count - s.size) { 0 } else s
        }
    }
}

/**
 * A sequencer pattern: [stepCount] sixteenths (16 = one bar of 4/4) over sample/loop rows. Bounced
 * to `pattern-<id>.m4a` on demand; ANY edit re-marks [bounceDirty].
 */
data class StudioPattern(
    val id: String,
    val name: String,
    val bpm: Double = 120.0,
    val stepCount: Int = DEFAULT_STEP_COUNT,
    val rows: List<StudioPatternRow> = emptyList(),
    val fileName: String? = null,
    val bounceDirty: Boolean = true,
    val wasUserFolder: Boolean = false,
    val createdAt: Double = 0.0,
    val folderId: String? = null,
) {
    val hasSoundingSteps: Boolean get() = rows.any { !it.isSilent }

    /** Full loop length in ms: [stepCount] sixteenths at [bpm]. */
    val lengthMs: Int get() = barMs(bpm) * stepCount / DEFAULT_STEP_COUNT

    /** Re-clamp [stepCount] and size every row to it (the iOS init invariant). */
    fun normalized(): StudioPattern {
        val n = clampStepCount(stepCount)
        return copy(stepCount = n, rows = rows.map { it.resized(n) })
    }

    fun toJson(): JsonObject = jsonObj(
        "id" to JsonPrimitive(id), "name" to JsonPrimitive(name), "bpm" to jsonNum(bpm),
        "stepCount" to JsonPrimitive(stepCount), "rows" to JsonArray(rows.map { it.toJson() }),
        "fileName" to jsonStr(fileName), "bounceDirty" to JsonPrimitive(bounceDirty),
        "wasUserFolder" to JsonPrimitive(wasUserFolder), "createdAt" to jsonNum(createdAt),
        "folderId" to jsonStr(folderId),
    )

    companion object {
        const val DEFAULT_STEP_COUNT = 16

        /** 512 bars of 16ths — a whole song's drum pattern sent from the Demuxer. */
        const val MAX_STEP_COUNT = 512 * 16

        /** One bar's length (ms) at [bpm]; guards a 0 bpm document with 120. */
        fun barMs(bpm: Double): Int {
            val b = if (bpm > 0) bpm else 120.0
            return Math.round(240_000.0 / b).toInt()
        }

        fun clampStepCount(n: Int): Int = n.coerceIn(1, MAX_STEP_COUNT)

        /** Mirror of the iOS memberwise init (clamps + resizes rows). */
        fun of(
            id: String, name: String, bpm: Double = 120.0, stepCount: Int = DEFAULT_STEP_COUNT,
            rows: List<StudioPatternRow> = emptyList(), fileName: String? = null, bounceDirty: Boolean = true,
            wasUserFolder: Boolean = false, createdAt: Double = 0.0, folderId: String? = null,
        ) = StudioPattern(id, name, bpm, stepCount, rows, fileName, bounceDirty, wasUserFolder, createdAt, folderId).normalized()

        fun fromJson(o: JsonObject): StudioPattern {
            val sc = clampStepCount(o.int("stepCount") ?: DEFAULT_STEP_COUNT)
            return StudioPattern(
                id = o.str("id") ?: StudioFactory.newPatternId(),
                name = o.str("name") ?: "",
                bpm = o.double("bpm") ?: 120.0,
                stepCount = sc,
                rows = (o.lossyList("rows") { StudioPatternRow.fromJson(it) } ?: emptyList()).map { it.resized(sc) },
                fileName = o.str("fileName"),
                bounceDirty = o.bool("bounceDirty") ?: true,
                wasUserFolder = o.bool("wasUserFolder") ?: false,
                createdAt = o.double("createdAt") ?: 0.0,
                folderId = o.str("folderId"),
            )
        }
    }
}

// ---------------------------------------------------------------------------------------------
// Instruments + takes
// ---------------------------------------------------------------------------------------------

/** The seven v1 instruments. The raw string persists in takes; GM programs are locked. */
enum class InstrumentKey(val raw: String, val gmProgram: Int, val displayName: String) {
    PIANO("piano", 0, "Piano"),
    VIOLIN("violin", 40, "Violin"),
    BASS_GUITAR("bassGuitar", 33, "Bass Guitar"),
    ACOUSTIC_GUITAR("acousticGuitar", 25, "Acoustic Guitar"),
    TRUMPET("trumpet", 56, "Trumpet"),
    CLARINET("clarinet", 71, "Clarinet"),
    HARP("harp", 46, "Harp");

    companion object {
        fun fromRaw(s: String?): InstrumentKey? = entries.firstOrNull { it.raw == s }
    }
}

/** How a note is spelled on the staff; absent => derived. Display-only. */
enum class Accidental(val raw: String) {
    NATURAL("natural"), SHARP("sharp"), FLAT("flat");

    companion object {
        fun fromRaw(s: String?): Accidental? = entries.firstOrNull { it.raw == s }
    }
}

/** One played note; times are ms from BEAT 1 (end of the count-in). */
data class StudioNoteEvent(
    val onMs: Int,
    val offMs: Int,
    val note: Int,
    val velocity: Int,
    val accidental: Accidental? = null,
) {
    fun toJson(): JsonObject = jsonObj(
        "onMs" to JsonPrimitive(onMs), "offMs" to JsonPrimitive(offMs), "note" to JsonPrimitive(note),
        "velocity" to JsonPrimitive(velocity), "accidental" to jsonStr(accidental?.raw),
    )

    companion object {
        fun fromJson(o: JsonObject) = StudioNoteEvent(
            o.int("onMs") ?: 0, o.int("offMs") ?: 0, o.int("note") ?: 0, o.int("velocity") ?: 0,
            Accidental.fromRaw(o.str("accidental")),
        )
    }
}

private fun events(o: JsonObject, key: String): List<StudioNoteEvent>? = o.lossyList(key) { StudioNoteEvent.fromJson(it) }
private fun eventsJson(xs: List<StudioNoteEvent>) = JsonArray(xs.map { it.toJson() })

/** One OVERDUB staff (staffs 2..4 of an instrumental). Events are ABSOLUTE on the take's clock. */
data class StudioTakeStaff(
    val id: String,
    val instrument: InstrumentKey = InstrumentKey.PIANO,
    val events: List<StudioNoteEvent> = emptyList(),
    val editedEvents: List<StudioNoteEvent>? = null,
    val createdAt: Double = 0.0,
) {
    /** Edited stream once touched, else raw. */
    val scoreEvents: List<StudioNoteEvent> get() = editedEvents ?: events

    fun toJson(): JsonObject = jsonObj(
        "id" to JsonPrimitive(id), "instrument" to JsonPrimitive(instrument.raw),
        "events" to eventsJson(events), "editedEvents" to editedEvents?.let { eventsJson(it) },
        "createdAt" to jsonNum(createdAt),
    )

    companion object {
        fun fromJson(o: JsonObject) = StudioTakeStaff(
            id = o.str("id") ?: StudioFactory.newStaffId(),
            instrument = InstrumentKey.fromRaw(o.str("instrument")) ?: InstrumentKey.PIANO,
            events = events(o, "events") ?: emptyList(),
            editedEvents = events(o, "editedEvents"),
            createdAt = o.double("createdAt") ?: 0.0,
        )
    }
}

/**
 * A recorded instrument performance ("instrumental"): captured audio (`take-<id>.m4a`) plus the
 * raw note-event log the score is quantized from. The rendered-audio cache is fresh iff
 * `(renderedRevision ?: 0) == renderRevision`.
 */
data class StudioTake(
    val id: String,
    val name: String,
    val instrument: InstrumentKey = InstrumentKey.PIANO,
    val fileName: String,
    val wasUserFolder: Boolean = false,
    val bpm: Double = 120.0,
    val events: List<StudioNoteEvent> = emptyList(),
    val durationMs: Int = 0,
    val createdAt: Double = 0.0,
    val editedEvents: List<StudioNoteEvent>? = null,
    val renderedFileName: String? = null,
    val renderedWasUserFolder: Boolean? = null,
    val renderRevision: Int = 0,
    val renderedRevision: Int? = null,
    val demuxSourceKey: String? = null,
    val demuxMode: String? = null,
    val folderId: String? = null,
    val extraStaffs: List<StudioTakeStaff>? = null,
) {
    val scoreEvents: List<StudioNoteEvent> get() = editedEvents ?: events

    /** EVERY staff's score events on the one score clock, onset-sorted. */
    val allScoreEvents: List<StudioNoteEvent>
        get() {
            val extras = extraStaffs
            if (extras.isNullOrEmpty()) return scoreEvents
            return (scoreEvents + extras.flatMap { it.scoreEvents }).sortedBy { it.onMs }
        }

    /** A pre-stamp cache has no renderedRevision and reads as revision 0. */
    val isRenderFresh: Boolean get() = renderedFileName != null && (renderedRevision ?: 0) == renderRevision

    /** Staff count including the primary. */
    val staffCount: Int get() = 1 + (extraStaffs?.size ?: 0)

    fun toJson(): JsonObject = jsonObj(
        "id" to JsonPrimitive(id), "name" to JsonPrimitive(name), "instrument" to JsonPrimitive(instrument.raw),
        "fileName" to JsonPrimitive(fileName), "wasUserFolder" to JsonPrimitive(wasUserFolder),
        "bpm" to jsonNum(bpm), "events" to eventsJson(events), "durationMs" to JsonPrimitive(durationMs),
        "createdAt" to jsonNum(createdAt), "editedEvents" to editedEvents?.let { eventsJson(it) },
        "renderedFileName" to jsonStr(renderedFileName),
        "renderedWasUserFolder" to renderedWasUserFolder?.let { JsonPrimitive(it) },
        "renderRevision" to JsonPrimitive(renderRevision),
        "renderedRevision" to renderedRevision?.let { JsonPrimitive(it) },
        "demuxSourceKey" to jsonStr(demuxSourceKey), "demuxMode" to jsonStr(demuxMode),
        "folderId" to jsonStr(folderId), "extraStaffs" to extraStaffs?.let { xs -> JsonArray(xs.map { it.toJson() }) },
    )

    companion object {
        /** 1 primary + <= 3 overdub staffs — STORE-enforced. */
        const val MAX_STAFFS = 4

        fun fromJson(o: JsonObject) = StudioTake(
            id = o.str("id") ?: StudioFactory.newTakeId(),
            name = o.str("name") ?: "",
            instrument = InstrumentKey.fromRaw(o.str("instrument")) ?: InstrumentKey.PIANO,
            fileName = o.str("fileName") ?: "",
            wasUserFolder = o.bool("wasUserFolder") ?: false,
            bpm = o.double("bpm") ?: 120.0,
            events = events(o, "events") ?: emptyList(),
            durationMs = o.int("durationMs") ?: 0,
            createdAt = o.double("createdAt") ?: 0.0,
            editedEvents = events(o, "editedEvents"),
            renderedFileName = o.str("renderedFileName"),
            renderedWasUserFolder = o.bool("renderedWasUserFolder"),
            renderRevision = o.int("renderRevision") ?: 0,
            renderedRevision = o.int("renderedRevision"),
            demuxSourceKey = o.str("demuxSourceKey"),
            demuxMode = o.str("demuxMode"),
            folderId = o.str("folderId"),
            extraStaffs = o.lossyList("extraStaffs") { StudioTakeStaff.fromJson(it) },
        )
    }
}

// ---------------------------------------------------------------------------------------------
// Cues + slices
// ---------------------------------------------------------------------------------------------

/** One cue point on an indexed track; <= [MAX_SLOTS] per song, store-enforced. */
data class StudioCue(
    val id: String,
    val songId: String,
    val slot: Int,
    val positionMs: Int,
    val name: String? = null,
) {
    fun toJson(): JsonObject = jsonObj(
        "id" to JsonPrimitive(id), "songId" to JsonPrimitive(songId), "slot" to JsonPrimitive(slot),
        "positionMs" to JsonPrimitive(positionMs), "name" to jsonStr(name),
    )

    companion object {
        const val MAX_SLOTS = 8

        fun fromJson(o: JsonObject) = StudioCue(
            o.str("id") ?: StudioFactory.newCueId(), o.str("songId") ?: "", o.int("slot") ?: 0,
            o.int("positionMs") ?: 0, o.str("name"),
        )
    }
}

/**
 * The cross-device cue mirror (`pocketdj-studio.cues.json`): JUST cue points, media-free, the ONLY
 * Studio data that ever leaves the device. Whole-document LWW; per-element lossy decode.
 */
data class StudioCueDoc(
    val schemaVersion: Int = STUDIO_CUE_SCHEMA_VERSION,
    val cues: List<StudioCue> = emptyList(),
) {
    fun toJson(): JsonObject = jsonObj(
        "schemaVersion" to JsonPrimitive(schemaVersion), "cues" to JsonArray(cues.map { it.toJson() }),
    )

    fun encode(): String = PdjJson.lenient.encodeToString(JsonElement.serializer(), toJson())

    companion object {
        fun decode(text: String): StudioCueDoc? {
            val o = parseObject(text) ?: return null
            return StudioCueDoc(o.int("schemaVersion") ?: 0, o.lossyList("cues") { StudioCue.fromJson(it) } ?: emptyList())
        }
    }
}

/** A start-marker on a SAMPLE (pad); plays until the next slice's start or the sample end. */
data class StudioSlice(
    val id: String,
    val sampleId: String,
    val slot: Int,
    val startMs: Int,
    val name: String? = null,
) {
    fun toJson(): JsonObject = jsonObj(
        "id" to JsonPrimitive(id), "sampleId" to JsonPrimitive(sampleId), "slot" to JsonPrimitive(slot),
        "startMs" to JsonPrimitive(startMs), "name" to jsonStr(name),
    )

    companion object {
        const val MAX_SLOTS = 8

        fun fromJson(o: JsonObject) = StudioSlice(
            o.str("id") ?: StudioFactory.newSliceId(), o.str("sampleId") ?: "", o.int("slot") ?: 0,
            o.int("startMs") ?: 0, o.str("name"),
        )
    }
}

// ---------------------------------------------------------------------------------------------
// Arrangement (multitrack — the "Tracks" sub-tab)
// ---------------------------------------------------------------------------------------------

/** Provenance of a clip's baked audio. Unknown/future kind => [RECORDING]. */
enum class StudioClipSource(val raw: String) {
    SAMPLE("sample"), LOOP("loop"), PATTERN("pattern"), TAKE("take"),
    RECORDING("recording"), MASTER("master"), STEM("stem");

    companion object {
        fun fromRaw(s: String?): StudioClipSource? = entries.firstOrNull { it.raw == s }
    }
}

/** One clip: an IMMUTABLE baked snapshot placed at [startMs]; [fileStartMs] windows into the file. */
data class StudioClip(
    val id: String,
    val name: String,
    val fileName: String,
    val startMs: Int = 0,
    val durationMs: Int = 0,
    val fileStartMs: Int = 0,
    val source: StudioClipSource = StudioClipSource.RECORDING,
    val sourceId: String? = null,
    val grid: StudioGrid? = null,
    val createdAt: Double = 0.0,
) {
    val endMs: Int get() = startMs + durationMs

    fun toJson(): JsonObject = jsonObj(
        "id" to JsonPrimitive(id), "name" to JsonPrimitive(name), "fileName" to JsonPrimitive(fileName),
        "startMs" to JsonPrimitive(startMs), "durationMs" to JsonPrimitive(durationMs),
        "fileStartMs" to JsonPrimitive(fileStartMs), "source" to JsonPrimitive(source.raw),
        "sourceId" to jsonStr(sourceId), "grid" to grid?.toJson(), "createdAt" to jsonNum(createdAt),
    )

    companion object {
        fun fromJson(o: JsonObject) = StudioClip(
            id = o.str("id") ?: StudioFactory.newClipId(),
            name = o.str("name") ?: "",
            fileName = o.str("fileName") ?: "",
            startMs = o.int("startMs") ?: 0,
            durationMs = o.int("durationMs") ?: 0,
            fileStartMs = o.int("fileStartMs") ?: 0,
            source = StudioClipSource.fromRaw(o.str("source")) ?: StudioClipSource.RECORDING,
            sourceId = o.str("sourceId"),
            grid = StudioGrid.fromJson(o["grid"]),
            createdAt = o.double("createdAt") ?: 0.0,
        )
    }
}

/** Per-track channel strip (pitch/tempo BAKED; EQ + sends live). Clamped by [clamped]. */
data class StudioChannelStrip(
    val pitchSemitones: Double = 0.0,
    val tempoRatio: Double = 1.0,
    val eqLowDb: Double = 0.0,
    val eqMidDb: Double = 0.0,
    val eqHighDb: Double = 0.0,
    val reverb: Double = 0.0,
    val delay: Double = 0.0,
    val chorus: Double = 0.0,
) {
    val bakesAudio: Boolean get() = Math.abs(pitchSemitones) > 0.001 || Math.abs(tempoRatio - 1) > 0.001
    val hasLiveFX: Boolean
        get() = Math.abs(eqLowDb) > 0.01 || Math.abs(eqMidDb) > 0.01 || Math.abs(eqHighDb) > 0.01 ||
            reverb > 0.001 || delay > 0.001 || chorus > 0.001

    fun clamped() = StudioChannelStrip(
        pitchSemitones.coerceIn(-12.0, 12.0), tempoRatio.coerceIn(0.1, 10.0),
        eqLowDb.coerceIn(-18.0, 18.0), eqMidDb.coerceIn(-18.0, 18.0), eqHighDb.coerceIn(-18.0, 18.0),
        reverb.coerceIn(0.0, 1.0), delay.coerceIn(0.0, 1.0), chorus.coerceIn(0.0, 1.0),
    )

    fun toJson(): JsonObject = jsonObj(
        "pitchSemitones" to jsonNum(pitchSemitones), "tempoRatio" to jsonNum(tempoRatio),
        "eqLowDb" to jsonNum(eqLowDb), "eqMidDb" to jsonNum(eqMidDb), "eqHighDb" to jsonNum(eqHighDb),
        "reverb" to jsonNum(reverb), "delay" to jsonNum(delay), "chorus" to jsonNum(chorus),
    )

    companion object {
        fun fromJson(el: JsonElement?): StudioChannelStrip? {
            val o = el as? JsonObject ?: return null
            return StudioChannelStrip(
                o.double("pitchSemitones") ?: 0.0, o.double("tempoRatio") ?: 1.0,
                o.double("eqLowDb") ?: 0.0, o.double("eqMidDb") ?: 0.0, o.double("eqHighDb") ?: 0.0,
                o.double("reverb") ?: 0.0, o.double("delay") ?: 0.0, o.double("chorus") ?: 0.0,
            )
        }
    }
}

/** One lane: ordered clips + live strip (gain/pan/mute/solo) + palette colour. */
data class StudioTrack(
    val id: String,
    val name: String,
    val clips: List<StudioClip> = emptyList(),
    val gainDb: Double = 0.0,
    val pan: Double = 0.0,
    val muted: Boolean = false,
    val soloed: Boolean = false,
    val colorIndex: Int = 0,
    val strip: StudioChannelStrip = StudioChannelStrip(),
    val createdAt: Double = 0.0,
) {
    /** The end of the last clip. */
    val lengthMs: Int get() = clips.maxOfOrNull { it.endMs } ?: 0

    fun toJson(): JsonObject = jsonObj(
        "id" to JsonPrimitive(id), "name" to JsonPrimitive(name), "clips" to JsonArray(clips.map { it.toJson() }),
        "gainDb" to jsonNum(gainDb), "pan" to jsonNum(pan), "muted" to JsonPrimitive(muted),
        "soloed" to JsonPrimitive(soloed), "colorIndex" to JsonPrimitive(colorIndex),
        "strip" to strip.toJson(), "createdAt" to jsonNum(createdAt),
    )

    companion object {
        fun fromJson(o: JsonObject) = StudioTrack(
            id = o.str("id") ?: StudioFactory.newTrackId(),
            name = o.str("name") ?: "",
            clips = o.lossyList("clips") { StudioClip.fromJson(it) } ?: emptyList(),
            gainDb = o.double("gainDb") ?: 0.0,
            pan = o.double("pan") ?: 0.0,
            muted = o.bool("muted") ?: false,
            soloed = o.bool("soloed") ?: false,
            colorIndex = o.int("colorIndex") ?: 0,
            strip = (StudioChannelStrip.fromJson(o["strip"]) ?: StudioChannelStrip()).clamped(),
            createdAt = o.double("createdAt") ?: 0.0,
        )
    }
}

/** Master-bus FX for one arrangement. [freezeEnabled] is persisted but excluded from [anyEffectEnabled]. */
data class StudioMasterFX(
    val phaserEnabled: Boolean = false,
    val phaserRate: Double = 0.5,
    val phaserDepth: Double = 0.6,
    val ringModEnabled: Boolean = false,
    val ringModFreqHz: Double = 200.0,
    val ringModMix: Double = 0.5,
    val freezeEnabled: Boolean = false,
    val brazilianBassEnabled: Boolean = false,
    val brazilianBassAmount: Double = 0.6,
    val driveEnabled: Boolean = false,
    val driveAmount: Double = 0.5,
    val masterGainDb: Double = 0.0,
) {
    val anyEffectEnabled: Boolean get() = phaserEnabled || ringModEnabled || brazilianBassEnabled || driveEnabled

    fun toJson(): JsonObject = jsonObj(
        "phaserEnabled" to JsonPrimitive(phaserEnabled), "phaserRate" to jsonNum(phaserRate),
        "phaserDepth" to jsonNum(phaserDepth), "ringModEnabled" to JsonPrimitive(ringModEnabled),
        "ringModFreqHz" to jsonNum(ringModFreqHz), "ringModMix" to jsonNum(ringModMix),
        "freezeEnabled" to JsonPrimitive(freezeEnabled), "brazilianBassEnabled" to JsonPrimitive(brazilianBassEnabled),
        "brazilianBassAmount" to jsonNum(brazilianBassAmount), "driveEnabled" to JsonPrimitive(driveEnabled),
        "driveAmount" to jsonNum(driveAmount), "masterGainDb" to jsonNum(masterGainDb),
    )

    companion object {
        fun fromJson(el: JsonElement?): StudioMasterFX? {
            val o = el as? JsonObject ?: return null
            return StudioMasterFX(
                o.bool("phaserEnabled") ?: false, o.double("phaserRate") ?: 0.5, o.double("phaserDepth") ?: 0.6,
                o.bool("ringModEnabled") ?: false, o.double("ringModFreqHz") ?: 200.0, o.double("ringModMix") ?: 0.5,
                o.bool("freezeEnabled") ?: false, o.bool("brazilianBassEnabled") ?: false,
                o.double("brazilianBassAmount") ?: 0.6, o.bool("driveEnabled") ?: false,
                o.double("driveAmount") ?: 0.5, o.double("masterGainDb") ?: 0.0,
            )
        }
    }
}

/** A multitrack arrangement (one "Tracks" workspace). */
data class StudioArrangement(
    val id: String,
    val name: String,
    val tracks: List<StudioTrack> = emptyList(),
    val folderId: String? = null,
    val bpm: Double = 120.0,
    val loopEnabled: Boolean = false,
    val loopStartMs: Int = 0,
    val loopEndMs: Int = 0,
    val masterFX: StudioMasterFX = StudioMasterFX(),
    val beatMatchEnabled: Boolean = false,
    val createdAt: Double = 0.0,
    val updatedAt: Double = 0.0,
) {
    val lengthMs: Int get() = tracks.maxOfOrNull { it.lengthMs } ?: 0
    val allClips: List<StudioClip> get() = tracks.flatMap { it.clips }
    val beatGridReady: Boolean get() = allClips.all { it.grid != null }

    fun toJson(): JsonObject = jsonObj(
        "id" to JsonPrimitive(id), "name" to JsonPrimitive(name), "tracks" to JsonArray(tracks.map { it.toJson() }),
        "folderId" to jsonStr(folderId), "bpm" to jsonNum(bpm), "loopEnabled" to JsonPrimitive(loopEnabled),
        "loopStartMs" to JsonPrimitive(loopStartMs), "loopEndMs" to JsonPrimitive(loopEndMs),
        "masterFX" to masterFX.toJson(), "beatMatchEnabled" to JsonPrimitive(beatMatchEnabled),
        "createdAt" to jsonNum(createdAt), "updatedAt" to jsonNum(updatedAt),
    )

    companion object {
        fun fromJson(o: JsonObject) = StudioArrangement(
            id = o.str("id") ?: StudioFactory.newArrangementId(),
            name = o.str("name") ?: "",
            tracks = o.lossyList("tracks") { StudioTrack.fromJson(it) } ?: emptyList(),
            folderId = o.str("folderId"),
            bpm = o.double("bpm") ?: 120.0,
            loopEnabled = o.bool("loopEnabled") ?: false,
            loopStartMs = o.int("loopStartMs") ?: 0,
            loopEndMs = o.int("loopEndMs") ?: 0,
            masterFX = StudioMasterFX.fromJson(o["masterFX"]) ?: StudioMasterFX(),
            beatMatchEnabled = o.bool("beatMatchEnabled") ?: false,
            createdAt = o.double("createdAt") ?: 0.0,
            updatedAt = o.double("updatedAt") ?: 0.0,
        )
    }
}

/** A rendered artifact of an arrangement: a bounce or a live recording. */
data class StudioArrangementArtifact(
    val id: String,
    val arrangementId: String,
    val kind: Kind = Kind.BOUNCE,
    val name: String,
    val fileName: String,
    val durationMs: Int = 0,
    val createdAt: Double = 0.0,
) {
    enum class Kind(val raw: String) {
        BOUNCE("bounce"), RECORDING("recording");

        companion object {
            fun fromRaw(s: String?): Kind? = entries.firstOrNull { it.raw == s }
        }
    }

    fun toJson(): JsonObject = jsonObj(
        "id" to JsonPrimitive(id), "arrangementId" to JsonPrimitive(arrangementId), "kind" to JsonPrimitive(kind.raw),
        "name" to JsonPrimitive(name), "fileName" to JsonPrimitive(fileName),
        "durationMs" to JsonPrimitive(durationMs), "createdAt" to jsonNum(createdAt),
    )

    companion object {
        fun fromJson(o: JsonObject) = StudioArrangementArtifact(
            id = o.str("id") ?: StudioFactory.newArtifactId(),
            arrangementId = o.str("arrangementId") ?: "",
            kind = Kind.fromRaw(o.str("kind")) ?: Kind.BOUNCE,
            name = o.str("name") ?: "",
            fileName = o.str("fileName") ?: "",
            durationMs = o.int("durationMs") ?: 0,
            createdAt = o.double("createdAt") ?: 0.0,
        )
    }
}

// ---------------------------------------------------------------------------------------------
// Document (persistence envelope)
// ---------------------------------------------------------------------------------------------

internal fun parseObject(text: String): JsonObject? =
    try { PdjJson.lenient.parseToJsonElement(text) as? JsonObject } catch (_: Exception) { null }

/** The versioned studio document (`pocketdj-studio.json`). */
data class StudioDocument(
    val schemaVersion: Int = STUDIO_SCHEMA_VERSION,
    val samples: List<StudioSample> = emptyList(),
    val loops: List<StudioLoop> = emptyList(),
    val patterns: List<StudioPattern> = emptyList(),
    val takes: List<StudioTake> = emptyList(),
    val cues: List<StudioCue> = emptyList(),
    val slices: List<StudioSlice> = emptyList(),
    val folders: List<StudioFolder> = emptyList(),
    val loopFolders: List<StudioFolder> = emptyList(),
    val patternFolders: List<StudioFolder> = emptyList(),
    val takeFolders: List<StudioFolder> = emptyList(),
    val arrangements: List<StudioArrangement> = emptyList(),
    val arrangementFolders: List<StudioFolder> = emptyList(),
    val arrangementArtifacts: List<StudioArrangementArtifact> = emptyList(),
    /** On-device detected Camelot key per studio id; absent => not analyzed. */
    val keys: Map<String, String> = emptyMap(),
) {
    fun toJson(): JsonObject = jsonObj(
        "schemaVersion" to JsonPrimitive(schemaVersion),
        "samples" to JsonArray(samples.map { it.toJson() }),
        "loops" to JsonArray(loops.map { it.toJson() }),
        "patterns" to JsonArray(patterns.map { it.toJson() }),
        "takes" to JsonArray(takes.map { it.toJson() }),
        "cues" to JsonArray(cues.map { it.toJson() }),
        "slices" to JsonArray(slices.map { it.toJson() }),
        "folders" to JsonArray(folders.map { it.toJson() }),
        "keys" to JsonObject(keys.mapValues { JsonPrimitive(it.value) }),
        "arrangements" to JsonArray(arrangements.map { it.toJson() }),
        "arrangementFolders" to JsonArray(arrangementFolders.map { it.toJson() }),
        "arrangementArtifacts" to JsonArray(arrangementArtifacts.map { it.toJson() }),
        "loopFolders" to JsonArray(loopFolders.map { it.toJson() }),
        "patternFolders" to JsonArray(patternFolders.map { it.toJson() }),
        "takeFolders" to JsonArray(takeFolders.map { it.toJson() }),
    )

    fun encode(): String = PdjJson.lenient.encodeToString(JsonElement.serializer(), toJson())

    companion object {
        /** null only when [text] is not a JSON object at all (the iOS `try? decode` failing). */
        fun decode(text: String): StudioDocument? = parseObject(text)?.let { fromJson(it) }

        fun fromJson(o: JsonObject) = StudioDocument(
            schemaVersion = o.int("schemaVersion") ?: 0,
            samples = o.lossyList("samples") { StudioSample.fromJson(it) } ?: emptyList(),
            loops = o.lossyList("loops") { StudioLoop.fromJson(it) } ?: emptyList(),
            patterns = o.lossyList("patterns") { StudioPattern.fromJson(it) } ?: emptyList(),
            takes = o.lossyList("takes") { StudioTake.fromJson(it) } ?: emptyList(),
            cues = o.lossyList("cues") { StudioCue.fromJson(it) } ?: emptyList(),
            slices = o.lossyList("slices") { StudioSlice.fromJson(it) } ?: emptyList(),
            folders = o.lossyList("folders", StudioFolder.decoder(StudioFactory::newSampleFolderId)) ?: emptyList(),
            loopFolders = o.lossyList("loopFolders", StudioFolder.decoder(StudioFactory::newLoopFolderId)) ?: emptyList(),
            patternFolders = o.lossyList("patternFolders", StudioFolder.decoder(StudioFactory::newPatternFolderId)) ?: emptyList(),
            takeFolders = o.lossyList("takeFolders", StudioFolder.decoder(StudioFactory::newTakeFolderId)) ?: emptyList(),
            arrangements = o.lossyList("arrangements") { StudioArrangement.fromJson(it) } ?: emptyList(),
            arrangementFolders = o.lossyList("arrangementFolders", StudioFolder.decoder(StudioFactory::newArrangementFolderId)) ?: emptyList(),
            arrangementArtifacts = o.lossyList("arrangementArtifacts") { StudioArrangementArtifact.fromJson(it) } ?: emptyList(),
            keys = o.stringMap("keys") ?: emptyMap(),
        )
    }
}

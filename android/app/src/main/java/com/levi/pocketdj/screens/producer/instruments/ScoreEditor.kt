package com.levi.pocketdj.screens.producer.instruments

import androidx.compose.foundation.background
import androidx.compose.foundation.border
import androidx.compose.foundation.gestures.detectTapGestures
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.BoxWithConstraints
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.offset
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.horizontalScroll
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.filled.AddCircle
import androidx.compose.material.icons.filled.RemoveCircle
import androidx.compose.material3.FilterChip
import androidx.compose.material3.Icon
import androidx.compose.material3.IconButton
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.OutlinedButton
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
import androidx.compose.ui.Modifier
import androidx.compose.ui.geometry.Offset
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.drawscope.DrawScope
import androidx.compose.ui.graphics.drawscope.Stroke
import androidx.compose.ui.graphics.nativeCanvas
import androidx.compose.ui.input.pointer.pointerInput
import androidx.compose.ui.platform.LocalDensity
import androidx.compose.ui.platform.testTag
import androidx.compose.ui.unit.dp
import com.levi.pocketdj.studio.model.Accidental
import com.levi.pocketdj.studio.model.InstrumentKey
import com.levi.pocketdj.studio.model.StudioNoteEvent
import com.levi.pocketdj.studio.score.ClefPlan
import com.levi.pocketdj.studio.score.NoteDuration
import com.levi.pocketdj.studio.score.Pt
import com.levi.pocketdj.studio.score.ScoreLayout
import com.levi.pocketdj.studio.score.ScorePage
import com.levi.pocketdj.studio.score.ScorePlayhead
import com.levi.pocketdj.studio.score.ScorePlaybackState
import com.levi.pocketdj.studio.score.ScoreQuantizer
import com.levi.pocketdj.studio.score.ScoreRenderer
import kotlinx.coroutines.delay
import kotlin.math.max
import kotlin.math.min

/** The four score-editor interaction modes (iOS `ScoreEditMode`). */
enum class ScoreEditMode(val label: String) { ENTER("Enter"), SELECT("Select"), MOVE("Move"), EDIT("Edit") }

/** In SELECT mode a tap picks a single note or every note in the tapped bar. */
enum class ScoreGranularity { NOTE, BAR }

/**
 * The editor's view-local state. The selection is keyed by VALUE ([StudioNoteEvent] is a data class) and resolved against the
 * current events each time: the host re-sorts events on commit, so an index-based selection would move the WRONG notes. [undo]
 * holds the PRE-edit event streams (multi-step); [minBars] pads empty trailing bars so the cursor can enter them.
 */
data class ScoreEditState(
    val mode: ScoreEditMode = ScoreEditMode.ENTER,
    val granularity: ScoreGranularity = ScoreGranularity.NOTE,
    val penLength: NoteDuration = NoteDuration.QUARTER,
    val penAccidental: Accidental = Accidental.NATURAL,
    val selection: Set<StudioNoteEvent> = emptySet(),
    val undo: List<List<StudioNoteEvent>> = emptyList(),
    val cursor: Int = 0,
    val minBars: Int = 0,
)

/** The outcome of an edit: [events] is the stream to commit through the host (null = nothing changed), [state] the next editor state. */
data class EditResult(val events: List<StudioNoteEvent>?, val state: ScoreEditState)

/**
 * Pure editing logic (iOS `ScoreEditorView` private funcs, lifted out so they unit-test): every mutating op returns an [EditResult]
 * and pushes the PRE-edit stream on the undo stack. No Compose, no store.
 */
class ScoreEdits(val bpm: Double, val instrument: InstrumentKey) {
    val step: Double = ScoreQuantizer.sixteenthMs(bpm)
    private val plan = ClefPlan.plan(instrument)

    fun onset(e: StudioNoteEvent): Int = roundHalfAwayInt(e.onMs / step)
    private fun roundHalfAwayInt(d: Double): Int = (if (d < 0) -Math.floor(-d + 0.5) else Math.floor(d + 0.5)).toInt()
    private fun ms(sixteenths: Double): Int = roundHalfAwayInt(sixteenths * step)

    private fun commit(events: List<StudioNoteEvent>, next: List<StudioNoteEvent>, st: ScoreEditState, selection: Set<StudioNoteEvent> = st.selection) =
        EditResult(next, st.copy(undo = st.undo + listOf(events), selection = selection))

    // ---- undo / select
    /** Pops the last snapshot and re-commits it WITHOUT pushing; clears the selection (the events changed underneath it). Null when empty. */
    fun undo(st: ScoreEditState): EditResult? {
        val prev = st.undo.lastOrNull() ?: return null
        return EditResult(prev, st.copy(undo = st.undo.dropLast(1), selection = emptySet()))
    }

    /** Sync the pen length / accidental to a note (so the chips reflect the last-touched one). */
    fun syncPen(st: ScoreEditState, e: StudioNoteEvent): ScoreEditState =
        st.copy(penLength = NoteDuration.snapped(max(1, roundHalfAwayInt((e.offMs - e.onMs) / step))), penAccidental = e.accidental ?: Accidental.NATURAL)

    fun toggle(st: ScoreEditState, e: StudioNoteEvent): ScoreEditState {
        val sel = if (e in st.selection) st.selection - e else st.selection + e
        return syncPen(st.copy(selection = sel), e)
    }

    fun toggleBar(events: List<StudioNoteEvent>, st: ScoreEditState, measure: Int): ScoreEditState {
        val inBar = events.filter { onset(it) / 16 == measure }
        if (inBar.isEmpty()) return st
        return st.copy(selection = if (inBar.all { it in st.selection }) st.selection - inBar.toSet() else st.selection + inBar)
    }

    /** The events currently selected, in stream order (resolved by VALUE so a host re-sort cannot change which notes). */
    fun selected(events: List<StudioNoteEvent>, st: ScoreEditState): List<StudioNoteEvent> = events.filter { it in st.selection }

    // ---- tap
    /** ENTER: place a new note at the tapped staff position with the pen; an existing same-time/same-pitch note is SELECTED instead of stacking an invisible duplicate. */
    fun place(events: List<StudioNoteEvent>, st: ScoreEditState, loc: ScoreLayout.Located): EditResult {
        val natural = ScoreLayout.naturalMidi(loc.position, loc.staff)
        val (midi, acc) = when (st.penAccidental) {
            Accidental.NATURAL -> natural to null
            Accidental.SHARP -> (natural + 1) to Accidental.SHARP
            Accidental.FLAT -> (natural - 1) to Accidental.FLAT
        }
        val onMs = ms((loc.measureIndex * 16 + loc.onset16ths).toDouble())
        events.firstOrNull { it.onMs == onMs && it.note == midi }?.let { return EditResult(null, syncPen(st.copy(selection = setOf(it)), it)) }
        val offMs = onMs + ms(st.penLength.sixteenths.toDouble())
        val n = StudioNoteEvent(onMs, offMs, midi.coerceIn(0, 127), 96, acc)
        return commit(events, events + n, st, setOf(n))
    }

    /** SELECT / MOVE / EDIT tap on empty space: SELECT clears, the others ignore. */
    fun tapNote(st: ScoreEditState, nearest: StudioNoteEvent?): ScoreEditState = when {
        nearest != null -> toggle(st, nearest)
        st.mode == ScoreEditMode.SELECT -> st.copy(selection = emptySet())
        else -> st
    }

    /** The note whose head is closest to [p] on [pageIndex], only if within ~8% of the page height (a stray tap selects nothing). */
    fun nearestNote(events: List<StudioNoteEvent>, pages: List<ScorePage>, pageIndex: Int, p: Pt): StudioNoteEvent? {
        if (pageIndex !in pages.indices) return null
        var best: StudioNoteEvent? = null
        var bestD = Float.MAX_VALUE
        for (e in events) {
            val np = ScoreLayout.notePoint(e.note, e.accidental, onset(e), plan, pages) ?: continue
            if (np.page != pageIndex) continue
            val dx = np.point.x - p.x; val dy = np.point.y - p.y
            val d = dx * dx + dy * dy
            if (d < bestD) { best = e; bestD = d }
        }
        val reach = pages[pageIndex].height * 0.08f
        return if (best != null && bestD <= reach * reach) best else null
    }

    // ---- cursor + bars
    fun lastNote(events: List<StudioNoteEvent>): StudioNoteEvent? = events.maxByOrNull { it.onMs }
    private fun noteOnsets(events: List<StudioNoteEvent>): List<Int> = events.map(::onset).distinct().sorted()
    fun contentBars(events: List<StudioNoteEvent>): Int {
        val end = events.maxOfOrNull { roundHalfAwayInt(it.offMs / step) } ?: return 0
        return (end + 15) / 16
    }
    fun barCount(events: List<StudioNoteEvent>, st: ScoreEditState) = max(contentBars(events), st.minBars)
    fun lastBarEmpty(events: List<StudioNoteEvent>, st: ScoreEditState) = barCount(events, st) > contentBars(events)

    fun selectAtOnset(events: List<StudioNoteEvent>, st: ScoreEditState, on: Int): ScoreEditState {
        val here = events.filter { onset(it) == on }
        val s = st.copy(selection = here.toSet())
        return here.firstOrNull()?.let { syncPen(s, it) } ?: s
    }
    private fun selectBar(events: List<StudioNoteEvent>, st: ScoreEditState, bar: Int): ScoreEditState {
        val inBar = events.filter { onset(it) / 16 == bar }
        val s = st.copy(selection = inBar.toSet())
        return inBar.firstOrNull()?.let { syncPen(s, it) } ?: s
    }

    /** Entering SELECT with nothing selected: put the cursor on (and select) the LAST note. */
    fun enterSelectMode(events: List<StudioNoteEvent>, st: ScoreEditState): ScoreEditState {
        val last = lastNote(events)
        return if (st.selection.isEmpty() && last != null) selectAtOnset(events, st.copy(cursor = onset(last)), onset(last)) else st
    }

    /** SELECT cursor: one note (NOTE) or one bar (BAR); moving forward past the end grows the score by an empty bar. */
    fun moveCursor(events: List<StudioNoteEvent>, st: ScoreEditState, delta: Int): ScoreEditState {
        val bars = barCount(events, st)
        if (st.granularity == ScoreGranularity.BAR) {
            val target = st.cursor / 16 + delta
            if (target < 0) return st
            val grown = if (target >= bars) st.copy(minBars = target + 1) else st
            return selectBar(events, grown.copy(cursor = target * 16), target)
        }
        val ons = noteOnsets(events)
        if (delta > 0) {
            val nxt = ons.firstOrNull { it > st.cursor }
            return if (nxt != null) selectAtOnset(events, st.copy(cursor = nxt), nxt)
            else st.copy(minBars = bars + 1, cursor = bars * 16, selection = emptySet())
        }
        val prv = ons.lastOrNull { it < st.cursor } ?: return st
        return selectAtOnset(events, st.copy(cursor = prv), prv)
    }

    fun addBar(events: List<StudioNoteEvent>, st: ScoreEditState) = st.copy(minBars = barCount(events, st) + 1)
    /** Removes the last bar only when it is EMPTY: never deletes notes. */
    fun removeBar(events: List<StudioNoteEvent>, st: ScoreEditState) = if (lastBarEmpty(events, st)) st.copy(minBars = barCount(events, st) - 1) else st

    // ---- move / duplicate / edit
    private fun mutateSelected(events: List<StudioNoteEvent>, st: ScoreEditState, f: (StudioNoteEvent) -> StudioNoteEvent): EditResult? {
        if (st.selection.isEmpty()) return null
        val newSel = LinkedHashSet<StudioNoteEvent>()
        val next = events.map { e -> if (e in st.selection) f(e).also { newSel.add(it) } else e }
        return commit(events, next, st, newSel)
    }

    fun moveSemitone(events: List<StudioNoteEvent>, st: ScoreEditState, delta: Int) =
        mutateSelected(events, st) { it.copy(note = (it.note + delta).coerceIn(0, 127), accidental = null) }

    /** Nudge the group by one 16th step (the whole group moves together, never before 0). */
    fun moveStep(events: List<StudioNoteEvent>, st: ScoreEditState, delta: Int): EditResult? {
        if (st.selection.isEmpty()) return null
        val d = roundHalfAwayInt(delta * step)
        val minOn = selected(events, st).minOfOrNull { it.onMs } ?: 0
        val shift = max(-minOn, d)
        if (shift == 0) return null
        return mutateSelected(events, st) { it.copy(onMs = it.onMs + shift, offMs = it.offMs + shift) }
    }

    fun duplicate(events: List<StudioNoteEvent>, st: ScoreEditState): EditResult? {
        val bar = ms(16.0)
        val copies = selected(events, st).map { it.copy(onMs = it.onMs + bar, offMs = it.offMs + bar) }
        if (copies.isEmpty()) return null
        return commit(events, events + copies, st, copies.toSet())
    }

    fun setLength(events: List<StudioNoteEvent>, st: ScoreEditState, d: NoteDuration): EditResult? {
        val s = st.copy(penLength = d)
        return mutateSelected(events, s) { it.copy(offMs = it.onMs + ms(d.sixteenths.toDouble())) } ?: EditResult(null, s)
    }

    fun setAccidental(events: List<StudioNoteEvent>, st: ScoreEditState, a: Accidental): EditResult? {
        val s = st.copy(penAccidental = a)
        return mutateSelected(events, s) { e ->
            val staff = plan.staff(e.note)
            val pos = ScoreLayout.spelledPosition(e.note, staff, e.accidental).position
            val natural = ScoreLayout.naturalMidi(pos, staff)
            when (a) {
                Accidental.NATURAL -> e.copy(note = natural, accidental = null)
                Accidental.SHARP -> e.copy(note = (natural + 1).coerceIn(0, 127), accidental = Accidental.SHARP)
                Accidental.FLAT -> e.copy(note = (natural - 1).coerceIn(0, 127), accidental = Accidental.FLAT)
            }
        } ?: EditResult(null, s)
    }

    fun deleteSelected(events: List<StudioNoteEvent>, st: ScoreEditState): EditResult? {
        if (st.selection.isEmpty()) return null
        return commit(events, events.filter { it !in st.selection }, st, emptySet())
    }

    fun hint(st: ScoreEditState): String {
        val n = st.selection.size
        val notes = "$n note${if (n == 1) "" else "s"}"
        return when (st.mode) {
            ScoreEditMode.ENTER -> "Tap the staff to place a note (length / accidental above)."
            ScoreEditMode.SELECT ->
                if (st.granularity == ScoreGranularity.BAR) { if (n == 0) "Tap a bar to select all its notes." else "$notes selected." }
                else if (n == 0) "Tap near a note to select it — it snaps to the closest." else "$notes selected — tap more, or switch to Move / Edit."
            ScoreEditMode.MOVE -> if (n == 0) "Select notes first, then nudge or duplicate them." else "Nudge the selected $notes by a semitone or a step, or duplicate a bar later."
            ScoreEditMode.EDIT -> if (n == 0) "Select notes first, then set length / accidental or delete." else "Length, accidental, and delete apply to the selected $notes."
        }
    }
}

/** What Cancel does for one staff: restore the pre-edit snapshot, or REVERT to derive-from-raw (editedEvents == null). */
sealed interface CancelAction {
    data class Set(val events: List<StudioNoteEvent>) : CancelAction
    data object Revert : CancelAction

    companion object {
        /** A staff that was deriving-from-raw (snapshot null, or overdubbed mid-session with no snapshot) must go back to null via revert, NEVER be pinned to a snapshot. */
        fun forSnapshot(snapshot: List<StudioNoteEvent>?): CancelAction = if (snapshot != null) Set(snapshot) else Revert
    }
}

private val GREY = Color(0xFF8A8A8A)

/**
 * The reusable editable score surface (iOS `ScoreEditorView`): renders [events] as notation and, when [editing], offers the four modes
 * (Enter / Select / Move / Edit) with multi-step Undo. Every edit commits through [onEdit]. [positionMs]/[onSeek] wire a playback clock
 * (cursor + played-behind wash + current / last-played ring); a tap while NOT editing seeks. Page painting is the shared [ScoreRenderer].
 */
@Composable
fun ScoreEditor(
    events: List<StudioNoteEvent>, bpm: Double, instrument: InstrumentKey, title: String, editing: Boolean,
    onEdit: (List<StudioNoteEvent>) -> Unit,
    modifier: Modifier = Modifier,
    positionMs: (() -> Int?)? = null,
    onSeek: ((Int) -> Unit)? = null,
    tagPrefix: String = "score",
) {
    val edits = remember(bpm, instrument) { ScoreEdits(bpm, instrument) }
    var st by remember { mutableStateOf(ScoreEditState()) }
    val density = LocalDensity.current

    // Leaving edit mode resets the session (selection, undo, mode, padded bars).
    LaunchedEffect(editing) { if (!editing) st = ScoreEditState() }

    val doc = remember(events, bpm, instrument, st.minBars) { ScoreQuantizer.quantize(events, bpm, instrument, st.minBars) }
    val pages = remember(doc, title, instrument) { ScoreLayout.paginate(doc, title, instrument) }
    val marks = remember(events, bpm, pages) { if (positionMs == null) emptyList() else ScoreLayout.playedMarks(events, bpm, doc.clefPlan, pages) }
    val slots = remember(events, bpm) { ScorePlayhead.timeline(events, bpm) }

    fun apply(r: EditResult?) {
        if (r == null) return
        st = r.state
        r.events?.let(onEdit)
    }

    Column(modifier.fillMaxWidth(), verticalArrangement = Arrangement.spacedBy(12.dp)) {
        if (editing) EditToolbar(edits, st, events, onState = { st = it }, onResult = ::apply, tagPrefix = tagPrefix)
        if (events.isEmpty()) Text(if (editing) "Tap the staff to place a note." else "No notes yet.", style = MaterialTheme.typography.bodySmall, color = MaterialTheme.colorScheme.onSurfaceVariant)
        for ((i, page) in pages.withIndex()) {
            BoxWithConstraints(Modifier.fillMaxWidth().testTag("$tagPrefix-page-$i")) {
                val wPx = with(density) { maxWidth.toPx() }
                val scale = wPx / page.width
                val heightDp = with(density) { (page.height * scale).toDp() }
                val highlights = remember(st.selection, events, pages) {
                    if (st.selection.isEmpty()) emptyList() else edits.selected(events, st).mapNotNull { e ->
                        ScoreLayout.notePoint(e.note, e.accidental, edits.onset(e), doc.clefPlan, pages)?.takeIf { it.page == i }?.point
                    }
                }
                Box(
                    Modifier.fillMaxWidth().size(maxWidth, heightDp)
                        .border(1.dp, GREY.copy(alpha = 0.4f))
                        .pointerInput(editing, st.mode, st.granularity, events, pages, onSeek) {
                            detectTapGestures { off ->
                                val p = Pt(off.x / scale, off.y / scale)
                                if (editing) {
                                    when (st.mode) {
                                        ScoreEditMode.ENTER -> ScoreLayout.locate(p, page)?.let { apply(edits.place(events, st, it)) }
                                        ScoreEditMode.SELECT ->
                                            if (st.granularity == ScoreGranularity.BAR) ScoreLayout.locate(p, page)?.let { st = edits.toggleBar(events, st, it.measureIndex) }
                                            else st = edits.tapNote(st, edits.nearestNote(events, pages, i, p))
                                        ScoreEditMode.MOVE, ScoreEditMode.EDIT -> st = edits.tapNote(st, edits.nearestNote(events, pages, i, p))
                                    }
                                } else if (onSeek != null) {
                                    ScoreLayout.time16ths(p, page)?.let { onSeek(ScorePlayhead.ms(it, bpm)) }
                                }
                            }
                        },
                ) {
                    androidx.compose.foundation.Canvas(Modifier.fillMaxWidth().size(maxWidth, heightDp)) {
                        drawIntoNative(scale) { c -> ScoreRenderer.draw(page, c) }
                        highlights.forEach { h ->
                            drawCircle(Color(0xF26EA8FF), radius = 8f * scale, center = Offset(h.x * scale, h.y * scale), style = Stroke(width = 1.6f * scale))
                        }
                    }
                    if (positionMs != null) PlaybackLayer(page, i, pages, marks.filter { it.page == i }, slots, bpm, positionMs, scale, maxWidth, heightDp)
                    if (editing && st.mode == ScoreEditMode.SELECT && i == pages.lastIndex) {
                        val sys = page.systems.lastOrNull()
                        val last = sys?.measures?.lastOrNull()
                        if (sys != null && last != null) {
                            val pad = sys.spacing * 3
                            val x = last.x + last.width
                            val topY = sys.strips.minOf { it.top } - pad
                            val botY = sys.strips.maxOf { it.top } + sys.spacing * 4 + pad
                            val canRemove = edits.lastBarEmpty(events, st)
                            val half = 16.dp
                            IconButton({ st = edits.addBar(events, st) }, Modifier.offset(with(density) { (x * scale).toDp() } - half, with(density) { (topY * scale).toDp() } - half).size(32.dp).testTag("$tagPrefix-add-bar")) { Icon(Icons.Filled.AddCircle, "Add bar", tint = MaterialTheme.colorScheme.primary) }
                            IconButton({ st = edits.removeBar(events, st) }, enabled = canRemove, modifier = Modifier.offset(with(density) { (x * scale).toDp() } - half, with(density) { (botY * scale).toDp() } - half).size(32.dp).testTag("$tagPrefix-remove-bar")) { Icon(Icons.Filled.RemoveCircle, "Remove bar", tint = if (canRemove) MaterialTheme.colorScheme.error else GREY) }
                        }
                    }
                }
            }
        }
    }
}

private inline fun DrawScope.drawIntoNative(scale: Float, crossinline body: (android.graphics.Canvas) -> Unit) {
    drawContext.canvas.nativeCanvas.let { c ->
        c.save(); c.scale(scale, scale); body(c); c.restore()
    }
}

/** One page's playback layer: ticks the host clock at ~10 Hz INSIDE this composable so only these few shapes redraw. */
@Composable
private fun PlaybackLayer(
    page: ScorePage, pageIndex: Int, pages: List<ScorePage>, marks: List<ScoreLayout.PlayedMark>, slots: List<ScorePlayhead.Slot>,
    bpm: Double, positionMs: () -> Int?, scale: Float, w: androidx.compose.ui.unit.Dp, h: androidx.compose.ui.unit.Dp,
) {
    var state by remember { mutableStateOf(ScorePlaybackState.IDLE) }
    LaunchedEffect(slots, bpm) {
        while (true) {
            val next = ScorePlayhead.state(positionMs(), slots, bpm)
            if (next != state) state = next
            delay(100)
        }
    }
    val ring = Color(0xFFF07019)
    androidx.compose.foundation.Canvas(Modifier.size(w, h).testTag("score-playhead-$pageIndex")) {
        for (m in marks) if (state.isPlayed(m.onset16ths)) drawCircle(Color(0x335C85DB), radius = 6.5f * scale, center = Offset(m.point.x * scale, m.point.y * scale))
        ScoreLayout.playhead(state.cursor16ths, pages)?.takeIf { it.page == pageIndex }?.let { ph ->
            drawLine(if (state.currentOnset16ths == null) Color(0x422966F0) else Color(0xB32966F0), Offset(ph.x * scale, ph.top * scale), Offset(ph.x * scale, ph.bottom * scale), strokeWidth = 1.6f * scale)
        }
        val cur = state.currentOnset16ths ?: return@Canvas
        for (m in marks) if (m.onset16ths == cur) {
            val c = Offset(m.point.x * scale, m.point.y * scale)
            if (state.isSounding) drawCircle(ring.copy(alpha = 0.22f), radius = 8f * scale, center = c)
            drawCircle(ring.copy(alpha = if (state.isSounding) 0.95f else 0.55f), radius = 8f * scale, center = c, style = Stroke(width = (if (state.isSounding) 2.0f else 1.4f) * scale))
        }
    }
}

@Composable
private fun EditToolbar(
    edits: ScoreEdits, st: ScoreEditState, events: List<StudioNoteEvent>,
    onState: (ScoreEditState) -> Unit, onResult: (EditResult?) -> Unit, tagPrefix: String,
) {
    val lengths = listOf(NoteDuration.EIGHTH to "1/8", NoteDuration.QUARTER to "1/4", NoteDuration.HALF to "1/2", NoteDuration.WHOLE to "○")
    val accs = listOf(Accidental.NATURAL to "♮", Accidental.SHARP to "♯", Accidental.FLAT to "♭")
    val none = st.selection.isEmpty()
    Column(Modifier.fillMaxWidth().background(MaterialTheme.colorScheme.surfaceVariant, RoundedCornerShape(12.dp)).padding(10.dp), verticalArrangement = Arrangement.spacedBy(6.dp)) {
        Row(Modifier.horizontalScroll(rememberScrollState()), horizontalArrangement = Arrangement.spacedBy(6.dp)) {
            for (m in ScoreEditMode.entries) FilterChip(st.mode == m, {
                var next = st.copy(mode = m)
                if (m == ScoreEditMode.SELECT) next = edits.enterSelectMode(events, next)
                onState(next)
            }, { Text(m.label) }, Modifier.testTag("$tagPrefix-mode-${m.name.lowercase()}"))
            OutlinedButton({ onResult(edits.undo(st)) }, enabled = st.undo.isNotEmpty(), modifier = Modifier.testTag("$tagPrefix-undo")) { Text("Undo") }
        }
        when (st.mode) {
            ScoreEditMode.ENTER -> {
                ChipRow("Length", lengths, st.penLength, "$tagPrefix-pen-length") { onState(st.copy(penLength = it)) }
                ChipRow("Accidental", accs, st.penAccidental, "$tagPrefix-pen-acc") { onState(st.copy(penAccidental = it)) }
            }
            ScoreEditMode.SELECT -> {
                Row(Modifier.horizontalScroll(rememberScrollState()), horizontalArrangement = Arrangement.spacedBy(6.dp)) {
                    FilterChip(st.granularity == ScoreGranularity.NOTE, { onState(st.copy(granularity = ScoreGranularity.NOTE)) }, { Text("Notes") }, Modifier.testTag("$tagPrefix-gran-note"))
                    FilterChip(st.granularity == ScoreGranularity.BAR, { onState(st.copy(granularity = ScoreGranularity.BAR)) }, { Text("Bars") }, Modifier.testTag("$tagPrefix-gran-bar"))
                    OutlinedButton({ onState(edits.moveCursor(events, st, -1)) }, modifier = Modifier.testTag("$tagPrefix-cursor-prev")) { Text("◀") }
                    OutlinedButton({ onState(edits.moveCursor(events, st, 1)) }, modifier = Modifier.testTag("$tagPrefix-cursor-next")) { Text("▶") }
                    if (!none) OutlinedButton({ onState(st.copy(selection = emptySet())) }, modifier = Modifier.testTag("$tagPrefix-deselect")) { Text("Deselect") }
                }
            }
            ScoreEditMode.MOVE -> Row(Modifier.horizontalScroll(rememberScrollState()), horizontalArrangement = Arrangement.spacedBy(6.dp)) {
                OutlinedButton({ onResult(edits.moveSemitone(events, st, 1)) }, enabled = !none, modifier = Modifier.testTag("$tagPrefix-move-up")) { Text("♯+") }
                OutlinedButton({ onResult(edits.moveSemitone(events, st, -1)) }, enabled = !none, modifier = Modifier.testTag("$tagPrefix-move-down")) { Text("♭−") }
                OutlinedButton({ onResult(edits.moveStep(events, st, -1)) }, enabled = !none, modifier = Modifier.testTag("$tagPrefix-move-left")) { Text("◀") }
                OutlinedButton({ onResult(edits.moveStep(events, st, 1)) }, enabled = !none, modifier = Modifier.testTag("$tagPrefix-move-right")) { Text("▶") }
                OutlinedButton({ onResult(edits.duplicate(events, st)) }, enabled = !none, modifier = Modifier.testTag("$tagPrefix-duplicate")) { Text("Duplicate") }
            }
            ScoreEditMode.EDIT -> {
                ChipRow("Length", lengths, st.penLength, "$tagPrefix-length") { onResult(edits.setLength(events, st, it)) }
                ChipRow("Accidental", accs, st.penAccidental, "$tagPrefix-acc") { onResult(edits.setAccidental(events, st, it)) }
                OutlinedButton({ onResult(edits.deleteSelected(events, st)) }, enabled = !none, modifier = Modifier.testTag("$tagPrefix-delete")) { Text("Delete") }
            }
        }
        Text(edits.hint(st), style = MaterialTheme.typography.labelSmall, color = MaterialTheme.colorScheme.onSurfaceVariant)
    }
}

@Composable
private fun <T> ChipRow(label: String, options: List<Pair<T, String>>, selected: T, tag: String, onPick: (T) -> Unit) {
    Row(Modifier.horizontalScroll(rememberScrollState()), horizontalArrangement = Arrangement.spacedBy(6.dp), verticalAlignment = androidx.compose.ui.Alignment.CenterVertically) {
        Text(label, style = MaterialTheme.typography.labelSmall, color = MaterialTheme.colorScheme.onSurfaceVariant)
        for ((v, text) in options) FilterChip(selected == v, { onPick(v) }, { Text(text) }, Modifier.testTag("$tag-${text}"))
    }
}

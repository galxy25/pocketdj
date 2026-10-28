package com.levi.pocketdj.screens.producer.demux

import androidx.compose.foundation.Canvas
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.material3.ExperimentalMaterial3Api
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.ModalBottomSheet
import androidx.compose.material3.SegmentedButton
import androidx.compose.material3.SegmentedButtonDefaults
import androidx.compose.material3.SingleChoiceSegmentedButtonRow
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.geometry.Offset
import androidx.compose.ui.geometry.Size
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.platform.testTag
import androidx.compose.ui.semantics.contentDescription
import androidx.compose.ui.semantics.semantics
import androidx.compose.ui.text.TextStyle
import androidx.compose.ui.text.drawText
import androidx.compose.ui.text.font.FontFamily
import androidx.compose.ui.text.rememberTextMeasurer
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import com.levi.pocketdj.studio.demux.DemuxChordSegment

/** Pure staff / fretboard geometry for the chord card (JVM-tested; the Canvas only paints it). */
object ChordStaffMath {
    enum class Clef { TREBLE, BASS }

    /** One note head: [stepsUp] half-lines above the staff's bottom line; [nudged] = second-interval offset. */
    data class Head(val midi: Int, val stepsUp: Int, val sharp: Boolean, val nudged: Boolean, val ledgerSteps: List<Int>)

    private val LETTER_OF_PC = intArrayOf(0, 0, 1, 1, 2, 3, 3, 4, 4, 5, 5, 6)
    private val SHARP_PCS = setOf(1, 3, 6, 8, 10)

    /** MIDI -> (diatonic step index, needs-sharp). Black keys spell as sharps of the letter below. */
    fun pitch(midi: Int): Pair<Int, Boolean> {
        val pc = ((midi % 12) + 12) % 12
        val octave = Math.floorDiv(midi, 12) - 1
        return (octave * 7 + LETTER_OF_PC[pc]) to (pc in SHARP_PCS)
    }

    /** Diatonic step of the staff's BOTTOM LINE (treble E4, bass G2). */
    fun bottomStep(clef: Clef): Int = pitch(if (clef == Clef.TREBLE) 64 else 43).first

    /**
     * Lay out [midiNotes] (any voicing, any octave). The previous-head tracker is NULLABLE, not a MIN_VALUE
     * sentinel: `stepsUp - Int.MIN_VALUE` overflows for any first note at/above the bottom line (the iOS
     * scrub-while-playing field crash, build 1784413084). Ledger lines: even steps sit ON a line.
     */
    fun layout(clef: Clef, midiNotes: List<Int>): List<Head> {
        val bottom = bottomStep(clef)
        var last: Int? = null
        val out = ArrayList<Head>()
        for (midi in midiNotes.sorted()) {
            val (step, sharp) = pitch(midi)
            val up = step - bottom
            val collides = last?.let { up - it == 1 } ?: false
            last = up
            val ledgers = when {
                up < 0 -> (-2 downTo up step 2).toList()
                up > 8 -> (10..up step 2).toList()
                else -> emptyList()
            }
            out.add(Head(midi, up, sharp, collides, ledgers))
        }
        return out
    }

    /** Fret window start for the chord box: 1 when the voicing reaches the nut area, else its lowest fretted fret. */
    fun boxBase(frets: List<Int?>): Int {
        val fretted = frets.filterNotNull().filter { it > 0 }
        val min = fretted.minOrNull() ?: 1
        return if (min <= 1) 1 else min
    }

    /** 0-based row inside the 5-fret window, or null when the fret falls outside it (or is open/muted). */
    fun boxRow(fret: Int?, base: Int): Int? = fret?.takeIf { it > 0 }?.let { (it - base).takeIf { r -> r in 0..4 } }
}

private enum class ChordForm(val label: String) { NOTATION("Notation"), GUITAR("Guitar") }

internal fun clock(ms: Int): String { val s = ms / 1000; return "%d:%02d".format(s / 60, s % 60) }

/** Detail card for one chord (tapped on the timeline): notation (treble + bass staves) or a guitar shape. */
@OptIn(ExperimentalMaterial3Api::class)
@Composable
fun ChordDetailSheet(chord: DemuxChordSegment, onDismiss: () -> Unit) {
    var form by remember { mutableStateOf(ChordForm.NOTATION) }
    ModalBottomSheet(onDismissRequest = onDismiss) {
        Column(Modifier.fillMaxWidth().padding(16.dp).testTag("demux-chord-detail"), verticalArrangement = Arrangement.spacedBy(12.dp)) {
            Row(verticalAlignment = Alignment.Bottom, horizontalArrangement = Arrangement.spacedBy(8.dp)) {
                Text(chord.name, style = MaterialTheme.typography.headlineSmall)
                Text(if (chord.minor) "minor" else "major", color = MaterialTheme.colorScheme.onSurfaceVariant)
                Text("${clock(chord.startMs)}–${clock(chord.endMs)}", color = MaterialTheme.colorScheme.onSurfaceVariant, fontFamily = FontFamily.Monospace)
            }
            SingleChoiceSegmentedButtonRow(Modifier.fillMaxWidth().testTag("demux-chord-form")) {
                ChordForm.entries.forEachIndexed { i, f ->
                    SegmentedButton(selected = form == f, onClick = { form = f }, shape = SegmentedButtonDefaults.itemShape(i, ChordForm.entries.size)) { Text(f.label) }
                }
            }
            when (form) {
                ChordForm.NOTATION -> Row(Modifier.fillMaxWidth(), horizontalArrangement = Arrangement.SpaceEvenly) {
                    StaffChordView(ChordStaffMath.Clef.TREBLE, chord.midiNotes(60))
                    StaffChordView(ChordStaffMath.Clef.BASS, chord.midiNotes(48))
                }
                ChordForm.GUITAR -> Column(Modifier.fillMaxWidth(), horizontalAlignment = Alignment.CenterHorizontally, verticalArrangement = Arrangement.spacedBy(8.dp)) {
                    GuitarChordView(chord.guitarFrets)
                    Text(chord.tabText, fontFamily = FontFamily.Monospace, modifier = Modifier.testTag("demux-chord-tab"))
                    Text("low E → high e", style = MaterialTheme.typography.labelSmall, color = MaterialTheme.colorScheme.onSurfaceVariant)
                }
            }
            Row(Modifier.height(16.dp)) {}
        }
    }
}

@Composable
private fun StaffChordView(clef: ChordStaffMath.Clef, midiNotes: List<Int>) {
    val fg = MaterialTheme.colorScheme.onSurface
    val dim = MaterialTheme.colorScheme.onSurfaceVariant
    val measurer = rememberTextMeasurer()
    val label = if (clef == ChordStaffMath.Clef.TREBLE) "Treble clef chord" else "Bass clef chord"
    Canvas(Modifier.size(120.dp, 96.dp).semantics { contentDescription = label }) {
        val gap = 8.dp.toPx()
        val top = (size.height - 4 * gap) / 2
        val bottomY = top + 4 * gap
        for (i in 0 until 5) drawLine(dim, Offset(6.dp.toPx(), top + i * gap), Offset(size.width - 6.dp.toPx(), top + i * gap), 1.dp.toPx())
        val clefGlyph = if (clef == ChordStaffMath.Clef.TREBLE) "𝄞" else "𝄢"
        val clefStyle = TextStyle(color = fg, fontSize = if (clef == ChordStaffMath.Clef.TREBLE) 40.sp else 30.sp)
        val m = measurer.measure(clefGlyph, clefStyle)
        drawText(m, topLeft = Offset(8.dp.toPx(), top + 2 * gap - m.size.height / 2f))
        val noteX = size.width * 0.62f
        for (h in ChordStaffMath.layout(clef, midiNotes)) {
            val y = bottomY - h.stepsUp * gap / 2
            val x = if (h.nudged) noteX + 9.dp.toPx() else noteX
            for (s in h.ledgerSteps) {
                val ly = bottomY - s * gap / 2
                drawLine(dim, Offset(x - 8.dp.toPx(), ly), Offset(x + 8.dp.toPx(), ly), 1.dp.toPx())
            }
            drawOval(fg, Offset(x - 5.5.dp.toPx(), y - 4.dp.toPx()), Size(11.dp.toPx(), 8.dp.toPx()))
            if (h.sharp) {
                val sm = measurer.measure("♯", TextStyle(color = fg, fontSize = 12.sp))
                drawText(sm, topLeft = Offset(x - 14.dp.toPx() - sm.size.width / 2f, y - sm.size.height / 2f))
            }
        }
    }
}

@Composable
private fun GuitarChordView(frets: List<Int?>) {
    val fg = MaterialTheme.colorScheme.onSurface
    val dim = MaterialTheme.colorScheme.onSurfaceVariant
    val accent = MaterialTheme.colorScheme.primary
    val measurer = rememberTextMeasurer()
    val base = ChordStaffMath.boxBase(frets)
    Canvas(Modifier.size(130.dp, 120.dp).semantics { contentDescription = "Guitar chord diagram" }) {
        val left = 18.dp.toPx(); val right = size.width - 8.dp.toPx()
        val top = 16.dp.toPx(); val bottom = size.height - 8.dp.toPx()
        val stringGap = (right - left) / 5
        val fretGap = (bottom - top) / 5
        drawLine(fg, Offset(left, top), Offset(right, top), if (base == 1) 4.dp.toPx() else 1.dp.toPx())
        if (base > 1) {
            val t = measurer.measure("${base}fr", TextStyle(color = dim, fontSize = 10.sp))
            drawText(t, topLeft = Offset(left - 10.dp.toPx() - t.size.width / 2f, top + fretGap / 2 - t.size.height / 2f))
        }
        for (s in 0 until 6) drawLine(dim, Offset(left + s * stringGap, top), Offset(left + s * stringGap, bottom), 1.dp.toPx())
        for (f in 1..5) drawLine(dim, Offset(left, top + f * fretGap), Offset(right, top + f * fretGap), 1.dp.toPx())
        frets.forEachIndexed { s, fret ->
            val x = left + s * stringGap
            when {
                fret == null -> {
                    val t = measurer.measure("×", TextStyle(color = dim, fontSize = 12.sp))
                    drawText(t, topLeft = Offset(x - t.size.width / 2f, top - 8.dp.toPx() - t.size.height / 2f))
                }
                fret == 0 -> drawCircle(fg, 3.5.dp.toPx(), Offset(x, top - 8.5.dp.toPx()), style = androidx.compose.ui.graphics.drawscope.Stroke(1.dp.toPx()))
                else -> ChordStaffMath.boxRow(fret, base)?.let { row ->
                    drawCircle(accent, 5.dp.toPx(), Offset(x, top + (row + 0.5f) * fretGap))
                }
            }
        }
    }
}

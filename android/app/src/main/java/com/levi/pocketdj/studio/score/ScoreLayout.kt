package com.levi.pocketdj.studio.score

import com.levi.pocketdj.studio.model.Accidental
import com.levi.pocketdj.studio.model.InstrumentKey
import com.levi.pocketdj.studio.model.StudioNoteEvent
import kotlin.math.abs
import kotlin.math.max
import kotlin.math.min

/** A page-space point (top-left origin, y-down). */
data class Pt(val x: Float, val y: Float)

/** One positioned drawable primitive (iOS `ScoreGlyph`); everything is page-space, top-left origin, y-down. */
sealed interface ScoreGlyph {
    data class Line(val from: Pt, val to: Pt, val width: Float) : ScoreGlyph
    data class NoteHead(val center: Pt, val rx: Float, val ry: Float, val filled: Boolean) : ScoreGlyph
    data class Flags(val tip: Pt, val count: Int, val stemUp: Boolean, val spacing: Float) : ScoreGlyph
    data class Dot(val center: Pt, val radius: Float) : ScoreGlyph
    data class Sharp(val center: Pt, val size: Float) : ScoreGlyph
    data class Flat(val center: Pt, val size: Float) : ScoreGlyph
    data class Rest(val duration: NoteDuration, val center: Pt, val spacing: Float) : ScoreGlyph
    data class Clef(val role: StaffRole, val x: Float, val topLineY: Float, val spacing: Float) : ScoreGlyph
    data class Text(val string: String, val at: Pt, val size: Float, val bold: Boolean) : ScoreGlyph
}

data class LaidMeasure(val measureIndex: Int, val x: Float, val width: Float)
data class LaidStrip(val role: StaffRole, val top: Float)
data class LaidSystem(val strips: List<LaidStrip>, val measures: List<LaidMeasure>, val spacing: Float)
data class ScorePage(val width: Float, val height: Float, val glyphs: List<ScoreGlyph>, val systems: List<LaidSystem> = emptyList())

/** Pure geometry: paginates a [ScoreDocument] into pages of positioned glyphs and inverts taps back to score coordinates. */
object ScoreLayout {
    data class Metrics(
        val pageWidth: Float = 595.2f,
        val pageHeight: Float = 841.8f,
        val margin: Float = 46f,
        val staffSpacing: Float = 7f,
        val measuresPerSystem: Int = 4,
        val clefZoneWidth: Float = 34f,
        val systemGap: Float = 26f,
        val grandStaffGap: Float = 42f,
        val headerHeight: Float = 58f,
    ) {
        val ledgerPad: Float get() = staffSpacing * 3
        companion object { val A4 = Metrics() }
    }

    /** Breathing room between a barline and its first/last head; the ONE constant shared by the forward and both inverse maps. */
    const val MEASURE_HEAD_PAD = 10f

    fun xPosition(onset16ths: Int, measureX: Float, measureWidth: Float): Float =
        xPosition(onset16ths.toDouble(), measureX, measureWidth)

    fun xPosition(fractional16ths: Double, measureX: Float, measureWidth: Float): Float =
        measureX + MEASURE_HEAD_PAD + (measureWidth - 2 * MEASURE_HEAD_PAD) * fractional16ths.toFloat() / 16f

    /** Exact inverse of [xPosition]: x inside a laid measure -> fractional 16th, clamped to 0..16. */
    fun fractional16ths(atX: Float, measureX: Float, measureWidth: Float): Double {
        val inner = measureWidth - 2 * MEASURE_HEAD_PAD
        if (!(inner > 0) || !atX.isFinite()) return 0.0
        val t = ((atX - measureX - MEASURE_HEAD_PAD) * 16f / inner).toDouble()
        if (!t.isFinite()) return 0.0
        return min(max(t, 0.0), 16.0)
    }

    private val LETTER = intArrayOf(0, 0, 1, 1, 2, 3, 3, 4, 4, 5, 5, 6)
    private val SHARPS = booleanArrayOf(false, true, false, true, false, false, true, false, true, false, true, false)

    private fun reference(clef: StaffRole) = if (clef == StaffRole.TREBLE) 30 else 18

    data class StaffPos(val position: Int, val sharp: Boolean)

    /** Diatonic half-line steps above the staff's bottom line; black keys spell as the natural below + a sharp. */
    fun staffPosition(midi: Int, clef: StaffRole): StaffPos {
        val pc = ((midi % 12) + 12) % 12
        val octave = Math.floorDiv(midi, 12) - 1
        val diatonic = octave * 7 + LETTER[pc]
        return StaffPos(diatonic - reference(clef), SHARPS[pc])
    }

    enum class RenderedAccidental { NATURAL, SHARP, FLAT }
    data class SpelledPos(val position: Int, val accidental: RenderedAccidental)

    /** Position + accidental glyph honouring an optional spelling override. */
    fun spelledPosition(midi: Int, clef: StaffRole, accidental: Accidental?): SpelledPos = when (accidental) {
        Accidental.FLAT -> SpelledPos(staffPosition(midi + 1, clef).position, RenderedAccidental.FLAT)
        Accidental.SHARP -> SpelledPos(staffPosition(midi - 1, clef).position, RenderedAccidental.SHARP)
        Accidental.NATURAL, null -> {
            val b = staffPosition(midi, clef)
            SpelledPos(b.position, if (b.sharp) RenderedAccidental.SHARP else RenderedAccidental.NATURAL)
        }
    }

    // ---- hit-testing
    data class Located(val measureIndex: Int, val onset16ths: Int, val staff: StaffRole, val position: Int)
    data class Hit(val system: LaidSystem, val measure: LaidMeasure)

    fun measureAt(p: Pt, page: ScorePage): Hit? {
        if (!p.x.isFinite() || !p.y.isFinite()) return null
        for (sys in page.systems) {
            if (verticalDistance(p.y, sys) != 0f) continue
            val lm = measureIn(sys, p.x) ?: continue
            return Hit(sys, lm)
        }
        return null
    }

    private fun verticalDistance(y: Float, sys: LaidSystem): Float {
        val first = sys.strips.firstOrNull() ?: return Float.POSITIVE_INFINITY
        val last = sys.strips.last()
        val s = sys.spacing
        val top = first.top - 3 * s
        val bottom = last.top + 4 * s + 3 * s
        if (y < top) return top - y
        if (y > bottom) return y - bottom
        return 0f
    }

    private fun measureIn(sys: LaidSystem, x: Float): LaidMeasure? =
        sys.measures.firstOrNull { x >= it.x && x < it.x + it.width }
            ?: sys.measures.minByOrNull { abs(it.x + it.width / 2 - x) }

    private fun nearestMeasure(p: Pt, page: ScorePage): Hit? {
        if (!p.x.isFinite() || !p.y.isFinite()) return null
        val ranked = page.systems.map { it to verticalDistance(p.y, it) }.filter { it.second.isFinite() }.minByOrNull { it.second }
        val sys = ranked?.first ?: return null
        val lm = measureIn(sys, p.x) ?: return null
        return Hit(sys, lm)
    }

    /** Invert a PAGE-space tap into score coordinates; null when off every system. Never Int.MIN: the step count is clamped first. */
    fun locate(p: Pt, page: ScorePage): Located? {
        val hit = measureAt(p, page) ?: return null
        val s = hit.system.spacing
        val strip = hit.system.strips.minByOrNull { abs(it.top + 2 * s - p.y) } ?: return null
        val onset = onsetFromX(p.x, hit.measure.x, hit.measure.width)
        val bottomLine = strip.top + 4 * s
        val steps = Math.rint(((bottomLine - p.y) / (s / 2)).toDouble())
        val position = (if (steps.isFinite()) min(max(steps, -400.0), 400.0) else 0.0).toInt()
        return Located(hit.measure.measureIndex, onset, strip.role, position)
    }

    fun onsetFromX(x: Float, measureX: Float, measureWidth: Float): Int {
        val t = fractional16ths(x, measureX, measureWidth)
        return max(0, min(15, roundHalfAway(t).toInt()))
    }

    private val SEMIS = intArrayOf(0, 2, 4, 5, 7, 9, 11)

    /** Inverse of [staffPosition] for a WHITE key (floor-divides for low ledger notes). */
    fun naturalMidi(position: Int, clef: StaffRole): Int {
        val diatonic = position + reference(clef)
        val octave = Math.floorDiv(diatonic, 7)
        val letter = diatonic - octave * 7
        return (octave + 1) * 12 + SEMIS[letter]
    }

    data class NotePoint(val page: Int, val point: Pt)

    /** Page index + page-space point of a note head (the selection ring). */
    fun notePoint(midi: Int, accidental: Accidental?, absOnset16ths: Int, plan: ClefPlan, pages: List<ScorePage>): NotePoint? {
        val staff = plan.staff(midi)
        val sp = spelledPosition(midi, staff, accidental)
        val measureIndex = absOnset16ths / 16
        val within = absOnset16ths % 16
        for ((pi, page) in pages.withIndex()) {
            for (sys in page.systems) {
                val lm = sys.measures.firstOrNull { it.measureIndex == measureIndex } ?: continue
                val strip = sys.strips.firstOrNull { it.role == staff } ?: continue
                val x = xPosition(within, lm.x, lm.width)
                val y = strip.top + 4 * sys.spacing - sp.position * sys.spacing / 2f
                return NotePoint(pi, Pt(x, y))
            }
        }
        return null
    }

    // ---- playback geometry
    data class Playhead(val page: Int, val x: Float, val top: Float, val bottom: Float)

    /** The cursor for a FRACTIONAL absolute 16th; parks at the last laid measure's end past the score. null for an empty layout / non-finite. */
    fun playhead(fractional16ths: Double, pages: List<ScorePage>): Playhead? {
        if (!fractional16ths.isFinite()) return null
        val pos = min(max(fractional16ths, 0.0), ScorePlayhead.MAX_CURSOR_16THS)
        val measure = (pos / 16).toInt()
        var park: Playhead? = null
        for ((pi, page) in pages.withIndex()) {
            for (sys in page.systems) {
                val firstStrip = sys.strips.firstOrNull() ?: continue
                val lastStrip = sys.strips.last()
                if (sys.measures.isEmpty()) continue
                val pad = 3 * sys.spacing
                val top = firstStrip.top - pad
                val bottom = lastStrip.top + 4 * sys.spacing + pad
                sys.measures.firstOrNull { it.measureIndex == measure }?.let { lm ->
                    val within = pos - measure * 16
                    return Playhead(pi, xPosition(within, lm.x, lm.width), top, bottom)
                }
                val lm = sys.measures.last()
                if (lm.measureIndex < measure) park = Playhead(pi, xPosition(16.0, lm.x, lm.width), top, bottom)
            }
        }
        return park
    }

    /** Inverse of [playhead]: a PAGE-space point -> absolute fractional 16th (nearest system when it misses every band). */
    fun time16ths(p: Pt, page: ScorePage): Double? {
        val hit = measureAt(p, page) ?: nearestMeasure(p, page) ?: return null
        val within = fractional16ths(p.x, hit.measure.x, hit.measure.width)
        val absolute = max(0, hit.measure.measureIndex).toDouble() * 16 + within
        return min(absolute, ScorePlayhead.MAX_CURSOR_16THS)
    }

    data class PlayedMark(val onset16ths: Int, val page: Int, val point: Pt)

    /** Page-space head centers for a whole event stream, onset-ordered; built ONCE per (events, pages). */
    fun playedMarks(events: List<StudioNoteEvent>, bpm: Double, plan: ClefPlan, pages: List<ScorePage>): List<PlayedMark> {
        if (events.isEmpty() || pages.isEmpty()) return emptyList()
        class Cell(val page: Int, val measure: LaidMeasure, val system: LaidSystem)
        val index = HashMap<Int, Cell>()
        for ((pi, page) in pages.withIndex()) for (sys in page.systems) for (lm in sys.measures) if (lm.measureIndex !in index) index[lm.measureIndex] = Cell(pi, lm, sys)
        val out = ArrayList<PlayedMark>(events.size)
        for (e in events) {
            if (e.note !in 0..127) continue
            val abs16 = roundHalfAway(ScorePlayhead.cursor16ths(max(0, e.onMs), bpm)).toInt()
            val cell = index[abs16 / 16] ?: continue
            val staff = plan.staff(e.note)
            val strip = cell.system.strips.firstOrNull { it.role == staff } ?: continue
            val sp = spelledPosition(e.note, staff, e.accidental)
            val x = xPosition(abs16 % 16, cell.measure.x, cell.measure.width)
            val y = strip.top + 4 * cell.system.spacing - sp.position * cell.system.spacing / 2f
            out.add(PlayedMark(abs16, cell.page, Pt(x, y)))
        }
        return out.sortedBy { it.onset16ths }
    }

    // ---- pagination
    private fun blockHeight(plan: ClefPlan, m: Metrics): Float {
        val stripH = 4 * m.staffSpacing
        return if (plan == ClefPlan.GRAND_STAFF) m.ledgerPad + stripH + m.grandStaffGap + stripH + m.ledgerPad else m.ledgerPad + stripH + m.ledgerPad
    }

    /** Lay the score into pages: header (page 1), then systems of up to `measuresPerSystem` bars. An empty score is one header-only page. */
    fun paginate(score: ScoreDocument, title: String, instrument: InstrumentKey, m: Metrics = Metrics.A4): List<ScorePage> {
        val plan = score.clefPlan
        val blockH = blockHeight(plan, m)
        val left = m.margin
        val right = m.pageWidth - m.margin
        val pages = ArrayList<ScorePage>()
        var glyphs = ArrayList<ScoreGlyph>()
        var pageSystems = ArrayList<LaidSystem>()

        val heading = title.trim()
        glyphs.add(ScoreGlyph.Text(heading.ifEmpty { "Untitled take" }, Pt(left, m.margin + 14), 16f, true))
        val bpm = if (score.bpm == Math.rint(score.bpm)) score.bpm.toInt().toString() else String.format(java.util.Locale.US, "%.1f", score.bpm)
        glyphs.add(ScoreGlyph.Text("${instrument.displayName} — $bpm BPM", Pt(left, m.margin + 32), 11f, false))
        var y = m.margin + m.headerHeight

        var start = 0
        while (start < score.measures.size) {
            val chunk = score.measures.subList(start, min(start + m.measuresPerSystem, score.measures.size))
            if (y + blockH > m.pageHeight - m.margin && glyphs.isNotEmpty()) {
                pages.add(ScorePage(m.pageWidth, m.pageHeight, glyphs, pageSystems))
                glyphs = ArrayList(); pageSystems = ArrayList()
                y = m.margin
            }
            appendSystem(chunk, plan, start, y, left, right, m, glyphs, pageSystems)
            y += blockH + m.systemGap
            start += m.measuresPerSystem
        }
        pages.add(ScorePage(m.pageWidth, m.pageHeight, glyphs, pageSystems))
        return pages
    }

    /** One page PER system (no header), for scroll-follow views. */
    fun systems(score: ScoreDocument, instrument: InstrumentKey, m: Metrics = Metrics.A4): List<ScorePage> {
        val plan = score.clefPlan
        val blockH = blockHeight(plan, m)
        val left = m.margin
        val right = m.pageWidth - m.margin
        val pages = ArrayList<ScorePage>()
        var start = 0
        while (start < score.measures.size) {
            val chunk = score.measures.subList(start, min(start + m.measuresPerSystem, score.measures.size))
            val glyphs = ArrayList<ScoreGlyph>()
            val sys = ArrayList<LaidSystem>()
            appendSystem(chunk, plan, start, 0f, left, right, m, glyphs, sys)
            pages.add(ScorePage(m.pageWidth, blockH, glyphs, sys))
            start += m.measuresPerSystem
        }
        return pages
    }

    private data class Strip(val role: StaffRole, val top: Float)

    private fun appendSystem(
        measures: List<ScoreMeasure>, plan: ClefPlan, startIndex: Int, y: Float, left: Float, right: Float, m: Metrics,
        glyphs: MutableList<ScoreGlyph>, systems: MutableList<LaidSystem>,
    ) {
        val s = m.staffSpacing
        val stripH = 4 * s
        val strips = ArrayList<Strip>()
        var stripTop = y + m.ledgerPad
        for (role in plan.staves) { strips.add(Strip(role, stripTop)); stripTop += stripH + m.grandStaffGap }
        val measureWidth = (right - left - m.clefZoneWidth) / m.measuresPerSystem
        val systemRight = left + m.clefZoneWidth + measureWidth * measures.size

        for (strip in strips) {
            for (i in 0 until 5) {
                val ly = strip.top + i * s
                glyphs.add(ScoreGlyph.Line(Pt(left, ly), Pt(systemRight, ly), 0.8f))
            }
            glyphs.add(ScoreGlyph.Clef(strip.role, left + m.clefZoneWidth * 0.4f, strip.top, s))
        }
        val sysTop = strips.first().top
        val sysBottom = strips.last().top + stripH
        if (plan == ClefPlan.GRAND_STAFF) glyphs.add(ScoreGlyph.Line(Pt(left - 3, sysTop), Pt(left - 3, sysBottom), 2.4f))
        glyphs.add(ScoreGlyph.Line(Pt(left, sysTop), Pt(left, sysBottom), 1.1f))
        for (i in measures.indices) {
            val bx = left + m.clefZoneWidth + measureWidth * (i + 1)
            glyphs.add(ScoreGlyph.Line(Pt(bx, sysTop), Pt(bx, sysBottom), 1.1f))
        }
        val laid = ArrayList<LaidMeasure>()
        for ((i, measure) in measures.withIndex()) {
            val mx = left + m.clefZoneWidth + measureWidth * i
            laid.add(LaidMeasure(startIndex + i, mx, measureWidth))
            for (item in measure.items) appendItem(item, plan, strips, xPosition(item.onset16ths, mx, measureWidth), s, glyphs)
        }
        systems.add(LaidSystem(strips.map { LaidStrip(it.role, it.top) }, laid, s))
    }

    private fun appendItem(item: ScoreItem, plan: ClefPlan, strips: List<Strip>, x: Float, s: Float, glyphs: MutableList<ScoreGlyph>) {
        when (val k = item.kind) {
            ScoreKind.Rest -> {
                val middle = strips[0].top + 2 * s
                glyphs.add(ScoreGlyph.Rest(item.duration.base, Pt(x, middle), s))
                if (item.duration.isDotted) glyphs.add(ScoreGlyph.Dot(Pt(x + 1.5f * s, middle - s / 2), 0.19f * s))
            }
            is ScoreKind.Notes -> for (strip in strips) {
                val mine = k.notes.filter { plan.staff(it) == strip.role }
                if (mine.isEmpty()) continue
                appendChord(mine, item.spellings, strip.role, strip.top, x, item.duration, s, glyphs)
            }
        }
    }

    private fun appendChord(
        notes: List<Int>, spellings: Map<Int, Accidental>, clef: StaffRole, top: Float, x: Float, duration: NoteDuration, s: Float,
        glyphs: MutableList<ScoreGlyph>,
    ) {
        val bottomLine = top + 4 * s
        val rx = 0.62f * s
        val ry = 0.45f * s
        val headYs = ArrayList<Float>()
        val positions = ArrayList<Int>()
        val ledgers = HashSet<Int>()
        for (note in notes.sorted()) {
            val sp = spelledPosition(note, clef, spellings[note])
            val hy = bottomLine - sp.position * s / 2f
            positions.add(sp.position); headYs.add(hy)
            when (sp.accidental) {
                RenderedAccidental.SHARP -> glyphs.add(ScoreGlyph.Sharp(Pt(x - 2.6f * rx, hy), s))
                RenderedAccidental.FLAT -> glyphs.add(ScoreGlyph.Flat(Pt(x - 2.6f * rx, hy), s))
                RenderedAccidental.NATURAL -> {}
            }
            glyphs.add(ScoreGlyph.NoteHead(Pt(x, hy), rx, ry, duration.filledHead))
            if (duration.isDotted) {
                val dy = if (sp.position % 2 == 0) hy - s / 2 else hy
                glyphs.add(ScoreGlyph.Dot(Pt(x + rx + 0.5f * s, dy), 0.19f * s))
            }
            if (sp.position <= -2) { var p = -2; while (p >= sp.position) { ledgers.add(p); p -= 2 } }
            if (sp.position >= 10) { var p = 10; while (p <= sp.position) { ledgers.add(p); p += 2 } }
        }
        for (p in ledgers) {
            val ly = bottomLine - p * s / 2f
            glyphs.add(ScoreGlyph.Line(Pt(x - 1.7f * rx, ly), Pt(x + 1.7f * rx, ly), 1.0f))
        }
        if (duration.hasStem) {
            val avg = positions.sum().toDouble() / positions.size
            val up = avg < 4
            val stemLen = 3.4f * s
            val minY = headYs.min()
            val maxY = headYs.max()
            val sx = if (up) x + rx - 0.4f else x - rx + 0.4f
            val tip = Pt(sx, if (up) minY - stemLen else maxY + stemLen)
            glyphs.add(ScoreGlyph.Line(Pt(sx, if (up) maxY else minY), tip, 1.1f))
            if (duration.flags > 0) glyphs.add(ScoreGlyph.Flags(tip, duration.flags, up, s))
        }
    }
}

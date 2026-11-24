package com.levi.pocketdj.screens.history.wheel

import com.levi.pocketdj.data.pockets.wheel.PocketMode
import com.levi.pocketdj.data.pockets.wheel.PocketMoment
import com.levi.pocketdj.data.pockets.wheel.PocketMomentKey
import kotlin.math.abs
import kotlin.math.atan2
import kotlin.math.cos
import kotlin.math.hypot
import kotlin.math.min
import kotlin.math.sin

/**
 * The Pocket Wheel's PURE geometry (iOS `WheelLayout`, design §10.5): ring radii (with the focused-ring fisheye
 * and the Fri|Sat weekend gap), the cell -> sliver split, and polar hit-testing. Built once per
 * (radius, focus, mode filter, snapshot) and remembered; the Canvas draws only from it.
 *
 * Angles: radians measured CLOCKWISE from 12 o'clock (midnight at the top), 15 degrees per hour.
 * Screen point for (r, a): centre + r * (sin a, -cos a). Units are whatever the caller passes (px in the UI).
 */
class WheelLayout(
    val radius: Double,
    focusedDow: Int,
    val modeFilter: PocketMode?,
    moments: List<PocketMoment>,
) {
    data class Pt(val x: Double, val y: Double)

    /** [dow]: 1 = Monday (innermost) .. 7 = Sunday (outermost). */
    data class Ring(val dow: Int, val inner: Double, val outer: Double, val focused: Boolean) {
        val mid: Double get() = (inner + outer) / 2
        val thickness: Double get() = outer - inner
    }

    /** Angles in radians; [share] is of the cell's arc. */
    data class Sliver(val key: PocketMomentKey, val start: Double, val end: Double, val share: Double)

    data class Cell(val dow: Int, val hour: Int, val slivers: List<Sliver>)

    sealed interface Hit {
        data object Center : Hit
        data class CellHit(val dow: Int, val hour: Int, val key: PocketMomentKey?) : Hit
        data object Outside : Hit
    }

    val rings: List<Ring> = rings(radius, focusedDow)
    val cells: List<Cell>
    val holeRadius: Double get() = radius * HOLE_FRACTION

    // Lookups built once (the hit-test runs on every drag event).
    private val cellIndex: Map<Int, Cell>

    init {
        val byCell = java.util.TreeMap<Int, MutableList<PocketMoment>>()
        for (m in moments) {
            if (!(m.plays > 0 || m.skips > 0)) continue
            if (modeFilter != null && m.key.mode != modeFilter) continue
            byCell.getOrPut((m.key.dow - 1) * 24 + m.key.hour) { ArrayList() }.add(m)
        }
        cells = byCell.map { (idx, ms) ->
            val dow = idx / 24 + 1
            val hour = idx % 24
            Cell(dow, hour, slivers(hour, ms))
        }
        cellIndex = cells.associateBy { (it.dow - 1) * 24 + it.hour }
    }

    fun ring(dow: Int): Ring? = rings.firstOrNull { it.dow == dow }
    fun cell(dow: Int, hour: Int): Cell? = cellIndex[(dow - 1) * 24 + hour]

    /**
     * Polar hit-test: (r, a) -> ring -> hour -> sliver. A point in a ring gap belongs to the nearer ring; inside the
     * hole is the centre button; beyond the rim is outside.
     */
    fun hit(p: Pt, c: Pt): Hit {
        val r = hypot(p.x - c.x, p.y - c.y)
        if (r < holeRadius) return Hit.Center
        if (r > radius) return Hit.Outside
        val ring = rings.minByOrNull { distance(r, it) } ?: return Hit.Outside
        val a = angleOf(p, c)
        val hour = min(23, (a / angleForHour(1.0)).toInt())
        val cell = cell(ring.dow, hour)
        val key = cell?.slivers?.firstOrNull { a >= it.start && a < it.end }?.key ?: cell?.slivers?.lastOrNull()?.key
        return Hit.CellHit(ring.dow, hour, key)
    }

    private fun distance(r: Double, ring: Ring): Double =
        if (r >= ring.inner && r <= ring.outer) 0.0 else min(abs(r - ring.inner), abs(r - ring.outer))

    override fun equals(other: Any?): Boolean =
        other is WheelLayout && radius == other.radius && modeFilter == other.modeFilter &&
            rings == other.rings && cells == other.cells

    override fun hashCode(): Int = ((radius.hashCode() * 31 + (modeFilter?.hashCode() ?: 0)) * 31 + rings.hashCode()) * 31 + cells.hashCode()

    companion object {
        const val HOLE_FRACTION = 0.30
        const val FOCUS_SCALE = 1.8
        const val WEEKEND_GAP_FRACTION = 0.025
        const val RING_GAP_FRACTION = 0.006
        const val MAX_SLIVERS = 3
        const val MIN_SLIVER_SHARE = 0.2

        fun rings(radius: Double, focusedDow: Int): List<Ring> {
            val hole = radius * HOLE_FRACTION
            val weekendGap = radius * WEEKEND_GAP_FRACTION
            val ringGap = radius * RING_GAP_FRACTION
            val usable = radius - hole - weekendGap - ringGap * 6
            val unit = usable / (6 + FOCUS_SCALE)
            var r = hole
            val out = ArrayList<Ring>(7)
            for (dow in 1..7) {
                if (dow == 6) r += weekendGap
                val t = unit * (if (dow == focusedDow) FOCUS_SCALE else 1.0)
                out += Ring(dow, r, r + t, dow == focusedDow)
                r += t + (if (dow < 7) ringGap else 0.0)
            }
            return out
        }

        /**
         * One (hour, day) cell's slivers: the top 3 modes by plays, in the fixed precedence order, each width
         * proportional to plays with a 20 % floor. One mode => one full sector.
         */
        fun slivers(hour: Int, moments: List<PocketMoment>): List<Sliver> {
            val top = moments
                .sortedWith { a, b -> if (a.plays != b.plays) b.plays.compareTo(a.plays) else a.key.mode.rank.compareTo(b.key.mode.rank) }
                .take(MAX_SLIVERS)
                .sortedBy { it.key.mode.rank }
            val shares = sliverShares(top.map { maxOf(it.plays, 1e-9) })
            val a0 = angleForHour(hour.toDouble())
            val span = angleForHour(1.0)
            val out = ArrayList<Sliver>(top.size)
            var cursor = a0
            for ((m, s) in top.zip(shares)) {
                out += Sliver(m.key, cursor, cursor + span * s, s)
                cursor += span * s
            }
            return out
        }

        /**
         * Proportional shares with a floor: below-floor entries are lifted to the floor and the rest rescaled over
         * what remains (iterated until stable - at most `count` passes).
         */
        fun sliverShares(weights: List<Double>): List<Double> {
            if (weights.isEmpty()) return emptyList()
            if (weights.size == 1) return listOf(1.0)
            val floor = MIN_SLIVER_SHARE
            val fixed = HashSet<Int>()
            val total = weights.sum()
            val shares = weights.map { it / total }.toMutableList()
            repeat(weights.size) {
                val low = shares.indices.filter { it !in fixed && shares[it] < floor }
                if (low.isEmpty()) return@repeat
                fixed += low
                val free = shares.indices.filter { it !in fixed }
                val remaining = 1 - fixed.size * floor
                val freeTotal = free.sumOf { weights[it] }
                for (i in shares.indices) {
                    shares[i] = if (i in fixed) floor else if (freeTotal > 0) remaining * weights[i] / freeTotal else 0.0
                }
            }
            return shares
        }

        fun angleForHour(h: Double): Double = h / 24 * 2 * Math.PI

        /** Clockwise-from-12 angle of [p] relative to [c], in [0, 2 pi). */
        fun angleOf(p: Pt, c: Pt): Double {
            var a = atan2(p.x - c.x, -(p.y - c.y))
            if (a < 0) a += 2 * Math.PI
            return a
        }

        fun point(radius: Double, angle: Double, c: Pt): Pt = Pt(c.x + radius * sin(angle), c.y - radius * cos(angle))
    }
}

/** TalkBack / test text for the wheel (iOS `PocketWheelAccessibility`, pure parts). */
object WheelAccessibility {
    /** The spoken value for one (day, hour) cell. */
    fun value(dow: Int, hour: Int, layout: WheelLayout, index: Map<PocketMomentKey, PocketMoment>, names: Map<String, String>): String {
        val h = PocketMomentKey.hourLabel(hour)
        val cell = layout.cell(dow, hour)
        if (cell == null || cell.slivers.isEmpty()) return "$h, nothing yet"
        val parts = cell.slivers.mapNotNull { s ->
            val m = index[s.key] ?: return@mapNotNull null
            val coll = m.dominantCollectionId?.let { names[it] } ?: "mixed"
            val skip = Math.round(m.skipRate * 100).toInt()
            m.plays to "${s.key.mode.label}: $coll, ${m.directPlays} plays, $skip% skips"
        }.sortedByDescending { it.first }.map { it.second }
        val first = parts.firstOrNull() ?: return "$h, nothing yet"
        return "$h, $first" + if (parts.size > 1) "; also " + parts.drop(1).joinToString("; ") else ""
    }

    /** Hours with a recurring pocket on this ring. */
    fun recurringHours(dow: Int, layout: WheelLayout, index: Map<PocketMomentKey, PocketMoment>): List<Int> =
        layout.cells.filter { c -> c.dow == dow && c.slivers.any { index[it.key]?.isRecurring == true } }.map { it.hour }

    /** The cell's busiest mode key (what the ring's default action opens). */
    fun busiestKey(dow: Int, hour: Int, layout: WheelLayout, index: Map<PocketMomentKey, PocketMoment>): PocketMomentKey? =
        layout.cell(dow, hour)?.slivers?.maxByOrNull { index[it.key]?.plays ?: 0.0 }?.key

    fun nextHour(h: Int, delta: Int): Int = (((h + delta) % 24) + 24) % 24
}

package com.levi.pocketdj.screens.history.wheel

import com.levi.pocketdj.data.pockets.wheel.PocketMode
import com.levi.pocketdj.data.pockets.wheel.PocketMoment
import com.levi.pocketdj.data.pockets.wheel.PocketMomentKey
import org.junit.Assert.assertEquals
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test

/** Port of iOS WheelLayoutTests: ring radii (fisheye + weekend gap), polar hit-test, sliver widths + 20 % floor. */
class WheelLayoutTest {
    private val c = WheelLayout.Pt(200.0, 200.0)

    private fun moment(dow: Int, hour: Int, mode: PocketMode, plays: Double) =
        PocketMoment(key = PocketMomentKey(hour, dow, mode), plays = plays)

    private fun at(radius: Double, hour: Double) = WheelLayout.point(radius, WheelLayout.angleForHour(hour), c)

    @Test fun ringsMondayInnermostFocusedThickerWeekendGap() {
        val l = WheelLayout(175.0, 2, null, emptyList())
        assertEquals((1..7).toList(), l.rings.map { it.dow })
        assertEquals(175 * WheelLayout.HOLE_FRACTION, l.rings[0].inner, 0.001)
        assertEquals(175.0, l.rings[6].outer, 0.001)
        val unfocused = l.rings[0].thickness
        assertEquals(WheelLayout.FOCUS_SCALE, l.rings[1].thickness / unfocused, 0.0001)
        assertTrue(l.rings[1].focused)
        assertTrue(l.rings.count { it.focused } == 1)
        for (i in 0 until 6) assertTrue("rings never overlap", l.rings[i].outer < l.rings[i + 1].inner)
        val weekdayGap = l.rings[4].inner - l.rings[3].outer
        val weekendGap = l.rings[5].inner - l.rings[4].outer
        assertTrue("Fri | Sat gap marks the weekend", weekendGap > weekdayGap * 3)
        // The design numbers on a 390 dp phone (R = 175): focused ~ 26, others ~ 14.
        assertEquals(26.0, l.rings[1].thickness, 3.0)
        assertEquals(14.0, unfocused, 2.0)
    }

    @Test fun focusingAnotherDayMovesTheFisheyeButKeepsTheRim() {
        for (f in listOf(1, 4, 7)) {
            val l = WheelLayout(200.0, f, null, emptyList())
            assertEquals(f, l.rings.single { it.focused }.dow)
            assertEquals(200.0, l.rings.last().outer, 1e-9)
        }
        // An out-of-range focus (nothing focused) still tiles the full usable width without crashing.
        assertTrue(WheelLayout(200.0, 0, null, emptyList()).rings.none { it.focused })
    }

    @Test fun anglesAndPointsRoundTrip() {
        assertEquals(Math.PI / 2, WheelLayout.angleForHour(6.0), 1e-12)
        val top = WheelLayout.point(100.0, 0.0, c)
        assertEquals(200.0, top.x, 1e-9); assertEquals(100.0, top.y, 1e-9)
        val right = WheelLayout.point(100.0, Math.PI / 2, c)
        assertEquals(300.0, right.x, 1e-9); assertEquals(200.0, right.y, 1e-9)
        var a = 0.01
        while (a < 2 * Math.PI) {
            assertEquals(a, WheelLayout.angleOf(WheelLayout.point(80.0, a, c), c), 1e-9)
            a += 0.37
        }
    }

    @Test fun hitTestRingsHoursAndBoundaries() {
        val ms = listOf(moment(2, 8, PocketMode.CAR_PLAY, 5.0), moment(2, 9, PocketMode.MIX, 2.0), moment(7, 23, PocketMode.COLLECTION, 1.0))
        val l = WheelLayout(175.0, 2, null, ms)
        assertEquals(WheelLayout.Hit.Center, l.hit(c, c))
        assertEquals(WheelLayout.Hit.Outside, l.hit(WheelLayout.Pt(200.0, 200.0 - 176), c))
        val tue = l.rings[1]
        assertEquals(WheelLayout.Hit.CellHit(2, 8, PocketMomentKey(8, 2, PocketMode.CAR_PLAY)), l.hit(at(tue.mid, 8.5), c))
        assertEquals(
            WheelLayout.Hit.CellHit(2, 9, PocketMomentKey(9, 2, PocketMode.MIX)),
            l.hit(WheelLayout.point(tue.mid, WheelLayout.angleForHour(9.0) + 1e-6, c), c),
        )
        val sun = l.rings[6]
        assertEquals(
            WheelLayout.Hit.CellHit(7, 23, PocketMomentKey(23, 7, PocketMode.COLLECTION)),
            l.hit(WheelLayout.point(sun.mid, 2 * Math.PI - 1e-6, c), c),
        )
        // An empty cell hits with no key.
        assertEquals(WheelLayout.Hit.CellHit(4, 3, null), l.hit(at(l.rings[3].mid, 3.5), c))
        // A point in the gap between Mon and Tue snaps to the nearer ring.
        val gapMid = (l.rings[0].outer + l.rings[1].inner) / 2
        val h = l.hit(WheelLayout.point(gapMid + 0.1, 1.0, c), c) as WheelLayout.Hit.CellHit
        assertEquals(2, h.dow)
        val h2 = l.hit(WheelLayout.point(gapMid - 0.1, 1.0, c), c) as WheelLayout.Hit.CellHit
        assertEquals(1, h2.dow)
    }

    @Test fun midnightIsAtTwelveOClockAndAdvancesClockwise() {
        val l = WheelLayout(175.0, 1, null, listOf(moment(1, 0, PocketMode.BROWSE, 1.0), moment(1, 6, PocketMode.MIX, 1.0)))
        val mon = l.rings[0]
        // Just right of straight up = hour 0; straight right (3 o'clock) = hour 6; straight down = 12; left = 18.
        val up = l.hit(WheelLayout.Pt(c.x + 0.5, c.y - mon.mid), c) as WheelLayout.Hit.CellHit
        assertEquals(0, up.hour)
        val right = l.hit(WheelLayout.Pt(c.x + mon.mid, c.y + 0.01), c) as WheelLayout.Hit.CellHit
        assertEquals(6, right.hour)
        val down = l.hit(WheelLayout.Pt(c.x - 0.01, c.y + mon.mid), c) as WheelLayout.Hit.CellHit
        assertEquals(12, down.hour)
        val left = l.hit(WheelLayout.Pt(c.x - mon.mid, c.y - 0.01), c) as WheelLayout.Hit.CellHit
        assertEquals(18, left.hour)
    }

    @Test fun sliverSharesAndFloor() {
        assertEquals(listOf(1.0), WheelLayout.sliverShares(listOf(3.0)))
        assertEquals(listOf(0.5, 0.5), WheelLayout.sliverShares(listOf(1.0, 1.0)))
        val s = WheelLayout.sliverShares(listOf(10.0, 1.0, 1.0))
        assertEquals(0.6, s[0], 1e-9); assertEquals(0.2, s[1], 1e-9); assertEquals(0.2, s[2], 1e-9)
        val t = WheelLayout.sliverShares(listOf(6.0, 3.0, 1.0))
        assertEquals(1.0, t.sum(), 1e-9)
        assertEquals("floored", 0.2, t[2], 1e-9)
        assertEquals("the rest stay proportional", 2.0, t[0] / t[1], 1e-9)
        assertTrue(WheelLayout.sliverShares(emptyList()).isEmpty())
    }

    @Test fun cellSplitsIntoTopThreeModesInPrecedenceOrder() {
        val ms = listOf(
            moment(3, 21, PocketMode.COLLECTION, 1.0), moment(3, 21, PocketMode.MIX, 8.0),
            moment(3, 21, PocketMode.CAR_PLAY, 3.0), moment(3, 21, PocketMode.BROWSE, 0.5),
        )
        val l = WheelLayout(175.0, 3, null, ms)
        val cell = l.cell(3, 21)!!
        assertEquals(listOf(PocketMode.CAR_PLAY, PocketMode.MIX, PocketMode.COLLECTION), cell.slivers.map { it.key.mode })
        assertEquals(WheelLayout.angleForHour(21.0), cell.slivers.first().start, 1e-12)
        assertEquals(WheelLayout.angleForHour(22.0), cell.slivers.last().end, 1e-9)
        assertTrue(cell.slivers.minOf { it.share } >= 0.2 - 1e-9)
        for (i in 0 until cell.slivers.size - 1) assertEquals(cell.slivers[i].end, cell.slivers[i + 1].start, 1e-12)
    }

    @Test fun modeFilterShowsOnlyThatModeFullWidth() {
        val ms = listOf(moment(6, 9, PocketMode.RUNNING, 4.0), moment(6, 9, PocketMode.COLLECTION, 9.0), moment(2, 8, PocketMode.CAR_PLAY, 3.0))
        val l = WheelLayout(175.0, 6, PocketMode.RUNNING, ms)
        assertEquals(1, l.cells.size)
        assertEquals(listOf(PocketMode.RUNNING), l.cells[0].slivers.map { it.key.mode })
        assertEquals(1.0, l.cells[0].slivers[0].share, 0.0)
    }

    @Test fun momentsWithNoPlaysOrSkipsAreNotDrawnButSkipOnlyOnesAre() {
        val skipOnly = PocketMoment(key = PocketMomentKey(5, 1, PocketMode.MIX), plays = 0.0, skips = 2.0)
        val empty = PocketMoment(key = PocketMomentKey(6, 1, PocketMode.MIX))
        val l = WheelLayout(175.0, 1, null, listOf(skipOnly, empty))
        assertEquals(listOf(5), l.cells.map { it.hour })
        assertNull(l.cell(1, 6))
    }

    @Test fun equalLayoutsCompareEqual() {
        val ms = listOf(moment(2, 8, PocketMode.MIX, 3.0))
        assertEquals(WheelLayout(100.0, 2, null, ms), WheelLayout(100.0, 2, null, ms))
        assertTrue(WheelLayout(100.0, 2, null, ms) != WheelLayout(100.0, 3, null, ms))
    }

    @Test fun accessibilityValueNamesModesCollectionsAndCounts() {
        val a = moment(2, 8, PocketMode.CAR_PLAY, 10.0).copy(dominantCollectionId = "pl_pot", directPlays = 23)
        val b = moment(2, 8, PocketMode.MIX, 3.0).copy(dominantCollectionId = "pkt_late", directPlays = 6)
        val l = WheelLayout(175.0, 2, null, listOf(a, b))
        val names = mapOf("pl_pot" to "Potential", "pkt_late" to "Late Night")
        val v = WheelAccessibility.value(2, 8, l, mapOf(a.key to a, b.key to b), names)
        assertTrue(v, v.startsWith("8 AM, CarPlay: Potential, 23 plays"))
        assertTrue(v, v.contains("also Mix: Late Night, 6 plays"))
        assertEquals("3 AM, nothing yet", WheelAccessibility.value(1, 3, l, emptyMap(), emptyMap()))
        assertEquals(a.key, WheelAccessibility.busiestKey(2, 8, l, mapOf(a.key to a, b.key to b)))
    }

    @Test fun recurringHoursAndHourStepping() {
        val rec = moment(2, 8, PocketMode.MIX, 3.0).copy(distinctDays = 3)
        val one = moment(2, 9, PocketMode.MIX, 3.0).copy(distinctDays = 1)
        val l = WheelLayout(175.0, 2, null, listOf(rec, one))
        assertEquals(listOf(8), WheelAccessibility.recurringHours(2, l, mapOf(rec.key to rec, one.key to one)))
        assertEquals(0, WheelAccessibility.nextHour(23, 1))
        assertEquals(23, WheelAccessibility.nextHour(0, -1))
    }

    @Test fun paintOpacityFollowsConfidenceOneOffsDesaturateAndLegendDims() {
        val swatch = com.levi.pocketdj.data.pockets.wheel.PocketSwatch.Slot(0)
        val recurring = moment(1, 1, PocketMode.MIX, 6.0).copy(distinctDays = 3)
        val oneOff = recurring.copy(distinctDays = 1)
        val full = PocketWheelPaint.fill(recurring, swatch, dimmed = false)
        assertEquals(0.25 + 0.75 * recurring.confidence, full.a, 1e-12)
        val (r, g, b) = swatch.rgb(dark = true)
        assertEquals(r, full.r, 1e-12); assertEquals(g, full.g, 1e-12); assertEquals(b, full.b, 1e-12)
        val faded = PocketWheelPaint.fill(oneOff, swatch, dimmed = false)
        val lum = 0.2126 * r + 0.7152 * g + 0.0722 * b
        assertEquals((r + lum) / 2, faded.r, 1e-12)
        assertTrue("one-offs sit between the colour and its grey", Math.abs(faded.r - lum) < Math.abs(r - lum))
        assertEquals(full.a * 0.18, PocketWheelPaint.fill(recurring, swatch, dimmed = true).a, 1e-12)
        assertEquals("12a", PocketWheelPaint.hourTick(0)); assertEquals("6a", PocketWheelPaint.hourTick(6))
        assertEquals("12p", PocketWheelPaint.hourTick(12)); assertEquals("6p", PocketWheelPaint.hourTick(18))
    }

    @Test fun modeChipsCoverEveryModeOnceInTheDesignOrder() {
        assertEquals(PocketMode.entries.toSet(), CHIP_MODES.toSet())
        assertEquals(PocketMode.entries.size, CHIP_MODES.size)
        assertEquals(listOf("Car", "Trip", "Run", "Walk", "Mix", "Browse", "Home"), CHIP_MODES.map { chipLabel(it) })
    }

    @Test fun runProgressIsNullWithoutAnActiveOrWhenFinished() {
        assertNull(PocketWheelActions.progressOf(null))
        val run = com.levi.pocketdj.data.pockets.wheel.PocketRunStore.RunState(
            runId = "r", momentKey = "h08|d2|carPlay", label = "x", seed = "1",
            profile = com.levi.pocketdj.data.pockets.wheel.PocketProfile(com.levi.pocketdj.data.pockets.wheel.PocketProfile.Tier.RICH, caption = "c", detail = "d"),
            playedThrough = 12, startedAtMs = 0.0,
        )
        val p = PocketWheelActions.progressOf(run)!!
        assertEquals(12, p.done); assertEquals(100, p.total); assertEquals(PocketMomentKey(8, 2, PocketMode.CAR_PLAY), p.key)
        assertNull(PocketWheelActions.progressOf(run.copy(finished = true)))
    }
}

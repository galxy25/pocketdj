package com.levi.pocketdj.data.location

import com.levi.pocketdj.data.location.DwellDetector.Fix
import com.levi.pocketdj.data.location.DwellDetector.Output
import org.junit.Test
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue

class DwellDetectorTest {
    private val min = 60_000L
    private fun fix(lat: Double, lon: Double, acc: Double, atMin: Long) = Fix(lat, lon, acc, atMin * min)
    // ~0.001 deg lat = 111 m
    private val home = 37.8 to -122.4

    @Test fun minDwell() {
        val d = DwellDetector()
        assertTrue(d.onFix(fix(home.first, home.second, 20.0, 0)).isEmpty())
        assertTrue(d.onFix(fix(home.first + 0.0002, home.second, 20.0, 4)).isEmpty())
        val out = d.onFix(fix(home.first, home.second, 20.0, 5))
        assertEquals(1, out.size)
        val v = (out[0] as Output.Visit).sample
        assertEquals(0L, v.arrivalMs)
        assertEquals(null, v.departureMs)
        assertTrue(d.hasOpenVisit)
        // no duplicate open visit while still there
        assertTrue(d.onFix(fix(home.first, home.second, 20.0, 9)).isEmpty())
    }

    @Test fun radiusClose() {
        val d = DwellDetector()
        d.onFix(fix(home.first, home.second, 20.0, 0))
        d.onFix(fix(home.first, home.second, 20.0, 6))
        d.onFix(fix(home.first, home.second, 20.0, 10))
        // 0.0015 deg = ~167 m: inside radius + accuracy(30) = 180 -> ambiguous, no close
        assertTrue(d.onFix(fix(home.first + 0.0015, home.second, 30.0, 12)).isEmpty())
        assertTrue(d.hasOpenVisit)
        // far away: closes with departure = last in-radius fix, plus a hint
        val out = d.onFix(fix(home.first + 0.01, home.second, 30.0, 20))
        assertEquals(2, out.size)
        val v = (out[0] as Output.Visit).sample
        assertEquals(0L, v.arrivalMs)
        assertEquals(10 * min, v.departureMs)
        assertTrue(out[1] is Output.Hint)
        assertTrue(!d.hasOpenVisit)
    }

    @Test fun accuracyFilter() {
        val d = DwellDetector()
        d.onFix(fix(home.first, home.second, 20.0, 0))
        // worse than 3000 m: ignored entirely
        assertTrue(d.onFix(fix(home.first + 0.5, home.second, 3_500.0, 3)).isEmpty())
        // a 500 m fix never anchors or extends a stay, even right at the anchor
        assertTrue(d.onFix(fix(home.first, home.second, 500.0, 6)).isEmpty())
        assertTrue(!d.hasOpenVisit)
        // a coarse far fix is only a hint, and does not move the anchor
        val out = d.onFix(fix(home.first + 0.1, home.second, 500.0, 7))
        assertEquals(1, out.size)
        assertTrue(out[0] is Output.Hint)
        // anchor still home: a good fix at home at minute 8 completes the dwell from minute 0
        val v = d.onFix(fix(home.first, home.second, 20.0, 8))
        assertEquals(0L, ((v.single()) as Output.Visit).sample.arrivalMs)
    }

    @Test fun hintOnlyCloses() {
        val d = DwellDetector()
        d.onFix(fix(home.first, home.second, 20.0, 0))
        // moved away before 5 min: no visit was ever emitted, only a hint
        val out = d.onFix(fix(home.first + 0.01, home.second, 30.0, 3))
        assertEquals(1, out.size)
        assertTrue(out[0] is Output.Hint)
        // new anchor restarts the clock
        assertTrue(d.onFix(fix(home.first + 0.01, home.second, 30.0, 7)).isEmpty())
        assertEquals(1, d.onFix(fix(home.first + 0.01, home.second, 30.0, 8)).size)
    }

    @Test fun emittedSamplesFeedEngine() {
        val d = DwellDetector()
        val e = ListeningPlaceEngine()
        var n = 0
        fun feed(o: List<Output>) = o.forEach {
            when (it) {
                is Output.Visit -> e.ingest(it.sample, 1_000 * min) { "id${n++}" }
                is Output.Hint -> e.noteMovement(it.sample, 1_000 * min) { "id${n++}" }
            }
        }
        feed(d.onFix(fix(home.first, home.second, 20.0, 0)))
        feed(d.onFix(fix(home.first, home.second, 20.0, 6)))
        feed(d.onFix(fix(home.first + 0.01, home.second, 20.0, 30)))
        assertEquals(1, e.places.size)
        assertEquals(30 * 0 + 6 * min, e.timeline.single().endMs)
    }

    @Test fun coarseOnlyYieldsHintsButNoVisits() {
        val d = DwellDetector()
        // ~2 km accuracy fixes: first sets the provisional anchor, repeats in place do nothing
        assertTrue(d.onFix(fix(home.first, home.second, 2000.0, 0)).isEmpty())
        assertTrue(d.onFix(fix(home.first, home.second, 2000.0, 20)).isEmpty())
        assertTrue(d.onFix(fix(home.first, home.second, 2000.0, 40)).isEmpty())
        assertFalse(d.hasOpenVisit)
        // ~11 km away: a movement hint, never a visit
        val out = d.onFix(fix(home.first + 0.1, home.second, 2000.0, 60))
        assertEquals(1, out.size)
        assertTrue(out[0] is Output.Hint)
        assertFalse(d.hasOpenVisit)
        assertEquals(null, d.snapshot())
    }

    @Test fun snapshotRestoreResumesStayAfterProcessDeath() {
        val d1 = DwellDetector()
        d1.onFix(fix(home.first, home.second, 20.0, 0))
        d1.onFix(fix(home.first, home.second, 20.0, 6)) // open visit emitted
        val snap = d1.snapshot()
        val d2 = DwellDetector() // fresh process
        d2.restore(snap)
        assertTrue(d2.hasOpenVisit)
        val out = d2.onFix(fix(home.first + 0.01, home.second, 30.0, 30))
        assertEquals(2, out.size)
        assertEquals(6L * min, ((out[0] as Output.Visit).sample.departureMs))
        assertTrue(out[1] is Output.Hint)
        // a stationary phone with only poll-rate fixes in fresh processes still reaches the dwell
        val d3 = DwellDetector(); d3.onFix(fix(home.first, home.second, 20.0, 0))
        val d4 = DwellDetector(); d4.restore(d3.snapshot())
        assertTrue(d4.onFix(fix(home.first, home.second, 20.0, 15)).single() is Output.Visit)
        DwellDetector().restore("garbage") // never throws
    }
}

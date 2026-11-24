package com.levi.pocketdj.data.motion

import com.levi.pocketdj.data.history.PlayEvent
import com.levi.pocketdj.data.pockets.wheel.MotionToken
import java.io.File
import org.junit.Assert.*
import org.junit.Rule
import org.junit.Test
import org.junit.rules.TemporaryFolder

/** Port of iOS MotionSettleTests (pure rule + store behaviour with a scripted timeline). */
class MotionSettleTest {
    @get:Rule val tmp = TemporaryFolder()
    private val t0 = 1_793_115_000_000L
    private fun seg(fromMinAgo: Double, toMinAgo: Double, a: String, conf: Int = 2) =
        MotionSegment(t0 - (fromMinAgo * 60_000).toLong(), t0 - (toMinAgo * 60_000).toLong(), a, conf)
    private fun play(id: String, minAgo: Double, minutes: Double = 3.0) =
        MotionSettle.Play(id, t0 - minAgo * 60_000, minutes * 60_000)

    @Test fun mostOverlapWins() {
        val p = play("p", 30.0, 4.0)
        val segs = listOf(seg(31.0, 29.0, MotionToken.WALKING), seg(29.0, 20.0, MotionToken.RUNNING))
        assertEquals("running", MotionSettle.settle(listOf(p), segs, t0.toDouble())["p"])
    }

    @Test fun lowConfidenceIgnored() {
        val p = play("p", 30.0, 4.0)
        val segs = listOf(seg(31.0, 20.0, "running", 0), seg(28.0, 27.0, "walking", 1))
        assertEquals("walking", MotionSettle.settle(listOf(p), segs, t0.toDouble())["p"])
        assertTrue(MotionSettle.settle(listOf(p), listOf(seg(31.0, 20.0, "running", 0)), t0.toDouble()).isEmpty())
    }

    @Test fun tiesGoToMoreActiveState() {
        val p = play("p", 30.0, 4.0)
        assertEquals("walking", MotionSettle.settle(listOf(p), listOf(seg(30.0, 28.0, "automotive"), seg(28.0, 26.0, "walking")), t0.toDouble())["p"])
        assertEquals("cycling", MotionSettle.settle(listOf(p), listOf(seg(30.0, 28.0, "stationary"), seg(28.0, 26.0, "cycling")), t0.toDouble())["p"])
        assertEquals("automotive", MotionSettle.settle(listOf(p), listOf(seg(30.0, 28.0, "stationary"), seg(28.0, 26.0, "automotive")), t0.toDouble())["p"])
    }

    @Test fun pendingAndHorizon() {
        val fresh = play("fresh", 1.0, 0.5)
        val ongoing = play("ongoing", 3.0, 4.0)
        val old = MotionSettle.Play("old", t0 - 7 * 86_400_000.0, 180_000.0)
        val segs = listOf(MotionSegment(t0 - 8 * 86_400_000L, t0, "running", 2))
        val out = MotionSettle.settle(listOf(fresh, ongoing, old), segs, t0.toDouble())
        assertNull(out["fresh"]); assertNull(out["ongoing"]); assertNull(out["old"])
        assertEquals("running", MotionSettle.settle(listOf(play("ok", 10.0)), segs, t0.toDouble())["ok"])
    }

    @Test fun noOverlapLeavesUnsettled() {
        assertTrue(MotionSettle.settle(listOf(play("p", 60.0)), listOf(seg(30.0, 10.0, "running")), t0.toDouble()).isEmpty())
    }

    @Test fun durationEstimate() {
        assertEquals(180_000.0, MotionSettle.duration(null, null), 0.0)
        assertEquals(240_000.0, MotionSettle.duration(240_000, null), 0.0)
        assertEquals(120_000.0, MotionSettle.duration(240_000, 0.5), 0.0)
        assertEquals(30_000.0, MotionSettle.duration(240_000, 0.01), 0.0)
    }

    @Test fun currentIsLatestQualifying() {
        assertEquals("running", MotionSettle.current(listOf(seg(5.0, 3.0, "walking"), seg(3.0, 0.0, "running"), seg(2.0, 0.0, "automotive", 0))))
        assertNull(MotionSettle.current(listOf(seg(5.0, 0.0, "running", 0))))
    }

    // ---- store ----
    private class FakeSource : ListeningMotionStore.Source {
        var registers = 0; var unregisters = 0
        override fun register() { registers++ }
        override fun unregister() { unregisters++ }
    }
    private fun event(id: String, minAgo: Double, origin: String? = "me") = PlayEvent(
        id = id, songId = "s_$id", playedAt = t0 - minAgo * 60_000, originInstallId = origin,
    )

    private fun fixture(permitted: Boolean = true): Triple<ListeningMotionStore, MotionTimelineStore, FakeSource> {
        val tl = MotionTimelineStore(File(tmp.root, "tl.json")) { t0 }
        tl.onTransition("running", true, t0 - 120 * 60_000)
        val src = FakeSource()
        val st = ListeningMotionStore(File(tmp.root, "lm.json"), tl, { permitted }, src) { t0 }
        return Triple(st, tl, src)
    }

    @Test fun settlesOwnUnsettledPlaysOnlyAndIsWriteOnce() {
        val (st, _, src) = fixture()
        st.setEnabled(true)
        assertEquals(1, src.registers)
        val events = listOf(event("mine", 30.0), event("peer", 30.0, "peer"))
        val stamped = HashMap<String, String>()
        val n = st.settle(events, { it.originInstallId == "me" }, { 200_000 }) { stamped += it; it.size }
        assertEquals(1, n)
        assertEquals(mapOf("mine" to "running"), stamped)
        // already-settled play is skipped
        val again = st.settle(listOf(event("mine", 30.0).copy(motion = "running")), { true }, { 200_000 }) { error("no stamp") }
        assertEquals(0, again)
        assertEquals("running", st.currentActivity())
    }

    @Test fun inertWhenOffOrDenied() {
        val (off, _, _) = fixture()
        assertFalse(off.isEnabled)
        assertEquals(0, off.settle(listOf(event("a", 30.0)), { true }, { null }) { error("no") })
        val (denied, _, src) = fixture(permitted = false)
        denied.setEnabled(true)
        assertTrue(denied.isEnabled); assertFalse(denied.isActive)
        assertEquals(0, src.registers)
        assertEquals(0, denied.settle(listOf(event("a", 30.0)), { true }, { null }) { error("no") })
        assertNull(denied.currentActivity())
        // opt-in persists across instances
        assertTrue(ListeningMotionStore.readEnabled(File(tmp.root, "lm.json")))
    }

    @Test fun disableUnregistersAndClearWipes() {
        val (st, tl, src) = fixture()
        st.setEnabled(true); st.setEnabled(false)
        assertEquals(1, src.unregisters)
        st.setEnabled(true)
        st.clearLocal()
        assertFalse(st.isEnabled)
        assertFalse(File(tmp.root, "lm.json").exists())
        assertTrue(tl.segments(0, t0 + 1).isEmpty())
    }

    @Test fun jsonShapeIsIosCompatible() {
        val (st, _, _) = fixture()
        st.setEnabled(true)
        assertEquals("""{"isEnabled":true}""", File(tmp.root, "lm.json").readText())
        File(tmp.root, "lm.json").writeText("""{"isEnabled":true,"future":1}""")
        assertTrue(ListeningMotionStore.readEnabled(File(tmp.root, "lm.json")))
    }
}

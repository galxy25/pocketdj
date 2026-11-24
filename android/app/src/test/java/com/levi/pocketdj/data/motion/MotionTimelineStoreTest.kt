package com.levi.pocketdj.data.motion

import com.google.android.gms.location.DetectedActivity
import java.io.File
import org.junit.Assert.*
import org.junit.Rule
import org.junit.Test
import org.junit.rules.TemporaryFolder

class MotionTimelineStoreTest {
    @get:Rule val tmp = TemporaryFolder()
    private var clock = 1_793_115_000_000L
    private val min = 60_000L
    private fun store() = MotionTimelineStore(File(tmp.root, "tl.json")) { clock }

    @Test fun enterExitPairsBecomeSegments() {
        val s = store()
        s.onTransition("walking", true, clock - 30 * min)
        s.onTransition("walking", false, clock - 20 * min)
        val segs = s.segments(0, clock)
        assertEquals(listOf(MotionSegment(clock - 30 * min, clock - 20 * min, "walking", 1)), segs)
    }

    @Test fun openSegmentIsClippedToNow() {
        val s = store()
        s.onTransition("running", true, clock - 5 * min)
        assertEquals(listOf(MotionSegment(clock - 5 * min, clock, "running", 1)), s.segments(clock - 10 * min, clock))
    }

    @Test fun enterWithoutExitClosesPreviousAtNewEnter() {
        val s = store()
        s.onTransition("stationary", true, clock - 30 * min)
        s.onTransition("automotive", true, clock - 10 * min)
        val segs = s.segments(0, clock)
        assertEquals(MotionSegment(clock - 30 * min, clock - 10 * min, "stationary", 1), segs[0])
        assertEquals("automotive", segs[1].activity)
    }

    @Test fun strayExitAndDuplicateEnterIgnored() {
        val s = store()
        s.onTransition("walking", false, clock - 9 * min)
        assertTrue(s.segments(0, clock).isEmpty())
        s.onTransition("walking", true, clock - 8 * min)
        s.onTransition("walking", true, clock - 4 * min)
        s.onTransition("running", false, clock - 3 * min) // exit of a non-open activity
        assertEquals(clock - 8 * min, s.segments(0, clock).single().startMs)
        s.onTransition("bogus", true, clock)
        assertEquals(1, s.segments(0, clock).size)
    }

    @Test fun ringTrimsToSevenDaysAndPersists() {
        val s = store()
        s.onTransition("walking", true, clock - 9 * 86_400_000L)
        s.onTransition("walking", false, clock - 9 * 86_400_000L + 10 * min)
        s.onTransition("running", true, clock - 2 * 86_400_000L)
        s.onTransition("running", false, clock - 2 * 86_400_000L + 10 * min)
        val segs = s.segments(0, clock)
        assertEquals(listOf("running"), segs.map { it.activity })
        // a reload from disk keeps the in-window segment and an open one
        s.onTransition("cycling", true, clock - min)
        val again = store()
        assertEquals(listOf("running", "cycling"), again.segments(0, clock).map { it.activity })
    }

    @Test fun fileShapeAndClear() {
        val s = store()
        s.onTransition("walking", true, clock - 4 * min)
        s.onTransition("walking", false, clock - 2 * min)
        val txt = File(tmp.root, "tl.json").readText()
        assertTrue(txt, txt.contains("\"segments\"") && txt.contains("\"activity\":\"walking\""))
        s.clear()
        assertFalse(File(tmp.root, "tl.json").exists())
        assertTrue(s.segments(0, clock).isEmpty())
    }

    @Test fun corruptFileReadsAsEmpty() {
        File(tmp.root, "tl.json").writeText("{nope")
        assertTrue(store().segments(0, clock).isEmpty())
    }

    @Test fun activityTypeMapping() {
        assertEquals("running", ActivityTransitionSource.tokenFor(DetectedActivity.RUNNING))
        assertEquals("walking", ActivityTransitionSource.tokenFor(DetectedActivity.WALKING))
        assertEquals("cycling", ActivityTransitionSource.tokenFor(DetectedActivity.ON_BICYCLE))
        assertEquals("automotive", ActivityTransitionSource.tokenFor(DetectedActivity.IN_VEHICLE))
        assertEquals("stationary", ActivityTransitionSource.tokenFor(DetectedActivity.STILL))
        assertNull(ActivityTransitionSource.tokenFor(DetectedActivity.ON_FOOT))
        assertEquals("walking", MotionTransitionReceiver.tokenForName("walking"))
        assertNull(MotionTransitionReceiver.tokenForName("flying"))
    }

    @Test fun staleOpenSegmentIsCappedNotGrowing() {
        val s = store()
        s.onTransition("walking", true, clock - 3 * 86_400_000L)
        val seg = s.segments(0, clock).single()
        assertEquals(MotionTimelineStore.MAX_SEGMENT_MS, seg.endMs - seg.startMs)
        assertTrue(s.segments(clock - 10 * min, clock).isEmpty())
    }

    @Test fun staleOpenFinalisedOnNextTransitionAndReload() {
        val s = store()
        s.onTransition("walking", true, clock - 3 * 86_400_000L)
        s.onTransition("running", true, clock - min)
        val segs = s.segments(0, clock)
        assertEquals(MotionTimelineStore.MAX_SEGMENT_MS, segs[0].endMs - segs[0].startMs)
        assertEquals("running", segs[1].activity)
    }

    @Test fun longGapImplicitCloseIsCapped() {
        val s = store()
        s.onTransition("walking", true, clock - 9 * 3_600_000L)
        s.onTransition("stationary", true, clock - min)
        val w = s.segments(0, clock).first { it.activity == "walking" }
        assertEquals(MotionTimelineStore.MAX_SEGMENT_MS, w.endMs - w.startMs)
    }

    @Test fun closeOpenStopsTheSegment() {
        val s = store()
        s.onTransition("walking", true, clock - 10 * min)
        s.closeOpen(clock - 4 * min)
        clock += 60 * min
        assertEquals(listOf(MotionSegment(clock - 70 * min, clock - 64 * min, "walking", 1)), s.segments(0, clock))
    }

    private class FakeSource : ListeningMotionStore.Source {
        var registers = 0; var unregisters = 0
        override fun register() { registers++ }
        override fun unregister() { unregisters++ }
    }

    private fun listening(perm: Boolean, src: FakeSource, tl: MotionTimelineStore) =
        ListeningMotionStore(File(tmp.root, "lm.json"), tl, { perm }, src) { clock }

    @Test fun inertWithoutPermissionAndOffByDefault() {
        val tl = store(); val src = FakeSource()
        val m = listening(false, src, tl)
        assertFalse(m.isEnabled)
        m.setEnabled(true)
        assertEquals(0, src.registers)
        assertFalse(m.isActive)
        tl.onTransition("walking", true, clock - min)
        assertNull(m.currentActivity())
        m.ensureRegistered()
        assertEquals(0, src.registers)
    }

    @Test fun disablingAndLostPermissionCloseOpenSegment() {
        val tl = store(); val src = FakeSource()
        val m = listening(true, src, tl)
        m.setEnabled(true)
        assertEquals(1, src.registers)
        tl.onTransition("walking", true, clock - 10 * min)
        m.setEnabled(false)
        assertEquals(1, src.unregisters)
        clock += 60 * min
        assertEquals(clock - 60 * min, tl.segments(0, clock).single().endMs)

        val tl2 = MotionTimelineStore(File(tmp.root, "tl2.json")) { clock }
        val m2 = ListeningMotionStore(File(tmp.root, "lm2.json"), tl2, { false }, src) { clock }
        tl2.onTransition("running", true, clock - 5 * min)
        m2.ensureRegistered()
        clock += 60 * min
        assertEquals(clock - 60 * min, tl2.segments(0, clock).single().endMs)
    }
}

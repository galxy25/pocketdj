package com.levi.pocketdj.data.pockets.wheel

import com.levi.pocketdj.data.motion.MotionSegment
import com.levi.pocketdj.data.motion.MotionTimelineStore
import com.levi.pocketdj.screens.settings.sections.ListeningMotionCopy
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Rule
import org.junit.Test
import org.junit.rules.TemporaryFolder

class ActivityTrackerTest {
    @get:Rule val tmp = TemporaryFolder()

    private fun seg(activity: String, start: Long, conf: Int = 1) = MotionSegment(start, start, activity, conf)

    @Test fun sustainIs180Seconds() {
        assertEquals(180_000L, ActivityTracker.SUSTAIN_MS)
        val t = ActivityTracker()
        t.note(seg(MotionToken.WALKING, 1_000))
        assertNull(t.sustainedMode(1_000 + 179_999))
        assertEquals(PocketMode.WALKING, t.sustainedMode(1_000 + 180_000))
    }

    @Test fun changeRestartsTheClock() {
        val t = ActivityTracker()
        t.note(seg(MotionToken.WALKING, 0))
        t.note(seg(MotionToken.RUNNING, 100_000))
        assertNull(t.sustainedMode(200_000))               // 100 s of running only
        assertEquals(PocketMode.RUNNING, t.sustainedMode(280_000))
    }

    @Test fun sameActivityDoesNotRestartTheClock() {
        val t = ActivityTracker()
        t.note(seg(MotionToken.WALKING, 0))
        t.note(seg(MotionToken.WALKING, 150_000))
        assertEquals(PocketMode.WALKING, t.sustainedMode(180_000))
        assertEquals(0L, t.sinceMs)
    }

    @Test fun lowConfidenceIgnored() {
        val t = ActivityTracker()
        t.note(seg(MotionToken.RUNNING, 0, conf = 0))
        assertNull(t.activity)
        assertNull(t.sustainedMode(1_000_000))
    }

    @Test fun modeMapping() {
        assertEquals(PocketMode.RUNNING, ActivityTracker.modeFor(MotionToken.RUNNING))
        assertEquals(PocketMode.WALKING, ActivityTracker.modeFor(MotionToken.WALKING))
        assertEquals(PocketMode.TRIP, ActivityTracker.modeFor(MotionToken.AUTOMOTIVE))
        assertEquals(PocketMode.TRIP, ActivityTracker.modeFor(MotionToken.CYCLING))
        assertNull(ActivityTracker.modeFor(MotionToken.STATIONARY))
        val t = ActivityTracker()
        t.note(seg(MotionToken.STATIONARY, 0))
        assertNull(t.sustainedMode(10_000_000))
    }

    @Test fun oncePerModePerRun() {
        // Run built for a collection: first sustained WALKING re-targets; the same mode again does not.
        assertTrue(ActivityTracker.shouldRetarget(PocketMode.WALKING, null, PocketMode.COLLECTION))
        assertFalse(ActivityTracker.shouldRetarget(PocketMode.WALKING, PocketMode.WALKING, PocketMode.WALKING))
        // Walking -> running is a new mode -> re-target again; then back to walking after running re-targets too (retargetedMode moved).
        assertTrue(ActivityTracker.shouldRetarget(PocketMode.RUNNING, PocketMode.WALKING, PocketMode.WALKING))
        // A run already for that mode, never re-targeted: nothing to do.
        assertFalse(ActivityTracker.shouldRetarget(PocketMode.RUNNING, null, PocketMode.RUNNING))
        assertFalse(ActivityTracker.shouldRetarget(null, null, PocketMode.RUNNING))
    }

    @Test fun timelineEnterFeedsTheTracker() {
        val tl = MotionTimelineStore(tmp.newFile("tl.json"), now = { 1_000_000L })
        val tracker = ActivityTracker()
        tl.onEnter = { tracker.note(it) }
        tl.onTransition(MotionToken.WALKING, entering = true, atMs = 500_000L)
        tl.onTransition(MotionToken.WALKING, entering = true, atMs = 600_000L)   // duplicate ENTER: no second event
        assertEquals(500_000L, tracker.sinceMs)
        assertEquals(PocketMode.WALKING, tracker.sustainedMode(680_000L))
        tl.onTransition(MotionToken.WALKING, entering = false, atMs = 700_000L)   // EXIT is not a sample
        assertEquals(MotionToken.WALKING, tracker.activity)
        tl.onEnter = null
        tl.onTransition(MotionToken.RUNNING, entering = true, atMs = 800_000L)
        assertEquals(MotionToken.WALKING, tracker.activity)
    }

    @Test fun accessStatusAndCopy() {
        assertEquals("Allowed", ListeningMotionCopy.statusText(ListeningMotionCopy.access(granted = true, asked = false)))
        assertEquals("Not asked yet", ListeningMotionCopy.statusText(ListeningMotionCopy.access(false, false)))
        val denied = ListeningMotionCopy.access(false, true)
        assertEquals("Denied", ListeningMotionCopy.statusText(denied))
        assertTrue(ListeningMotionCopy.showsOpenSettings(denied))
        assertFalse(ListeningMotionCopy.showsOpenSettings(ListeningMotionCopy.Access.ALLOWED))
        assertTrue(ListeningMotionCopy.footer(true).contains("sent with your pockets"))
        assertTrue(ListeningMotionCopy.footer(false).contains("nothing is sent"))
        assertFalse(ListeningMotionCopy.footer(true).contains("iPhone"))
        // Prominent disclosure names the data, the purpose and the background use.
        assertTrue(ListeningMotionCopy.DISCLOSURE.contains("closed or not in use"))
        assertTrue(ListeningMotionCopy.DISCLOSURE.contains("activity recognition"))
    }

    @Test fun endedClearsOnlyTheMatchingActivity() {
        val t = ActivityTracker()
        t.note(seg(MotionToken.WALKING, 0))
        t.ended(MotionToken.RUNNING)
        assertEquals(MotionToken.WALKING, t.activity)
        t.ended(MotionToken.WALKING)
        assertNull(t.activity)
        assertNull(t.sustainedMode(1_000_000))
    }

    @Test fun timelineExitFeedsOnExitOnlyWhenItClosedASegment() {
        val tl = MotionTimelineStore(tmp.newFile("tl2.json"), now = { 1_000_000L })
        val exits = mutableListOf<String>()
        tl.onExit = { exits += it }
        tl.onTransition(MotionToken.WALKING, true, 1_000)
        tl.onTransition(MotionToken.RUNNING, false, 2_000)   // not the open one
        assertTrue(exits.isEmpty())
        tl.onTransition(MotionToken.WALKING, false, 3_000)
        assertEquals(listOf(MotionToken.WALKING), exits)
    }
}

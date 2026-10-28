package com.levi.pocketdj.screens.foryou

import com.levi.pocketdj.data.recs.RecFeedbackStore
import com.levi.pocketdj.data.recs.RecFeedbackStore.Verdict
import java.io.File
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.SupervisorJob
import org.junit.After
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test

class RecFeedbackActionsTest {
    private val tmp = kotlin.io.path.createTempDirectory("fyfb").toFile()
    @After fun cleanup() { tmp.deleteRecursively() }
    private fun store() = RecFeedbackStore(File(tmp, "fb.json"), CoroutineScope(SupervisorJob() + Dispatchers.Unconfined), saveDebounceMs = 1)

    @Test fun labelsMatchTheIosAccessibilityWording() {
        assertEquals("More like this", RecFeedbackActions.label(Verdict.ACCEPTED, false))
        assertEquals("Undo more like this", RecFeedbackActions.label(Verdict.ACCEPTED, true))
        assertEquals("Not for me", RecFeedbackActions.label(Verdict.REJECTED, false))
        assertEquals("Undo not for me", RecFeedbackActions.label(Verdict.REJECTED, true))
    }

    @Test fun theAddRidesOnlyAThumbsUpThatLanded() {
        val fb = store()
        val first = RecFeedbackActions.record(fb, null, "s1", "pl1", RecFeedbackStore.Surface.TILE, Verdict.ACCEPTED)
        assertTrue(RecFeedbackActions.shouldAdd(first))
        // Tapping the lit thumbs-up is an UNDO: nothing lands, so nothing is added a second time.
        val undo = RecFeedbackActions.record(fb, null, "s1", "pl1", RecFeedbackStore.Surface.TILE, Verdict.ACCEPTED)
        assertNull(undo)
        assertFalse(RecFeedbackActions.shouldAdd(undo))
        assertNull(fb.verdict("s1", "pl1"))
    }

    @Test fun aThumbsDownNeverAddsAndSinksTheRow() {
        val fb = store()
        val landed = RecFeedbackActions.record(fb, null, "s9", "zone", RecFeedbackStore.Surface.TILE, Verdict.REJECTED)
        assertEquals(Verdict.REJECTED, landed)
        assertFalse(RecFeedbackActions.shouldAdd(landed))
        assertTrue(fb.isSuppressed("s9", "zone"))
    }
}

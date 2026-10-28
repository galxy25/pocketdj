package com.levi.pocketdj.data.rips

import kotlinx.coroutines.ExperimentalCoroutinesApi
import kotlinx.coroutines.test.runTest
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

@OptIn(ExperimentalCoroutinesApi::class)
class RipCollectionCoordinatorTest {
    @Test
    fun ripCollection_protectsIds_adoptsQueuedJobs_andPolls() = runTest {
        val tracker = RipJobTracker(backgroundScope, { RipJob("queued", it) }, pollMs = 1_000)
        val coord = RipCollectionCoordinator(
            tracker,
            { ids, _ -> BatchRipResult(listOf(BatchRipItem("a", "queued", "ja"), BatchRipItem("b", "ready"))) },
            { emptyList() },
        )
        coord.ripCollection(listOf("a", "b", "a"))
        assertTrue(tracker.isUserRequestedRip("a") && tracker.isUserRequestedRip("b"))
        assertEquals("queued", tracker.jobs.value["a"]?.phase)
        assertTrue(tracker.isPolling("a"))
        assertFalse(tracker.isPolling("b"))
    }

    @Test
    fun cancelRips_clearsOnlyCanceledIds() = runTest {
        val tracker = RipJobTracker(backgroundScope, { RipJob("queued", it) }, pollMs = 1_000)
        val coord = RipCollectionCoordinator(
            tracker,
            { _, _ -> BatchRipResult(listOf(BatchRipItem("a", "queued", "ja"), BatchRipItem("b", "queued", "jb"))) },
            { listOf(CancelItem("a", "canceled"), CancelItem("b", "not_found")) },
        )
        coord.ripCollection(listOf("a", "b"))
        coord.cancelRips(listOf("a", "b"))
        assertFalse(tracker.isPolling("a"))
        assertFalse(tracker.isUserRequestedRip("a"))
        assertTrue(tracker.isPolling("b"))
    }
}

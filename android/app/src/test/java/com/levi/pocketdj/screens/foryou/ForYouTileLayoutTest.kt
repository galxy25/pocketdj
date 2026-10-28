package com.levi.pocketdj.screens.foryou

import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import kotlinx.coroutines.cancel
import kotlinx.coroutines.launch
import org.junit.Test

class ForYouTileLayoutTest {
    @Test fun phoneWidthsFitTwoColumnsLikeTheIosAdaptiveGrid() {
        // 360dp phone: (360-24+12)/(150+12) = 2
        assertEquals(2, ForYouTileLayout.columns(360))
        assertEquals(2, ForYouTileLayout.columns(411))
    }

    @Test fun narrowWidthsNeverDropBelowOneColumn() {
        assertEquals(1, ForYouTileLayout.columns(100))
        assertEquals(1, ForYouTileLayout.columns(0))
        assertEquals(1, ForYouTileLayout.columns(173))
        assertEquals(2, ForYouTileLayout.columns(336)) // 2*150 + 12 gap + 24 padding
        assertEquals(1, ForYouTileLayout.columns(335))
    }

    @Test fun columnsGrowWithWidth() {
        assertEquals(3, ForYouTileLayout.columns(600))
        assertEquals(5, ForYouTileLayout.columns(900))
    }

    @Test fun tileWidthIsClampedToTheIosMaximum() {
        assertEquals(ForYouTileLayout.MAX_TILE_DP, ForYouTileLayout.tileWidthDp(300))
        assertTrue(ForYouTileLayout.tileWidthDp(360) in ForYouTileLayout.MIN_TILE_DP..ForYouTileLayout.MAX_TILE_DP)
    }

    @Test fun coldInstallSpinnerOnlyUntilTheFirstBuild() {
        assertTrue(ForYouRefreshPolicy.showSpinner(hasResult = false))
        assertFalse(ForYouRefreshPolicy.showSpinner(hasResult = true))
    }

    @Test fun spinnerShowsOnAnEmptySnapshotEvenThoughPinnedTilesAlwaysExist() {
        val snap = com.levi.pocketdj.data.recs.ForYouFeedSnapshot()
        val none = object : com.levi.pocketdj.data.recs.ForYouCollections {
            override fun exists(id: String) = false
            override fun recommendationsEnabled(id: String) = true
            override fun suggestionsExcludingMembers(suggestionIds: List<String>, id: String): List<String> = suggestionIds
        }
        // Production always emits the pinned New + In Da Zone cards, so a tile-count gate could never fire.
        val tiles = com.levi.pocketdj.data.recs.ForYouGrid.tiles(snap, none, null, null)
        assertTrue(tiles.size >= 2)
        assertTrue(ForYouRefreshPolicy.showSpinner(snap.hasResult))
    }

    @Test fun replayedInitialResumeIsIgnored() {
        val resume = androidx.lifecycle.Lifecycle.Event.ON_RESUME
        assertFalse(ForYouRefreshPolicy.isRealResume(resume, wasPaused = false))
        assertTrue(ForYouRefreshPolicy.isRealResume(resume, wasPaused = true))
    }

    @Test fun refreshOutlivesTheScreenScopeAndIsSingleFlight() = kotlinx.coroutines.runBlocking {
        val app = kotlinx.coroutines.CoroutineScope(kotlinx.coroutines.SupervisorJob() + kotlinx.coroutines.Dispatchers.Default)
        val flight = ForYouSingleFlight(app)
        val gate = kotlinx.coroutines.CompletableDeferred<Unit>()
        val committed = kotlinx.coroutines.CompletableDeferred<Unit>()
        // The "screen" triggers, then leaves composition (its scope is cancelled) mid-build.
        val screen = kotlinx.coroutines.CoroutineScope(kotlinx.coroutines.Job())
        screen.launch { assertTrue(flight.launch { gate.await(); committed.complete(Unit) }) }.join()
        screen.cancel()
        assertFalse(flight.launch { }) // a second trigger while running is dropped
        gate.complete(Unit)
        kotlinx.coroutines.withTimeout(5000) { committed.await() }
        app.cancel()
    }

    @Test fun firstBuildWaitsForTheCatalogAndNeverStampsAnEmptyOne() {
        assertFalse(ForYouRefreshPolicy.shouldRefreshAfterCatalog(catalogLoaded = false, hasResult = false, isRefreshing = false, scheduleDue = true))
        assertTrue(ForYouRefreshPolicy.shouldRefreshAfterCatalog(true, hasResult = false, isRefreshing = false, scheduleDue = false))
    }

    @Test fun aCachedFeedOnlyRefreshesWhenTheScheduleIsDue() {
        assertFalse(ForYouRefreshPolicy.shouldRefreshAfterCatalog(true, hasResult = true, isRefreshing = false, scheduleDue = false))
        assertTrue(ForYouRefreshPolicy.shouldRefreshAfterCatalog(true, hasResult = true, isRefreshing = false, scheduleDue = true))
        assertFalse(ForYouRefreshPolicy.shouldRefreshAfterCatalog(true, hasResult = true, isRefreshing = true, scheduleDue = true))
    }

    @Test fun resumeIsScheduleOnly() {
        assertTrue(ForYouRefreshPolicy.shouldRefreshOnResume(true, isRefreshing = false, scheduleDue = true))
        assertFalse(ForYouRefreshPolicy.shouldRefreshOnResume(true, isRefreshing = false, scheduleDue = false))
        assertFalse(ForYouRefreshPolicy.shouldRefreshOnResume(false, isRefreshing = false, scheduleDue = true))
        assertFalse(ForYouRefreshPolicy.shouldRefreshOnResume(true, isRefreshing = true, scheduleDue = true))
    }
}

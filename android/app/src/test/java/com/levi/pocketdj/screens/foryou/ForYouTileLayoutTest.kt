package com.levi.pocketdj.screens.foryou

import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
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
        assertEquals(ForYouTileLayout.MAX_TILE_DP, ForYouTileLayout.tileWidthDp(250))
        assertTrue(ForYouTileLayout.tileWidthDp(360) in ForYouTileLayout.MIN_TILE_DP..ForYouTileLayout.MAX_TILE_DP)
    }

    @Test fun coldInstallSpinnerOnlyUntilTheFirstBuild() {
        assertTrue(ForYouRefreshPolicy.showSpinner(tileCount = 0, hasResult = false))
        assertFalse(ForYouRefreshPolicy.showSpinner(tileCount = 0, hasResult = true))
        assertFalse(ForYouRefreshPolicy.showSpinner(tileCount = 2, hasResult = false))
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

package com.levi.pocketdj.widget

import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

class WidgetModelTest {
    @Test fun sizeClassBoundaries() {
        assertEquals(WidgetSizeClass.Small, WidgetSizeClass.of(110f, 40f))
        assertEquals(WidgetSizeClass.Medium, WidgetSizeClass.of(250f, 110f))
        assertEquals(WidgetSizeClass.Large, WidgetSizeClass.of(250f, 250f))
        assertEquals(WidgetSizeClass.Medium, WidgetSizeClass.of(250f, 219f))
    }

    @Test fun heartHiddenWithoutSeamOrContent() {
        val s = NowPlayingSnapshot(hasContent = true, songId = "a", favoriteAvailable = true)
        assertTrue(WidgetModel.showHeart(s))
        assertFalse(WidgetModel.showHeart(s.copy(favoriteAvailable = false)))
        assertFalse(WidgetModel.showHeart(NowPlayingSnapshot.EMPTY))
    }

    @Test fun repeatCycleMatchesNowPlaying() {
        assertEquals("all", WidgetModel.repeatNext(NowPlayingSnapshot(repeatMode = "off")))
        assertEquals("one", WidgetModel.repeatNext(NowPlayingSnapshot(repeatMode = "all")))
        assertEquals("off", WidgetModel.repeatNext(NowPlayingSnapshot(repeatMode = "one")))
    }

    @Test fun upNextRowsCappedAtFour() {
        val t = (1..9).map { NowPlayingSnapshot.Track("u$it", "s$it", "t", "a") }
        assertEquals(4, WidgetModel.rows(NowPlayingSnapshot(upNext = t)).size)
    }
}

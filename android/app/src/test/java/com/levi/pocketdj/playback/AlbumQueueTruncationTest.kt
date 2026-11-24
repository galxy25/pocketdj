package com.levi.pocketdj.playback

import org.junit.Assert.assertEquals
import org.junit.Test

class AlbumQueueTruncationTest {
    @Test fun truncatesAfterFirstUnboundedAtOrPastStart() {
        assertEquals(2, lastQueueIndex(listOf(false, false, true, false, false), 1))
        assertEquals(2, lastQueueIndex(listOf(false, false, true, false, false), 0))
    }
    @Test fun startOnUnboundedKeepsOnlyIt() {
        assertEquals(2, lastQueueIndex(listOf(false, false, true, true), 2))
    }
    @Test fun unboundedBeforeStartIgnored() {
        assertEquals(3, lastQueueIndex(listOf(true, false, false, false), 1))
    }
    @Test fun allBoundedKeepsEverything() {
        assertEquals(2, lastQueueIndex(listOf(false, false, false), 0))
    }
}

package com.levi.pocketdj.screens.discover

import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

class DiscoverRowStateTest {
    private fun hit(ripped: Boolean? = null) = DiscoverHit(appleMusicId = "11", title = "T", songId = "amrec_11", ripped = ripped)

    @Test fun rippedViaSearchFlag() = assertTrue(DiscoverRowState.ripped(hit(true), emptySet()))

    @Test fun rippedViaManifestAfterAddCompletes() {
        assertFalse(DiscoverRowState.ripped(hit(false), emptySet()))
        assertTrue(DiscoverRowState.ripped(hit(false), setOf("amrec_11")))
        assertTrue(DiscoverRowState.ripped(hit(null), setOf("other", "amrec_11")))
    }

    @Test fun manifestKeyUsesDerivedIdWhenSongIdEmpty() {
        val h = DiscoverHit(appleMusicId = "5", title = "T")
        assertTrue(DiscoverRowState.ripped(h, setOf("amrec_5")))
    }

    @Test fun trailingPrecedence() {
        assertEquals(DiscoverTrailing.PLAY, DiscoverRowState.trailing(true, false, working = true, added = true))
        assertEquals(DiscoverTrailing.PAUSE, DiscoverRowState.trailing(true, true, false, false))
        assertEquals(DiscoverTrailing.WORKING, DiscoverRowState.trailing(false, false, true, true))
        assertEquals(DiscoverTrailing.ADDED, DiscoverRowState.trailing(false, false, false, true))
        assertEquals(DiscoverTrailing.ADD, DiscoverRowState.trailing(false, false, false, false))
    }

    @Test fun playingButNotRippedNeverShowsPause() =
        assertEquals(DiscoverTrailing.ADD, DiscoverRowState.trailing(false, true, false, false))

    @Test fun albumAddEnabledWithoutSignIn() {
        assertEquals(LibraryWrite.SKIPPED_NO_CONNECTION,
            libraryWriteToken(com.levi.pocketdj.data.applemusic.AmResult.NeedsUserToken))
        assertEquals("Prepare your copy", DiscoverAddWording.addHelp("album", canAddToLibrary = false))
    }

    @Test fun libraryWriteTokenMapsEveryResult() {
        assertEquals(LibraryWrite.CONFIRMED_WEB, libraryWriteToken(com.levi.pocketdj.data.applemusic.AmResult.Ok(Unit)))
        assertEquals(LibraryWrite.SKIPPED_NO_CONNECTION, libraryWriteToken(com.levi.pocketdj.data.applemusic.AmResult.NeedsUserToken))
        assertEquals(LibraryWrite.failed("boom"), libraryWriteToken(com.levi.pocketdj.data.applemusic.AmResult.Failure(500, "boom")))
    }
}

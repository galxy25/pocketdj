package com.levi.pocketdj.screens.shazam

import com.levi.pocketdj.data.applemusic.AppleMusicResolution
import kotlinx.coroutines.ExperimentalCoroutinesApi
import kotlinx.coroutines.test.TestScope
import kotlinx.coroutines.test.UnconfinedTestDispatcher
import kotlinx.coroutines.test.runTest
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

@OptIn(ExperimentalCoroutinesApi::class)
class RecognizerEditionTest {
    private fun r(id: String, explicit: Boolean?, title: String = "Song", artist: String = "Art", dur: Double? = 200.0) =
        EditionRow(id, title, artist, explicit, dur)

    private suspend fun swap(id: String, prefer: Boolean?, rows: List<EditionRow>, throwing: Boolean = false) =
        RecognizerEdition.preferredStoreId(id, "Song", "Art", prefer) { if (throwing) error("offline") else rows }

    // ---- matches ------------------------------------------------------------------------------

    @Test fun matchRequiresSameRecordingAndEditionAndDuration() {
        assertTrue(RecognizerEdition.matches(r("2", false), "Song", "Art", 200_000, wantExplicit = false))
        assertFalse(RecognizerEdition.matches(r("2", true), "Song", "Art", 200_000, wantExplicit = false)) // wrong edition
        assertFalse(RecognizerEdition.matches(r("2", false, title = "Other"), "Song", "Art", 200_000, false)) // other song
        assertFalse(RecognizerEdition.matches(r("2", false, artist = "Someone"), "Song", "Art", 200_000, false))
        assertFalse(RecognizerEdition.matches(r("2", false, dur = 260.0), "Song", "Art", 200_000, false)) // a different cut
        assertTrue(RecognizerEdition.matches(r("2", false, dur = 206.9), "Song", "Art", 200_000, false)) // within 7 s
        assertTrue(RecognizerEdition.matches(r("2", false, dur = null), "Song", "Art", 200_000, false)) // no duration to compare
    }

    @Test fun featuredArtistCreditStillMatches() {
        assertTrue(RecognizerEdition.matches(r("2", false, artist = "Art & Friend"), "Song", "Art", null, false))
    }

    // ---- preferredStoreId --------------------------------------------------------------------

    @Test fun explicitRecognitionSwapsToCleanSibling() = runTest {
        val rows = listOf(r("E", true), r("C", false))
        assertEquals("C", swap("E", prefer = false, rows = rows))
    }

    @Test fun cleanRecognitionSwapsToExplicitWhenPreferred() = runTest {
        val rows = listOf(r("C", false), r("E", true))
        assertEquals("E", swap("C", prefer = true, rows = rows))
    }

    @Test fun alreadyThePreferredEditionIsKept() = runTest {
        assertEquals("C", swap("C", prefer = false, rows = listOf(r("E", true), r("C", false))))
    }

    @Test fun neverChosenSubstitutesNothing() = runTest {
        assertEquals("E", swap("E", prefer = null, rows = listOf(r("E", true), r("C", false))))
    }

    @Test fun everyMissKeepsTheRecognizedId() = runTest {
        assertEquals("E", swap("E", false, emptyList())) // recognized row not in results
        assertEquals("E", swap("E", false, listOf(r("E", true)))) // no sibling at all
        assertEquals("E", swap("E", false, listOf(r("E", true), r("X", false, dur = 400.0)))) // different cut
        assertEquals("E", swap("E", false, emptyList(), throwing = true)) // offline never blocks the add
        assertEquals("", swap("", false, listOf(r("C", false))))
    }

    // ---- ordering inside the add flow ---------------------------------------------------------

    private class OrderPort(val chosen: String) : AppleMusicRecognitionPort {
        val log = mutableListOf<String>()
        override val available = true
        override suspend fun canContribute() = true
        override val canAdd = true
        override suspend fun resolve(storeId: String?, title: String?, artist: String?): AppleMusicResolution? = null
        override suspend fun preferredEdition(storeId: String, title: String, artist: String): String { log += "edition($storeId)"; return chosen }
        override suspend fun addSongToLibrary(storeId: String): Boolean { log += "add($storeId)"; return true }
        override suspend fun startRipAndBurn(songId: String, title: String, artist: String, storeId: String): RipStart {
            log += "rip($songId,$storeId)"; return RipStart.REQUESTED
        }
    }

    @Test fun editionIsResolvedThenLibraryAddThenRipAndBurnWithTheChosenId() = runTest {
        val port = OrderPort("CLEAN")
        val c = RecognitionAddController(TestScope(UnconfinedTestDispatcher(testScheduler)), port)
        c.add("EXPL", "T", "A", null)
        assertEquals(listOf("edition(EXPL)", "add(CLEAN)", "rip(amrec_CLEAN,CLEAN)"), port.log)
        // UI state stays keyed by the recognized id; the burn id follows the chosen edition
        assertEquals("amrec_CLEAN", c.states.value.getValue("EXPL").burnSongId)
    }

    @Test fun indexedSongIsReResolvedForTheChosenEdition() = runTest {
        val port = OrderPort("CLEAN")
        val c = RecognitionAddController(TestScope(UnconfinedTestDispatcher(testScheduler)), port)
        c.add("EXPL", "T", "A", "idx_explicit", catalogSongIdFor = { chosen -> if (chosen == "CLEAN") "idx_clean" else null })
        assertEquals("idx_clean", c.states.value.getValue("EXPL").burnSongId)
    }

    @Test fun unchangedEditionKeepsTheCallersCatalogId() = runTest {
        val port = OrderPort("SAME")
        val c = RecognitionAddController(TestScope(UnconfinedTestDispatcher(testScheduler)), port)
        c.add("SAME", "T", "A", "idx_1", catalogSongIdFor = { "should-not-be-used" })
        assertEquals("idx_1", c.states.value.getValue("SAME").burnSongId)
    }

    @Test fun editionFailureStillAddsTheRecognizedTrack() = runTest {
        val port = object : AppleMusicRecognitionPort by OrderPort("x") {
            override suspend fun preferredEdition(storeId: String, title: String, artist: String): String = error("boom")
            override suspend fun addSongToLibrary(storeId: String): Boolean = storeId == "EXPL"
        }
        val c = RecognitionAddController(TestScope(UnconfinedTestDispatcher(testScheduler)), port)
        c.add("EXPL", "T", "A", null)
        assertTrue(c.states.value.getValue("EXPL").added)
    }
}

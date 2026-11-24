package com.levi.pocketdj.screens.history

import com.levi.pocketdj.data.pockets.ListeningPocketsResults
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

class PocketsTabGateTest {
    private fun r(json: String) = ListeningPocketsResults.parse(json)!!

    @Test fun tabVisibleWhenGateOpenOrUnansweredOfferOnly() {
        assertTrue(PocketsTabGate.tabVisible(recEngine = true, pocketsOn = true, answered = true))
        assertTrue(PocketsTabGate.tabVisible(true, false, answered = false))   // the once-only offer
        assertFalse(PocketsTabGate.tabVisible(true, false, answered = true))   // "Not now" removes the tab
        assertFalse(PocketsTabGate.tabVisible(false, true, true))              // engine off closes it
        assertFalse(PocketsTabGate.tabVisible(false, false, false))
    }

    @Test fun tabListGainsPocketsOnlyWhenVisible() {
        assertTrue(HistoryTab.POCKETS in visibleHistoryTabs(true, false))
        assertFalse(HistoryTab.POCKETS in visibleHistoryTabs(false, false))
    }

    @Test fun gateClosedShowsOptInEvenWithCachedResults() {
        val res = r("""{"v":1,"pockets":[{"id":"a","startMs":1}],"patterns":[]}""")
        assertEquals(PocketsTabMode.OptIn, PocketsTabGate.mode(false, res, true))
    }

    @Test fun serviceUnavailableAndEmptyStates() {
        assertEquals(PocketsTabMode.Empty(null), PocketsTabGate.mode(true, null, true))
        assertEquals(PocketsTabMode.Empty("Pockets aren't available yet."), PocketsTabGate.mode(true, ListeningPocketsResults.EMPTY, false))
        // available but nothing found: no detail line
        assertEquals(PocketsTabMode.Empty(null), PocketsTabGate.mode(true, ListeningPocketsResults.EMPTY, true))
    }

    @Test fun recentIsNewestFirstAndStaleFlagsBanner() {
        val res = r("""{"v":1,"stale":true,"pockets":[{"id":"old","startMs":100},{"id":"new","startMs":300},{"id":"mid","startMs":200}],
            "patterns":[{"id":"p1","title":"T"}]}""")
        val m = PocketsTabGate.mode(true, res, true) as PocketsTabMode.Content
        assertEquals(listOf("new", "mid", "old"), m.recent.map { it.id })
        assertEquals(listOf("p1"), m.patterns.map { it.id })
        assertTrue(m.stale)
        val fresh = PocketsTabGate.mode(true, r("""{"v":1,"pockets":[{"id":"a","startMs":1}],"patterns":[]}"""), true) as PocketsTabMode.Content
        assertFalse(fresh.stale)
    }

    @Test fun detailKeysAreDistinctForPocketAndPattern() {
        assertEquals("pocket:x", PocketsTabGate.pocketKey("x"))
        assertEquals("pattern:x", PocketsTabGate.patternKey("x"))
    }

    @Test fun historyNonEmptyOpensTheTabRegardlessOfEngineAndAnswer() {
        // The visibility matrix: historyNonEmpty is an OR on top of the old cloud gate.
        for (rec in listOf(true, false)) for (on in listOf(true, false)) for (answered in listOf(true, false)) {
            assertTrue(PocketsTabGate.tabVisible(rec, on, answered, historyNonEmpty = true))
            assertEquals(
                (rec && on) || (rec && !answered),
                PocketsTabGate.tabVisible(rec, on, answered, historyNonEmpty = false),
            )
            // Default argument keeps the three-arg callers unchanged.
            assertEquals(PocketsTabGate.tabVisible(rec, on, answered, false), PocketsTabGate.tabVisible(rec, on, answered))
        }
    }

    @Test fun listSegmentHiddenOnlyWhenCloudPocketsDeclined() {
        assertFalse(PocketsSegment.showsList(pocketsOn = false, answered = true))   // declined
        assertTrue(PocketsSegment.showsList(pocketsOn = false, answered = false))   // never asked: List keeps the offer
        assertTrue(PocketsSegment.showsList(pocketsOn = true, answered = true))
        assertTrue(PocketsSegment.showsList(pocketsOn = true, answered = false))
    }

    @Test fun segmentDefaultsToWheelAndHiddenListCollapsesToWheel() {
        assertEquals(PocketsSegment.WHEEL, PocketsSegment.parse(null))
        assertEquals(PocketsSegment.WHEEL, PocketsSegment.parse("garbage"))
        assertEquals(PocketsSegment.LIST, PocketsSegment.parse("List"))
        assertEquals(PocketsSegment.WHEEL, PocketsSegment.effective(PocketsSegment.LIST, showsList = false))
        assertEquals(PocketsSegment.LIST, PocketsSegment.effective(PocketsSegment.LIST, showsList = true))
        assertEquals("pdj.history.pockets.segment", PocketsSegment.PREF_KEY)
    }

    @Test fun runNoteTexts() {
        assertEquals("Playing a fresh mix from this pocket.", PocketDetailText.runNote(true, "ignored"))
        assertEquals("Not enough songs", PocketDetailText.runNote(false, "Not enough songs"))
        assertEquals(null, PocketDetailText.runNote(false, null))
        assertEquals("Building a mix from this pocket…", PocketDetailText.BUILDING)
    }
}

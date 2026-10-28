package com.levi.pocketdj.screens.games

import com.levi.pocketdj.data.games.friends.MwFMember
import com.levi.pocketdj.data.games.friends.MwFSettings
import com.levi.pocketdj.data.games.friends.MwFState
import com.levi.pocketdj.data.games.friends.MwFSuggestion
import com.levi.pocketdj.data.games.friends.MwFTurn
import org.junit.Test
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue

class MwFScreenLogicTest {
    private val L = MwFScreenLogic

    @Test fun expiresLabelHoursMinutesAndEnded() {
        val now = 1_000_000.0
        assertEquals("ended", L.expiresLabel(now, now))
        assertEquals("ended", L.expiresLabel(now - 5, now))
        assertEquals("ends in 0m", L.expiresLabel(now + 59_999, now))
        assertEquals("ends in 45m", L.expiresLabel(now + 45 * 60_000 + 30_000, now))
        assertEquals("ends in 1h 0m", L.expiresLabel(now + 60 * 60_000, now))
        assertEquals("ends in 2h 5m", L.expiresLabel(now + 125 * 60_000, now))
    }

    private fun st(turn: String?, outside: Boolean?) = MwFState(
        turn = MwFTurn(memberId = turn),
        settings = MwFSettings(acceptOutsideTurn = outside),
    )

    @Test fun canSuggestNowMatrix() {
        assertTrue(L.canSuggestNow(null, "me"))
        assertTrue(L.canSuggestNow(st("me", false), "me"))
        assertFalse(L.canSuggestNow(st("you", false), "me"))
        assertFalse(L.canSuggestNow(st("you", null), "me"))
        assertTrue(L.canSuggestNow(st("you", true), "me"))
        assertTrue(L.canSuggestNow(st("me", true), "me"))
        // no turn at all and no outside-turn allowance: not allowed
        assertFalse(L.canSuggestNow(MwFState(), "me"))
        // iOS parity: nil turn member == nil youId enables the composer
        assertTrue(L.canSuggestNow(st(null, false), null))
        assertFalse(L.canSuggestNow(st(null, false), "me"))
    }

    @Test fun openedSessionRoutesKnownToScreenUnknownToJoin() {
        assertEquals("a", routeOpenedSession("a") { it == "a" })
        assertNull(routeOpenedSession("zzz") { it == "a" })
    }

    @Test fun leaderboardSortsDescendingAndStable() {
        val s = MwFState(members = listOf(
            MwFMember("a", "A", score = 1), MwFMember("b", "B", score = 5),
            MwFMember("c", "C", score = 1), MwFMember("d", "D", score = null),
        ))
        assertEquals(listOf("b", "a", "c", "d"), L.sortedMembers(s).map { it.memberId })
        assertTrue(L.sortedMembers(null).isEmpty())
    }

    @Test fun feedNewestFirstAndInboxPendingOnly() {
        val s = MwFState(suggestions = listOf(
            MwFSuggestion(id = "1", seq = 1, status = "accepted"),
            MwFSuggestion(id = "3", seq = 3, status = "pending"),
            MwFSuggestion(id = "2", seq = 2, status = "rejected"),
            MwFSuggestion(id = "4", seq = null, status = "pending"),
        ))
        assertEquals(listOf("3", "2", "1", "4"), L.feed(s).map { it.id })
        assertEquals(listOf("3", "4"), L.pendingInbox(s).map { it.id })
    }

    @Test fun remainingSecondsClampsAtZeroAndFormats() {
        assertEquals(0, L.remainingSeconds(1_000.0, 5_000.0))
        assertEquals(90, L.remainingSeconds(100_000.0, 10_000.0))
        assertEquals("1:30 left", L.leftLabel(90))
        assertEquals("0:05 left", L.leftLabel(5))
        assertEquals("5:00 left", L.leftLabel(300))
    }

    @Test fun turnHeadlineYourTurnVsName() {
        val s = MwFState(members = listOf(MwFMember("a", "Ann"), MwFMember("b", "Bo")), turn = MwFTurn(memberId = "b"))
        assertEquals("Your turn!", L.turnHeadline(s, "b"))
        assertEquals("Bo's turn", L.turnHeadline(s, "a"))
        assertEquals("…'s turn", L.turnHeadline(null, "a"))
        assertEquals("Wait for your turn — Bo is up", L.waitHint(s))
    }

    @Test fun plusOneDisabledForOwnAlreadyAndEnded() {
        val sg = MwFSuggestion(id = "x", memberId = "a", plusOnes = listOf("c"))
        assertTrue(L.plusOneEnabled(sg, "b", false))
        assertFalse(L.plusOneEnabled(sg, "a", false))
        assertFalse(L.plusOneEnabled(sg, "c", false))
        assertFalse(L.plusOneEnabled(sg, "b", true))
    }

    @Test fun suggestErrorMapsConflictToHangTight() {
        assertEquals("Not your turn yet — hang tight.", L.suggestErrorMessage(409, "Not your turn yet."))
        assertEquals("boom", L.suggestErrorMessage(500, "boom"))
        assertEquals("Couldn't send that suggestion.", L.suggestErrorMessage(null, null))
    }

    @Test fun createDefaultsAndGating() {
        assertEquals("Player" to "Music with Friends", L.defaultNames("  "))
        assertEquals("Levi" to "Levi's Music with Friends", L.defaultNames(" Levi "))
        assertEquals(144, L.clampTheme("x".repeat(300)).length)
        assertTrue(L.canCreate("90s", "https://j", false))
        assertFalse(L.canCreate("   ", "https://j", false))
        assertFalse(L.canCreate("90s", " ", false))
        assertFalse(L.canCreate("90s", "https://j", true))
        assertEquals(listOf(30, 60, 120, 300), L.TURN_CHOICES.map { it.first })
    }

    @Test fun pollingStopsWhenEndedAndAgoLabel() {
        assertTrue(L.shouldKeepPolling(null))
        assertTrue(L.shouldKeepPolling(MwFState(ended = false)))
        assertFalse(L.shouldKeepPolling(MwFState(ended = true)))
        assertEquals("12 sec", L.agoLabel(0.0, 12_000.0))
        assertEquals("3 min", L.agoLabel(0.0, 185_000.0))
        assertEquals("2 hr", L.agoLabel(0.0, 2 * 3_600_000.0))
        assertEquals("1 song", L.collectionLine(1).substringAfter("· "))
        assertEquals("3 songs", L.collectionLine(3).substringAfter("· "))
    }
}

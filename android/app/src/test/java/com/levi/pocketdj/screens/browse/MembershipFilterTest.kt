package com.levi.pocketdj.screens.browse

import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

class MembershipFilterTest {
    @Test fun inactiveByDefault() {
        assertFalse(MembershipFilter().active)
        assertEquals("", MembershipFilter().selectionKey())
    }

    @Test fun anyFlagOrIdsActivate() {
        assertTrue(MembershipFilter(includeAny = true).active)
        assertTrue(MembershipFilter(excludeIds = setOf("pkt_1")).active)
        assertTrue(MembershipFilter(includeIds = setOf("pls_1")).showActive)
        assertTrue(MembershipFilter(excludeAny = true).hideActive)
    }

    @Test fun clearedDropsEverything() {
        val m = MembershipFilter(true, setOf("a"), true, setOf("b")).cleared()
        assertFalse(m.active)
    }

    @Test fun selectionKeyTracksSelectionNotOrder() {
        val a = MembershipFilter(includeIds = setOf("pls_b", "pkt_a"))
        val b = MembershipFilter(includeIds = setOf("pkt_a", "pls_b"))
        assertEquals(a.selectionKey(), b.selectionKey())
        assertTrue(a.selectionKey() != MembershipFilter(excludeIds = setOf("pls_b", "pkt_a")).selectionKey())
        assertTrue(MembershipFilter(includeAny = true).selectionKey().contains("*"))
    }

    @Test fun clearAllKeepsMembershipButResetsFavoriteAndHideSkips() {
        val f = BrowseFilters(
            clauses = listOf(Clause("genre", FilterOp.EQ, "Rock")),
            favorite = com.levi.pocketdj.data.favorites.FavoriteFilter.FAVORITE,
            membership = MembershipFilter(includeAny = true),
            hideSkips = true,
        ).clearedAll()
        assertTrue(f.clauses.isEmpty())
        assertFalse(f.favoriteActive)
        assertFalse(f.hideSkips)
        assertTrue(f.membership.includeAny)
    }

    @Test fun glyphAndCountGating() {
        val f = BrowseFilters(
            favorite = com.levi.pocketdj.data.favorites.FavoriteFilter.NOT,
            membership = MembershipFilter(includeIds = setOf("pls_1")),
            hideSkips = true,
        )
        assertEquals(1, f.activeCount(BrowseKind.SONGS))
        assertEquals(0, f.activeCount(BrowseKind.ALBUMS))
        assertEquals(2, f.activeCount(BrowseKind.SONGS, historyMode = true))
        assertTrue(f.glyphLit(BrowseKind.SONGS))
        assertFalse(f.glyphLit(BrowseKind.ALBUMS))
        assertTrue(BrowseFilters(membership = MembershipFilter(includeAny = true)).glyphLit(BrowseKind.SONGS))
        assertEquals(0, BrowseFilters(membership = MembershipFilter(includeAny = true)).activeCount(BrowseKind.SONGS))
    }
}

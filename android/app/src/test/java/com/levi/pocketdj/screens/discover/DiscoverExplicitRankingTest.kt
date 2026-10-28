package com.levi.pocketdj.screens.discover

import org.junit.Assert.assertEquals
import org.junit.Test

class DiscoverExplicitRankingTest {
    private fun h(id: String, t: String, a: String, e: Boolean?) = DiscoverHit(appleMusicId = id, title = t, artist = a, explicit = e)

    @Test fun cleanFirstByDefault() {
        val r = DiscoverExplicitRanking.rank(listOf(h("1", "Pulse", "Aria", true), h("2", "Pulse", "Aria", false), h("3", "Other", "B", true)), false)
        assertEquals(listOf("2", "1", "3"), r.map { it.appleMusicId })
    }

    @Test fun explicitFirstWhenPreferred() {
        val r = DiscoverExplicitRanking.rank(listOf(h("1", "Pulse", "Aria", false), h("2", "Pulse", "Aria", true)), true)
        assertEquals(listOf("2", "1"), r.map { it.appleMusicId })
    }

    @Test fun groupsKeepRelativeOrder() {
        val r = DiscoverExplicitRanking.rank(
            listOf(h("a1", "Alpha", "X", true), h("b1", "Beta", "Y", false), h("a2", "Alpha", "X", false), h("b2", "Beta", "Y", true)), false,
        )
        assertEquals(listOf("a2", "a1", "b1", "b2"), r.map { it.appleMusicId })
    }

    @Test fun unclassifiedUntouched() {
        val hits = listOf(h("1", "P", "A", null), h("2", "P", "A", null))
        assertEquals(listOf("1", "2"), DiscoverExplicitRanking.rank(hits, false).map { it.appleMusicId })
    }
}

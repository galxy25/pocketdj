package com.levi.pocketdj.di

import org.junit.Assert.assertEquals
import org.junit.Test

class GamesGraphCapsTest {
    private fun src(id: String, n: Int) = Triple(id, id, (0 until n).map { "s$it" })

    @Test fun collectionCountSongCapAndTotalBudgetMirrorIos() {
        val many = (0 until 600).map { src("c$it", 3) }
        assertEquals(GamesGraph.COLLECTION_CAP, GamesGraph.capCollections(many).size)
        val big = GamesGraph.capCollections(listOf(src("a", 6_000)))
        assertEquals(GamesGraph.SONG_CAP, big[0].songIds.size)
        val budget = GamesGraph.capCollections((0 until 30).map { src("b$it", 5_000) })
        assertEquals(GamesGraph.TOTAL_SONG_CAP, budget.sumOf { it.songIds.size })
    }
}

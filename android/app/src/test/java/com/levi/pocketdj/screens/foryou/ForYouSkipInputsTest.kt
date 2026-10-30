package com.levi.pocketdj.screens.foryou

import com.levi.pocketdj.data.catalog.IndexSong
import com.levi.pocketdj.data.recs.ZoneEngine
import com.levi.pocketdj.data.stats.PlayCountService
import com.levi.pocketdj.data.stats.PlayStatsStore
import java.io.File
import java.nio.file.Files
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Test

class ForYouSkipInputsTest {
    private fun store() = PlayStatsStore(File(Files.createTempDirectory("pdj-skip").toFile(), PlayStatsStore.FILE_NAME), nowMs = 0)

    @Test fun snapshotCarriesCumulativeCountsAndPenaltyOnlyForSkippedSongs() {
        val s = store()
        s.notePlayed("a", 1_000_000)
        repeat(3) { s.noteSkipped("b") }
        val snap = PlayCountService(s).snapshot()
        assertEquals(1, snap.plays["a"])
        assertEquals(3, snap.skips["b"])
        assertFalse("a" in snap.skipPenalty)
        // 3 skips / (max(0,3) + 3) = 0.5
        assertEquals(0.5, snap.skipPenalty["b"]!!, 1e-9)
    }

    @Test fun withSkipsInjectsPenaltyAndKeepsOtherFeedback() {
        val fb = ZoneEngine.Feedback(suppressed = setOf("x"))
        val out = PlayCountService.withSkips(fb, mapOf("b" to 0.5))
        assertEquals(setOf("x"), out.suppressed)
        assertEquals(mapOf("b" to 0.5), out.skipPenalty)
    }

    @Test fun skippedSongsRankLowerThanUnskippedPeer() {
        val now = 1_000_000_000_000.0
        val day = 86_400_000.0
        val songs = listOf("a", "b", "c").map { IndexSong(id = it, artist = "Artist $it", name = "Title $it", year = 1990) }
        val genres = songs.associate { it.id to "g" }
        val plays = songs.map { ZoneEngine.Play(it.id, now - day) }
        val st = store()
        repeat(6) { st.noteSkipped("a") } // alphabetically first: wins the equal-heat tie unless demoted
        fun familiar(fb: ZoneEngine.Feedback) = ZoneEngine.inDaZone(
            songs = songs, genreBySongId = genres, plays = plays, playCount = { 0 },
            lastPlayedMs = emptyMap(), feedback = fb, nowMs = now,
        ).picks.filter { it.pool == ZoneEngine.Pool.FAMILIAR }.map { it.songId }
        assertEquals(listOf("a", "b", "c"), familiar(ZoneEngine.Feedback()))
        val ranked = familiar(PlayCountService.withSkips(ZoneEngine.Feedback(), PlayCountService(st).snapshot().skipPenalty))
        assertEquals(setOf("a", "b", "c"), ranked.toSet()) // demoted, never removed
        assertEquals("a", ranked.last())
    }
}

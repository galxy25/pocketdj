package com.levi.pocketdj.data.jukebox

import org.junit.Assert.assertEquals
import org.junit.Test

class JukeboxPlayedDedupTest {
    private val a = JukeboxOnAir("A", "x")
    private val b = JukeboxOnAir("B", "y")

    /** Feed a sequence of on-air snapshots through the reducer; returns titles newest-first. */
    private fun run(seq: List<JukeboxOnAir?>, cap: Int = 30): List<String> {
        var played = emptyList<JukeboxPlayedEntry>()
        var prev: JukeboxOnAir? = null
        seq.forEachIndexed { i, cur ->
            played = JukeboxPlayedDedup.apply(played, prev, cur, i.toLong(), cap)
            prev = cur
        }
        return played.map { it.title }
    }

    @Test fun pauseResumeCycleThenSkip_isOneRow() = assertEquals(listOf("A"), run(listOf(a, null, a, b)))

    @Test fun rewindOfSameTrack_addsNothing() = assertEquals(listOf("A"), run(listOf(a, a, a, b)))

    @Test fun playPauseResumePause_addsNothingUntilTransition() {
        assertEquals(emptyList<String>(), run(listOf(a, a, a, a)))
        // pause clears now-playing: outgoing A logged once, resume + pause again folds.
        assertEquals(listOf("A"), run(listOf(a, null, a, null)))
    }

    @Test fun nonConsecutiveRepeatsStack() = assertEquals(listOf("A", "B"), run(listOf(a, b, a)).reversed())

    @Test fun foldRefreshesTimestampOfHead() {
        val played = JukeboxPlayedDedup.apply(
            listOf(JukeboxPlayedEntry("A", "x", 1)), a, null, 99,
        )
        assertEquals(listOf(JukeboxPlayedEntry("A", "x", 99)), played)
    }

    @Test fun capRespected() {
        val tracks = (1..10).map { JukeboxOnAir("T$it", "z") } + listOf(null)
        val result = run(tracks, cap = 3)
        assertEquals(listOf("T10", "T9", "T8"), result)
    }

    @Test fun nothingBefore_isNoop() = assertEquals(emptyList<String>(), run(listOf(null, a)))
}

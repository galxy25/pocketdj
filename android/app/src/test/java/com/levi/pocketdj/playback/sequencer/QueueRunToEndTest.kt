package com.levi.pocketdj.playback.sequencer

import com.levi.pocketdj.screens.nowplaying.NowPlayingModel
import com.levi.pocketdj.screens.nowplaying.RecordMath
import kotlinx.coroutines.ExperimentalCoroutinesApi
import kotlinx.coroutines.test.runTest
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

/**
 * UI review 2026-10-28 #7 ("playlist queue stopped after ~3 songs", shot 33). Root cause on the
 * emulator: NOT a dropped queue. SeedRip is 13 clip rows totalling 5:46; shot 13 was taken at
 * 19:28:51 and shot 33 at 20:22:30, so the run had simply reached its natural end (iOS
 * `advanceToNext` also stops there with repeat off). Re-driven three times on the emulator
 * (burned, cloud + concurrent Mix collection download, Mix/Producer/Games tab visits): every
 * playable row played and the run ended after the last one. What WAS wrong is what the deck showed
 * afterwards: the tonearm stayed on the record over "Nothing playing" (now parks off the record).
 */
@OptIn(ExperimentalCoroutinesApi::class)
class QueueRunToEndTest {
    private val ids = listOf("hot", "leech", "indo", "interlude", "anywhere", "jewels", "outreaux",
        "intro", "nostalgia", "origin", "interlude2", "scratch", "statement")

    @Test fun seedRipShapedQueuePlaysEveryPlayableRowThenEnds() = runTest {
        val playable = ids.filter { it != "leech" } // the dimmed metadata-only row
        val h = SequencerHarness(this, backgroundScope, playable.toSet())
        h.seq.play(ids.map { QueueItem(it, title = it) })
        h.settle()
        for ((n, id) in playable.withIndex()) {
            assertTrue("run must still be live before row $n ($id) ends", h.seq.state.value.isRunning)
            assertEquals(id, h.seq.state.value.current?.id)
            h.seq.handleEnded(id); h.settle()
        }
        assertEquals(playable, h.port.loadedIds) // all 12 playable rows sounded, the unplayable one skipped
        val s = h.seq.state.value
        assertFalse(s.isRunning)
        assertTrue(s.queue.isEmpty())
        assertEquals(1, h.port.stops)

        // The deck after the natural end: no track, so the tonearm parks OFF the record.
        val deck = NowPlayingModel.build(s, audible = null, facts = null, startPending = false, appleMusicActive = false)
        assertFalse(deck.hasTrack)
        assertEquals("Nothing playing", deck.title)
    }

    @Test fun parkedTonearmTipIsOffTheRecordAndInsideTheChassis() {
        val (x, y) = RecordMath.tipPosition(RecordMath.TONEARM_PARKED_DEG)
        assertTrue(Math.hypot(x - 0.5, y - 0.5) > RecordMath.RECORD_RADIUS)
        assertTrue(x in 0.0..1.0 && y in 0.0..1.0)
        // ...while at 0 % the stylus sits on the record's outer grooves.
        assertTrue(RecordMath.tipDistanceFromCentre(0.0) < RecordMath.RECORD_RADIUS)
    }
}

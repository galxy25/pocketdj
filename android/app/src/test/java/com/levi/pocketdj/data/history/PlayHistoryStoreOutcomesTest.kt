package com.levi.pocketdj.data.history

import com.levi.pocketdj.data.PdjJson
import com.levi.pocketdj.data.collections.NOW_PLAYING_SETLIST_ID
import com.levi.pocketdj.playback.PlayContext
import java.io.File
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNotNull
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Rule
import org.junit.Test
import org.junit.rules.TemporaryFolder

class PlayHistoryStoreOutcomesTest {
    @get:Rule val tmp = TemporaryFolder()
    private val file get() = File(tmp.root, "h.json")
    private fun store() = PlayHistoryStore(file, PdjJson.lenient)
    private val t0 = 1_750_000_000_000L

    @Test fun record_stampsInstallTzAndOrigin() {
        val s = store()
        val ctx = PlayContext.playlist(NOW_PLAYING_SETLIST_ID, "Mix A")
        val e = s.record("a", context = ctx, nowMs = t0, originCollectionId = "pl_1", tzOffsetMin = -420)!!
        assertEquals(s.installId, e.originInstallId)
        assertEquals(-420, e.tzOffsetMin)
        assertEquals("pl_1", e.originCollectionId)
        // not the now-playing run -> origin not stamped
        val e2 = s.record("b", context = PlayContext.album("al", "A"), nowMs = t0, originCollectionId = "pl_1")!!
        assertNull(e2.originCollectionId)
    }

    @Test fun onRecordFires_onResumeFiresOnWindowHit() {
        val s = store()
        val recorded = mutableListOf<PlayEvent>()
        val resumed = mutableListOf<PlayEvent>()
        s.onRecord = { recorded += it }
        s.onResume = { resumed += it }
        val e = s.record("a", nowMs = t0)!!
        assertNull(s.record("a", nowMs = t0 + 10_000))
        assertEquals(listOf(e), recorded)
        assertEquals(listOf(e), resumed)
        assertNotNull(s.record("a", nowMs = t0 + 40_000))
        assertEquals(2, recorded.size)
    }

    @Test fun markSkipped_idempotent_persists_noOnRecord() {
        val s = store()
        var fired = 0
        val e = s.record("a", nowMs = t0)!!
        s.onRecord = { fired++ }
        s.markSkipped(e.id)
        val rev = s.revision
        s.markSkipped(e.id)
        assertEquals(rev, s.revision)
        s.markSkipped("nope")
        assertEquals(0, fired)
        assertTrue(s.events.single().wasSkipped == true)
        assertTrue(store().events.single().wasSkipped == true)
    }

    @Test fun noteListened_maxMerges_dropsSubOnePercent_clamps() {
        val s = store()
        val e = s.record("a", nowMs = t0)!!
        s.noteListened(e.id, 0.6)
        s.noteListened(e.id, 0.3)
        assertEquals(0.6, s.events.single().listenedFraction!!, 1e-9)
        val rev = s.revision
        s.noteListened(e.id, 0.605)
        assertEquals(rev, s.revision)
        s.noteListened(e.id, 7.0)
        assertEquals(1.0, s.events.single().listenedFraction!!, 1e-9)
        s.noteListened(e.id, Double.NaN)
        assertEquals(1.0, store().events.single().listenedFraction!!, 1e-9)
    }

    @Test fun recountWindow_ignoresForeignEvents_andResumeIsLocalOnly() {
        val s = store()
        s.replaceAll(listOf(PlayEvent("f", "a", t0.toDouble(), originInstallId = "peer")))
        val resumed = mutableListOf<PlayEvent>()
        s.onResume = { resumed += it }
        // a peer's play seconds ago must not swallow a real play here
        assertNotNull(s.record("a", nowMs = t0 + 5_000))
        assertTrue(resumed.isEmpty())
        assertEquals(2, s.playCount("a")) // counts span devices
        assertTrue(s.isFromAnotherDevice(s.events.first()))
        assertFalse(s.isFromAnotherDevice(s.events.last()))
        assertFalse(s.isFromAnotherDevice(PlayEvent("l", "a", 1.0))) // legacy nil = local
    }

    @Test fun recentPlaysForZone_walksBackPastLimitInsideCoverage() {
        val s = store()
        val now = 10.0 * 86_400_000
        val evs = (0 until 10).map { PlayEvent("e$it", "s$it", now - (10 - it) * 3_600_000.0) } +
            PlayEvent("old", "old", now - 100 * 86_400_000.0)
        s.replaceAll(listOf(evs.last()) + evs.dropLast(1))
        val got = s.recentPlaysForZone(limit = 3, coverageDays = 60.0, nowMs = now)
        assertEquals(10, got.size) // walked back past limit; stopped at the out-of-window one
        assertEquals(3, s.recentPlaysForZone(limit = 3, coverageDays = 0.0, nowMs = now).size)
    }

    @Test fun lastLocalEvent_skipsPeers() {
        val s = store()
        s.replaceAll(listOf(PlayEvent("l", "a", 1.0), PlayEvent("p", "a", 2.0, originInstallId = "peer")))
        assertEquals("l", s.lastLocalEvent("a")!!.id)
    }
}

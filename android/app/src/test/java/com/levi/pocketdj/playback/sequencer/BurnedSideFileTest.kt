package com.levi.pocketdj.playback.sequencer

import com.levi.pocketdj.data.burns.Rig
import com.levi.pocketdj.data.burns.album
import com.levi.pocketdj.data.burns.analog
import com.levi.pocketdj.data.burns.bs
import com.levi.pocketdj.data.burns.song
import java.io.File
import kotlinx.coroutines.test.runTest
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNotNull
import org.junit.Assert.assertTrue
import org.junit.Test

/** A burned analog row with a per-song cut on disk plays the shared SIDE file + window, never the cut. */
class BurnedSideFileTest {
    private fun rig(): Rig {
        val r = Rig()
        listOf("s1", "s2").forEachIndexed { i, id ->
            r.rips.entries[id] = analog("alb_1", startMs = i * 60_000L)
            r.catalog[id] = song(id, albumId = "alb_1") to album("alb_1", name = "Live")
        }
        r.rips.serve("rips/alb_1.mp3", 20_000)
        return r
    }

    @Test fun cutOnDiskStillResolvesToSideFileWithWindow() = runTest {
        val r = rig(); val store = r.store()
        store.burn(listOf(bs("s1"), bs("s2")))
        // A cut lands on disk (deterministic -<songId>.mp3 suffix): the cut-preferring lookup would pick it.
        File(r.burns, "Artist-Song s2-1999-s2.mp3").writeBytes(ByteArray(10))
        assertTrue(store.localUrlPreferringCut("s2")!!.isCut)

        val resolver = BurnedRowResolver.from(
            playbackFile = store::localUrlForPlayback,
            startMs = store::startMs,
            durationMs = { 30_000L },
        )
        val lf = resolver.localUrlForPlayback(QueueItem("s2"))!!
        assertTrue(lf.url, lf.url.endsWith("Artist-Live-1999-Rock-alb_1.mp3"))
        assertFalse(lf.url.contains("-s2.mp3"))
        assertEquals(60_000L, lf.startMs); assertEquals(90_000L, lf.endMs)
    }

    @Test fun editedStartMovesTheWindowOnlyWhenTheItemHasAStart() = runTest {
        val r = rig(); val store = r.store()
        store.burn(listOf(bs("s1"), bs("s2")))
        store.segmentStartOverride = { if (it == "s2") 55_000L else null }
        assertEquals(55_000L, store.startMs("s2"))
        assertEquals(0L, store.startMs("s1"))
        assertNotNull(store.localUrlForPlayback("s2"))
        // A digital (no-start) item ignores any override.
        r.rips.entries["d"] = com.levi.pocketdj.data.burns.digital("d"); r.rips.serve("rips/d.mp3")
        r.catalog["d"] = song("d") to album("alb_d")
        store.burn(listOf(bs("d")))
        store.segmentStartOverride = { 99L }
        assertEquals(null, store.startMs("d"))
    }
}

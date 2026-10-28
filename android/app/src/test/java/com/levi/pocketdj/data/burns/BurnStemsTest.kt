package com.levi.pocketdj.data.burns

import com.levi.pocketdj.data.rips.RipStems
import java.io.File
import java.io.IOException
import kotlinx.coroutines.test.runTest
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNotNull
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test

class BurnStemsTest {
    private fun Rig.stemmed(id: String, grid: Boolean = true) {
        rips.entries[id] = digital(id).copy(
            stems = RipStems("stems/$id/vocals.mp3", "stems/$id/drums.mp3", "stems/$id/bass.mp3", "stems/$id/other.mp3"),
            stemVersion = 1,
            beatgrid = if (grid) "rips/analysis/$id.json" else null,
        )
        rips.serve("rips/$id.mp3", 6_000)
        BurnFileNames.STEM_NAMES.forEach { rips.serve("stems/$id/$it.mp3", 1_000 + it.length) }
        if (grid) rips.bodies["$BASE/rips/analysis/$id.json"] = """{"beatGridBpm":120.0,"beatsMs":[0,500]}""".toByteArray()
        catalog[id] = song(id) to album("a")
    }

    @Test fun burnPullsAllFourStemsAndGridWithDeterministicNames() = runTest {
        val r = Rig(); r.stemmed("s1")
        val store = r.store()
        val res = store.burn(listOf(bs("s1")))
        assertEquals(1, res.stemmedSongs); assertEquals(1, res.beatGridded)
        BurnFileNames.STEM_NAMES.forEach { assertTrue(File(r.burns, "stem-s1-$it.mp3").isFile) }
        assertTrue(File(r.burns, "analysis-s1.json").isFile)
        assertTrue(store.stemsBurned("s1")); assertTrue(store.beatgridBurned("s1"))
        assertEquals(listOf("s1"), store.localStemSongIds())
        assertEquals(120.0, store.localBeatGrid("s1")!!.beatGridBpm!!, 0.0)
        // idempotent: a re-burn downloads nothing new
        val n = r.rips.downloads.size
        store.burn(listOf(bs("s1")))
        assertEquals(n, r.rips.downloads.size)
    }

    @Test fun stemsAreAllOrNothingOnRead() = runTest {
        val r = Rig(); r.stemmed("s1")
        val store = r.store()
        store.burn(listOf(bs("s1")))
        File(r.burns, "stem-s1-bass.mp3").delete()
        assertNull(store.localStemFiles("s1"))
        assertFalse(store.stemsBurned("s1"))
        assertEquals(setOf("vocals", "drums", "other"), store.stemPartsBurned("s1"))
        assertEquals(emptyList<String>(), store.localStemSongIds())
        assertTrue(store.burnStemPart("s1", "bass"))
        assertTrue(store.stemsBurned("s1"))
        assertFalse(store.burnStemPart("s1", "kazoo"))
    }

    @Test fun stemFailureNeverFailsTheBurn() = runTest {
        val r = Rig(); r.stemmed("s1")
        r.rips.failWith = { if (it.contains("stems/")) IOException("HTTP 500") else null }
        val store = r.store()
        val res = store.burn(listOf(bs("s1")))
        assertEquals(1, res.burned); assertEquals(0, res.stemmedSongs); assertEquals(0, res.failed)
        assertEquals(BurnState.READY, store.items.value.getValue("s1").state)
        assertNull(store.burnStems("s1"))
    }

    @Test fun burnStemsAndStemsRemoteAndUnstemmedSong() = runTest {
        val r = Rig(); r.stemmed("s1", grid = false)
        r.rips.entries["plain"] = digital("plain")
        val store = r.store()
        assertTrue(store.stemsRemote("s1")); assertFalse(store.stemsRemote("plain"))
        assertNull(store.burnStems("plain"))
        val got = store.burnStems("s1")!!
        assertEquals(setOf("vocals", "drums", "bass", "other"), got.keys)
        assertEquals(got, store.burnStems("s1")) // idempotent, no network
    }

    @Test fun garbageBeatGridIsNeverCached() = runTest {
        val r = Rig(); r.stemmed("s1")
        r.rips.bodies["$BASE/rips/analysis/s1.json"] = "<html>not json</html>".toByteArray()
        val store = r.store()
        val res = store.burn(listOf(bs("s1")))
        assertEquals(0, res.beatGridded)
        assertFalse(File(r.burns, "analysis-s1.json").exists())
        assertNull(store.burnBeatGrid("s1"))
        r.rips.bodies["$BASE/rips/analysis/s1.json"] = """{"beatsMs":[1]}""".toByteArray()
        assertNotNull(store.burnBeatGrid("s1"))
        assertTrue(File(r.burns, "analysis-s1.json").exists())
    }

    @Test fun stopSkipsTheStemPass() = runTest {
        val r = Rig(); r.stemmed("s1"); r.stemmed("s2")
        val store = r.store()
        r.rips.onDownload = { if (it.endsWith("s1.mp3")) store.requestStop() }
        val res = store.burn(listOf(bs("s1"), bs("s2")))
        assertTrue(res.stopped)
        assertFalse(File(r.burns, "stem-s1-vocals.mp3").exists())
    }

    @Test fun adoptStreamedStemsIsAllOrNothingWithRollback() {
        val r = Rig(); val store = r.store()
        val src = tmpDir()
        val files = BurnFileNames.STEM_NAMES.associateWith { File(src, "$it.tmp").apply { writeText(it) } }
        // Break the 3rd move: its source vanished.
        val broken = files.toMutableMap().also { it["bass"] = File(src, "missing.tmp") }
        assertNull(store.adoptStreamedStems("s1", broken))
        assertTrue(r.names().none { it.startsWith("stem-") })
        files.filterKeys { it != "bass" }.values.forEach { assertTrue("rolled back ${it.name}", it.exists()) }
        // Partial key sets are rejected outright.
        assertNull(store.adoptStreamedStems("s1", files.filterKeys { it != "other" }))
        // Success path.
        val out = store.adoptStreamedStems("s1", files)!!
        assertEquals(4, out.size)
        assertTrue(store.stemsBurned("s1"))
        assertTrue(files.values.none { it.exists() })
    }

    @Test fun stemUsageCleanupAndRemovalKeepGridsAndAudio() = runTest {
        val r = Rig(); r.stemmed("s1"); r.stemmed("s2")
        val store = r.store()
        store.burn(listOf(bs("s1", artist = "A"), bs("s2", artist = "B")))
        val total = store.stemUsageBytes()
        assertTrue(total > 0)
        assertEquals(listOf("A", "B"), store.stemUsageByArtist().map { it.artist })
        store.removeStems(listOf("s1"))
        assertFalse(store.stemsBurned("s1")); assertTrue(store.stemsBurned("s2"))
        store.removeAllStems(protecting = setOf("s2"))
        assertTrue(store.stemsBurned("s2"))
        store.removeAllStems()
        assertEquals(0L, store.stemUsageBytes())
        assertTrue(store.beatgridBurned("s1") && store.beatgridBurned("s2"))
        assertNotNull(store.localUrl("s1"))
    }

    @Test fun orphanAuxSweepRemovesOnlyUnledgeredSongs() = runTest {
        val r = Rig(); r.stemmed("s1")
        val store = r.store()
        store.burn(listOf(bs("s1")))
        File(r.burns, "stem-ghost-vocals.mp3").writeText("x")
        File(r.burns, "analysis-ghost.json").writeText("{}")
        store.sweepOrphanAuxFiles()
        assertFalse(File(r.burns, "stem-ghost-vocals.mp3").exists())
        assertFalse(File(r.burns, "analysis-ghost.json").exists())
        assertTrue(store.stemsBurned("s1"))
    }

    @Test fun removeBurnsAlsoRemovesThatSongsStemsAndGrid() = runTest {
        val r = Rig(); r.stemmed("s1")
        val store = r.store()
        store.burn(listOf(bs("s1")))
        store.removeBurns(listOf("s1"))
        assertTrue(r.names().isEmpty())
    }

    @Test fun beatGridFromManifest() {
        val r = Rig()
        r.rips.entries["x"] = digital("x").copy(beatGridBpm = 121.0, firstDownbeatMs = 400, steady = true)
        val g = r.store().beatGrid("x")!!
        assertEquals(121.0, g.bpm!!, 0.0); assertEquals(400L, g.firstDownbeatMs); assertEquals(true, g.steady)
        assertNull(r.store().beatGrid("none"))
    }
}

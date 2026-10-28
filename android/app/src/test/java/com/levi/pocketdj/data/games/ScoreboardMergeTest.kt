package com.levi.pocketdj.data.games

import java.io.File
import java.nio.file.Files
import org.junit.Assert.assertEquals
import org.junit.Assert.assertTrue
import org.junit.Test

/** Two-device convergence scenarios over the tombstone union. */
class ScoreboardMergeTest {
    private val dir = Files.createTempDirectory("mergeboard").toFile().also { it.deleteOnExit() }
    private fun device(name: String) = File(dir, "$name.json").let { it to GameScoreboardStore(it) }

    @Test fun deletionOnOneDevicePropagatesAndNeverResurrects() {
        val (aFile, a) = device("a")
        val (bFile, b) = device("b")
        a.record(GameKind.CollectorsPuzzle, 5, "a1", atMs = 1.0)
        // sync a -> b
        bFile.writeText(aFile.readText()); b.reloadFromDisk()
        assertEquals(1, b.runs.size)
        // b deletes; a (never saw it) pushes its doc again
        b.deleteAll()
        val staleFromA = aFile.readText()
        bFile.writeText(staleFromA)
        assertTrue(b.reloadFromDisk())          // b re-asserts its tombstone
        assertTrue(b.runs.isEmpty())
        // b's doc now reaches a: a drops the run too
        aFile.writeText(bFile.readText()); a.reloadFromDisk()
        assertTrue(a.runs.isEmpty())
        assertEquals(1, a.tombstones.size)
        // and a stale re-push of the old doc cannot bring it back
        aFile.writeText(staleFromA); a.reloadFromDisk()
        assertTrue(a.runs.isEmpty())
    }

    @Test fun runsUnionAcrossDevices() {
        val (aFile, a) = device("a2")
        val (bFile, b) = device("b2")
        a.record(GameKind.CollectorsPuzzle, 5, "a", atMs = 1.0)
        b.record(GameKind.MusicWithFriends, 7, "b", atMs = 2.0)
        val aDoc = aFile.readText(); val bDoc = bFile.readText()
        aFile.writeText(bDoc); a.reloadFromDisk()
        bFile.writeText(aDoc); b.reloadFromDisk()
        assertEquals(a.runs.map { it.id }, b.runs.map { it.id })
        assertEquals(2, a.runs.size)
    }

    @Test fun earliestTombstoneTimeWinsOnUnion() {
        val id = "11111111-1111-1111-1111-111111111111"
        val merged = ScoreboardCodec.unionTombstones(
            listOf(Tombstone(id, 50.0, "x"), Tombstone(id, 20.0, "y"), Tombstone(id, 80.0, "z")),
        )
        assertEquals(listOf(20.0), merged.map { it.at })
        assertEquals("y", merged.single().byInstallId)
    }
}

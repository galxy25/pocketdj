package com.levi.pocketdj.data.games

import java.io.File
import java.nio.file.Files
import java.util.UUID
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNotNull
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Before
import org.junit.Test

class GameScoreboardStoreTest {
    private lateinit var dir: File
    private lateinit var file: File

    @Before fun setUp() {
        dir = Files.createTempDirectory("scoreboard").toFile().also { it.deleteOnExit() }
        file = File(dir, GamesPrefs.SCOREBOARD_FILE)
    }

    private fun store() = GameScoreboardStore(file)
    private fun onDisk() = ScoreboardCodec.decode(file.readText())!!

    @Test fun tokensFrozenLabelsFree() {
        assertEquals(
            listOf("collectorsPuzzle", "musicWithFriends", "inThePocket"),
            GameKind.entries.map { it.token },
        )
        assertEquals(listOf("Gem Collector", "Music with Friends", "In the Pocket"), GameKind.entries.map { it.label })
        assertEquals(GameKind.InThePocket, GameKind.fromToken("inThePocket"))
        assertNull(GameKind.fromToken("nope"))
    }

    @Test fun recordTrimsAt500NeverTombstones() {
        val s = store()
        repeat(GameScoreboardStore.MAX_RUNS + 7) { s.record(GameKind.CollectorsPuzzle, it, null, atMs = it.toDouble()) }
        assertEquals(GameScoreboardStore.MAX_RUNS, s.runs.size)
        assertEquals(7, s.runs.first().score) // oldest trimmed
        assertTrue(s.tombstones.isEmpty())
        assertNull(onDisk().deleted)
        assertEquals(GameScoreboardStore.MAX_RUNS, onDisk().runs.size)
    }

    @Test fun bestRunTieNewestWins() {
        val s = store()
        s.record(GameKind.CollectorsPuzzle, 9, "old", atMs = 1.0)
        s.record(GameKind.CollectorsPuzzle, 9, "new", atMs = 2.0)
        s.record(GameKind.CollectorsPuzzle, 3, "low", atMs = 3.0)
        assertEquals("new", s.bestRun(GameKind.CollectorsPuzzle)!!.settingsSummary)
        assertEquals(9, s.bestScore(GameKind.CollectorsPuzzle))
        assertNull(s.bestRun(GameKind.InThePocket))
        assertEquals(listOf("low", "new", "old"), s.recentRuns(GameKind.CollectorsPuzzle, 5).map { it.settingsSummary })
        assertEquals(2, s.recentRuns(GameKind.CollectorsPuzzle, 2).size)
    }

    @Test fun deleteGameTombstonesAndSurvivesReload() {
        val s = store()
        s.record(GameKind.CollectorsPuzzle, 5, null)
        s.record(GameKind.CollectorsPuzzle, 6, null)
        s.record(GameKind.MusicWithFriends, 4, null)
        assertEquals(2, s.delete(GameKind.CollectorsPuzzle))
        assertEquals(1, s.runs.size)
        assertEquals(2, s.tombstones.size)
        val reopened = store()
        assertEquals(listOf(GameKind.MusicWithFriends.token), reopened.runs.map { it.game })
        assertEquals(2, reopened.tombstones.size)
        assertEquals(0, reopened.delete(GameKind.CollectorsPuzzle)) // nothing left
    }

    @Test fun deleteAllThenReloadOfStaleDocRewrites() {
        val s = store()
        s.record(GameKind.CollectorsPuzzle, 5, null)
        s.record(GameKind.InThePocket, 3, null, mapOf("outcome" to "pocket"))
        val stale = file.readText() // a peer's doc still holding both runs
        assertEquals(2, s.deleteAll())
        file.writeText(stale)
        // id-based mustSave: no extra runs to count, but the doc carries tombstoned runs.
        assertTrue(s.reloadFromDisk())
        assertTrue(s.runs.isEmpty())
        val doc = onDisk()
        assertTrue(doc.runs.isEmpty())
        assertEquals(2, doc.deleted!!.size)
        assertTrue(store().runs.isEmpty()) // next launch does not resurrect
        assertFalse(s.reloadFromDisk()) // converged: nothing more to write
    }

    @Test fun initFiltersRunsThroughTombstones() {
        val id = UUID.randomUUID().toString().uppercase()
        file.writeText(
            """{"schemaVersion":1,"installId":"X","runs":[{"id":"$id","game":"collectorsPuzzle","score":1,"at":1}],""" +
                """"deleted":[{"id":"$id","at":2}]}""",
        )
        assertTrue(store().runs.isEmpty())
    }

    @Test fun mergeIdempotentCommutative() {
        val a = store()
        a.record(GameKind.CollectorsPuzzle, 5, "a", atMs = 10.0)
        val peerFile = File(dir, "peer.json")
        val b = GameScoreboardStore(peerFile)
        b.record(GameKind.CollectorsPuzzle, 8, "b", atMs = 20.0)
        val peerDoc = peerFile.readText()

        file.writeText(peerDoc)
        val firstSave = a.reloadFromDisk() // a held a run the doc lacked
        assertTrue(firstSave)
        assertEquals(listOf("a", "b"), a.runs.map { it.settingsSummary })
        val rev = a.revision
        val snapshot = a.runs
        file.writeText(peerDoc)
        a.reloadFromDisk() // again: still idempotent for content
        assertEquals(snapshot, a.runs)
        assertEquals(2, a.runs.size)
        assertTrue(a.revision >= rev)

        // Commutativity: b applying a's doc ends with the same set.
        peerFile.writeText(peerDoc)
        val aDoc = file.readText()
        file.writeText(aDoc)
        peerFile.writeText(aDoc)
        b.reloadFromDisk()
        assertEquals(a.runs.map { it.id }, b.runs.map { it.id })
    }

    @Test fun reloadMissingFileIsNoop() {
        val s = store()
        s.record(GameKind.CollectorsPuzzle, 1, null)
        file.delete()
        assertFalse(s.reloadFromDisk())
        assertEquals(1, s.runs.size)
    }

    @Test fun tombstoneCapOldestFirst() {
        val incoming = (0 until GameScoreboardStore.MAX_TOMBSTONES + 5).map {
            Tombstone(UUID.randomUUID().toString().uppercase(), it.toDouble())
        }
        val merged = ScoreboardCodec.unionTombstones(incoming)
        assertEquals(GameScoreboardStore.MAX_TOMBSTONES, merged.size)
        assertEquals(5.0, merged.first().at, 0.0)
        // earliest `at` wins for a duplicated id
        val dup = ScoreboardCodec.unionTombstones(
            listOf(Tombstone("AAAAAAAA-0000-0000-0000-000000000000", 9.0), Tombstone("aaaaaaaa-0000-0000-0000-000000000000", 3.0)),
        )
        assertEquals(1, dup.size)
        assertEquals(3.0, dup.single().at, 0.0)
    }

    @Test fun lenientRowDrop() {
        val good = UUID.randomUUID().toString().uppercase()
        file.writeText(
            """{"schemaVersion":1,"installId":"I","runs":[""" +
                """{"id":"$good","game":"inThePocket","score":3,"at":5,"detail":{"outcome":"pocket"}},""" +
                """{"id":"not-a-uuid","game":"collectorsPuzzle","score":1,"at":1},""" +
                """{"id":"${UUID.randomUUID()}","game":"collectorsPuzzle","score":"oops","at":1},""" +
                """{"id":"${UUID.randomUUID()}","game":"collectorsPuzzle","score":2,"at":1,"detail":{"k":7}},""" +
                """42],"deleted":[{"id":"junk"},5]}""",
        )
        val s = store()
        assertEquals(listOf(good), s.runs.map { it.id })
        assertEquals("pocket", s.runs.single().detail!!["outcome"])
        assertTrue(s.tombstones.isEmpty())
        assertEquals("I", s.installId)
    }

    @Test fun corruptDocumentStartsEmpty() {
        file.writeText("{ not json")
        val s = store()
        assertTrue(s.runs.isEmpty())
        assertTrue(s.installId.isNotEmpty())
        s.record(GameKind.CollectorsPuzzle, 1, null) // and recovers
        assertEquals(1, store().runs.size)
    }

    @Test fun deletedKeyOmittedWhenEmpty() {
        val s = store()
        s.record(GameKind.CollectorsPuzzle, 1, null)
        assertFalse(file.readText().contains("\"deleted\""))
        s.deleteAll()
        assertTrue(file.readText().contains("\"deleted\""))
        s.clear() // hard wipe: no residual tombstones
        assertFalse(file.readText().contains("\"deleted\""))
        assertTrue(s.tombstones.isEmpty())
    }

    @Test fun iosShapeRoundTrips() {
        val s = store()
        val r = s.record(GameKind.MusicWithFriends, 4, "sum", mapOf("sessionId" to "x"), 1234.0)
        assertTrue(r.id == r.id.uppercase())
        val doc = onDisk()
        assertEquals(1, doc.schemaVersion)
        assertEquals(s.installId, doc.installId)
        val row = doc.runs.single()
        assertEquals("musicWithFriends", row.game)
        assertEquals(1234.0, row.at, 0.0)
        assertEquals(s.installId, row.originInstallId)
        assertEquals("x", row.detail!!["sessionId"])
    }

    @Test fun inThePocketStatsStreaks() {
        val s = store()
        fun r(outcome: String, at: Double) = s.record(GameKind.InThePocket, 3, null, mapOf("outcome" to outcome), at)
        assertEquals("No rounds yet", s.inThePocketStats().summary())
        r("pocket", 1.0); r("pocket", 2.0)
        r("abandoned", 3.0) // neither extends nor breaks
        r("pocket", 4.0)
        r("broke", 5.0)
        r("pocket", 6.0)
        val st = s.inThePocketStats()
        assertEquals(6, st.rounds)
        assertEquals(4, st.pockets)
        assertEquals(4.0 / 5.0, st.pocketRate!!, 1e-9) // abandoned excluded from decided
        assertEquals(3, st.bestStreak)
        assertEquals(1, st.currentStreak)
        assertEquals("6 rounds · 80% in the pocket · best streak 3", st.summary())
    }

    @Test fun statsWithOnlyAbandonedHasNoRate() {
        val s = store()
        s.record(GameKind.InThePocket, 0, null, mapOf("outcome" to "abandoned"))
        val st = s.inThePocketStats()
        assertNull(st.pocketRate)
        assertEquals("1 round · best streak 0", st.summary())
    }

    @Test fun seedFixtureReplaceExisting() {
        val s = store()
        s.record(GameKind.InThePocket, 2, null)
        s.seedFixture(replaceExisting = false) // polite no-op
        assertEquals(1, s.runs.size)
        s.seedFixture(replaceExisting = true)
        assertEquals(4, s.runs.size)
        assertEquals(9, s.bestScore(GameKind.CollectorsPuzzle))
        assertEquals(4, s.bestScore(GameKind.MusicWithFriends))
        assertEquals(listOf(7, 9, 5), s.recentRuns(GameKind.CollectorsPuzzle, 5).map { it.score })
        assertNull(s.bestRun(GameKind.InThePocket))
        assertNull(onDisk().deleted)
        assertNotNull(store().bestRun(GameKind.CollectorsPuzzle))
    }
}

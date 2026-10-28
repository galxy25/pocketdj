package com.levi.pocketdj.data.applemusic

import com.levi.pocketdj.data.applemusic.PlaylistWriteBack.JobState
import java.io.File
import kotlinx.coroutines.test.runTest
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNotNull
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Rule
import org.junit.Test
import org.junit.rules.TemporaryFolder

class PlaylistWriteBackQueueTest {
    @get:Rule val tmp = TemporaryFolder()

    private var clock = 1_000_000.0
    private var ids = 0

    /** Scriptable transport. */
    private class Fake : PlaylistWriteBackTransport {
        override var isSupported = true
        var canWriteNow = true
        var resolveResult: String? = "mk-1"
        var resolveCalls = 0
        val adds = mutableListOf<Pair<String, String>>()
        var addThrows: ((Int) -> Throwable?) = { null }
        var catalogResult: String? = null
        var catalogThrows: Throwable? = null
        override var lastResolutionNote: String? = null
        override suspend fun canWrite() = canWriteNow
        override suspend fun resolvePlaylistId(name: String, expectedAppleMusicIds: List<String>): String? {
            resolveCalls++
            return resolveResult
        }
        override suspend fun addSong(appleMusicId: String, toPlaylistId: String) {
            addThrows(adds.size + 1)?.let { adds += appleMusicId to toPlaylistId; throw it }
            adds += appleMusicId to toPlaylistId
        }
        override suspend fun resolveCatalogId(song: WriteBackSong): String? {
            catalogThrows?.let { throw it }
            return catalogResult
        }
    }

    private fun file() = File(tmp.root, PlaylistWriteBack.FILE_NAME)
    private fun queue(t: PlaylistWriteBackTransport? = Fake()) = PlaylistWriteBack(
        file = file(), transport = t, now = { clock }, newJobId = { "wbj_${ids++}" },
    )

    private fun PlaylistWriteBack.add(song: String, pl: String = "pl1", am: String? = "am-$song") =
        enqueue(pl, "Mix", song, am, title = "T$song", artist = "A")

    // ---- enqueue ----
    @Test fun enqueueDedup_acrossQueuedAndDelivered_butNotAcrossPlaylists() = runTest {
        val q = queue()
        assertNotNull(q.add("s1"))
        assertNull(q.add("s1"))               // queued twin
        assertNotNull(q.add("s1", pl = "pl2")) // different playlist is a different debt
        q.run()
        assertEquals(2, q.jobs.count { it.state == JobState.DELIVERED })
        assertNull(q.add("s1"))               // delivered twin
        assertEquals(2, q.jobs.size)
    }

    @Test fun enqueueRejectsNoIdentityAndEmptyName() {
        val q = queue()
        assertNull(q.enqueue("pl", "Mix", "s", null, title = "T", artist = ""))
        assertNull(q.enqueue("pl", "Mix", "s", "  ", title = "", artist = ""))
        assertNull(q.enqueue("pl", "", "s", "am"))
        assertNotNull(q.enqueue("pl", "Mix", "s", null, title = "T", artist = "A")) // identity-only is fine
    }

    @Test fun enqueueMany_sameRulesAndDedupWithinBatch() {
        val q = queue()
        val items = listOf(
            PlaylistWriteBack.EnqueueItem("pl", "Mix", "a", "am-a", "", ""),
            PlaylistWriteBack.EnqueueItem("pl", "Mix", "a", "am-a", "", ""), // dup in batch
            PlaylistWriteBack.EnqueueItem("pl", "Mix", "b", null, "T", "A"),
            PlaylistWriteBack.EnqueueItem("pl", "Mix", "c", null, "", ""),  // no identity
        )
        assertEquals(2, q.enqueueMany(items))
        assertEquals(0, q.enqueueMany(items))
        assertEquals(listOf("a", "b"), q.jobs.map { it.songId })
    }

    // ---- state machine ----
    @Test fun maxAttemptsToFailed_withBackoffGatingBetweenAttempts() = runTest {
        val t = Fake().apply { addThrows = { WriteBackException.Http(500) } }
        val q = queue(t)
        q.add("s1")
        for (n in 1..3) {
            q.run()
            val j = q.jobs.single()
            assertEquals(JobState.QUEUED, j.state); assertEquals(n, j.attempts)
            // Inside the backoff window the job is not retried.
            q.run(); assertEquals(n, q.jobs.single().attempts)
            clock += PlaylistWriteBack.backoffMs(n) + 1
        }
        q.run()
        val j = q.jobs.single()
        assertEquals(JobState.FAILED, j.state)
        assertEquals(PlaylistWriteBack.MAX_ATTEMPTS, j.attempts)
        assertNotNull(j.settledAtMs); assertNull(j.nextAttemptAtMs)
        assertEquals("Apple Music API error (500)", j.lastError)
    }

    @Test fun backoffSchedule_is30s_1m_2m() {
        assertEquals(30_000.0, PlaylistWriteBack.backoffMs(1), 0.0)
        assertEquals(60_000.0, PlaylistWriteBack.backoffMs(2), 0.0)
        assertEquals(120_000.0, PlaylistWriteBack.backoffMs(3), 0.0)
    }

    @Test fun retryRearmsOnlyFailedJobs() = runTest {
        val t = Fake().apply { addThrows = { WriteBackException.Http(500) } }
        val q = queue(t)
        q.add("s1")
        repeat(4) { q.run(); clock += 200_000 }
        assertEquals(JobState.FAILED, q.jobs.single().state)
        t.addThrows = { null }
        q.retryFailed()
        assertEquals(JobState.QUEUED, q.jobs.single().state); assertEquals(0, q.jobs.single().attempts)
        q.run()
        assertEquals(JobState.DELIVERED, q.jobs.single().state)
        q.retry(q.jobs.single().id) // not failed -> no-op
        assertEquals(JobState.DELIVERED, q.jobs.single().state)
    }

    @Test fun signedOutLeavesJobsQueuedWithoutBurningAnAttempt() = runTest {
        val t = Fake().apply { canWriteNow = false }
        val q = queue(t)
        q.add("s1")
        q.run()
        assertEquals(JobState.QUEUED, q.jobs.single().state)
        assertEquals(0, q.jobs.single().attempts)
        assertTrue(q.lastError!!.contains("Sign in to Apple Music"))
        t.canWriteNow = true
        q.run()
        assertEquals(JobState.DELIVERED, q.jobs.single().state)
        assertNull(q.lastError)
    }

    @Test fun unsupportedTransportSettlesNotApplicable() = runTest {
        val q = queue(Fake().apply { isSupported = false })
        q.add("s1")
        q.run()
        assertEquals(JobState.NOT_APPLICABLE, q.jobs.single().state)
        assertFalse(q.canWriteBack)
        val q2 = queue(null)
        assertFalse(q2.canWriteBack)
    }

    // ---- prune / cancel ----
    @Test fun pruneKeepsQueuedAndFailed_dropsOldestSettledFirst() = runTest {
        val t = Fake()
        val q = queue(t)
        // 150 delivered (oldest settled first), then 40 queued + failed to push past 200.
        for (i in 0 until 150) { q.add("d$i"); clock += 1 }
        q.run()
        t.addThrows = { WriteBackException.Http(500) }
        q.add("f1")
        repeat(4) { q.run(); clock += 200_000 }
        assertEquals(JobState.FAILED, q.jobs.first { it.songId == "f1" }.state)
        t.canWriteNow = false
        for (i in 0 until 60) q.add("q$i")
        assertEquals(200, q.jobs.size)
        assertEquals(60, q.pending.size)
        assertEquals(1, q.failed.size)
        // The 11 oldest delivered rows were pruned.
        assertFalse(q.jobs.any { it.songId == "d0" })
        assertTrue(q.jobs.any { it.songId == "d149" })
    }

    @Test fun cancelPendingScoped_onlyUndeliveredForThatPlaylistsSongs() = runTest {
        val t = Fake()
        val q = queue(t)
        q.add("a"); q.run()                    // delivered a@pl1
        t.canWriteNow = false
        q.add("b"); q.add("c")                 // queued b,c @pl1
        q.add("b", pl = "pl2")                 // queued b @pl2
        q.cancelPending("pl1", setOf("b"))
        val left = q.jobs.map { it.songId + "@" + it.indexPlaylistId }.toSet()
        assertEquals(setOf("a@pl1", "c@pl1", "b@pl2"), left)
        q.cancelPending("pl1", setOf("a")) // delivered is irretrievable - left alone
        assertTrue("a@pl1" in q.jobs.map { it.songId + "@" + it.indexPlaylistId })
    }

    // ---- the join ----
    @Test fun resolvedPlaylistIdIsPersistedAndReusedWithoutAnotherResolve() = runTest {
        val t = Fake()
        val q = queue(t)
        q.add("a"); q.add("b")
        q.run()
        assertEquals(1, t.resolveCalls)
        assertEquals(mapOf("pl1" to "mk-1"), q.resolvedPlaylistIds)
        q.add("c"); q.run()
        assertEquals(1, t.resolveCalls)
        assertEquals(listOf("mk-1", "mk-1", "mk-1"), t.adds.map { it.second })
        // Survives a relaunch, and later jobs are seeded with it.
        val q2 = queue(t)
        assertEquals(mapOf("pl1" to "mk-1"), q2.resolvedPlaylistIds)
        assertEquals("mk-1", q2.add("d")!!.musicKitPlaylistId)
    }

    @Test fun playlistGoneClearsMappingAndReResolvesExactlyOnce() = runTest {
        val t = Fake()
        val q = queue(t)
        q.add("a"); q.run()
        assertEquals(1, t.resolveCalls)
        t.resolveResult = "mk-2"
        t.addThrows = { n -> if (t.adds.last().second == "mk-1" && n == 2) WriteBackException.PlaylistGone("mk-1") else null }
        q.add("b"); q.run()
        assertEquals(2, t.resolveCalls)
        assertEquals("mk-2", q.resolvedPlaylistIds["pl1"])
        assertEquals(JobState.DELIVERED, q.jobs.first { it.songId == "b" }.state)
    }

    @Test fun playlistGoneTwiceDoesNotLoop() = runTest {
        val t = Fake().apply { addThrows = { WriteBackException.PlaylistGone("x") } }
        val q = queue(t)
        q.add("a"); q.run()
        assertEquals(2, t.adds.size)           // first try + ONE retry after re-resolve
        assertEquals(JobState.QUEUED, q.jobs.single().state)
        assertEquals(1, q.jobs.single().attempts)
    }

    @Test fun missingPlaylistIsAnActionableFailure() = runTest {
        val q = queue(Fake().apply { resolveResult = null })
        q.add("a"); q.run()
        val j = q.jobs.single()
        assertEquals(1, j.attempts)
        assertTrue(j.lastError!!.contains("named “Mix”"))
    }

    @Test fun guessedResolutionIsRecordedAndSurvivesCleanDrain_thenRetiredByUnambiguousOne() = runTest {
        val t = Fake().apply { lastResolutionNote = "Several playlists called Mix" }
        val q = queue(t)
        q.add("a"); q.run()
        assertEquals("Several playlists called Mix", q.jobs.single().resolutionNote)
        assertEquals("Several playlists called Mix", q.resolutionWarning)
        assertNull(q.lastError) // the guess is NOT an error
        // A different playlist resolves unambiguously: the earlier job still carries a note, so the warning stays.
        t.lastResolutionNote = null
        q.add("b", pl = "pl2"); q.run()
        assertEquals("Several playlists called Mix", q.resolutionWarning)
    }

    // ---- catalog-id resolution ----
    @Test fun identityOnlyJobResolvesCatalogIdAndPersistsItBeforeAdding() = runTest {
        val t = Fake().apply { catalogResult = "cat-9" }
        val q = queue(t)
        q.enqueue("pl1", "Mix", "s", null, title = "T", artist = "A")
        q.run()
        assertEquals("cat-9", q.jobs.single().appleMusicId)
        assertEquals("cat-9", t.adds.single().first)
    }

    @Test fun noConfidentMatchIsTerminalUnresolvable_notRetryable_andSupersededByRealId() = runTest {
        val t = Fake()
        val q = queue(t)
        q.enqueue("pl1", "Mix", "s", null, title = "T", artist = "A")
        q.run()
        assertEquals(JobState.UNRESOLVABLE, q.jobs.single().state)
        assertTrue(q.isUnsyncable("s"))
        assertNull(q.enqueue("pl1", "Mix", "s", null, title = "T", artist = "A")) // still no id -> no-op
        assertEquals(0, t.adds.size)
        // The crawl later finds a real id: the stale verdict is superseded, the badge clears.
        assertNotNull(q.enqueue("pl1", "Mix", "s", "am-s", title = "T", artist = "A"))
        assertFalse(q.isUnsyncable("s"))
        q.run()
        assertEquals(JobState.DELIVERED, q.jobs.single().state)
    }

    @Test fun transientCatalogFailureRetriesInsteadOfSettlingUnresolvable() = runTest {
        val t = Fake().apply { catalogThrows = WriteBackException.Http(503) }
        val q = queue(t)
        q.enqueue("pl1", "Mix", "s", null, title = "T", artist = "A")
        q.run()
        assertEquals(JobState.QUEUED, q.jobs.single().state)
        assertEquals(1, q.jobs.single().attempts)
    }

    // ---- persistence ----
    @Test fun ledgerIsDurableAfterEveryJob_relaunchSeesDelivered() = runTest {
        val t = Fake()
        val q = queue(t)
        q.add("a"); q.add("b")
        t.addThrows = { n -> if (n == 2) WriteBackException.Http(500) else null }
        q.run()
        val q2 = queue(t) // a fresh process
        assertEquals(JobState.DELIVERED, q2.jobs.first { it.songId == "a" }.state)
        assertEquals(JobState.QUEUED, q2.jobs.first { it.songId == "b" }.state)
    }

    @Test fun decodesIosShapeDocumentLeniently() {
        file().writeText(
            """{"schemaVersion":1,"resolvedPlaylistIds":{"p":"mk"},"jobs":[
              {"id":"wbj_A","indexPlaylistId":"p","playlistName":"N","songId":"s","appleMusicId":"1","queuedAtMs":5,"attempts":2,"state":"notApplicable","futureField":true},
              {"indexPlaylistId":"p","songId":"t","state":"weird","queuedAtMs":"bad"},
              "not an object"
            ]}""",
        )
        val q = queue()
        assertEquals(2, q.jobs.size)
        assertEquals(JobState.NOT_APPLICABLE, q.jobs[0].state)
        assertEquals(2, q.jobs[0].attempts)
        assertEquals(JobState.QUEUED, q.jobs[1].state)  // unknown state -> queued
        assertEquals(0.0, q.jobs[1].queuedAtMs, 0.0)
        assertTrue(q.jobs[1].id.startsWith("wbj_"))
        assertEquals("mk", q.resolvedPlaylistIds["p"])
    }

    @Test fun writesIosShapeStateTokensAndOmitsNulls() {
        val q = queue()
        q.add("s")
        val text = file().readText()
        assertTrue(text.contains("\"state\":\"queued\""))
        assertTrue(text.contains("\"schemaVersion\":1"))
        assertFalse(text.contains("null"))
    }

    @Test fun corruptDocumentIsQuarantinedNotSilentlyOverwritten() {
        file().writeText("{{not json")
        val q = queue()
        assertTrue(q.jobs.isEmpty())
        assertTrue(File(tmp.root, PlaylistWriteBack.FILE_NAME + ".bak").exists())
    }

    @Test fun clearWipesQueueAndDocument() {
        val q = queue()
        q.add("a")
        assertTrue(file().exists())
        q.clear()
        assertTrue(q.jobs.isEmpty()); assertFalse(file().exists())
    }

    @Test fun appleMusicSourceNames() {
        assertTrue(PlaylistWriteBack.isAppleMusicSource("Apple Music (Local)"))
        assertTrue(PlaylistWriteBack.isAppleMusicSource("Apple Music"))
        assertFalse(PlaylistWriteBack.isAppleMusicSource("My Vinyl"))
        assertFalse(PlaylistWriteBack.isAppleMusicSource(null))
    }
}

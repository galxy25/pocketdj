package com.levi.pocketdj.data.games.puzzle

import java.io.File
import java.util.ArrayDeque
import kotlin.coroutines.CoroutineContext
import kotlinx.coroutines.CoroutineDispatcher
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.ExperimentalCoroutinesApi
import kotlinx.coroutines.test.StandardTestDispatcher
import kotlinx.coroutines.test.TestCoroutineScheduler
import kotlinx.coroutines.test.advanceTimeBy
import kotlinx.coroutines.test.runCurrent
import kotlinx.serialization.json.Json
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Rule
import org.junit.Test
import org.junit.rules.TemporaryFolder

/** Port of PuzzleDecisionStoreTests on virtual time (no real sleeps). */
@OptIn(ExperimentalCoroutinesApi::class)
class PuzzleDecisionStoreTest {
    @get:Rule val tmp = TemporaryFolder()

    private val scheduler = TestCoroutineScheduler()
    private val scope = CoroutineScope(StandardTestDispatcher(scheduler))
    private var ids = 0
    private fun file() = File(tmp.root, "dec-${System.nanoTime()}.json")
    private fun store(f: File, writeContext: CoroutineContext = kotlin.coroutines.EmptyCoroutineContext) =
        PuzzleDecisionStore(f, scope, writeContext, newId = { "ID-${ids++}" })

    /** A writer that only runs when the test says so — models a block already handed to the queue. */
    private class ManualDispatcher : CoroutineDispatcher() {
        val queue = ArrayDeque<Runnable>()
        var dispatched = 0
        override fun dispatch(context: CoroutineContext, block: Runnable) { dispatched++; queue.add(block) }
        fun drain() { while (queue.isNotEmpty()) queue.poll().run() }
    }

    private fun peerRow(id: String = "PEER-1", song: String = "sng_peer") =
        PuzzleDecisionStore.Decision(id = id, roundId = "R", at = 500.0, songId = song, action = "skipped", originInstallId = "peer")

    private fun peerBytes(vararg rows: PuzzleDecisionStore.Decision): ByteArray =
        Json.encodeToString(PuzzleDecisionStore.Document.serializer(), PuzzleDecisionStore.Document(installId = "peer", decisions = rows.toList())).toByteArray()

    private fun reload(f: File) = PuzzleDecisionStore(f, scope, kotlin.coroutines.EmptyCoroutineContext)

    @Test fun recordAssignSkipExpired() {
        val s = store(file())
        s.record("R", "sng_1", "assigned", collectionId = "pkt_x", collectionName = "Crate", positionInRound = 0)
        s.record("R", "sng_2", "skipped", positionInRound = 1)
        s.record("R", "sng_3", "expired", positionInRound = 2)
        s.record("OTHER", "sng_9", "assigned")
        val rows = s.decisions("R")
        assertEquals(3, rows.size)
        assertEquals(listOf("assigned", "skipped", "expired"), rows.map { it.action })
        assertEquals("pkt_x", rows[0].collectionId)
        assertEquals("Crate", rows[0].collectionName)
        assertNull("skip carries no target", rows[1].collectionId)
        assertEquals(s.installId, rows[0].originInstallId)
    }

    @Test fun unionMergeAndIdempotentReload() {
        val f = file()
        val s = store(f)
        s.record("R", "sng_1", "assigned", nowMs = 1000.0)
        f.writeBytes(peerBytes(peerRow()))
        assertTrue(s.reloadFromDisk())
        assertEquals(2, s.decisions.size)
        assertEquals("sorted by time", listOf("sng_peer", "sng_1"), s.decisions.map { it.songId })
        s.reloadFromDisk()
        assertEquals("idempotent", 2, s.decisions.size)
    }

    @Test fun reloadReturnsFalseWhenThePulledDocAlreadyHoldsEverything() {
        val f = file()
        val s = store(f)
        s.record("R", "sng_1", "assigned", nowMs = 1000.0)
        s.flush()
        val before = s.revision
        assertFalse(s.reloadFromDisk())
        assertEquals("nothing new ⇒ revision unchanged", before, s.revision)
    }

    @Test fun reloadMatchesIdsCaseInsensitively() {
        val f = file()
        val s = store(f)
        s.record("R", "sng_1", "assigned", nowMs = 1000.0)
        s.flush()
        val mine = s.decisions.single()
        // the same row echoed back by iOS with a different UUID case must not duplicate
        f.writeBytes(peerBytes(mine.copy(id = mine.id.lowercase())))
        s.reloadFromDisk()
        assertEquals(1, s.decisions.size)
    }

    @Test fun settingsSnapshotRoundTrips() {
        val f = file()
        val s = store(f)
        val settings = PuzzleSettings(
            roundSeconds = 300, favoriteBias = PuzzleSettings.Bias.FAVOR, genreCategories = setOf("hip-hop", "jazz"),
            yearMin = 1990, yearMax = 1999, membershipMode = PuzzleSettings.MembershipMode.NOT_IN_ANY,
            membershipCollectionIds = setOf("pls_a"), targetCollectionIds = listOf("pkt_x", "pls_b"),
        )
        s.record("R", "sng_1", "assigned", settings = settings)
        s.flush()
        assertEquals(settings, reload(f).decisions.first().settings)
    }

    @Test fun recordBatchWritesOnceAndFlushLands() {
        val f = file()
        val s = store(f)
        val settings = PuzzleSettings(roundSeconds = 90)
        val made = s.recordBatch(
            listOf(
                PuzzleDecisionStore.BatchRow("sng_1", "expired", 0),
                PuzzleDecisionStore.BatchRow("sng_2", "expired", 1),
                PuzzleDecisionStore.BatchRow("sng_3", "expired", 2),
            ),
            roundId = "R", settings = settings,
        )
        assertEquals(3, made.size)
        assertEquals(listOf(0, 1, 2), s.decisions("R").map { it.positionInRound })
        assertEquals(settings, s.decisions.last().settings)
        assertTrue("the write is coalesced, not per-row", s.hasUnsavedChanges)
        assertFalse("…and nothing hit the disk yet", f.exists())
        s.flush()
        assertFalse(s.hasUnsavedChanges)
        assertEquals(3, reload(f).decisions.size)
    }

    @Test fun recordBatchOfNothingIsANoOp() {
        val s = store(file())
        assertTrue(s.recordBatch(emptyList(), "R").isEmpty())
        assertFalse(s.hasUnsavedChanges)
        assertEquals(0, s.revision)
    }

    @Test fun burstOfRecordsCoalescesIntoOneWriteInsideSixHundredMs() {
        val f = file()
        val writer = ManualDispatcher()
        val s = store(f, writer)
        for (i in 0 until 20) s.record("R", "sng_$i", "skipped")
        assertTrue(s.hasUnsavedChanges)
        scheduler.advanceTimeBy(599); scheduler.runCurrent()
        assertEquals("still inside the debounce window", 0, writer.dispatched)
        assertFalse(f.exists())
        scheduler.advanceTimeBy(1); scheduler.runCurrent()
        assertEquals("exactly ONE write for the whole burst", 1, writer.dispatched)
        writer.drain(); scheduler.runCurrent()
        assertFalse(s.hasUnsavedChanges)
        assertEquals(20, reload(f).decisions.size)
    }

    @Test fun eachNewRecordRestartsTheDebounce() {
        val f = file()
        val writer = ManualDispatcher()
        val s = store(f, writer)
        s.record("R", "a", "skipped")
        scheduler.advanceTimeBy(500); scheduler.runCurrent()
        s.record("R", "b", "skipped")
        scheduler.advanceTimeBy(500); scheduler.runCurrent()
        assertEquals("first timer was superseded", 0, writer.dispatched)
        scheduler.advanceTimeBy(100); scheduler.runCurrent()
        assertEquals(1, writer.dispatched)
        writer.drain(); scheduler.runCurrent()
        assertEquals(2, reload(f).decisions.size)
    }

    @Test fun pendingSaveNeverClobbersACloudMerge() {
        val f = file()
        val s = store(f)
        s.record("R", "sng_mine", "assigned", nowMs = 2000.0)
        assertTrue(s.hasUnsavedChanges)
        f.writeBytes(peerBytes(peerRow()))
        s.reloadFromDisk()
        assertEquals(2, s.decisions.size)
        scheduler.advanceTimeBy(1200); scheduler.runCurrent()
        assertEquals(setOf("sng_mine", "sng_peer"), reload(f).decisions.map { it.songId }.toSet())
    }

    /** A block already handed to the writer survives job cancellation — the generation must stop it. */
    @Test fun staleEnqueuedWriteSkipsAfterAnOrderedPullMerge() {
        val f = file()
        val writer = ManualDispatcher()
        val s = store(f, writer)
        s.record("R", "sng_mine", "assigned", nowMs = 2000.0)
        scheduler.advanceTimeBy(600); scheduler.runCurrent()
        assertEquals("the pre-merge snapshot is ENQUEUED on the writer", 1, writer.dispatched)
        s.applyPulledPayload(peerBytes(peerRow()))
        assertTrue("we hold a row the pulled doc lacks ⇒ merge-save", s.reloadFromDisk())
        assertEquals(2, s.decisions.size)
        writer.drain(); scheduler.runCurrent() // the stale block finally runs…
        assertEquals("…and must write NOTHING", setOf("sng_mine", "sng_peer"), reload(f).decisions.map { it.songId }.toSet())
    }

    @Test fun staleEnqueuedWriteSkipsAfterAnOrderedPullWithoutMerge() {
        val f = file()
        val writer = ManualDispatcher()
        val s = store(f, writer)
        s.record("R", "sng_mine", "assigned")
        scheduler.advanceTimeBy(600); scheduler.runCurrent()
        s.applyPulledPayload(peerBytes(peerRow()))
        writer.drain(); scheduler.runCurrent()
        assertEquals(listOf("sng_peer"), reload(f).decisions.map { it.songId })
    }

    @Test fun flushAsyncLandsImmediatelyWithoutTheDebounce() {
        val f = file()
        val s = store(f)
        s.record("R", "sng_1", "assigned")
        s.flushAsync()
        scheduler.advanceTimeBy(1); scheduler.runCurrent() // far inside the 600 ms window
        assertFalse(s.hasUnsavedChanges)
        assertEquals(1, reload(f).decisions.size)
    }

    @Test fun flushAsyncKeepsPendingTrueUntilTheWriterRuns() {
        val f = file()
        val writer = ManualDispatcher()
        val s = store(f, writer)
        s.record("R", "sng_1", "assigned")
        s.flushAsync()
        scheduler.runCurrent()
        assertTrue("enqueued, not yet landed", s.hasUnsavedChanges)
        s.flush() // a suspension's synchronous flush still catches it
        assertFalse(s.hasUnsavedChanges)
        assertEquals(1, reload(f).decisions.size)
    }

    @Test fun saveAfterFlushAsyncWinsTheRace() {
        val f = file()
        val writer = ManualDispatcher()
        val s = store(f, writer)
        s.record("R", "sng_1", "assigned")
        s.flushAsync()
        scheduler.runCurrent()
        s.clear() // bumps generation + writes the empty doc synchronously
        writer.drain(); scheduler.runCurrent()
        assertTrue(reload(f).decisions.isEmpty())
    }

    @Test fun flushWithNothingPendingDoesNotTouchTheFile() {
        val f = file()
        val s = store(f)
        s.flush()
        assertFalse(f.exists())
    }

    @Test fun flushWritesSynchronously() {
        val f = file()
        val s = store(f)
        s.record("R", "sng_1", "assigned")
        assertFalse(f.exists())
        s.flush()
        assertTrue(f.exists())
        assertEquals(1, reload(f).decisions.size)
        // the debounce timer must not write again afterwards
        val len = f.length()
        scheduler.advanceTimeBy(2000); scheduler.runCurrent()
        assertEquals(len, f.length())
    }

    @Test fun capIsTwentyThousandOldestDropped() {
        val s = store(file())
        val first = (0 until 15_000).map { PuzzleDecisionStore.BatchRow("a$it", "skipped", it) }
        s.recordBatch(first, "R", nowMs = 1.0)
        val second = (0 until 5_005).map { PuzzleDecisionStore.BatchRow("b$it", "skipped", it) }
        s.recordBatch(second, "R", nowMs = 2.0)
        assertEquals(PuzzleDecisionStore.MAX_DECISIONS, s.decisions.size)
        assertEquals(20_000, PuzzleDecisionStore.MAX_DECISIONS)
        assertEquals("a5", s.decisions.first().songId) // 20005 - 20000 = 5 oldest dropped
        assertEquals("b5004", s.decisions.last().songId)
    }

    @Test fun capAlsoAppliesToTheUnionReload() {
        val f = file()
        val s = store(f)
        val peerRows = (0 until 20_010).map { peerRow(id = "P$it", song = "p$it").copy(at = it.toDouble()) }
        f.writeBytes(peerBytes(*peerRows.toTypedArray()))
        s.reloadFromDisk()
        assertEquals(20_000, s.decisions.size)
        assertEquals("p10", s.decisions.first().songId)
    }

    @Test fun lenientDecodeDropsBadRowsNotTheLog() {
        val f = file()
        val good = PuzzleDecisionStore.Decision(id = "G", roundId = "R", at = 1000.0, songId = "sng_1", action = "assigned")
        val goodJson = Json.encodeToString(PuzzleDecisionStore.Decision.serializer(), good)
        f.writeText("""{ "schemaVersion": 1, "installId": "i1", "decisions": [ $goodJson, { "id": 42 }, "junk", null ] }""")
        val s = PuzzleDecisionStore(f, scope, kotlin.coroutines.EmptyCoroutineContext)
        assertEquals(1, s.decisions.size)
        assertEquals("sng_1", s.decisions.first().songId)
        assertEquals("i1", s.installId)
    }

    @Test fun corruptOrMissingFileStartsFreshWithAnInstallId() {
        val f = file()
        f.writeText("{{{ not json")
        val s = PuzzleDecisionStore(f, scope, kotlin.coroutines.EmptyCoroutineContext)
        assertTrue(s.decisions.isEmpty())
        assertTrue(s.installId.isNotBlank())
        assertTrue(PuzzleDecisionStore(file(), scope).installId.isNotBlank())
    }

    @Test fun readsAnIosShapedDocument() {
        val f = file()
        f.writeText(
            """{"schemaVersion":1,"installId":"IOS-INSTALL","decisions":[
              {"id":"6F9619FF-8B86-D011-B42D-00C04FC964FF","roundId":"A1B2C3D4-0000-0000-0000-000000000001",
               "at":1761000000000.5,"songId":"sng_9","action":"assigned","collectionId":"pkt_x",
               "collectionName":"Crate","positionInRound":3,"originInstallId":"IOS-INSTALL",
               "settings":{"roundSeconds":180,"playCountBias":"favor","favoriteBias":"off",
                           "genreCategories":["jazz"],"membershipMode":"inAny",
                           "membershipCollectionIds":["pls_a"],"targetCollectionIds":["pkt_x"]},
               "someFutureField":true}]}""",
        )
        val d = PuzzleDecisionStore(f, scope, kotlin.coroutines.EmptyCoroutineContext).decisions.single()
        assertEquals(1761000000000.5, d.at, 0.0)
        assertEquals(PuzzleSettings.Bias.FAVOR, d.settings!!.playCountBias)
        assertEquals(PuzzleSettings.Similarity.ON, d.settings!!.similarity) // older iOS blob ⇒ default
        assertEquals(PuzzleSettings.MembershipMode.IN_ANY, d.settings!!.membershipMode)
        assertEquals(3, d.positionInRound)
    }

    @Test fun writtenDocumentCarriesSchemaVersionInstallIdAndOmitsNulls() {
        val f = file()
        val s = store(f)
        s.record("R", "sng_1", "skipped")
        s.flush()
        val text = f.readText()
        assertTrue(text.contains("\"schemaVersion\":1"))
        assertTrue(text.contains("\"installId\":\"${s.installId}\""))
        assertFalse("nil optionals are omitted like Swift's synthesized Codable", text.contains("null"))
    }

    @Test fun revisionBumpsOnEveryMutationAndStateFlowTracksIt() {
        val s = store(file())
        assertEquals(0, s.revision)
        s.record("R", "a", "skipped")
        s.recordBatch(listOf(PuzzleDecisionStore.BatchRow("b", "expired", 1)), "R")
        assertEquals(2, s.revision)
        assertEquals(2, s.state.value.decisions.size)
        s.clear()
        assertEquals(3, s.revision)
        assertTrue(s.decisions.isEmpty())
    }

    @Test fun clearWritesTheEmptyDocumentSynchronously() {
        val f = file()
        val s = store(f)
        s.record("R", "a", "skipped")
        s.flush()
        s.clear()
        assertTrue(reload(f).decisions.isEmpty())
        assertFalse(s.hasUnsavedChanges)
    }

    @Test fun installIdIsStableAcrossReloads() {
        val f = file()
        val s = store(f)
        s.record("R", "a", "skipped")
        s.flush()
        assertEquals(s.installId, reload(f).installId)
    }
}

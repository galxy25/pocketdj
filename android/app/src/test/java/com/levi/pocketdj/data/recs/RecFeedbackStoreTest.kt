package com.levi.pocketdj.data.recs

import com.levi.pocketdj.data.recs.RecFeedbackStore.Surface
import com.levi.pocketdj.data.recs.RecFeedbackStore.Verdict
import java.io.File
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.SupervisorJob
import org.junit.After
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNotEquals
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test

class RecFeedbackStoreTest {
    private val now = 1_800_000_000_000.0
    private val day = 86_400_000.0
    private val scope = CoroutineScope(SupervisorJob() + Dispatchers.Unconfined)
    private val tmp = kotlin.io.path.createTempDirectory("recfb").toFile()
    private val file = File(tmp, "fb.json")
    private val identity = File(tmp, "install-id")

    @After fun cleanup() { tmp.deleteRecursively() }

    private fun store(f: File = file, id: File? = identity) = RecFeedbackStore(f, scope, id, saveDebounceMs = 1)

    @Test fun tombstoneIsSevenDaysEvaluatedAtRead() {
        val s = store()
        s.record("a", "zone", Verdict.REJECTED, Surface.TILE, atMs = now)
        assertTrue(s.isSuppressed("a", "zone", now + 6.9 * day))
        assertEquals(setOf("a"), s.activeTombstones("zone", now + 6.9 * day).keys)
        // same store, later clock: the row is simply no longer a tombstone (no sweep happened)
        assertFalse(s.isSuppressed("a", "zone", now + 7.1 * day))
        assertTrue(s.activeTombstones("zone", now + 7.1 * day).isEmpty())
        // verdict itself is still standing (it only stops sinking)
        assertEquals(Verdict.REJECTED, s.verdict("a", "zone"))
        // tombstones are per scope
        assertFalse(s.isSuppressed("a", "other", now))
    }

    @Test fun futureStampIsKeptRatherThanDropped() {
        val s = store()
        s.record("a", "zone", Verdict.REJECTED, Surface.TILE, atMs = now + 3 * day)
        assertTrue(s.isSuppressed("a", "zone", now))
    }

    @Test fun acceptIsPermanentInScopeAndIsNotATombstone() {
        val s = store()
        s.record("a", "zone", Verdict.ACCEPTED, Surface.TILE, atMs = now)
        assertEquals(mapOf("a" to now), s.acceptedInScope("zone"))
        assertEquals(mapOf("a" to now), s.acceptedInScope("zone").filterKeys { it == "a" }) // never ages out
        assertTrue(s.activeTombstones("zone", now + 100 * day).isEmpty())
        assertEquals(setOf("a"), s.zoneFeedback("zone", now + 100 * day).suppressed) // accepted joins suppressed
        assertEquals(Verdict.ACCEPTED, s.anyVerdict("a"))
    }

    @Test fun toggleUndoWritesAClearedRowNotADeletion() {
        val s = store()
        assertEquals(Verdict.REJECTED, s.toggle("a", Verdict.REJECTED, "zone", Surface.TILE, atMs = now))
        assertNull(s.toggle("a", Verdict.REJECTED, "zone", Surface.TILE, atMs = now + 1000))
        assertNull(s.verdict("a", "zone"))
        assertFalse(s.isSuppressed("a", "zone", now + 2000))
        assertNull(s.anyVerdict("a"))
        // two rows, the second is a "cleared" verdict
        assertEquals(listOf("rejected", "cleared"), s.decisions.map { it.verdict })
        // switching direction is not an undo
        assertEquals(Verdict.ACCEPTED, s.toggle("a", Verdict.ACCEPTED, "zone", Surface.TILE, atMs = now + 3000))
        assertEquals(Verdict.REJECTED, s.toggle("a", Verdict.REJECTED, "zone", Surface.TILE, atMs = now + 4000))
    }

    @Test fun sameMillisecondDoubleTapResolvesBySeq() {
        val s = store()
        s.record("a", "zone", Verdict.REJECTED, Surface.TILE, atMs = now)
        s.record("a", "zone", Verdict.ACCEPTED, Surface.TILE, atMs = now)
        assertEquals(Verdict.ACCEPTED, s.verdict("a", "zone"))
        val s2 = store(File(tmp, "fb2.json"), null)
        s2.record("a", "zone", Verdict.ACCEPTED, Surface.TILE, atMs = now)
        s2.record("a", "zone", Verdict.REJECTED, Surface.TILE, atMs = now)
        assertEquals(Verdict.REJECTED, s2.verdict("a", "zone"))
        assertTrue(s2.decisions[1].seq > s2.decisions[0].seq)
    }

    @Test fun globalTasteIsTheNewestVerdictInAnyScope() {
        val s = store()
        s.record("a", "crateA", Verdict.REJECTED, Surface.TILE, atMs = now)
        s.record("a", "crateB", Verdict.ACCEPTED, Surface.TILE, atMs = now + 1000)
        assertEquals(Verdict.ACCEPTED, s.anyVerdict("a"))
        assertEquals(Verdict.REJECTED, s.verdict("a", "crateA")) // scoped opinion untouched
        s.record("a", "crateB", Verdict.CLEARED, Surface.TILE, atMs = now + 2000)
        // newest overall is a cleared row => no global opinion
        assertNull(s.anyVerdict("a"))
        val w = s.weights(Verdict.REJECTED, now + 365 * 10 * day)
        assertTrue(w.isEmpty())
    }

    @Test fun weightsDecayWithAFloor() {
        val s = store()
        s.record("fresh", "zone", Verdict.REJECTED, Surface.TILE, atMs = now)
        s.record("ancient", "zone", Verdict.REJECTED, Surface.TILE, atMs = now - 40_000 * day)
        val w = s.weights(Verdict.REJECTED, now)
        assertEquals(1.0, w.getValue("fresh"), 1e-9)
        assertEquals(0.05, w.getValue("ancient"), 1e-9)
    }

    @Test fun partitionSinksNeverFilters() {
        val s = store()
        s.record("b", "zone", Verdict.REJECTED, Surface.TILE, atMs = now - 2 * day)
        s.record("d", "zone", Verdict.REJECTED, Surface.TILE, atMs = now - 3 * day)
        val ids = listOf("a", "b", "c", "d", "a")
        val p = s.partition(ids, "zone", now)
        assertEquals(listOf("a", "c"), p.live)
        assertEquals(listOf("d", "b"), p.sunk) // oldest rejection first
        assertEquals(listOf("a", "c", "d", "b"), s.rankedIds(ids, "zone", now))
        assertEquals(3, s.visibleCount(ids, "zone", now)) // a, c, a (raw count minus tombstoned)
        // a tombstone for an id the list no longer holds is still reachable
        s.record("gone", "zone", Verdict.REJECTED, Surface.TILE, atMs = now - 1 * day)
        assertEquals(listOf("d", "b", "gone"), s.partition(listOf("a"), "zone", now).sunk)
        // after expiry everything is live again, untouched order
        assertEquals(RecFeedbackStore.Partition(ids, emptyList()), s.partition(ids, "zone", now + 30 * day))
    }

    @Test fun blankSongOrScopeRecordsNothing() {
        val s = store()
        assertNull(s.record("", "zone", Verdict.ACCEPTED, Surface.TILE))
        assertNull(s.record("a", "", Verdict.ACCEPTED, Surface.TILE))
        assertTrue(s.decisions.isEmpty())
        assertEquals(0, s.revision)
    }

    @Test fun revisionBumpsOnRecordAndPlayingScope() {
        val s = store()
        s.record("a", "zone", Verdict.ACCEPTED, Surface.TILE)
        assertEquals(1, s.revision)
        s.beginPlayback("crateA", listOf("a", "b"))
        assertEquals(2, s.revision)
        s.endPlaybackScope()
        assertEquals(3, s.revision)
        s.endPlaybackScope() // already null: no bump
        assertEquals(3, s.revision)
    }

    @Test fun playingScopeResolvesOnlyForSongsInTheStampedQueue() {
        val s = store()
        assertNull(s.scopeForPlaying("a"))
        s.beginPlayback("crateA", listOf("a", "b"), atMs = now)
        assertEquals("crateA", s.scopeForPlaying("a"))
        assertNull(s.scopeForPlaying("zzz"))
        assertNull(s.scopeForPlaying(null))
    }

    @Test fun lenientDecodeSkipsBadRowsAndKeepsGoodOnes() {
        val text = """
            {"schemaVersion":1,"installId":"INST","seq":7,"decisions":[
              {"id":"11111111-1111-1111-1111-111111111111","at":1000,"songId":"a","scope":"zone","verdict":"accepted","surface":"carPlay","artistKey":"x","genre":"g","originInstallId":"O","seq":3},
              {"at":"notanumber","songId":"b","scope":"zone","verdict":"accepted"},
              {"at":2000,"songId":"c","scope":"zone"},
              {"at":3000,"songId":"","scope":"zone","verdict":"accepted"},
              "garbage",
              {"id":"not-a-uuid","at":4000,"songId":"d","scope":"zone","verdict":"rejected"}
            ]}
        """.trimIndent()
        val doc = RecFeedbackStore.decodeDocument(text)!!
        assertEquals(listOf("a", "d"), doc.decisions.map { it.songId })
        val a = doc.decisions[0]
        assertEquals("carPlay", a.surface)
        assertEquals(3, a.seq)
        assertEquals("x", a.artistKey)
        val d = doc.decisions[1]
        assertEquals("tile", d.surface) // missing surface defaults
        assertEquals(0, d.seq) // pre-seq rows decode to 0
        assertEquals(36, d.id.length) // bad id replaced with a fresh UUID
        assertEquals(7, doc.seq)
        assertEquals("INST", doc.installId)
        assertNull(RecFeedbackStore.decodeDocument("[1,2]"))
        assertNull(RecFeedbackStore.decodeDocument("not json"))
    }

    @Test fun documentWithMissingFieldsStillDecodes() {
        val doc = RecFeedbackStore.decodeDocument("{}")!!
        assertEquals(REC_FEEDBACK_SCHEMA_VERSION, doc.schemaVersion)
        assertTrue(doc.decisions.isEmpty())
        assertNull(doc.playing)
        assertTrue(doc.installId.isNotEmpty())
    }

    @Test fun encodeDecodeRoundTripKeepsEverything() {
        val doc = RecFeedbackStore.Document(
            installId = "I", seq = 9,
            decisions = listOf(
                RecFeedbackStore.Decision("AAAAAAAA-0000-0000-0000-000000000000", 1_800_000_000_123.0, "s", "zone", "rejected",
                    "nowPlaying", "ak", "gn", "I", 5),
            ),
            playing = RecFeedbackStore.PlayingScope("zone", listOf("s", "t"), 42.0),
        )
        val text = RecFeedbackStore.encodeDocument(doc)
        assertTrue(text.contains("\"at\":1800000000123"))
        assertEquals(doc, RecFeedbackStore.decodeDocument(text))
    }

    @Test fun persistsAndReloadsAcrossInstancesWithLocalIdentity() {
        val s = store()
        s.record("a", "zone", Verdict.REJECTED, Surface.TILE, atMs = now)
        s.beginPlayback("crateA", listOf("a"), atMs = now)
        s.flush()
        val reopened = store()
        assertEquals(s.installId, reopened.installId)
        assertEquals(Verdict.REJECTED, reopened.verdict("a", "zone"))
        assertEquals("crateA", reopened.scopeForPlaying("a")) // our own document => playing adopted
        // new record continues the seq, never reuses one
        val before = reopened.decisions.maxOf { it.seq }
        assertTrue(reopened.record("b", "zone", Verdict.ACCEPTED, Surface.TILE)!!.seq > before)
    }

    @Test fun playingScopeFromAPeersDocumentIsNotAdopted() {
        val peer = RecFeedbackStore.Document(
            installId = "PEER", seq = 1,
            playing = RecFeedbackStore.PlayingScope("crateX", listOf("a"), 1.0),
        )
        file.writeText(RecFeedbackStore.encodeDocument(peer))
        identity.writeText("MINE")
        val s = store()
        assertEquals("MINE", s.installId) // a pulled doc cannot move our id
        assertNull(s.scopeForPlaying("a"))
    }

    @Test fun reloadFromDiskUnionsByIdAndWritesBackWhenWeHoldExtraRows() {
        val s = store()
        s.record("mine", "zone", Verdict.ACCEPTED, Surface.TILE, atMs = now)
        s.flush()
        // a peer's pull replaces the file with a document that has a different row and lacks ours
        val peerRow = RecFeedbackStore.Decision("BBBBBBBB-0000-0000-0000-000000000000", now + 5, "theirs", "zone", "rejected", "tile", null, null, "PEER", 1)
        s.applyPulledPayload(RecFeedbackStore.encodeDocument(RecFeedbackStore.Document(installId = "PEER", decisions = listOf(peerRow))).toByteArray())
        assertTrue(s.reloadFromDisk()) // we held a row the doc lacked -> merged doc written back
        assertEquals(setOf("mine", "theirs"), s.decisions.map { it.songId }.toSet())
        assertEquals(Verdict.REJECTED, s.verdict("theirs", "zone"))
        val onDisk = RecFeedbackStore.decodeDocument(file.readText())!!
        assertEquals(2, onDisk.decisions.size)
        // second reload is a no-op
        assertFalse(s.reloadFromDisk())
    }

    @Test fun clearEmptiesEverythingAndPersists() {
        val s = store()
        s.record("a", "zone", Verdict.REJECTED, Surface.TILE, atMs = now)
        s.beginPlayback("z", listOf("a"))
        s.clear()
        assertTrue(s.decisions.isEmpty())
        assertNull(s.playing)
        assertNull(s.verdict("a", "zone"))
        assertTrue(RecFeedbackStore.decodeDocument(file.readText())!!.decisions.isEmpty())
    }

    @Test fun decisionLogIsCappedAtTwentyThousand() {
        assertEquals(20_000, RecFeedbackStore.MAX_DECISIONS)
        val s = RecFeedbackStore(file, scope, identity, saveDebounceMs = 1, maxDecisions = 50)
        repeat(55) { s.record("s$it", "zone", Verdict.ACCEPTED, Surface.TILE, atMs = now + it) }
        assertEquals(50, s.decisions.size)
        assertEquals("s5", s.decisions.first().songId) // oldest dropped
    }

    @Test fun decisionsSinceIsOrderedByAtThenSeq() {
        val s = store()
        s.record("late", "zone", Verdict.ACCEPTED, Surface.TILE, atMs = now + 10)
        s.record("early", "zone", Verdict.ACCEPTED, Surface.TILE, atMs = now)
        s.record("early2", "zone", Verdict.ACCEPTED, Surface.TILE, atMs = now)
        assertEquals(listOf("early", "early2", "late"), s.decisionsSince(now).map { it.songId })
        assertEquals(listOf("late"), s.decisionsSince(now + 1).map { it.songId })
    }

    @Test fun zoneFeedbackCombinesTombstonesAcceptsAndWeights() {
        val s = store()
        s.record("rej", "zone", Verdict.REJECTED, Surface.TILE, atMs = now)
        s.record("acc", "zone", Verdict.ACCEPTED, Surface.TILE, atMs = now)
        s.record("elsewhere", "other", Verdict.REJECTED, Surface.TILE, atMs = now)
        val fb = s.zoneFeedback("zone", now)
        assertEquals(setOf("rej", "acc"), fb.suppressed)
        assertEquals(setOf("rej", "elsewhere"), fb.rejected.keys) // taste half is global
        assertEquals(setOf("acc"), fb.accepted.keys)
        assertNotEquals(fb, ZoneEngine.Feedback())
    }
}

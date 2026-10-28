package com.levi.pocketdj.di

import com.levi.pocketdj.data.recs.ForYouFeedSnapshot
import com.levi.pocketdj.data.recs.ForYouFeedStore
import com.levi.pocketdj.data.recs.RecFeedbackStore
import java.io.File
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.SupervisorJob
import kotlinx.coroutines.runBlocking
import org.junit.After
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test

class BrowseGraphRecsWiringTest {
    private val tmp = kotlin.io.path.createTempDirectory("brwrecs").toFile()
    private val fbFile = File(tmp, BrowseGraph.REC_FEEDBACK_FILE)
    private val feedFile = File(tmp, ForYouFeedStore.FILE_NAME)
    private val scope = CoroutineScope(SupervisorJob() + Dispatchers.Unconfined)
    private val fb = lazy { RecFeedbackStore(fbFile, scope, File(tmp, "id"), saveDebounceMs = 1) }
    private val feed = lazy { ForYouFeedStore(feedFile) }

    @After fun cleanup() { tmp.deleteRecursively() }

    @Test fun syncKeysAndFilesMirrorIos() {
        val e = BrowseGraph.recsSyncEntries(fb, feed).associateBy { it.key }
        assertEquals("pocketdj-rec-feedback.json", e["rec-feedback"]!!.fileName)
        assertEquals(ForYouFeedStore.FILE_NAME, e["foryou-feed"]!!.fileName)
        assertTrue(e.values.all { it.applyPayload != null && it.onPulled != null })
    }

    @Test fun pulledFeedbackPayloadLandsAndIsAdopted() {
        val src = RecFeedbackStore(File(tmp, "other.json"), scope, null, saveDebounceMs = 1)
        src.record("a", "zone", RecFeedbackStore.Verdict.REJECTED, RecFeedbackStore.Surface.TILE, atMs = 1_800_000_000_000.0)
        src.flush()
        val bytes = File(tmp, "other.json").readBytes()
        val entry = BrowseGraph.recsSyncEntries(fb, feed).first { it.key == "rec-feedback" }
        entry.applyPayload!!(bytes)
        entry.onPulled!!()
        assertEquals(RecFeedbackStore.Verdict.REJECTED, fb.value.verdict("a", "zone"))
    }

    @Test fun resetClearsVerdictsAndFeedFromMemoryAndDisk() = runBlocking {
        fb.value.record("a", "zone", RecFeedbackStore.Verdict.REJECTED, RecFeedbackStore.Surface.TILE)
        fb.value.flush()
        feed.value.commit(ForYouFeedSnapshot(refreshedAtMs = 5.0, zoneIds = listOf("x")))
        assertTrue(feedFile.exists())
        BrowseGraph.recsResetHooks(fb, feed).forEach { it.reset() }
        assertNull(fb.value.verdict("a", "zone"))
        assertFalse(feedFile.exists())
        assertTrue(feed.value.snapshot.zoneIds.isEmpty())
    }

    @Test fun flushableWritesPendingDecisionAndSkipsUntouchedStore() = runBlocking {
        val untouched = lazy<RecFeedbackStore> { error("must not initialize") }
        BrowseGraph.recsFlushable(untouched).flush() // no throw
        val big = RecFeedbackStore(fbFile, scope, null, saveDebounceMs = 60_000)
        big.record("a", "zone", RecFeedbackStore.Verdict.REJECTED, RecFeedbackStore.Surface.TILE)
        BrowseGraph.recsFlushable(lazyOf(big)).flush()
        assertTrue(fbFile.exists() && fbFile.length() > 0)
    }
}

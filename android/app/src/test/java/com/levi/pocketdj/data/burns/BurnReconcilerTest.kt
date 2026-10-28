package com.levi.pocketdj.data.burns

import java.io.File
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

class BurnReconcilerTest {
    private fun item(id: String, file: String, state: BurnState = BurnState.READY) = BurnItem(
        songId = id, title = id, artist = "A", audioFileName = file, sidecarFileName = "", source = "digital",
        bytes = 1, state = state, wasAppStorage = true,
    )

    @Test fun missingFileIsDropped() {
        val d = tmpDir()
        val out = BurnReconciler.reconcile(listOf(item("a", "gone.mp3")), { d })
        assertEquals(setOf("a"), out.dropped)
    }

    @Test fun poisoned536ByteXmlIsDeletedAndDropped() {
        val d = tmpDir()
        val f = File(d, "bad.mp3")
        val xml = "<?xml version=\"1.0\"?><Error><Code>InvalidArgument</Code>" + " ".repeat(480)
        f.writeText(xml.take(536))
        assertEquals(536, f.length().toInt())
        val out = BurnReconciler.reconcile(listOf(item("a", "bad.mp3")), { d })
        assertEquals(setOf("a"), out.dropped)
        assertFalse(f.exists())
    }

    @Test fun smallButRealAudioAndBigXmlLookalikeAreKept() {
        val d = tmpDir()
        File(d, "tiny.mp3").writeBytes(byteArrayOf(0x49, 0x44, 0x33) + ByteArray(100)) // ID3, < 4 KB, not XML
        File(d, "big.mp3").writeText("<?xml" + "x".repeat(5_000)) // >= 4 KB floor: kept
        val out = BurnReconciler.reconcile(listOf(item("a", "tiny.mp3"), item("b", "big.mp3")), { d })
        assertTrue(out.dropped.isEmpty())
        assertTrue(File(d, "tiny.mp3").exists() && File(d, "big.mp3").exists())
    }

    @Test fun unreachableDirAndNonReadyItemsAreSkippedNotPruned() {
        val out = BurnReconciler.reconcile(
            listOf(item("a", "x.mp3"), item("e", "y.mp3", BurnState.ERROR)),
            { null },
        )
        assertTrue(out.dropped.isEmpty())
        val d = tmpDir()
        assertTrue(BurnReconciler.reconcile(listOf(item("e", "y.mp3", BurnState.ERROR)), { d }).dropped.isEmpty())
    }
}

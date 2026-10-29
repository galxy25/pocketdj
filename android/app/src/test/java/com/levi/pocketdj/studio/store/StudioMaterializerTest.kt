package com.levi.pocketdj.studio.store

import kotlinx.coroutines.async
import kotlinx.coroutines.runBlocking
import org.junit.Assert.*
import org.junit.Rule
import org.junit.Test
import org.junit.rules.TemporaryFolder
import java.io.ByteArrayInputStream
import java.io.File

class StudioMaterializerTest {
    @get:Rule val tmp = TemporaryFolder()

    private val docs = HashMap<String, ByteArray>()
    private val stats = HashMap<String, SafStat>()
    private var opens = 0
    private fun doc(uri: String, size: Int, mtime: Long = 1, fill: Byte = 7) { docs[uri] = ByteArray(size) { fill }; stats[uri] = SafStat(size.toLong(), mtime) }
    private fun mat(max: Long = 1_000) = StudioMaterializer(tmp.newFolder(), { stats[it] }, { opens++; docs[it]?.let(::ByteArrayInputStream) }, max)

    @Test fun fileRefPassesThroughWithoutCopying() = runBlocking {
        val f = tmp.newFile("a.m4a").also { it.writeText("x") }
        val m = mat()
        val l = m.lease(StudioFileRef(f, f.toURI().toString()))!!
        assertSame(f, l.file); assertEquals(0, opens); assertEquals(0, m.cachedCount())
        l.release(); l.release(); assertTrue("direct file never deleted", f.isFile)
    }

    @Test fun contentUriIsCopiedIntoStudioSafCache() = runBlocking {
        doc("content://x/1", 100)
        val l = mat().lease(StudioFileRef(null, "content://x/1"))!!
        assertEquals(StudioMaterializer.DIR_NAME, l.file.parentFile!!.name)
        assertEquals(100L, l.file.length()); assertEquals(1, opens)
    }

    @Test fun cacheHitDoesNotRecopyButChangedMtimeDoes() = runBlocking {
        doc("content://x/1", 100)
        val m = mat(); val ref = StudioFileRef(null, "content://x/1")
        m.lease(ref)!!.release(); m.lease(ref)!!.release()
        assertEquals(1, opens)
        doc("content://x/1", 100, mtime = 2, fill = 9)
        val l = m.lease(ref)!!
        assertEquals(2, opens); assertEquals(9.toByte(), l.file.readBytes()[0])
    }

    @Test fun lruEvictsOldestUnpinnedOverTheByteCap() = runBlocking {
        doc("content://a", 400); doc("content://b", 400); doc("content://c", 400)
        val m = mat(1_000)
        val a = m.lease(StudioFileRef(null, "content://a"))!!; a.release()
        val b = m.lease(StudioFileRef(null, "content://b"))!!; b.release()
        val c = m.lease(StudioFileRef(null, "content://c"))!!
        assertFalse("oldest evicted", a.file.exists()); assertTrue(b.file.exists()); assertTrue(c.file.exists())
        assertEquals(2, m.cachedCount())
    }

    @Test fun pinnedEntriesSurviveEvictionAndReleaseIsIdempotent() = runBlocking {
        doc("content://a", 600); doc("content://b", 600)
        val m = mat(1_000)
        val a = m.lease(StudioFileRef(null, "content://a"))!!   // still held
        val b = m.lease(StudioFileRef(null, "content://b"))!!
        assertTrue(a.file.exists()); assertTrue(b.file.exists())   // over cap but both pinned
        a.release(); a.release()                                    // second release must not unpin b or underflow
        assertFalse(a.file.exists()); assertTrue(b.file.exists())
    }

    @Test fun revokedOrUnreadableUriYieldsNullAndLeavesNoPartial() = runBlocking {
        val m = mat()
        assertNull(m.lease(StudioFileRef(null, "content://gone")))          // stat fails
        stats["content://noopen"] = SafStat(5, 1)
        assertNull(m.lease(StudioFileRef(null, "content://noopen")))        // open fails
        assertNull(m.lease(StudioFileRef(null, "file:///nope")))            // not a content uri, no file
        assertEquals(0, m.cachedCount())
    }
}

class StudioMaterializerRobustnessTest {
    @get:Rule val tmp = TemporaryFolder()

    @Test fun concurrentLeasesOfSameUriCopyOnceAndBothGetIntactFile() = runBlocking {
        val bytes = ByteArray(5000) { 3 }
        val opens = java.util.concurrent.atomic.AtomicInteger()
        val m = StudioMaterializer(tmp.newFolder(), { SafStat(5000, 1) }, { opens.incrementAndGet(); Thread.sleep(50); java.io.ByteArrayInputStream(bytes) }, 1_000_000)
        val ref = StudioFileRef(null, "content://same")
        val ls = (1..4).map { async(kotlinx.coroutines.Dispatchers.Default) { m.lease(ref) } }.map { it.await() }
        assertTrue(ls.all { it != null && it.file.readBytes().contentEquals(bytes) })
        assertEquals(1, opens.get())
    }

    @Test fun existingDiskCopiesAreSeededAndEvictedAndPartialsDeleted() = runBlocking {
        val root = tmp.newFolder()
        val d = File(root, StudioMaterializer.DIR_NAME).also { it.mkdirs() }
        File(d, "old1.audio").writeBytes(ByteArray(600)); File(d, "stray.part").writeBytes(ByteArray(10))
        val m = StudioMaterializer(root, { SafStat(600, 1) }, { java.io.ByteArrayInputStream(ByteArray(600)) }, 1_000)
        val l = m.lease(StudioFileRef(null, "content://new"))!!
        assertFalse("orphan evicted", File(d, "old1.audio").exists()); assertFalse(File(d, "stray.part").exists())
        assertTrue(l.file.exists())
    }

    @Test fun nullMtimeAlwaysRecopies() = runBlocking {
        var opens = 0
        val m = StudioMaterializer(tmp.newFolder(), { SafStat(4, 0) }, { opens++; java.io.ByteArrayInputStream(ByteArray(4)) }, 1_000)
        val ref = StudioFileRef(null, "content://z")
        m.lease(ref)!!.release(); m.lease(ref)!!.release()
        assertEquals(2, opens)
    }

    @Test fun hashCollidingUrisGetDistinctKeys() {
        assertEquals("Aa".hashCode(), "BB".hashCode())
        val st = SafStat(1, 1)
        assertNotEquals(StudioMaterializer.cacheKey("content://x/Aa", st), StudioMaterializer.cacheKey("content://x/BB", st))
    }

    @Test fun olderSlowSelectionDoesNotUnpinNewerOne() = runBlocking {
        val gate = java.util.concurrent.CountDownLatch(1)
        val m = StudioMaterializer(tmp.newFolder(), { SafStat(100, 1) }, { u ->
            if (u.endsWith("A")) gate.await()
            java.io.ByteArrayInputStream(ByteArray(100))
        }, 150)
        val s = SingleLeaseFiles({ StudioFileRef(null, "content://$it") }, m)
        val a = async(kotlinx.coroutines.Dispatchers.Default) { s.file("A") }
        Thread.sleep(100)
        val b = s.file("B")!!
        gate.countDown()
        assertNull("stale selection yields null", a.await())
        m.lease(StudioFileRef(null, "content://C"))!!.release()
        assertTrue("active selection stays pinned", b.exists())
        s.clear()
    }
}

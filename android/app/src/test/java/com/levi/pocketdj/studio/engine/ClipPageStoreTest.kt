package com.levi.pocketdj.studio.engine

import org.junit.After
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNotNull
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Before
import org.junit.Test
import java.io.File
import kotlin.math.sin

class ClipPageStoreTest {
    private lateinit var dir: File
    private lateinit var store: ClipPageStore

    @Before fun setUp() { dir = java.nio.file.Files.createTempDirectory("pages").toFile(); store = ClipPageStore(dir) }
    @After fun tearDown() { dir.deleteRecursively() }

    private fun key(name: String = "clip-a.m4a", stamp: String = "1", start: Int = 0, dur: Int = 1000, rate: Double = 1.0, pitch: Double = 0.0) =
        ClipPageStore.Key(name, stamp, start, dur, rate, pitch, 44_100)

    private fun tone(frames: Int) = FloatArray(frames * 2) { sin(it * 0.01).toFloat() * 0.8f }

    @Test fun writeThenReadRoundTripsOnThePcm16Grid() {
        val s = tone(5000)
        assertFalse(store.has(key()))
        assertEquals(5000, store.write(key(), s))
        assertTrue(store.has(key()))
        val r = store.open(key())!!
        assertEquals(5000, r.frameCount)
        val out = FloatArray(200)
        r.read(out, 0, 1234, 100)
        val snapped = ClipPageStore.snap(s)
        for (i in 0 until 200) assertEquals(snapped[1234 * 2 + i], out[i], 0f)
        // within one LSB of the original
        for (i in 0 until 200) assertEquals(s[1234 * 2 + i], out[i], 1f / 32768f)
        r.close()
    }

    @Test fun quantizeClampsAndIsSymmetricAtTheRails() {
        assertEquals(32767.toShort(), ClipPageStore.quantize(1f))
        assertEquals((-32768).toShort(), ClipPageStore.quantize(-2f))
        assertEquals(0.toShort(), ClipPageStore.quantize(0f))
    }

    @Test fun editChangesTheKeySoStalePagesAreNeverReused() {
        store.write(key(), tone(100))
        assertFalse(store.has(key(start = 500)))
        assertFalse(store.has(key(stamp = "2")))
        assertFalse(store.has(key(rate = 1.1)))
        assertFalse(store.has(key(pitch = 100.0)))
    }

    @Test fun invalidateSourceDropsOnlyThatFilesPages() {
        store.write(key("a.m4a"), tone(100)); store.write(key("a.m4a", start = 10), tone(100)); store.write(key("b.m4a"), tone(100))
        store.invalidateSource("a.m4a")
        assertFalse(store.has(key("a.m4a"))); assertFalse(store.has(key("a.m4a", start = 10)))
        assertTrue(store.has(key("b.m4a")))
        store.invalidate(key("b.m4a"))
        assertNull(store.open(key("b.m4a")))
    }

    @Test fun truncatedOrCorruptPageIsTreatedAsMissing() {
        store.write(key(), tone(100))
        val f = dir.listFiles()!!.single { it.name.endsWith(ClipPageStore.EXT) }
        f.writeBytes(f.readBytes().copyOf(f.length().toInt() - 3))
        assertFalse(store.has(key())); assertNull(store.open(key()))
    }

    @Test fun trimEvictsLeastRecentlyUsedButNeverProtectedKeys() {
        val small = ClipPageStore(dir, maxBytes = 40_000)
        val ks = (0 until 4).map { key("f$it.m4a") }
        ks.forEachIndexed { i, k -> small.write(k, tone(2500)); dir.listFiles()!!.first { it.name.startsWith(k.id) }.setLastModified(1_000L + i) }
        // 4 * (16 + 10000) bytes > 40000
        small.trim(keep = setOf(ks[0]))
        assertTrue(small.has(ks[0]))            // oldest but protected
        assertFalse(small.has(ks[1]))           // next oldest evicted
        assertTrue(small.sizeBytes <= 40_000)
    }

    @Test fun sixtyMinutesOfClipsAreHeapFreeAndRandomAccessible() {
        // 6 long clips x 10 min = 60 min of canonical stereo: ~635 MB on disk, ~0 on the Java heap (the old path needed ~2.5 GB of floats).
        val perClip = 44_100 * 600
        val rt = Runtime.getRuntime()
        System.gc(); val before = rt.totalMemory() - rt.freeMemory()
        val readers = (0 until 6).map { c ->
            val k = key("long$c.m4a")
            store.writeStream(k, perClip) { b, at, n -> for (i in 0 until n) { val v = (((at + i) % 1000) / 1000f - 0.5f) * (c + 1) / 7f; b[2 * i] = v; b[2 * i + 1] = -v } }
            store.open(k)!!
        }
        System.gc(); val after = rt.totalMemory() - rt.freeMemory()
        assertTrue("heap grew ${(after - before) / 1_000_000} MB", after - before < 64L * 1024 * 1024)
        val out = FloatArray(4)
        for ((c, r) in readers.withIndex()) {
            assertEquals(perClip, r.frameCount)
            for (f in intArrayOf(0, perClip / 2, perClip - 2)) {
                r.prefetch(f, 2); r.read(out, 0, f, 2)
                val v = ((f % 1000) / 1000f - 0.5f) * (c + 1) / 7f
                assertEquals(v, out[0], 1f / 32768f); assertEquals(-v, out[1], 1f / 32768f)
            }
            r.close()
        }
        store.clear()
        assertEquals(0L, store.sizeBytes)
        assertNotNull(readers)
    }
}

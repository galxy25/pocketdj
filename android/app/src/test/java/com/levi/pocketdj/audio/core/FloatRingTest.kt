package com.levi.pocketdj.audio.core

import org.junit.Assert.assertEquals
import org.junit.Assert.assertTrue
import org.junit.Test

class FloatRingTest {
    @Test fun writeReadWrapsAroundCapacity() {
        val r = FloatRing(8)
        assertEquals(6, r.write(floatArrayOf(1f, 2f, 3f, 4f, 5f, 6f), 0, 6))
        val d = FloatArray(4)
        assertEquals(4, r.read(d, 0, 4))
        assertEquals(listOf(1f, 2f, 3f, 4f), d.toList())
        assertEquals(6, r.write(floatArrayOf(7f, 8f, 9f, 10f, 11f, 12f), 0, 6)) // wraps
        val e = FloatArray(8)
        assertEquals(8, r.read(e, 0, 8))
        assertEquals((5..12).map { it.toFloat() }, e.toList())
    }

    @Test fun writeIsBoundedByFreeSpaceAndReadByContent() {
        val r = FloatRing(4)
        assertEquals(4, r.write(FloatArray(10), 0, 10))
        assertEquals(0, r.write(FloatArray(1), 0, 1))
        assertEquals(0, r.writable)
        assertEquals(4, r.read(FloatArray(10), 0, 10))
        assertEquals(0, r.read(FloatArray(10), 0, 10))
    }

    @Test fun skipAndClearDropContent() {
        val r = FloatRing(16)
        r.write(FloatArray(10) { it.toFloat() }, 0, 10)
        assertEquals(3, r.skip(3))
        val d = FloatArray(1); r.read(d, 0, 1)
        assertEquals(3f, d[0], 0f)
        r.clearConsumer()
        assertEquals(0, r.readable)
        assertEquals(16, r.writable)
    }

    @Test fun spscStressDeliversEveryFloatInOrder() {
        val ring = FloatRing(1024)
        val total = 2_000_000
        val producer = Thread {
            var next = 0
            val chunk = FloatArray(333)
            while (next < total) {
                val n = minOf(chunk.size, total - next)
                for (i in 0 until n) chunk[i] = (next + i).toFloat()
                var off = 0
                while (off < n) {
                    val w = ring.write(chunk, off, n - off)
                    off += w
                    if (w == 0) Thread.yield()
                }
                next += n
            }
        }
        producer.start()
        var expected = 0
        var bad = -1
        val buf = FloatArray(257)
        val deadline = System.nanoTime() + 30_000_000_000L
        while (expected < total && System.nanoTime() < deadline) {
            val n = ring.read(buf, 0, buf.size)
            if (n == 0) { Thread.yield(); continue }
            for (i in 0 until n) { if (buf[i] != (expected + i).toFloat() && bad < 0) bad = expected + i }
            expected += n
        }
        producer.join()
        assertEquals("first out-of-order float", -1, bad)
        assertEquals(total, expected)
        assertTrue(ring.readable == 0)
    }
}

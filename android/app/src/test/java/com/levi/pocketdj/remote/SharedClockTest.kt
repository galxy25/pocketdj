package com.levi.pocketdj.remote

import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNotEquals
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test

class SharedClockTest {
    @Test fun sampleMathSymmetricPath() {
        // P is 500 ms behind H; 20 ms each way.
        val s = SharedClock.sample(t0 = 1_000.0, t1 = 1_520.0, t2 = 1_525.0, t3 = 1_045.0)
        assertEquals(500.0, s.offsetMs, 0.0)
        assertEquals(40.0, s.rttMs, 0.0)
    }

    @Test fun negativeRttClampsToZero() {
        assertEquals(0.0, SharedClock.sample(0.0, 0.0, 10.0, 5.0).rttMs, 0.0)
    }

    @Test fun keepsTheLowestRttSampleNotTheAverage() {
        val c = SharedClock()
        c.reset("H", isHost = false)
        c.ingest(SharedClock.Sample(offsetMs = 100.0, rttMs = 80.0))
        c.ingest(SharedClock.Sample(offsetMs = 40.0, rttMs = 12.0))
        c.ingest(SharedClock.Sample(offsetMs = 900.0, rttMs = 300.0))
        assertEquals(40.0, c.offsetMs!!, 0.0)
        assertEquals(12.0, c.best!!.rttMs, 0.0)
    }

    @Test fun onlyTheLastEightSamplesAreRetained() {
        val c = SharedClock()
        c.reset("H", false)
        c.ingest(SharedClock.Sample(1.0, 1.0)) // the best, but it will age out
        repeat(8) { c.ingest(SharedClock.Sample(2.0, 50.0 + it)) }
        assertEquals(8, c.samples.size)
        assertEquals(2.0, c.offsetMs!!, 0.0)
        assertEquals(50.0, c.best!!.rttMs, 0.0)
    }

    @Test fun resetOnHostChangeDropsSamplesAndUnsyncs() {
        val c = SharedClock()
        c.reset("H1", false)
        c.ingest(SharedClock.Sample(5.0, 5.0))
        assertTrue(c.isSynced)
        c.reset("H2", false)
        assertFalse(c.isSynced)
        assertNull(c.offsetMs)
        assertNull(c.sharedNow)
        assertNull(c.localTime(1.0))
        assertEquals("H2", c.hostId)
    }

    @Test fun hostHasOffsetZeroAndIsSyncedImmediately() {
        val c = SharedClock(localNow = { 1_000.0 })
        c.reset("me", isHost = true)
        assertTrue(c.isSynced)
        assertEquals(0.0, c.offsetMs!!, 0.0)
        assertEquals(1_000.0, c.sharedNow!!, 0.0)
        assertEquals(777.0, c.localTime(777.0)!!, 0.0)
    }

    @Test fun pongsCountOnlyFromTheMeasuredHost() {
        var t = 1_000.0
        val c = SharedClock(localNow = { t })
        c.reset("H", false)
        val pong = RemotePong("p", t0 = 900.0, t1 = 1_450.0, t2 = 1_451.0)
        c.ingest(pong, sender = "someone-else")
        assertFalse(c.isSynced)
        t = 1_000.0
        c.ingest(pong, sender = "H")
        assertTrue(c.isSynced)
        // ((1450-900) + (1451-1000)) / 2 = 500.5; rtt = 100 - 1 = 99
        assertEquals(500.5, c.offsetMs!!, 0.0)
        assertEquals(99.0, c.best!!.rttMs, 0.0)
        // A host never folds in pongs.
        val h = SharedClock()
        h.reset("me", true)
        h.ingest(pong, "me")
        assertTrue(h.samples.isEmpty())
    }

    @Test fun skewedDevicesConvergeOnTheHostTimeline() {
        var host = 10_000_000.0
        var part = host - 3_000.0 // participant clock is 3 s behind
        val h = SharedClock(localNow = { host }).also { it.reset("H", true) }
        val p = SharedClock(localNow = { part }).also { it.reset("H", false) }
        val ping = p.makePing()
        host += 30.0; part += 30.0 // 30 ms flight
        val pong = h.pong(ping)
        host += 30.0; part += 30.0
        p.ingest(pong, "H")
        assertEquals(3_000.0, p.offsetMs!!, 0.0)
        assertEquals(host, p.sharedNow!!, 0.0)
        assertEquals(60.0, p.best!!.rttMs, 0.0)
        assertEquals(part, p.localTime(host)!!, 0.0)
    }

    @Test fun pingsCarryDistinctIdsAndTheLocalSendTime() {
        val c = SharedClock(localNow = { 42.0 })
        val a = c.makePing()
        val b = c.makePing()
        assertNotEquals(a.id, b.id)
        assertEquals(42.0, a.t0, 0.0)
        val pong = c.pong(a)
        assertEquals(a.id, pong.id)
        assertEquals(a.t0, pong.t0, 0.0)
    }
}

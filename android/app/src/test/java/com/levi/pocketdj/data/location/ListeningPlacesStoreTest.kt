package com.levi.pocketdj.data.location

import com.levi.pocketdj.data.pockets.ListeningContextTag
import java.io.File
import java.util.concurrent.Executor
import org.junit.Test
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNotEquals
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue

class ListeningPlacesStoreTest {
    private val H = 3_600_000L
    private var clock = 1_700_000_000_000L

    private class FakeSource(var auth: ListeningLocationAuthorization) : ListeningLocationSource {
        var started = 0; var stopped = 0; var upgrades = 0
        override val authorization get() = auth
        override fun start(store: ListeningLocationStore) { started++ }
        override fun stop() { stopped++ }
        override fun requestAlwaysUpgrade() { upgrades++ }
    }

    private fun tmp(): File = File.createTempFile("pdj-places", ".json").also { it.delete(); it.deleteOnExit() }

    private fun store(f: File, src: FakeSource? = null, supported: Boolean = true) =
        ListeningLocationStore(f, now = { clock }, platformSupported = supported, makeSource = { src }, io = Executor { it.run() })

    private val visit get() = LocationVisitSample(45.0, -122.0, 20.0, clock - 2 * H, clock - H)

    @Test fun defaultOff() {
        val f = tmp()
        val s = store(f)
        assertFalse(s.isEnabled); assertFalse(s.isActive)
        assertEquals(ListeningContextLookup.Unavailable, s.context(clock.toDouble()))
        s.ingestVisit(visit)                       // ignored while off
        assertTrue(s.engine.places.isEmpty())
        assertFalse(f.exists())
        assertTrue(s.placeLabels().isEmpty())
        // unsupported platform: setEnabled is a no-op
        val u = store(tmp(), supported = false)
        u.setEnabled(true)
        assertFalse(u.isEnabled)
        assertEquals(ListeningLocationAuthorization.UNSUPPORTED, u.authorization)
    }

    @Test fun disableErases() {
        val f = tmp()
        val src = FakeSource(ListeningLocationAuthorization.WHEN_IN_USE)
        val s = store(f, src)
        s.setEnabled(true)
        assertTrue(s.isEnabled); assertTrue(s.isActive); assertEquals(1, src.started)
        assertEquals(clock, s.engine.trackingStartedAtMs)
        s.ingestVisit(visit)
        assertEquals(1, s.engine.places.size); assertTrue(f.exists())
        val rev = s.revision
        s.setEnabled(false)
        assertEquals(1, src.stopped)
        assertFalse(f.exists()); assertFalse(File(f.parentFile, f.name + ".tmp").exists())
        assertFalse(s.isEnabled); assertFalse(s.isActive)
        assertTrue(s.engine.places.isEmpty()); assertNull(s.engine.trackingStartedAtMs)
        assertNotEquals(rev, s.revision)
        // a fresh store sees the default (off, empty)
        assertFalse(store(f).isEnabled)
    }

    @Test fun contextLookupDelegates() {
        val src = FakeSource(ListeningLocationAuthorization.NOT_DETERMINED)
        val s = store(tmp(), src)
        val enabledAt = clock
        s.setEnabled(true)
        s.sourceAuthorizationDidChange(ListeningLocationAuthorization.WHEN_IN_USE)
        clock += 10 * H
        s.ingestVisit(LocationVisitSample(45.0, -122.0, 20.0, enabledAt + H, enabledAt + 2 * H))
        s.sourceAuthorizationDidChange(ListeningLocationAuthorization.DENIED)
        val inside = (enabledAt + H + 30 * 60_000L).toDouble()
        // Permission not granted => inactive => unavailable, even with a visit ingested.
        assertEquals(ListeningContextLookup.Unavailable, s.context(inside))
        assertNull(s.currentContextGuess())
        s.sourceAuthorizationDidChange(ListeningLocationAuthorization.WHEN_IN_USE)
        assertTrue(s.isActive)
        val place = s.engine.places[0].id
        assertEquals(ListeningContextLookup.Settled(ListeningContextTag.place(place)), s.context(inside))
        // before tracking started => unavailable
        assertEquals(ListeningContextLookup.Unavailable, s.context((enabledAt - H).toDouble()))
        assertNull(s.label(ListeningContextTag.NONE))
        assertEquals("Location A", s.label(ListeningContextTag.place(place)))
        s.requestAlwaysUpgrade()
        assertEquals(1, src.upgrades); assertTrue(s.didRequestAlways)
    }

    @Test fun grantedLateRestartsTracking() {
        val src = FakeSource(ListeningLocationAuthorization.NOT_DETERMINED)
        val s = store(tmp(), src)
        s.setEnabled(true)
        val t1 = s.engine.trackingStartedAtMs
        clock += 5 * H
        s.sourceAuthorizationDidChange(ListeningLocationAuthorization.ALWAYS)
        assertEquals(clock, s.engine.trackingStartedAtMs)
        assertNotEquals(t1, s.engine.trackingStartedAtMs)
    }

    @Test fun docRoundTrip() {
        val f = tmp()
        val src = FakeSource(ListeningLocationAuthorization.WHEN_IN_USE)
        val s = store(f, src)
        s.setEnabled(true)
        s.ingestVisit(visit)
        s.requestAlwaysUpgrade()
        val s2 = store(f, FakeSource(ListeningLocationAuthorization.WHEN_IN_USE))
        assertTrue(s2.isEnabled); assertTrue(s2.didRequestAlways)
        assertEquals(s.engine.places, s2.engine.places)
        assertEquals(s.engine.timeline, s2.engine.timeline)
        assertEquals(s.engine.trackingStartedAtMs, s2.engine.trackingStartedAtMs)
        // An unsupported platform loads the doc but stays disabled; garbage doc => defaults.
        assertFalse(store(f, supported = false).isEnabled)
        f.writeText("{not json")
        val bad = store(f)
        assertFalse(bad.isEnabled); assertTrue(bad.engine.places.isEmpty())
        f.writeText("""{"isEnabled":"yes","engine":{"places":42}}""")
        assertFalse(store(f).isEnabled)
    }

    @Test fun eraseAllKeepsTrackingWhileEnabled() {
        val s = store(tmp(), FakeSource(ListeningLocationAuthorization.WHEN_IN_USE))
        s.setEnabled(true)
        s.ingestVisit(visit)
        clock += H
        s.eraseAll()
        assertTrue(s.engine.places.isEmpty())
        assertEquals(clock, s.engine.trackingStartedAtMs)
        assertTrue(s.isEnabled)
    }

    @Test fun engineIsSnapshot() {
        val src = FakeSource(ListeningLocationAuthorization.WHEN_IN_USE)
        val s = store(tmp(), src)
        s.setEnabled(true)
        s.ingestVisit(visit)
        val snap = s.engine
        val n = snap.places.size
        s.ingestVisit(LocationVisitSample(10.0, 10.0, 20.0, clock - 5 * H, clock - 4 * H))
        assertEquals(n, snap.places.size)               // earlier snapshot unaffected
        assertTrue(s.engine.places.size > n)
        assertTrue(snap !== s.engine)                    // fresh copy each read
    }

    @Test fun writesAreOffCallerThreadAndOrdered() {
        val f = tmp()
        val queue = ArrayDeque<Runnable>()
        val s = ListeningLocationStore(f, now = { clock }, makeSource = { FakeSource(ListeningLocationAuthorization.WHEN_IN_USE) }, io = Executor { queue.add(it) })
        s.setEnabled(true)
        s.ingestVisit(visit)
        assertFalse(f.exists())                          // nothing written on the caller thread
        s.setEnabled(false)                              // queues delete AFTER the writes
        while (queue.isNotEmpty()) queue.removeFirst().run()
        assertFalse(f.exists())
    }

    @Test fun disableAndDisabledEraseNeverWriteADoc() {
        val f = tmp()
        val queue = ArrayDeque<Runnable>()
        val s = ListeningLocationStore(f, now = { clock }, makeSource = { FakeSource(ListeningLocationAuthorization.WHEN_IN_USE) }, io = Executor { queue.add(it) })
        s.setEnabled(true); queue.clear()
        s.setEnabled(false)
        s.eraseAll()
        while (queue.isNotEmpty()) queue.removeFirst().run()
        assertFalse(f.exists())
    }
}

package com.levi.pocketdj.data.pockets

import com.levi.pocketdj.data.location.ListeningContextLookup
import com.levi.pocketdj.data.location.ListeningContextProviding
import com.levi.pocketdj.data.location.ListeningPlaceLabel
import com.levi.pocketdj.data.location.ListeningTripLabel
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.async
import kotlinx.coroutines.delay
import kotlinx.coroutines.runBlocking
import kotlinx.serialization.json.JsonNull
import kotlinx.serialization.json.jsonObject
import kotlinx.serialization.json.jsonPrimitive
import org.junit.After
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNotNull
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Before
import org.junit.Rule
import org.junit.Test
import org.junit.rules.TemporaryFolder

class ListeningPocketsServiceTest {
    @get:Rule val tmp = TemporaryFolder()
    private lateinit var fx: PocketsFixture
    private val be get() = fx.backend

    @Before fun setUp() { fx = PocketsFixture(tmp.root) }
    @After fun tearDown() { fx.close() }

    @Test fun gateBlocksNetwork() = runBlocking {
        fx.plays(3)
        val svc = fx.service()
        // Either toggle off.
        fx.pocketsOn = false
        assertFalse(svc.flushNow()); svc.refreshResults(force = true); svc.flushSoon(); svc.startAutoFlush()
        fx.pocketsOn = true; fx.recOn = false
        assertFalse(svc.flushNow()); svc.refreshResults(force = true)
        // Gate open but credentials seam null.
        fx.recOn = true; fx.creds = null
        assertFalse(svc.flushNow()); svc.refreshResults(force = true)
        delay(150)
        assertEquals(emptyList<String>(), be.requests.toList())
        assertFalse(svc.isAutoFlushArmed)
    }

    @Test fun fingerprintDiffOnly() = runBlocking {
        val ev = fx.plays(3)
        val svc = fx.service()
        assertTrue(svc.flushNow())
        assertEquals(1, be.eventCount()); assertEquals(3, be.events(0).size)
        assertEquals(1, be.resultsCount())   // fresh results after a send
        // Nothing moved -> no second POST.
        assertFalse(svc.flushNow()); assertEquals(1, be.eventCount())
        // A skip verdict moves exactly one fingerprint.
        fx.history.markSkipped(ev[1].id)
        assertTrue(svc.flushNow())
        assertEquals(2, be.eventCount())
        val resent = be.events(1)
        assertEquals(1, resent.size)
        assertEquals("skipped", resent[0]["outcome"]!!.jsonPrimitive.content)
        // Fingerprint shape: outcome|fraction%|ctx|tz
        fx.history.noteListened(ev[0].id, 0.8)
        assertEquals("unknown|-|-|0", svc.acknowledgedFingerprints[ev[2].id])
        assertTrue(svc.flushNow())
        assertEquals("completed|80|-|0", svc.acknowledgedFingerprints[ev[0].id])
    }

    @Test fun sentOn2xxOnly() = runBlocking {
        fx.plays(2)
        val svc = fx.service()
        be.eventsCode = 500
        assertFalse(svc.flushNow())
        assertTrue(svc.acknowledgedFingerprints.isEmpty())
        assertNotNull(svc.syncError)
        be.eventsCode = 200
        assertTrue(svc.flushNow())
        assertEquals(2, svc.acknowledgedFingerprints.size)
        assertNull(svc.syncError)
        assertEquals(2, be.eventCount())
    }

    @Test fun profileRebindResets() = runBlocking {
        fx.plays(2)
        val svc = fx.service()
        assertTrue(svc.flushNow())
        assertEquals("prof-A", svc.syncDoc.profileId)
        assertFalse(svc.flushNow())
        fx.creds = PocketsCredentials("KEY2", "prof-B", "ENR")
        assertTrue(svc.flushNow())
        assertEquals("prof-B", svc.syncDoc.profileId)
        assertEquals(2, be.events(be.eventPosts.size - 1).size)   // whole window re-sent
    }

    @Test fun deleteSetsFloorAndBlocks() = runBlocking {
        fx.plays(2)
        val svc = fx.service()
        var floorTold: Double? = null
        svc.onUploadFloor = { floorTold = it }
        assertTrue(svc.flushNow())
        be.deleteDelayMs = 400
        val del = async(Dispatchers.IO) { svc.deleteCloudData(fx.creds!!) }
        delay(120)
        val before = be.eventCount()
        assertFalse("no flush may start while the DELETE is in flight", svc.flushNow())
        assertEquals(before, be.eventCount())
        assertTrue(del.await())
        assertTrue(be.requests.contains("DELETE /pockets/state"))
        assertTrue(svc.acknowledgedFingerprints.isEmpty())
        assertEquals(fx.clock.toDouble(), svc.uploadFloorMs!!, 0.0)
        assertEquals(svc.uploadFloorMs, floorTold)
        // Old plays never upload again; only fresh ones do.
        assertFalse(svc.flushNow())
        fx.clock += 600_000
        fx.history.record("fresh", nowMs = fx.clock - 1000, tzOffsetMin = 0)
        assertTrue(svc.flushNow())
        assertEquals(listOf("fresh"), be.events(be.eventPosts.size - 1).map { it["songId"]!!.jsonPrimitive.content })
        // The floor survives a restart (persisted).
        assertEquals(svc.uploadFloorMs, fx.service().uploadFloorMs)
    }

    @Test fun deleteFailureKeepsStateAnd404IsSuccess() = runBlocking {
        fx.plays(1)
        val svc = fx.service()
        assertTrue(svc.flushNow())
        be.deleteCode = 500
        assertFalse(svc.deleteCloudData(fx.creds!!))
        assertEquals(1, svc.acknowledgedFingerprints.size)
        be.deleteCode = 404
        assertTrue(svc.deleteCloudData(fx.creds!!))
    }

    @Test fun epochAbandons() = runBlocking {
        fx.plays(3)
        val svc = fx.service()
        be.eventsDelayMs = 400
        val flush = async(Dispatchers.IO) { svc.flushNow() }
        delay(150)
        svc.enabledDidChange()   // toggle observed after the await: the in-flight flush abandons
        assertFalse(flush.await())
        assertTrue("an abandoned flush must record no fingerprints", svc.acknowledgedFingerprints.isEmpty())
        assertEquals(0, be.resultsCount())
        be.eventsDelayMs = 0
        assertTrue(svc.flushNow())
        assertEquals(3, svc.acknowledgedFingerprints.size)
    }

    @Test fun resultsTTL() = runBlocking {
        val svc = fx.service()
        svc.refreshIfStale(); svc.refreshIfStale()
        assertEquals(1, be.resultsCount())
        assertNotNull(svc.results.value)
        fx.clock += ListeningPocketsService.RESULTS_TTL_MS - 1
        svc.refreshIfStale(); assertEquals(1, be.resultsCount())
        fx.clock += 2
        svc.refreshIfStale(); assertEquals(2, be.resultsCount())
        svc.refreshResults(force = true); assertEquals(3, be.resultsCount())
        // Cache survives a restart.
        assertNotNull(fx.service().results.value)
    }

    @Test fun silent404() = runBlocking {
        fx.plays(1)
        val svc = fx.service()
        be.eventsCode = 404; be.resultsCode = 404
        assertFalse(svc.flushNow())
        assertFalse(svc.serviceAvailable)
        assertNull(svc.syncError)
        svc.refreshResults(force = true)
        assertNull(svc.syncError)
        be.eventsCode = 200; be.resultsCode = 200
        assertTrue(svc.flushNow())
        assertTrue(svc.serviceAvailable)
    }

    @Test fun keyMismatchSurfacesError() = runBlocking {
        fx.plays(1)
        val svc = fx.service()
        be.eventsCode = 403
        assertFalse(svc.flushNow())
        assertTrue(svc.syncError!!.contains("Delete cloud data"))
    }

    @Test fun windowIs90DaysAndBatchesAre1000() = runBlocking {
        fx.history.record("old", nowMs = fx.clock - 91L * 86_400_000, tzOffsetMin = 0)
        val svc = fx.service()
        assertFalse(svc.flushNow())   // out of window -> nothing to send
        assertEquals(0, be.eventCount())
        val now = fx.clock
        for (i in 0 until 1_001) fx.history.record("b$i", nowMs = now - 1_001_000L + i * 1000L, tzOffsetMin = 0)
        assertTrue(svc.flushNow())
        assertEquals(2, be.eventCount())
        assertEquals(1000, be.events(0).size); assertEquals(1, be.events(1).size)
    }

    @Test fun collectionsSnapshotUploadedWhenDueAndRoundsAfterPlays() = runBlocking {
        fx.plays(1)
        val svc = fx.service()
        val pocket = com.levi.pocketdj.data.collections.Pocket(id = "pkt_1", name = "Secret Name", songIds = listOf("s0", "x"))
        svc.collectionsProvider = {
            ListeningPocketsCollections.Input(com.levi.pocketdj.data.collections.CollectionFlattener.Source(pockets = listOf(pocket)))
        }
        val order = mutableListOf<String>()
        svc.roundsFlusher = { _, _ -> val first = order.isEmpty(); order += "rounds:" + be.eventCount(); first }
        assertTrue(svc.flushNow())
        assertEquals(2, be.eventCount())                       // plays batch + collections batch
        assertEquals(0, be.events(1).size)                      // snapshot rides its own events:[] batch
        assertNotNull(be.eventPosts[1]["collections"])
        assertFalse("collection NAMES never reach the wire", be.eventPosts[1].toString().contains("Secret Name"))
        assertEquals("rounds:2", order[0])                 // rounds only after plays + collections
        // Unchanged + <24h -> not due; >=24h -> re-sent.
        assertFalse(svc.flushNow()); assertEquals(2, be.eventCount())
        fx.clock += ListeningPocketsCollections.RESEND_AFTER_MS.toLong() + 1
        assertTrue(svc.flushNow()); assertEquals(3, be.eventCount())
    }

    @Test fun contextRidesOnlyWhileLocationOnAndSettlesOntoOwnPlays() = runBlocking {
        val ev = fx.plays(2)
        val tag = ListeningContextTag.place("plc_0123456789abcdef")
        var active = true
        val provider = object : ListeningContextProviding {
            override val isSupported = true
            override val isActive get() = active
            override fun context(atMs: Double) =
                if (atMs == ev[0].playedAt) ListeningContextLookup.Settled(tag) else ListeningContextLookup.Pending
            override fun placeLabels() = listOf(ListeningPlaceLabel("plc_0123456789abcdef", 1, "Location A", 0.12345))
            override fun tripLabels() = listOf(ListeningTripLabel("trp_1", "plc_0123456789abcdef", null, "Leaving A", 3))
            override fun label(tag: ListeningContextTag) = "Location A"
        }
        val svc = fx.service(provider)
        svc.locationOptedIn = { false }
        assertTrue(svc.flushNow())
        val first = be.events(0).first { it["songId"]!!.jsonPrimitive.content == "s0" }
        assertEquals(JsonNull, first["ctx"])        // settled onto history but withheld while places & trips is off
        assertNotNull(fx.history.events.first { it.id == ev[0].id }.listeningContext)
        assertNull(fx.history.events.first { it.id == ev[1].id }.listeningContext)   // pending stays null
        svc.locationOptedIn = { true }
        assertTrue(svc.flushNow())                   // ctx moved the fingerprint -> exactly that play re-sends
        val resent = be.events(be.eventPosts.size - 1)
        assertEquals(1, resent.size)
        assertEquals("place", resent[0]["ctx"]!!.jsonObject["kind"]!!.jsonPrimitive.content)
        // Labels ride the batch only while location is active; share rounded to 3 dp.
        val withLabels = be.eventPosts[be.eventPosts.size - 1]
        assertEquals(0.123, withLabels["places"]!!.let { (it as kotlinx.serialization.json.JsonArray)[0].jsonObject["share"]!!.jsonPrimitive.content.toDouble() }, 1e-9)
        active = false
    }

    @Test fun ordinalsAreStablePerMinuteAndStream() {
        val h = fx.history
        val t = 1_750_000_020_000L
        val a = h.record("a", nowMs = t, tzOffsetMin = 0)!!
        val b = h.record("b", nowMs = t + 10_000, tzOffsetMin = 0)!!
        val c = h.record("c", nowMs = t + 61_000, tzOffsetMin = 0)!!
        val o = ListeningPocketsService.ordinals(h.events, h.installId)
        assertEquals(0, o[a.id]); assertEquals(1, o[b.id]); assertEquals(0, o[c.id])
    }

    @Test fun autoFlushLoopAndDebounceAndDisable() = runBlocking {
        fx.plays(3)
        val svc = fx.service()
        svc.autoFlushDelayMs = 60; svc.autoFlushPeriodMs = 60_000; svc.debounceMs = 40
        svc.startAutoFlush(); svc.startAutoFlush()   // idempotent: one loop
        assertTrue(svc.isAutoFlushArmed)
        val deadline = System.currentTimeMillis() + 3000
        while (be.eventCount() == 0 && System.currentTimeMillis() < deadline) delay(20)
        assertEquals(1, be.eventCount())
        fx.history.record("late", nowMs = fx.clock, tzOffsetMin = 0)
        svc.flushSoon(); svc.flushSoon()
        val d2 = System.currentTimeMillis() + 3000
        while (be.eventCount() < 2 && System.currentTimeMillis() < d2) delay(20)
        assertEquals(2, be.eventCount())
        // Toggle off: loop stops, onDisabled fires, nothing more is sent.
        var disabled = 0
        svc.onDisabled = { disabled++ }
        fx.pocketsOn = false
        svc.enabledDidChange()
        assertEquals(1, disabled)
        assertFalse(svc.isAutoFlushArmed)
        assertFalse(svc.enabled.value)
        fx.history.record("after", nowMs = fx.clock, tzOffsetMin = 0)
        svc.flushSoon()
        delay(200)
        assertEquals(2, be.eventCount())
    }

    @Test fun coldStartDoesNotFireOnDisabledAndRealCloseFiresOnce() = runBlocking {
        // Cold start: the pockets mirror reads OFF until the stored pref arrives -> gate false -> still false.
        fx.pocketsOn = false
        val svc = fx.service()
        var disabled = 0
        svc.onDisabled = { disabled++ }
        svc.enabledDidChange()        // rec emission before the pref: false -> false
        svc.enabledDidChange()
        assertEquals(0, disabled)
        fx.pocketsOn = true
        svc.enabledDidChange()        // opens
        assertEquals(0, disabled)
        fx.pocketsOn = false
        svc.enabledDidChange()        // real true -> false
        svc.enabledDidChange()
        assertEquals(1, disabled)
    }

    @Test fun deleteWaitsForFlushThatRegisteredBeforeIt() = runBlocking {
        fx.plays(2)
        be.eventsDelayMs = 400
        val svc = fx.service()
        val flush = async(Dispatchers.IO) { svc.flushNow() }
        delay(120)   // flush is in flight
        assertTrue(svc.deleteCloudData(fx.creds!!))
        flush.await()
        // The DELETE is the last thing the server saw; the abandoned flush re-uploaded nothing after it.
        val reqs = be.requests.toList()
        assertEquals("DELETE /pockets/state", reqs.last())
        assertEquals(1, be.eventCount())
    }
}

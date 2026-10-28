package com.levi.pocketdj.data.location

import com.levi.pocketdj.data.pockets.ListeningContextTag
import org.junit.Test
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNotEquals
import org.junit.Assert.assertNotNull
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue

class ListeningPlaceEngineTest {
    private val H = 3_600_000L
    private val M = 60_000L
    private val D = 24 * H
    private val t0 = 1_700_000_000_000L

    private var counter = 0
    private val newId: () -> String = { (++counter).toString(16).padStart(16, '0') }

    // ~111 m per 0.001 deg latitude.
    private val homeLat = 45.0000; private val homeLon = -122.0000
    private val workLat = 45.0500; private val workLon = -122.0000
    private val gymLat = 45.1000; private val gymLon = -122.0000

    private fun engine(start: Long = t0 - D): ListeningPlaceEngine =
        ListeningPlaceEngine().also { it.trackingStartedAtMs = start }

    private fun visit(lat: Double, lon: Double, a: Long?, d: Long?, acc: Double = 20.0) =
        LocationVisitSample(lat, lon, acc, a, d)

    @Test fun accuracyDrop() {
        val e = engine()
        e.ingest(visit(homeLat, homeLon, t0, t0 + H, acc = 250.0), t0 + 2 * H, newId)
        assertTrue(e.places.isEmpty()); assertTrue(e.rawVisits.isEmpty())
        e.ingest(visit(homeLat, homeLon, t0, t0 + H, acc = 200.0), t0 + 2 * H, newId)
        assertEquals(1, e.places.size)
        // too short a stay and no timestamps are dropped as well
        e.ingest(visit(workLat, workLon, t0, t0 + 2 * M), t0 + 2 * H, newId)
        e.ingest(visit(workLat, workLon, null, null), t0 + 2 * H, newId)
        assertEquals(1, e.places.size)
    }

    @Test fun clusterJoin() {
        val e = engine()
        e.ingest(visit(homeLat, homeLon, t0, t0 + H), t0 + 2 * H, newId)
        // ~89 m north: joins; ~222 m north (separate stay) does not.
        e.ingest(visit(homeLat + 0.0008, homeLon, t0 + 3 * H, t0 + 4 * H), t0 + 5 * H, newId)
        assertEquals(1, e.places.size)
        e.ingest(visit(homeLat + 0.0022, homeLon, t0 + 6 * H, t0 + 7 * H), t0 + 8 * H, newId)
        assertEquals(2, e.places.size)
        val p = e.places.first()
        // dwell-weighted drift (equal dwell => midpoint) stored at 4 dp
        assertEquals(45.0004, p.latitude, 1e-9)
        assertEquals(2 * H / 1000.0, p.weight, 1e-6)
        assertTrue(p.id.startsWith("plc_"))
    }

    @Test fun mergeAlias() {
        val e = engine()
        val now = t0 + 100 * H
        e.ingest(visit(homeLat, homeLon, t0, t0 + H), now, newId)                       // A at 0
        e.ingest(visit(homeLat + 0.0020, homeLon, t0 + 2 * H, t0 + 3 * H), now, newId)   // B, 222 m away
        assertEquals(2, e.places.size)
        val survivor = e.places[0].id; val victim = e.places[1].id
        // Visits nearer B than A (but within 150 m of it) drag B's centroid toward A.
        e.ingest(visit(homeLat + 0.0011, homeLon, t0 + 4 * H, t0 + 7 * H), now, newId)
        assertEquals(2, e.places.size)
        e.ingest(visit(homeLat + 0.0008, homeLon, t0 + 8 * H, t0 + 48 * H), now, newId)
        assertEquals("places should have merged", 1, e.places.size)
        assertEquals(survivor, e.places[0].id)           // older id survives
        assertEquals(survivor, e.resolve(victim))        // old tags still resolve
        assertEquals(survivor, e.aliases[victim])
        assertNotNull(e.label(ListeningContextTag.place(victim), now))
        assertEquals(e.label(ListeningContextTag.place(survivor), now), e.label(ListeningContextTag.place(victim), now))
        assertTrue(e.timeline.none { it.placeId == victim })
        assertTrue(e.tripIds.keys.none { victim in it })  // trip pairs re-keyed to the survivor
    }

    @Test fun orderedTrips() {
        val e = engine()
        e.ingest(visit(homeLat, homeLon, t0, t0 + H), t0 + 10 * H, newId)
        e.ingest(visit(workLat, workLon, t0 + H + 20 * M, t0 + 5 * H), t0 + 10 * H, newId)
        e.ingest(visit(homeLat, homeLon, t0 + 5 * H + 30 * M, t0 + 8 * H), t0 + 10 * H, newId)
        val home = e.places[0].id; val work = e.places[1].id
        val ab = e.tripIds[ListeningPlaceEngine.tripKey(home, work)]
        val ba = e.tripIds[ListeningPlaceEngine.tripKey(work, home)]
        assertNotNull(ab); assertNotNull(ba)
        assertNotEquals(ab, ba)
        assertTrue(ab!!.startsWith("trp_") && ba!!.startsWith("trp_"))
        // a lookup in the gap between home and work yields the A->B trip
        val r = e.lookup(t0 + H + 10 * M, t0 + 10 * H)
        assertEquals(ListeningContextLookup.Settled(ListeningContextTag.trip(ab, home, work)), r)
        // and a departure that never arrived keys "<origin>>?"
        assertNotNull(e.tripIds[ListeningPlaceEngine.tripKey(home, null)])
    }

    @Test fun noTripOver4h() {
        val e = engine()
        e.ingest(visit(homeLat, homeLon, t0, t0 + H), t0 + 30 * H, newId)
        e.ingest(visit(workLat, workLon, t0 + 6 * H, t0 + 7 * H), t0 + 30 * H, newId) // 5 h gap
        val home = e.places[0].id; val work = e.places[1].id
        assertNull(e.tripIds[ListeningPlaceEngine.tripKey(home, work)])
        // Midway through the gap but past 4 h after departure => nothing, not a trip.
        val mid = t0 + H + 4 * H + 30 * M
        assertEquals(ListeningContextLookup.Settled(ListeningContextTag.NONE), e.lookup(mid, t0 + 30 * H))
        // Within 4 h of departure it is the unarrived "Leaving home" trip.
        val early = e.lookup(t0 + H + 30 * M, t0 + 30 * H)
        val tag = (early as ListeningContextLookup.Settled).tag
        assertEquals(home, tag.origin); assertNull(tag.destination)
    }

    @Test fun pendingHorizon() {
        val e = engine(start = t0 - D)
        val now = t0 + 10 * H
        // Open stay started 1 h ago at home.
        e.ingest(visit(homeLat, homeLon, now - H, null), now, newId)
        assertEquals(ListeningContextLookup.Pending, e.lookup(now - 30 * M, now))   // recent, in open stay
        // Same open stay but 7 h in => older than the horizon is never pending.
        val later = now + 7 * H
        assertEquals(ListeningContextLookup.Settled(ListeningContextTag.place(e.places[0].id)),
            e.lookup(now - 30 * M, later))
        // Nothing claims a recent t yet => pending; an old one => settled none.
        val e2 = engine()
        assertEquals(ListeningContextLookup.Pending, e2.lookup(now - M, now))
        assertEquals(ListeningContextLookup.Settled(ListeningContextTag.NONE), e2.lookup(now - 7 * H, now))
        // Before tracking started => unavailable.
        assertEquals(ListeningContextLookup.Unavailable, e2.lookup(t0 - 2 * D, now))
        assertEquals(ListeningContextLookup.Unavailable,
            ListeningPlaceEngine().lookup(now - 7 * H, now))   // never started
    }

    @Test fun rankLabels() {
        val e = engine()
        val now = t0 + 20 * H
        e.ingest(visit(homeLat, homeLon, t0, t0 + 6 * H), now, newId)             // 6 h
        e.ingest(visit(workLat, workLon, t0 + 7 * H, t0 + 10 * H), now, newId)     // 3 h
        e.ingest(visit(gymLat, gymLon, t0 + 11 * H, t0 + 11 * H + 30 * M), now, newId) // 0.5 h: below 1 h
        val ranked = e.rankedPlaces(now)
        assertEquals(listOf("Location A", "Location B"), ranked.map { it.label })
        assertEquals(6.0 / 9.5, ranked[0].shareOfTime, 1e-6)
        // the sub-threshold place still gets a letter after the ranked ones
        val gym = e.places.first { it.latitude > 45.09 }
        assertEquals("Location C", e.label(ListeningContextTag.place(gym.id), now))
        assertEquals("AA", ListeningPlaceEngine.letters(27))
        assertEquals("Z", ListeningPlaceEngine.letters(26))
        assertEquals("AB", ListeningPlaceEngine.letters(28))
        assertEquals("A", ListeningPlaceEngine.letters(0))
        assertEquals("A ↺", ListeningPlaceEngine.tripLabel("x", "x", mapOf("x" to 1)))
        assertEquals("Leaving A", ListeningPlaceEngine.tripLabel("x", null, mapOf("x" to 1)))
    }

    @Test fun pruneRetention() {
        val e = engine(start = t0 - 400 * D)
        e.ingest(visit(homeLat, homeLon, t0, t0 + H), t0 + 2 * H, newId)
        e.ingest(visit(workLat, workLon, t0 + 2 * H, t0 + 3 * H), t0 + 3 * H, newId)
        assertEquals(2, e.rawVisits.size)
        e.prune(t0 + 31 * D)                      // raw 30 d cutoff passed; places/timeline remain
        assertTrue(e.rawVisits.isEmpty())
        assertEquals(2, e.places.size); assertEquals(2, e.timeline.size)
        e.prune(t0 + 181 * D)                     // timeline + places 180 d
        assertTrue(e.places.isEmpty()); assertTrue(e.timeline.isEmpty())
        assertTrue(e.tripIds.isEmpty()); assertTrue(e.aliases.isEmpty())
    }

    @Test fun movementHintClosesStay() {
        val e = engine()
        val now = t0 + 3 * H
        e.ingest(visit(homeLat, homeLon, t0, null), now, newId)
        // A fix near home does nothing; a coarse fix 5 km away closes the stay (estimate).
        e.noteMovement(LocationFixSample(homeLat + 0.0005, homeLon, 100.0, t0 + 2 * H), now, newId)
        assertNull(e.timeline[0].endMs)
        e.noteMovement(LocationFixSample(homeLat + 0.05, homeLon, 1000.0, t0 + 2 * H), now, newId)
        assertEquals(t0 + 2 * H, e.timeline[0].endMs)
        assertEquals(true, e.timeline[0].endIsEstimate)
        assertNotNull(e.tripIds[ListeningPlaceEngine.tripKey(e.places[0].id, null)])
        // Too inaccurate a fix is ignored.
        val e2 = engine()
        e2.ingest(visit(homeLat, homeLon, t0, null), now, newId)
        e2.noteMovement(LocationFixSample(homeLat + 0.5, homeLon, 5000.0, t0 + 2 * H), now, newId)
        assertNull(e2.timeline[0].endMs)
        // The real, back-dated departure then overwrites the estimate.
        e.ingest(visit(homeLat, homeLon, t0, t0 + 90 * M), now + H, newId)
        assertEquals(t0 + 90 * M, e.timeline[0].endMs)
        assertNull(e.timeline[0].endIsEstimate)
    }

    @Test fun redeliveredVisitUpdatesSegment() {
        val e = engine()
        val v = visit(homeLat, homeLon, t0, t0 + H)
        e.ingest(v, t0 + 2 * H, newId)
        e.ingest(v, t0 + 2 * H, newId)                      // identical redelivery: no double weight
        assertEquals(1, e.rawVisits.size)
        assertEquals(H / 1000.0, e.places[0].weight, 1e-6)
        // A revised sample for the same stay (arrival within 15 min) updates, not duplicates.
        e.ingest(visit(homeLat, homeLon, t0 + 5 * M, t0 + 2 * H), t0 + 3 * H, newId)
        assertEquals(1, e.timeline.size)
        assertEquals(t0 + 5 * M, e.timeline[0].startMs)
        assertEquals(t0 + 2 * H, e.timeline[0].endMs)
    }

    @Test fun currentGuessAndJsonRoundTrip() {
        val e = engine()
        val now = t0 + 3 * H
        e.ingest(visit(homeLat, homeLon, t0, null), now, newId)
        assertEquals(ListeningContextTag.place(e.places[0].id), e.currentGuess(now))
        val j = e.toJson()
        val back = ListeningPlaceEngine.fromJson(j)
        assertEquals(e.places, back.places); assertEquals(e.timeline, back.timeline)
        assertEquals(e.trackingStartedAtMs, back.trackingStartedAtMs)
        // damaged field resets to empty instead of failing
        val damaged = kotlinx.serialization.json.JsonObject(j + ("places" to kotlinx.serialization.json.JsonPrimitive("junk")))
        val lenient = ListeningPlaceEngine.fromJson(damaged)
        assertTrue(lenient.places.isEmpty()); assertFalse(lenient.timeline.isEmpty())
    }
}

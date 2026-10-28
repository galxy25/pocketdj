package com.levi.pocketdj.data.recs

import com.levi.pocketdj.data.catalog.IndexSong
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNotNull
import org.junit.Assert.assertNull
import org.junit.Assert.assertSame
import org.junit.Assert.assertTrue
import org.junit.Test

class ForYouFeedTest {
    private val now = 1_800_000_000_000.0

    // ── lenient decode matrix ──────────────────────────────────────────────────────────

    @Test fun fullDocumentRoundTrips() {
        val snap = ForYouFeedSnapshot(
            refreshedAtMs = 1_800_000_000_123.0,
            zoneIds = listOf("a", "b"), zoneBuriedIds = listOf("b"),
            zoneSourceRaw = "cloud", zoneReasons = mapOf("a" to "because"),
            crates = listOf(
                ForYouFeedSnapshot.Crate("c1", "pocket", "Crate", listOf("x", "y"), mapOf("x" to "why"), listOf("y")),
                ForYouFeedSnapshot.Crate("c2", "playlist", "Plain", listOf("z")),
            ),
        )
        val text = snap.encode()
        assertTrue(text.contains("\"schemaVersion\":3"))
        assertFalse("nil optionals are omitted, as Swift's encoder does", text.contains("\"reasons\":null"))
        assertEquals(snap, ForYouFeedSnapshot.decode(text))
    }

    @Test fun missingZoneSourceRawDecodesToOnDevice() {
        val s = ForYouFeedSnapshot.decode("""{"schemaVersion":3,"refreshedAtMs":5,"zoneIds":["a"]}""")!!
        assertEquals(ForYouTileSource.ON_DEVICE, s.zoneSource)
        assertEquals("onDevice", s.zoneSourceRaw)
    }

    @Test fun unknownZoneSourceFallsBackToOnDeviceButKeepsTheRawString() {
        val s = ForYouFeedSnapshot.decode("""{"zoneSourceRaw":"quantum"}""")!!
        assertEquals(ForYouTileSource.ON_DEVICE, s.zoneSource)
        assertEquals("quantum", s.zoneSourceRaw)
        assertEquals(ForYouTileSource.CLOUD, ForYouFeedSnapshot.decode("""{"zoneSourceRaw":"cloud"}""")!!.zoneSource)
    }

    @Test fun missingReasonsAreNullNeverEmpty() {
        val s = ForYouFeedSnapshot.decode(
            """{"refreshedAtMs":1,"zoneIds":["a"],"crates":[{"id":"c","kind":"playlist","name":"N","songIds":["x"]}]}""",
        )!!
        assertNull(s.zoneReasons)
        assertNull(s.crates[0].reasons)
        assertNull(s.crates[0].soundIds)
        assertEquals(emptyMap<String, String>(), s.reasons("zone"))
        assertEquals(emptyMap<String, String>(), s.reasons("col-c"))
        assertEquals(emptySet<String>(), s.soundIds("col-c"))
    }

    @Test fun explicitNullReasonsAreNull() {
        val s = ForYouFeedSnapshot.decode(
            """{"zoneReasons":null,"crates":[{"id":"c","kind":"k","name":"N","songIds":[],"reasons":null,"soundIds":null}]}""",
        )!!
        assertNull(s.zoneReasons)
        assertEquals(1, s.crates.size)
    }

    @Test fun wrongTypedFieldFallsBackToItsDefaultNotAFailure() {
        val s = ForYouFeedSnapshot.decode(
            """{"schemaVersion":"three","refreshedAtMs":"soon","zoneIds":"nope","zoneBuriedIds":[1,2],"zoneSourceRaw":7,"zoneReasons":[1]}""",
        )!!
        assertEquals(3, s.schemaVersion)
        assertEquals(0.0, s.refreshedAtMs, 0.0)
        assertTrue(s.zoneIds.isEmpty() && s.zoneBuriedIds.isEmpty())
        assertEquals("onDevice", s.zoneSourceRaw)
        assertNull(s.zoneReasons)
        assertFalse(s.hasResult)
    }

    @Test fun oneMalformedCrateDropsTheWholeCratesArray() {
        val s = ForYouFeedSnapshot.decode(
            """{"refreshedAtMs":9,"zoneIds":["a"],"crates":[{"id":"ok","kind":"k","name":"N","songIds":[]},{"id":"bad"}]}""",
        )!!
        assertTrue(s.crates.isEmpty())
        assertEquals(listOf("a"), s.zoneIds) // other fields survive
    }

    @Test fun nonObjectDocumentIsNotASnapshot() {
        assertNull(ForYouFeedSnapshot.decode("[]"))
        assertNull(ForYouFeedSnapshot.decode("garbage"))
        assertNotNull(ForYouFeedSnapshot.decode("{}"))
    }

    // ── schema gate ────────────────────────────────────────────────────────────────────

    @Test fun schemaBelowThreeIsNotACacheAndHasNoResultViaStore() {
        val dir = kotlin.io.path.createTempDirectory("fyfeed").toFile()
        try {
            val f = java.io.File(dir, "feed.json")
            f.writeText("""{"schemaVersion":2,"refreshedAtMs":1700000000000,"zoneIds":["a"]}""")
            val old = ForYouFeedStore(f)
            assertFalse(old.snapshot.hasResult)
            assertTrue(old.snapshot.zoneIds.isEmpty())
            assertEquals(0, old.revision)
            assertFalse(ForYouFeedSnapshot.decode("""{"schemaVersion":2}""")!!.isCurrent)

            f.writeText("""{"schemaVersion":3,"refreshedAtMs":1700000000000,"zoneIds":["a"]}""")
            val cur = ForYouFeedStore(f)
            assertTrue(cur.snapshot.hasResult)
            assertEquals(listOf("a"), cur.snapshot.zoneIds)
            // a document from a newer engine is still a cache
            f.writeText("""{"schemaVersion":4,"refreshedAtMs":1700000000000}""")
            assertTrue(ForYouFeedStore(f).snapshot.hasResult)
            // a document with NO schemaVersion is treated as current (iOS default)
            f.writeText("""{"refreshedAtMs":1700000000000}""")
            assertTrue(ForYouFeedStore(f).snapshot.hasResult)
        } finally { dir.deleteRecursively() }
    }

    @Test fun tileLookupsFollowTileIds() {
        val s = ForYouFeedSnapshot(
            refreshedAtMs = 1.0, zoneIds = listOf("z"),
            crates = listOf(ForYouFeedSnapshot.Crate("c", "pocket", "C", listOf("x"), mapOf("x" to "w"), listOf("x"))),
        )
        assertEquals(listOf("z"), s.songIds("zone"))
        assertEquals(listOf("x"), s.songIds("col-c"))
        assertNull(s.songIds("col-nope"))
        assertEquals(mapOf("x" to "w"), s.reasons("col-c"))
        assertEquals(setOf("x"), s.soundIds("col-c"))
        assertNull(ForYouFeedSnapshot().songIds("zone")) // no result yet
    }

    // ── builder ────────────────────────────────────────────────────────────────────────

    private fun t(id: String, artist: String, genre: String?, year: Int) =
        ZoneEngine.Track(songId = id, artistKey = artist.lowercase(), artistName = artist, genre = genre, year = year)

    private val members = (0 until 4).map { t("m$it", "Member", "rock", 2000 + it) }
    private val liked = t("liked", "Liked Artist", "jazz", 2001)
    private val cands = (0 until 6).map { t("c$it", "Other $it", "jazz", 2001) }
    private val tracks = members + liked + cands
    private val songs = tracks.map { IndexSong(id = it.songId, artist = it.artistName, name = "T ${it.songId}", year = it.year) }

    private fun inputs(vararg crates: ForYouFeedSnapshot.Crate, off: Set<String> = emptySet(), songs: List<IndexSong> = this.songs) =
        ForYouFeedInputs(
            songs = songs, tracks = tracks,
            genreBySongId = tracks.associate { it.songId to (it.genre ?: "") }.filterValues { it.isNotEmpty() },
            crates = crates.toList(),
            crateFeedback = crates.associate { it.id to ZoneEngine.Feedback(accepted = mapOf("liked" to 1.0)) },
            recsOffCrateIds = off, nowMs = now,
        )

    private val memberIds = members.map { it.songId }

    @Test fun buildStampsNowAndProducesCratesWithSuggestions() {
        val snap = ForYouFeedBuilder.build(inputs(ForYouFeedSnapshot.Crate("on", "playlist", "On", memberIds)))
        assertEquals(now, snap.refreshedAtMs, 0.0)
        assertEquals(FOR_YOU_FEED_SCHEMA_VERSION, snap.schemaVersion)
        assertEquals("onDevice", snap.zoneSourceRaw)
        assertEquals(listOf("on"), snap.crates.map { it.id })
        val c = snap.crates[0]
        assertTrue(c.songIds.isNotEmpty())
        assertTrue("members are never suggested back", c.songIds.none { it in memberIds })
        // reasons never carry blanks and only reference emitted rows
        c.reasons?.let { r -> assertTrue(r.values.none { it.isEmpty() } && c.songIds.containsAll(r.keys)) }
        c.soundIds?.let { assertTrue(c.songIds.containsAll(it)) }
    }

    @Test fun buildSkipsRecsOffCratesBeforeSweepingAndDropsThemFromTheSnapshot() {
        val on = ForYouFeedSnapshot.Crate("on", "playlist", "On", memberIds)
        val off = ForYouFeedSnapshot.Crate("off", "pocket", "Off", memberIds)
        val snap = ForYouFeedBuilder.build(inputs(on, off, off = setOf("off")))
        assertEquals(listOf("on"), snap.crates.map { it.id })
        // all off -> no crates at all
        assertTrue(ForYouFeedBuilder.build(inputs(on, off, off = setOf("on", "off"))).crates.isEmpty())
    }

    @Test fun buildIsDeterministicForTheSameInputs() {
        val crate = ForYouFeedSnapshot.Crate("on", "playlist", "On", memberIds)
        assertEquals(ForYouFeedBuilder.build(inputs(crate)).encode(), ForYouFeedBuilder.build(inputs(crate)).encode())
    }

    // ── cloud zone ─────────────────────────────────────────────────────────────────────

    private fun base() = ForYouFeedSnapshot(
        refreshedAtMs = now, zoneIds = listOf("local1"), zoneReasons = mapOf("local1" to "mine"),
        crates = listOf(ForYouFeedSnapshot.Crate("c", "playlist", "C", listOf("x"))),
    )

    @Test fun emptyCloudRowsHandBackTheSameSnapshot() {
        val b = base()
        assertSame(b, ForYouFeedBuilder.applyingCloudZone(b, emptyList(), inputs()))
    }

    @Test fun unresolvableCloudIdsShapeAwayToNothingAndLeaveTheSnapshotUntouched() {
        val b = base()
        val rows = listOf(ForYouCloudZoneRow("ghost1", "why"), ForYouCloudZoneRow("ghost2"))
        assertSame(b, ForYouFeedBuilder.applyingCloudZone(b, rows, inputs()))
        // and an empty catalog can resolve nothing either
        assertSame(b, ForYouFeedBuilder.applyingCloudZone(b, listOf(ForYouCloudZoneRow("c0")), inputs(songs = emptyList())))
    }

    @Test fun resolvableCloudRowsReplaceTheZoneAndKeepReasonsOnlyForSurvivors() {
        val b = base()
        val rows = listOf(
            ForYouCloudZoneRow("c0", "cloud says"), ForYouCloudZoneRow("ghost", "orphan"),
            ForYouCloudZoneRow("c1", ""), ForYouCloudZoneRow("c2", null),
        )
        val out = ForYouFeedBuilder.applyingCloudZone(b, rows, inputs())
        assertEquals("cloud", out.zoneSourceRaw)
        assertEquals(ForYouTileSource.CLOUD, out.zoneSource)
        assertTrue(out.zoneIds.isNotEmpty())
        assertTrue(out.zoneIds.all { it in setOf("c0", "c1", "c2") })
        assertFalse("local ranking replaced", "local1" in out.zoneIds)
        assertEquals(b.crates, out.crates) // crates untouched
        assertEquals(b.refreshedAtMs, out.refreshedAtMs, 0.0)
        val reasons = out.zoneReasons
        if (reasons != null) {
            assertTrue(out.zoneIds.containsAll(reasons.keys))
            assertFalse("ghost" in reasons.keys)
            assertTrue(reasons.values.none { it.isEmpty() })
        }
        if ("c0" in out.zoneIds) assertEquals("cloud says", reasons?.get("c0"))
    }

    @Test fun cloudAnswerWithNoReasonsStoresNullNotEmpty() {
        val out = ForYouFeedBuilder.applyingCloudZone(
            base(), listOf(ForYouCloudZoneRow("c0"), ForYouCloudZoneRow("c1")), inputs(),
        )
        assertEquals("cloud", out.zoneSourceRaw)
        assertNull(out.zoneReasons)
    }

    // ── store ──────────────────────────────────────────────────────────────────────────

    @Test fun refreshOnAnEmptyCatalogNeverTouchesTheCache() {
        val dir = kotlin.io.path.createTempDirectory("fyfeed2").toFile()
        try {
            val store = ForYouFeedStore(java.io.File(dir, "feed.json"), kotlinx.coroutines.Dispatchers.Unconfined)
            store.commit(base())
            val rev = store.revision
            kotlinx.coroutines.runBlocking { store.refresh(inputs(songs = emptyList())) }
            assertEquals(rev, store.revision)
            assertEquals(base(), store.snapshot)
            assertFalse(store.isRefreshing)
        }
        finally { dir.deleteRecursively() }
    }

    @Test fun refreshCommitsOnDeviceThenCloudAsASecondCommit() {
        val dir = kotlin.io.path.createTempDirectory("fyfeed3").toFile()
        try {
            val f = java.io.File(dir, "feed.json")
            val store = ForYouFeedStore(f, kotlinx.coroutines.Dispatchers.Unconfined)
            val crate = ForYouFeedSnapshot.Crate("on", "playlist", "On", memberIds)
            kotlinx.coroutines.runBlocking { store.refresh(inputs(crate)) }
            assertEquals(1, store.revision)
            assertEquals(now, store.snapshot.refreshedAtMs, 0.0)
            assertEquals(store.snapshot, ForYouFeedStore(f).snapshot) // durable

            kotlinx.coroutines.runBlocking {
                store.refresh(inputs(crate), cloudZone = { listOf(ForYouCloudZoneRow("c0", "w"), ForYouCloudZoneRow("c1")) })
            }
            assertEquals(3, store.revision) // two more commits
            assertEquals("cloud", store.snapshot.zoneSourceRaw)

            // a cloud answer that shapes to nothing does not burn a revision
            val before = store.revision
            kotlinx.coroutines.runBlocking {
                store.refresh(inputs(crate), cloudZone = { listOf(ForYouCloudZoneRow("ghost")) })
            }
            assertEquals(before + 1, store.revision)
            assertEquals("onDevice", store.snapshot.zoneSourceRaw)
        } finally { dir.deleteRecursively() }
    }

    @Test fun pulledPayloadOnlyLandsWhenFresherAndCurrent() {
        val dir = kotlin.io.path.createTempDirectory("fyfeed4").toFile()
        try {
            val f = java.io.File(dir, "feed.json")
            val store = ForYouFeedStore(f, kotlinx.coroutines.Dispatchers.Unconfined)
            store.commit(base().copy(refreshedAtMs = 2000.0))
            fun payload(v: Int, at: Double) = """{"schemaVersion":$v,"refreshedAtMs":$at,"zoneIds":["peer"]}""".toByteArray()

            store.applyPulledPayload(payload(3, 1000.0)) // older
            assertEquals(listOf("local1"), ForYouFeedStore(f).snapshot.zoneIds)
            assertEquals(2000L, f.lastModified()) // re-stamped to OUR refresh
            store.applyPulledPayload(payload(2, 9000.0)) // fresher but old engine
            assertEquals(listOf("local1"), ForYouFeedStore(f).snapshot.zoneIds)
            store.applyPulledPayload("junk".toByteArray())
            assertEquals(listOf("local1"), ForYouFeedStore(f).snapshot.zoneIds)

            store.applyPulledPayload(payload(3, 9000.0)) // fresher + current
            assertEquals(9000L, f.lastModified())
            assertTrue(store.reloadFromDisk())
            assertEquals(listOf("peer"), store.snapshot.zoneIds)
            assertFalse(store.reloadFromDisk()) // nothing newer now
        } finally { dir.deleteRecursively() }
    }

    @Test fun clearResetsAndDeletesTheFile() {
        val dir = kotlin.io.path.createTempDirectory("fyfeed5").toFile()
        try {
            val f = java.io.File(dir, "feed.json")
            val store = ForYouFeedStore(f, kotlinx.coroutines.Dispatchers.Unconfined)
            store.commit(base())
            assertTrue(f.exists())
            store.clear()
            assertFalse(f.exists())
            assertFalse(store.snapshot.hasResult)
        } finally { dir.deleteRecursively() }
    }

    @Test fun updatedLabelBuckets() {
        fun l(agoSecs: Double) = ForYouFeedStore.updatedLabel(now - agoSecs * 1000, now)
        assertEquals("Not refreshed yet", ForYouFeedStore.updatedLabel(0.0, now))
        assertEquals("Updated just now", l(30.0))
        assertEquals("Updated 5 min ago", l(300.0))
        assertEquals("Updated 1 hour ago", l(3600.0))
        assertEquals("Updated 3 hours ago", l(3.0 * 3600))
        assertEquals("Updated 1 day ago", l(86400.0))
        assertEquals("Updated 4 days ago", l(4.0 * 86400))
    }

    @Test fun audioShortlistStartsWithTheZoneAndDedupes() {
        val snap = ForYouFeedSnapshot(
            refreshedAtMs = now, zoneIds = listOf("c0", "c1"),
            crates = listOf(ForYouFeedSnapshot.Crate("k", "playlist", "K", listOf("c1", "c2", "ghost"))),
        )
        val out = ForYouFeedBuilder.audioShortlist(snap, inputs(), perNight = 10)
        assertEquals(out.size, out.toSet().size)
        assertTrue(out.all { it in setOf("c0", "c1", "c2") })
        assertTrue(ForYouFeedBuilder.audioShortlist(snap, inputs().copy(tracks = emptyList())).isEmpty())
    }
}

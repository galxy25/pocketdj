package com.levi.pocketdj.remote

import com.levi.pocketdj.data.catalog.IndexSong
import com.levi.pocketdj.playback.durable.SessionRow
import com.levi.pocketdj.playback.sequencer.QueueItem
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNotEquals
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test

class RemoteSongResolverTest {
    private fun row(
        songId: String, title: String = "T", artist: String = "A", am: String? = null,
        variant: String? = null, locked: Boolean? = null, len: Long? = null, repeat: Int? = null,
    ) = RemoteRow("r-$songId", SessionRow(songId, title, artist, len, repeat, variant, locked, appleMusicId = am))

    private fun qi(id: String, title: String = id, artist: String = "x", len: Long? = null) =
        QueueItem(id = id, title = title, artist = artist, lengthMs = len)

    /** Records which rung was consulted, in order. */
    private class Calls { val log = mutableListOf<String>() }

    private fun resolver(
        calls: Calls = Calls(),
        catalog: Map<String, QueueItem> = emptyMap(),
        byAm: Map<String, QueueItem> = emptyMap(),
        exact: Map<String, QueueItem> = emptyMap(),
        fuzzy: Map<String, QueueItem>? = emptyMap(),
        amOk: Boolean = false,
    ) = RemoteSongResolver(
        catalogItem = { calls.log += "id"; catalog[it] },
        catalogItemForAppleMusicId = { calls.log += "amcat"; byAm[it] },
        matchTitleArtist = { t, a -> calls.log += "exact"; exact["$t|$a"] },
        fuzzyTitleArtist = fuzzy?.let { f -> { t, a -> calls.log += "fuzzy"; f["$t|$a"] } },
        appleMusicAvailable = { calls.log += "amok"; amOk },
    )

    @Test
    fun ladder_ownSongIdWins_andStopsEarly() {
        val c = Calls()
        val r = resolver(c, catalog = mapOf("s1" to qi("s1")), byAm = mapOf("9" to qi("other")), amOk = true)
        val res = r.resolve(row("s1", am = "9"))
        assertTrue(res is RemoteResolution.Catalog)
        assertEquals("s1", res.item?.id)
        assertEquals(listOf("id"), c.log)
    }

    @Test
    fun ladder_order_id_amCatalog_amStream_exact_fuzzy_unavailable() {
        val c = Calls()
        val r = resolver(c, amOk = false)
        assertEquals(RemoteResolution.Unavailable, r.resolve(row("zz", "T", "A", am = "9")))
        assertEquals(listOf("id", "amcat", "amok", "exact", "fuzzy"), c.log)
    }

    @Test
    fun appleMusicCatalogHit_beatsStreaming() {
        val r = resolver(byAm = mapOf("9" to qi("local9")), amOk = true)
        val res = r.resolve(row("zz", am = "9"))
        assertTrue(res is RemoteResolution.Catalog)
        assertEquals("local9", res.item?.id)
    }

    @Test
    fun appleMusicStreaming_whenBackendUsable_namespacesAndKeepsMetadata() {
        val r = resolver(amOk = true)
        val res = r.resolve(row("zz", "Song", "Band", am = "9", len = 1234))
        assertTrue(res is RemoteResolution.AppleMusic)
        assertEquals("am:9", res.item?.id)
        assertEquals("Song", res.item?.title)
        assertEquals(1234L, res.item?.lengthMs)
    }

    @Test
    fun amNamespacedSongId_countsAsAppleMusicId() {
        val r = resolver(amOk = true)
        val res = r.resolve(row("am:777"))
        assertEquals("am:777", res.item?.id)
        assertTrue(res is RemoteResolution.AppleMusic)
    }

    @Test
    fun appleMusicUnusable_fallsThroughToExactThenUnavailable() {
        val r = resolver(exact = mapOf("T|A" to qi("local")), amOk = false)
        val res = r.resolve(row("zz", "T", "A", am = "9"))
        assertTrue(res is RemoteResolution.Matched)
        assertEquals("local", res.item?.id)
    }

    @Test
    fun noAppleMusicId_skipsAmRungsEntirely() {
        val c = Calls()
        resolver(c).resolve(row("zz"))
        assertFalse(c.log.contains("amcat"))
        assertFalse(c.log.contains("amok"))
    }

    @Test
    fun fuzzyDisallowed_isUndecided_notUnavailable() {
        val r = resolver(fuzzy = mapOf("T|A" to qi("f")))
        assertNull(r.resolve(row("zz", "T", "A"), allowFuzzy = false))
        assertEquals("f", r.resolve(row("zz", "T", "A"), allowFuzzy = true)?.item?.id)
    }

    @Test
    fun noFuzzyMatcher_cheapMissIsDecidedUnavailable() {
        val r = resolver(fuzzy = null)
        assertEquals(RemoteResolution.Unavailable, r.resolve(row("zz"), allowFuzzy = false))
    }

    @Test
    fun lastResort_isTriedAfterEverythingElse() {
        val r = RemoteSongResolver(catalogItem = { null }, lastResort = { qi("fake") })
        assertEquals("fake", r.resolve(row("q")).item?.id)
    }

    @Test
    fun stamping_variantAndLockOnlyOnOwnSong() {
        val own = resolver(catalog = mapOf("s1" to qi("s1"))).resolve(row("s1", variant = "clean", locked = true, repeat = 2, len = 9000))
        assertEquals("clean", own.item?.variant)
        assertTrue(own.item!!.editionLocked)
        assertEquals(2, own.item?.repeatCount)
        assertEquals(9000L, own.item?.lengthMs)

        val matched = resolver(exact = mapOf("T|A" to qi("other"))).resolve(row("s1", "T", "A", variant = "clean", locked = true))
        assertNull(matched.item?.variant)
        assertFalse(matched.item!!.editionLocked)
    }

    @Test
    fun catalogLength_winsOverRowLength() {
        val res = resolver(catalog = mapOf("s1" to qi("s1", len = 5000))).resolve(row("s1", len = 9000))
        assertEquals(5000L, res.item?.lengthMs)
    }

    @Test
    fun storeId_parsing() {
        assertEquals("123", RemoteSongResolver.storeId("am:123"))
        assertNull(RemoteSongResolver.storeId("am:album:5"))
        assertNull(RemoteSongResolver.storeId("am:"))
        assertNull(RemoteSongResolver.storeId("sng_1"))
    }

    // ---- window + cache ------------------------------------------------------------------------------

    @Test
    fun fuzzyWindow_isCurrentPlusThree() {
        val fuzzed = mutableListOf<String>()
        val r = RemoteSongResolver(catalogItem = { null }, fuzzyTitleArtist = { t, _ -> fuzzed += t; null })
        val cache = RemoteResolutionCache(r)
        val rows = (0 until 10).map { row("s$it", "t$it") }
        val out = cache.resolve(rows, currentIndex = 2)
        // current(2) + next 3 (3,4,5) decided unavailable; played rows (0,1) and far rows (6..9) undecided.
        assertEquals(setOf("t2", "t3", "t4", "t5"), fuzzed.toSet())
        assertEquals(listOf(null, null) + List(4) { RemoteResolution.Unavailable } + List(4) { null }, out)
    }

    @Test
    fun undecidedRows_areRetried_asTheyNearCurrent() {
        val fuzzed = mutableListOf<String>()
        val r = RemoteSongResolver(
            catalogItem = { null },
            fuzzyTitleArtist = { t, _ -> fuzzed += t; if (t == "t6") qi("hit6") else null },
        )
        val cache = RemoteResolutionCache(r)
        val rows = (0 until 8).map { row("s$it", "t$it") }
        assertNull(cache.resolve(rows, 0)[6])
        val later = cache.resolve(rows, 3)
        assertEquals("hit6", later[6]?.item?.id)
        // decided rows are not re-resolved
        fuzzed.clear()
        cache.resolve(rows, 3)
        assertTrue(fuzzed.isEmpty())
        assertEquals(setOf("r-s0", "r-s1", "r-s2", "r-s3", "r-s4", "r-s5"), cache.unavailableRids)
        assertFalse(cache.unavailableRids.contains("r-s6"))
    }

    @Test
    fun cachedResolution_alwaysGetsFreshUid() {
        val cache = RemoteResolutionCache(resolver(catalog = mapOf("s1" to qi("s1"))))
        val rows = listOf(row("s1"))
        val res1 = cache.resolve(rows, 0)[0]!!
        val res2 = cache.resolve(rows, 0)[0]!!
        assertEquals(res1, res2)
        val a = cache.queueItem(res1)!!
        val b = cache.queueItem(res2)!!
        assertNotEquals(a.uid, b.uid)
        assertNotEquals(res1.item!!.uid, a.uid)
        assertEquals(a.id, b.id)
        assertNull(cache.queueItem(RemoteResolution.Unavailable))
    }

    // ---- outbound ------------------------------------------------------------------------------------

    @Test
    fun outbound_stampsAppleMusicId_andCarriesNoUrlOrToken() {
        val r = RemoteSongResolver(catalogItem = { null }, appleMusicIdForSong = { if (it == "s1") "4242" else null })
        val out = r.outboundRow(QueueItem(id = "s1", title = "Song", artist = "Band", lengthMs = 100, variant = "clean", editionLocked = true))
        assertEquals("4242", out.appleMusicId)
        assertEquals("clean", out.variant)
        assertEquals(true, out.editionLocked)
        val wire = RemoteWire.json.encodeToString(RemoteRow.serializer(), RemoteRow("rid", out))
        assertFalse(wire.contains("http"))
        assertFalse(wire.contains("token", ignoreCase = true))
        assertFalse(wire.contains("resolveId"))
        assertTrue(wire.contains("\"appleMusicId\":\"4242\""))
    }

    @Test
    fun outbound_amNamespacedItem_stampsItsOwnStoreId_noRowIdLeakWhenUnknown() {
        val r = RemoteSongResolver(catalogItem = { null })
        assertEquals("55", r.outboundRow(QueueItem(id = "am:55", title = "t")).appleMusicId)
        assertNull(r.outboundRow(QueueItem(id = "sng_1", title = "t")).appleMusicId)
        assertNull(r.outboundRow(QueueItem(id = "sng_1", title = "t")).editionLocked)
    }

    // ---- production wiring over the catalog ----------------------------------------------------------

    private fun song(id: String, name: String, artist: String, am: String? = null) =
        IndexSong(id = id, artist = artist, name = name, appleMusicId = am, length = 1000)

    @Test
    fun forCatalog_resolvesExactNormalizedKey_andAppleMusicId_andFuzzy() {
        val songs = listOf(song("a", "Café del Mar!", "Energy 52"), song("b", "Other", "Someone", am = "88"), song("c", "Hello World Extended", "Zed"))
        val r = RemoteSongResolver.forCatalog({ songs }, { 1 }, { false })
        assertEquals("a", r.resolve(row("zz", "cafe del mar", "ENERGY 52")).item?.id)
        assertEquals("b", r.resolve(row("zz", "Nope", "Nope", am = "88")).item?.id)
        // fuzzy containment only when allowed
        assertNull(r.resolve(row("zz", "Hello World", "Zed"), allowFuzzy = false))
        assertEquals("c", r.resolve(row("zz", "Hello World", "Zed"), allowFuzzy = true)?.item?.id)
        assertEquals(RemoteResolution.Unavailable, r.resolve(row("zz", "Totally Unknown", "Nobody")))
    }

    @Test
    fun catalogIndex_rebuildsOnlyOnRevisionChange() {
        var rev = 1
        var songs = listOf(song("a", "One", "X"))
        val idx = RemoteCatalogIndex({ songs }, { rev }, { it.run() })
        idx.byTitleArtist(); idx.byTitleArtist(); idx.songById("a")
        assertEquals(1, idx.builds)
        songs = songs + song("b", "Two", "Y")
        idx.byTitleArtist()
        assertEquals("a stale revision keeps the old tables", 1, idx.builds)
        rev = 2
        idx.prepare() // inline runner: the new tables land before the next read
        assertEquals("b", idx.songById("b")?.id)
        assertEquals(2, idx.builds)
    }

    @Test
    fun catalogIndex_firstSongWinsDuplicateKeys() {
        val t = RemoteCatalogIndex.build(listOf(song("a", "Same", "X", am = "1"), song("b", "same", "x", am = "1")))
        assertEquals("a", t.byTitleArtist[RemoteCatalogIndex.key("Same", "X")])
        assertEquals("a", t.byAppleMusicId["1"])
    }

    @Test
    fun catalogIndex_revisionMove_answersFromOldTablesWhileBuilding_thenSwaps() {
        var rev = 1
        var songs = listOf(song("a", "One", "X"))
        val pending = ArrayList<Runnable>()
        val idx = RemoteCatalogIndex({ songs }, { rev }, { pending.add(it) })
        assertEquals("a", idx.songById("a")?.id) // first build is synchronous
        songs = songs + song("b", "Two", "Y"); rev = 2
        assertNull("old tables answer until the background build lands", idx.songById("b"))
        idx.songById("a"); idx.prepare()
        assertEquals("single-flight: one pending build", 1, pending.size)
        pending.removeAt(0).run()
        assertEquals("b", idx.songById("b")?.id)
        assertEquals(2, idx.builds)
    }

    @Test
    fun catalogIndex_fuzzyMemoIsPerBuild() {
        var rev = 1
        var songs = listOf(song("c", "Hello World Extended", "Zed"))
        val idx = RemoteCatalogIndex({ songs }, { rev }, { it.run() })
        assertEquals("c", idx.fuzzy("Hello World", "Zed")?.id)
        songs = emptyList(); rev = 2
        idx.prepare()
        assertNull("a new build must not inherit the old build's memo", idx.fuzzy("Hello World", "Zed"))
    }

    @Test
    fun unknownVariant_isDroppedOnStamp() {
        val base = QueueItem(id = "s1", title = "T", artist = "A")
        val r = RemoteSongResolver(catalogItem = { if (it == "s1") base else null })
        val known = r.resolve(row("s1", "T", "A").let { it.copy(row = it.row.copy(variant = "clean")) })
        assertEquals("clean", known.item?.variant)
        val unknown = r.resolve(row("s1", "T", "A").let { it.copy(row = it.row.copy(variant = "remaster9")) })
        assertNull(unknown.item?.variant)
    }
}

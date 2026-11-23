package com.levi.pocketdj.data.recs

import java.io.File
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNotNull
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test

/** "Liked - not added": which thumbed-up releases still need adding. Pure - no store, network or UI. */
class LikedReleaseSelectionTest {
    private val now = 1_800_000_000_000.0
    private val day = 86_400_000.0
    private val hour = 3_600_000.0

    private fun rel(
        id: String,
        title: String = "Rec",
        releaseAt: Double? = now - 3 * day,
        attempt: LikeAddAttempt? = null,
        tombstoned: Boolean? = null,
    ) = LikedRelease(id, artistId = 1, artistName = "Artist", title = title, releaseAtMs = releaseAt, likedAtMs = now - day, attempt = attempt, tombstoned = tombstoned)

    private fun select(
        accepted: Map<String, Double>,
        meta: List<LikedRelease>,
        owned: Set<String> = emptySet(),
        versionOwned: Set<String> = emptySet(),
        needsRetry: Map<String, String> = emptyMap(),
        inFlight: Set<String> = emptySet(),
    ) = LikedReleaseSelection.likedNotAdded(
        accepted = accepted, meta = meta.associateBy { it.storeId },
        owns = { it.storeId in owned }, ownsVersion = { _, _, t -> t in versionOwned },
        writeNeedsRetry = { needsRetry[it] }, inFlight = inFlight, nowMs = now,
    )

    @Test fun acceptedReleaseWithMetaAndNotOwnedIsARow() {
        val r = select(mapOf("rel:1" to now - hour), listOf(rel("1")))
        assertEquals(listOf("1"), r.rows.map { it.id })
        assertTrue(r.needsHydration.isEmpty())
    }

    @Test fun relartistLikesAreSkippedAndNeverHydrated() {
        val r = select(mapOf("relartist:5" to now), emptyList())
        assertTrue(r.rows.isEmpty()); assertTrue(r.needsHydration.isEmpty())
    }

    @Test fun missingMetaGoesToHydrationNotRows() {
        val r = select(mapOf("rel:7" to now, "rel:8" to now), listOf(rel("8")))
        assertEquals(listOf("7"), r.needsHydration)
        assertEquals(listOf("8"), r.rows.map { it.id })
    }

    @Test fun tombstonedIdIsNeitherRowNorHydrated() {
        val r = select(mapOf("rel:9" to now), listOf(rel("9", tombstoned = true)))
        assertTrue(r.rows.isEmpty()); assertTrue(r.needsHydration.isEmpty())
    }

    @Test fun ownedByProbeIsDropped() {
        assertTrue(select(mapOf("rel:1" to now), listOf(rel("1")), owned = setOf("1")).rows.isEmpty())
    }

    @Test fun ownedAsAnotherVersionIsDropped() {
        assertTrue(select(mapOf("rel:1" to now), listOf(rel("1", title = "Deluxe")), versionOwned = setOf("Deluxe")).rows.isEmpty())
    }

    @Test fun ownedButAppleMusicWriteUnprovenIsKeptAsRetryRow() {
        val r = select(mapOf("rel:1" to now), listOf(rel("1")), owned = setOf("1"), needsRetry = mapOf("1" to "Apple Music write failed: x"))
        assertEquals(1, r.rows.size)
        assertTrue(r.rows[0].retryWriteOnly)
        assertEquals("Apple Music write failed: x", r.rows[0].message)
    }

    @Test fun noAgeLimit() {
        val old = rel("1", releaseAt = now - 200 * day)
        assertEquals(1, select(mapOf("rel:1" to now - 200 * day), listOf(old)).rows.size)
    }

    @Test fun addedWithin24hIsHiddenThenShownAgainIfStillNotOwned() {
        fun attempt(ageHours: Double) = LikeAddAttempt(now - ageHours * hour, LikeAddState.ADDED, null, "confirmed (web)", true)
        assertTrue(select(mapOf("rel:1" to now), listOf(rel("1", attempt = attempt(23.0)))).rows.isEmpty())
        assertEquals(1, select(mapOf("rel:1" to now), listOf(rel("1", attempt = attempt(25.0)))).rows.size)
    }

    @Test fun provenPreAddIsHiddenFromLikedUntilThreeDaysAfterRelease() {
        val a = LikeAddAttempt(now - 10 * day, LikeAddState.AWAITING_RELEASE, null, "confirmed (web)", false)
        assertTrue(select(mapOf("rel:1" to now), listOf(rel("1", releaseAt = now + 5 * day, attempt = a))).rows.isEmpty())
        assertTrue(select(mapOf("rel:1" to now), listOf(rel("1", releaseAt = now - 2 * day, attempt = a))).rows.isEmpty())
        assertEquals(1, select(mapOf("rel:1" to now), listOf(rel("1", releaseAt = now - 4 * day, attempt = a))).rows.size)
    }

    @Test fun unprovenPreOrderShowsInLikedAsAwaitingRelease() {
        val a = LikeAddAttempt(now - hour, LikeAddState.AWAITING_RELEASE, null, "Apple Music write failed: x", false)
        val r = select(mapOf("rel:1" to now), listOf(rel("1", releaseAt = now + 5 * day, attempt = a)))
        assertEquals(LikeAddState.AWAITING_RELEASE, r.rows.first().state)
    }

    @Test fun preAddedSetIsOnlyProvenAwaitingRelease() {
        val proven = LikeAddAttempt(now, LikeAddState.AWAITING_RELEASE, null, "confirmed", false)
        val unproven = LikeAddAttempt(now, LikeAddState.AWAITING_RELEASE, null, "Apple Music write failed: x", false)
        val set = LikedReleaseSelection.preAdded(mapOf("1" to rel("1", attempt = proven), "2" to rel("2", attempt = unproven), "3" to rel("3")))
        assertEquals(setOf("1"), set)
    }

    @Test fun orderingInFlightAndErrorsFirstThenNewestLikeFirst() {
        val failed = LikeAddAttempt(now - hour, LikeAddState.FAILED, "no", null, false)
        val r = select(
            mapOf("rel:old" to now - 5 * day, "rel:new" to now - hour, "rel:err" to now - 9 * day, "rel:busy" to now - 20 * day),
            listOf(rel("old"), rel("new"), rel("err", attempt = failed), rel("busy")),
            inFlight = setOf("busy"),
        )
        assertEquals(listOf("busy", "err", "new", "old"), r.rows.map { it.id })
        assertTrue(r.rows[0].inFlight)
    }

    @Test fun storeIdParsing() {
        assertEquals("123", LikedReleaseSelection.storeId("rel:123"))
        assertNull(LikedReleaseSelection.storeId("relartist:123"))
        assertNull(LikedReleaseSelection.storeId("rel:"))
    }

    // ---- row copy (pure) ----

    @Test fun actionTitlesAndStatusLines() {
        fun row(release: LikedRelease = rel("1"), inFlight: Boolean = false, retry: Boolean = false, message: String? = null) =
            LikedRow(release, now, inFlight, retry, message)
        val p = com.levi.pocketdj.screens.foryou.NewReleasesPresentation
        assertEquals("Add", p.likedActionTitle(row()))
        assertEquals("Retry Apple Music", p.likedActionTitle(row(retry = true)))
        val failed = rel("1", attempt = LikeAddAttempt(now, LikeAddState.FAILED, "boom", null, false))
        assertEquals("Retry", p.likedActionTitle(row(failed)))
        assertEquals("boom", p.likedStatusLine(row(failed, message = "boom"), now))
        assertEquals("Adding…", p.likedStatusLine(row(inFlight = true), now))
        val off = rel("1", attempt = LikeAddAttempt(now, LikeAddState.OFFLINE, null, null, false))
        assertEquals(com.levi.pocketdj.screens.foryou.NewReleaseLikeAdder.OFFLINE_MESSAGE, p.likedStatusLine(row(off), now))
        assertNull(p.likedStatusLine(row(), now))
        val waiting = rel("1", releaseAt = now + 2 * day, attempt = LikeAddAttempt(now, LikeAddState.AWAITING_RELEASE, null, "x", false))
        assertTrue(p.likedStatusLine(row(waiting), now)!!.contains("will add on release day"))
    }

    // ---- offered() keeps proven pre-adds ----

    @Test fun offeredKeepsPreAddedReleasesOnly() {
        val e = ArtistReleaseEntry(1, "A", releaseId = "10")
        val e2 = ArtistReleaseEntry(2, "B", releaseId = "11")
        val items = listOf(ReleaseFeedItem(e, ReleaseStatus.COMING_SOON), ReleaseFeedItem(e2, ReleaseStatus.COMING_SOON))
        val accepted = mapOf("rel:10" to 1.0, "rel:11" to 1.0)
        val out = com.levi.pocketdj.screens.foryou.NewReleasesPresentation.offered(items, accepted, setOf("10"))
        assertEquals(listOf(1), out.map { it.entry.artistId })
        // Default (no keeping) is the old behaviour.
        assertTrue(com.levi.pocketdj.screens.foryou.NewReleasesPresentation.offered(items, accepted).isEmpty())
    }

    // ---- store / codec / hydration decode ----

    private fun tmp(): File = File.createTempFile("pdj-liked", ".json").also { it.deleteOnExit() }

    @Test fun storeRoundTrip() {
        val f = tmp()
        val a = LikedReleasesStore(f)
        a.upsert(
            LikedRelease(
                "10", 3, "A", "T", "https://x/{w}x{h}.jpg", 5.0, "album", 9, true, 7.0,
                LikeAddAttempt(8.0, LikeAddState.FAILED, "m", "w", true),
            ),
        )
        val b = LikedReleasesStore(f)
        assertEquals(a.releases["10"], b.releases["10"])
    }

    @Test fun malformedRowIsSkippedUnknownKeysIgnoredUnknownStateDropsOnlyTheAttempt() {
        val f = tmp()
        f.writeText(
            """{"schemaVersion":1,"surprise":true,"releases":[
              {"storeId":"1","title":"Good","futureField":42},
              {"title":"no id"},
              {"storeId":"2","attempt":{"atMs":1,"state":"somethingNew"}}]}""",
        )
        val s = LikedReleasesStore(f)
        assertEquals("Good", s.releases["1"]?.title)
        assertEquals(setOf("1", "2"), s.releases.keys)
        assertNull(s.releases["2"]?.attempt)
    }

    @Test fun addingBecomesOfflineAfterReload() {
        val f = tmp()
        val a = LikedReleasesStore(f)
        a.upsert(LikedRelease("1", attempt = LikeAddAttempt(1.0, LikeAddState.ADDING)))
        val b = LikedReleasesStore(f)
        assertEquals(LikeAddState.OFFLINE, b.releases["1"]?.attempt?.state)
    }

    @Test fun upsertKeepsAttemptAndLikeTimeWhenIncomingHasNone() {
        val s = LikedReleasesStore(null)
        s.upsert(LikedRelease("1", likedAtMs = 5.0, attempt = LikeAddAttempt(1.0, LikeAddState.FAILED, "x")))
        s.upsert(LikedRelease("1", artistName = "Fresh"))
        assertEquals("Fresh", s.releases["1"]?.artistName)
        assertEquals(5.0, s.releases["1"]?.likedAtMs)
        assertEquals(LikeAddState.FAILED, s.releases["1"]?.attempt?.state)
    }

    @Test fun pruneDropsRowsNoLongerAccepted() {
        val s = LikedReleasesStore(null)
        s.upsert(listOf(LikedRelease("1"), LikedRelease("2")))
        s.prune(setOf("2"))
        assertEquals(setOf("2"), s.releases.keys)
    }

    @Test fun albumsParserCoversDatesKindsMissingRelationshipsAndTombstones() {
        val body = """{"data":[
          {"id":"100","attributes":{"name":"Full","artistName":"Ann","releaseDate":"2026-08-01","artwork":{"url":"https://a/{w}x{h}bb.jpg"},"trackCount":12,"contentRating":"explicit"},"relationships":{"artists":{"data":[{"id":"555"}]}}},
          {"id":"101","attributes":{"name":"Year Only","artistName":"Bob","releaseDate":"2026","isSingle":true}},
          {"id":"102","attributes":{"name":"Comp","artistName":"Cy","isCompilation":true}}]}"""
        val out = AlbumsCatalogParser.parse(body, listOf("100", "101", "102", "999")) { 42.0 }!!.associateBy { it.storeId }
        assertEquals(555, out["100"]?.artistId)
        assertEquals("Full", out["100"]?.title)
        assertEquals(true, out["100"]?.explicit)
        assertEquals(12, out["100"]?.trackCount)
        assertEquals("album", out["100"]?.kind)
        assertEquals(ArtistsCatalogResponse.parseReleaseDate("2026-08-01"), out["100"]?.releaseAtMs)
        assertNotNull(out["100"]?.releaseAtMs)
        assertNull(out["101"]?.releaseAtMs)
        assertEquals("single", out["101"]?.kind)
        assertNull(out["101"]?.artistId)
        assertEquals("compilation", out["102"]?.kind)
        assertEquals(true, out["999"]?.tombstoned)
        assertEquals(42.0, out["999"]?.likedAtMs)
    }

    @Test fun errorEnvelopeIsNotAllTombstones() {
        assertNull(AlbumsCatalogParser.parse("""{"errors":[{"status":"500"}]}""", listOf("1")) { null })
        assertNull(AlbumsCatalogParser.parse("not json", listOf("1")) { null })
    }

    @Test fun requestUrlShape() {
        assertEquals("https://api.music.apple.com/v1/catalog/us/albums?ids=1,2", LikedReleaseHydration.requestUrl(listOf("1", "2")))
    }

    @Test fun likedFromEntryRequiresReleaseId() {
        assertNull(LikedRelease.from(ArtistReleaseEntry(1, "A"), 1.0))
        assertFalse(LikedRelease.from(ArtistReleaseEntry(1, "A", releaseId = "5"), 1.0)?.storeId.isNullOrEmpty())
    }
}

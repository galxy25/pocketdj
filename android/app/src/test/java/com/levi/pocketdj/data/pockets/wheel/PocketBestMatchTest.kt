package com.levi.pocketdj.data.pockets.wheel

import com.levi.pocketdj.data.PdjJson
import com.levi.pocketdj.data.history.PlayEvent
import com.levi.pocketdj.data.history.PlaySource
import com.levi.pocketdj.data.pockets.ListeningContextTag
import com.levi.pocketdj.data.pockets.ListeningPocketCollectionCandidate
import com.levi.pocketdj.data.pockets.ListeningPocketFeature
import com.levi.pocketdj.data.pockets.ListeningPocketMembershipWeight
import com.levi.pocketdj.data.pockets.ListeningPocketNumeric
import com.levi.pocketdj.di.PocketsGraph
import kotlinx.coroutines.runBlocking
import kotlinx.serialization.Serializable
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNotNull
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test
import kotlin.math.exp
import com.levi.pocketdj.data.pockets.wheel.PocketMode.*

/** Port of iOS `PocketBestMatchTests` on the shared `pocket-wheel-history.json` fixture, plus the controller. */
class PocketBestMatchTest {

    @Serializable
    private data class FxSong(val artist: String, val genre: String? = null, val bpm: Double? = null, val year: Int? = null)

    @Serializable
    private data class FxColl(val id: String, val name: String, val songIds: List<String>)

    @Serializable
    private data class Fixture(
        val nowMs: Double,
        val tzOffsetMin: Int,
        val librarySize: Int,
        val songs: Map<String, FxSong>,
        val collections: List<FxColl>,
        val events: List<PlayEvent>,
    )

    private fun fixture(): Fixture {
        val s = javaClass.classLoader!!.getResourceAsStream("fixtures/pocket-wheel-history.json") ?: error("missing fixture")
        return PdjJson.lenient.decodeFromString(Fixture.serializer(), s.readBytes().decodeToString())
    }

    private fun fixtureWheel(): PocketWheelSnapshot {
        val f = fixture()
        return PocketMomentEngine.build(
            PocketMomentEngine.Input(
                events = f.events,
                collections = f.collections.map { PocketMomentEngine.CollectionInfo(it.id, it.name, it.songIds.toSet()) },
                songs = f.songs.mapValues { PocketMomentEngine.SongInfo(it.value.artist, it.value.genre, it.value.bpm, it.value.year) },
                librarySize = f.librarySize,
                nowMs = f.nowMs,
            ),
        )
    }

    private fun key(d: Int, h: Int, m: PocketMode) = PocketMomentKey(h, d, m)
    private fun now(h: Double, d: Int, m: PocketMode? = null, ctx: String? = null) = PocketBestMatch.Now(h, d, m, ctx)

    // Kernels

    @Test fun timeKernelIsCircular() {
        assertEquals(1.0, PocketBestMatch.kt(now(8.5, 2), key(2, 8, CAR_PLAY)), 1e-12)
        assertEquals(exp(-0.5), PocketBestMatch.kt(now(9.5, 2), key(2, 8, CAR_PLAY)), 1e-12)
        assertEquals("wraps midnight", exp(-0.5), PocketBestMatch.kt(now(23.5, 2), key(2, 0, CAR_PLAY)), 1e-12)
        assertEquals(2.0, PocketBestMatch.circularHours(1.0, 23.0), 1e-12)
    }

    @Test fun dayModeAndPlaceKernels() {
        assertEquals(1.0, PocketBestMatch.kd(now(8.0, 2), key(2, 8, CAR_PLAY)), 0.0)
        assertEquals(0.6, PocketBestMatch.kd(now(8.0, 2), key(4, 8, CAR_PLAY)), 0.0)
        assertEquals(0.25, PocketBestMatch.kd(now(8.0, 2), key(6, 8, CAR_PLAY)), 0.0)
        assertEquals(1.0, PocketBestMatch.km(now(8.0, 2, CAR_PLAY), key(2, 8, CAR_PLAY)), 0.0)
        assertEquals(0.7, PocketBestMatch.km(now(8.0, 2, CAR_PLAY), key(2, 8, TRIP)), 0.0)
        assertEquals(0.35, PocketBestMatch.km(now(8.0, 2, CAR_PLAY), key(2, 8, MIX)), 0.0)
        assertEquals("unknown mode", 0.6, PocketBestMatch.km(now(8.0, 2), key(2, 8, MIX)), 0.0)
        val m = PocketMoment(key = key(2, 8, TRIP), ctx = mapOf("trip:trp_ab" to 0.5, "none" to 0.5))
        assertEquals(0.65, PocketBestMatch.kl(now(8.0, 2, ctx = "trip:trp_ab"), m), 1e-12)
        assertEquals("no place now is neutral", 1.0, PocketBestMatch.kl(now(8.0, 2), m), 0.0)
    }

    @Test fun modeNowOrdersCarThenMotionThenTrip() {
        val trip = ListeningContextTag(ListeningContextTag.KIND_TRIP, tripId = "t", origin = "a")
        assertEquals(CAR_PLAY, PocketBestMatch.modeNow(true, "running", null))
        assertEquals(RUNNING, PocketBestMatch.modeNow(false, "running", null))
        assertEquals(WALKING, PocketBestMatch.modeNow(false, "walking", null))
        assertEquals(TRIP, PocketBestMatch.modeNow(false, "automotive", null))
        assertEquals(TRIP, PocketBestMatch.modeNow(false, "cycling", null))
        assertEquals(TRIP, PocketBestMatch.modeNow(false, null, trip))
        assertNull(PocketBestMatch.modeNow(false, "stationary", ListeningContextTag.place("p")))
    }

    // Tiers on the fixture

    @Test fun richTierPicksTheMomentAndOffersDistinctAlternatives() {
        val r = PocketBestMatch.best(fixtureWheel(), now(8.5, 2, CAR_PLAY))
        assertEquals(PocketProfile.Tier.RICH, r.profile.tier)
        assertEquals(key(2, 8, CAR_PLAY), r.profile.key)
        assertEquals("pl_potential", r.profile.dominantCollectionId)
        assertEquals("Tue 8 AM · CarPlay", r.profile.caption)
        assertTrue(r.profile.detail, r.profile.detail.startsWith("Potential · "))
        assertEquals(CAR_PLAY, r.profile.mode)
        val alts = r.alternatives.mapNotNull { it.dominantCollectionId }
        assertEquals("alternatives have distinct collections", alts.size, alts.toSet().size)
        assertFalse(alts.contains("pl_potential"))
        assertTrue(alts.size <= 3)
        assertNotNull(r.winner)
    }

    @Test fun saturdayMorningRunWins() {
        val r = PocketBestMatch.best(fixtureWheel(), now(9.2, 6, RUNNING))
        assertEquals(key(6, 9, RUNNING), r.profile.key)
        assertEquals("fav_songs", r.profile.dominantCollectionId)
    }

    @Test fun eveningMixAndW7Mode() {
        val r = PocketBestMatch.best(fixtureWheel(), now(21.3, 3))
        assertEquals("unknown mode at 9 PM -> the Mix pocket", MIX, r.profile.key?.mode)
        assertEquals("W7: the run plays through Mix Auto-DJ", MIX, r.profile.mode)
    }

    @Test fun continuityPullsAndSkipStreakPushes() {
        val snap = fixtureWheel()
        val base = PocketBestMatch.best(snap, now(12.5, 3))
        assertEquals("pkt_chill", base.profile.dominantCollectionId)
        val n = now(10.5, 3).copy(recentCollections = mapOf("pl_potential" to 1.0), recentSkipRate = 0.0)
        val potCell = snap.moments.first { it.key == key(3, 8, CAR_PLAY) }
        val pull = PocketBestMatch.score(potCell, n, emptySet())
        val push = PocketBestMatch.score(potCell, n.copy(recentSkipRate = 0.8), emptySet())
        assertTrue(pull.continuity > 0)
        assertTrue("a skip streak negates continuity", push.continuity < 0)
        assertEquals(-pull.continuity, push.continuity, 1e-12)
        assertTrue(pull.score > push.score)
        // Exactly at the threshold is NOT a streak.
        assertTrue(PocketBestMatch.score(potCell, n.copy(recentSkipRate = 0.5), emptySet()).continuity > 0)
    }

    @Test fun cloudBoost() {
        val m = PocketMoment(key = key(2, 8, CAR_PLAY), plays = 10.0, cloudPatternIds = listOf("pat_1"))
        val a = PocketBestMatch.score(m, now(8.5, 2, CAR_PLAY), emptySet())
        val b = PocketBestMatch.score(m, now(8.5, 2, CAR_PLAY), setOf("pat_1"))
        assertEquals(1.15, b.score / a.score, 1e-9)
        assertEquals("a non-matching pattern is not boosted", a.score, PocketBestMatch.score(m, now(8.5, 2, CAR_PLAY), setOf("other")).score, 0.0)
    }

    @Test fun constantsMatchTheDesign() {
        assertEquals(0.35, PocketBestMatch.richMinMatch, 0.0)
        assertEquals(3.0, PocketBestMatch.richMinPlays, 0.0)
        assertEquals(3.0, PocketBestMatch.neighbourhoodHours, 0.0)
        assertEquals(5, PocketBestMatch.neighbourhoodMinPlays)
        assertEquals(20, PocketBestMatch.coldMinPlays)
        assertEquals(0.35, PocketBestMatch.continuityWeight, 0.0)
        assertEquals(1.15, PocketBestMatch.cloudBoost, 0.0)
    }

    // Cold-start tiers (trimmed fixtures)

    private fun snapshot(moments: List<PocketMoment>, total: Int) = PocketWheelSnapshot(
        builtAtMs = 0.0, moments = moments, collectionNames = mapOf("c1" to "One", "c2" to "Two"),
        dominanceOrder = listOf("c1"), totalDirectPlays = total,
    )

    private fun cell(d: Int, h: Int, mode: PocketMode, plays: Double, direct: Int, coll: String) = PocketMoment(
        key = key(d, h, mode), plays = plays, directPlays = direct, distinctDays = 2,
        collections = mapOf(coll to 1.0), dominantCollectionId = coll,
    )

    @Test fun neighbourhoodTierBlendsNearbyCells() {
        val s = snapshot(
            listOf(cell(2, 6, COLLECTION, 2.0, 2, "c1"), cell(3, 7, COLLECTION, 2.0, 2, "c1"), cell(4, 10, MIX, 2.0, 2, "c2")), 6,
        )
        val r = PocketBestMatch.best(s, now(8.5, 2))
        assertEquals(PocketProfile.Tier.NEIGHBOURHOOD, r.profile.tier)
        assertEquals("Weekday mornings", r.profile.caption)
        assertEquals(setOf("c1", "c2"), r.profile.collections.keys)
        assertTrue((r.profile.collections["c1"] ?: 0.0) > (r.profile.collections["c2"] ?: 0.0))
        assertEquals(COLLECTION, r.profile.mode)
        assertTrue(r.profile.momentKeys.size == 3)
    }

    @Test fun neighbourhoodDoesNotCrossTheWeekendBoundary() {
        // Same hour, but weekend plays do not count for a weekday NOW.
        val s = snapshot(listOf(cell(6, 8, COLLECTION, 2.0, 6, "c1")), 6)
        assertEquals(PocketProfile.Tier.EMPTY, PocketBestMatch.best(s, now(8.5, 2)).profile.tier)
    }

    @Test fun cloudThenHistoryThenEmptyTiers() {
        val far = snapshot(listOf(cell(6, 22, MIX, 30.0, 25, "c2")), 25)
        val cloud = PocketProfile(PocketProfile.Tier.CLOUD, caption = "From your listening pockets", detail = "x", collections = mapOf("c9" to 1.0))
        assertEquals(PocketProfile.Tier.CLOUD, PocketBestMatch.best(far, now(8.5, 2), PocketBestMatch.Fallbacks(cloud = cloud)).profile.tier)
        val hist = PocketBestMatch.best(far, now(8.5, 2))
        assertEquals(PocketProfile.Tier.HISTORY, hist.profile.tier)
        assertEquals("Your recent favourites", hist.profile.caption)
        assertEquals("c2", hist.profile.dominantCollectionId)
        val thin = snapshot(listOf(cell(6, 22, MIX, 3.0, 3, "c2")), 3)
        val empty = PocketBestMatch.best(thin, now(8.5, 2))
        assertEquals(PocketProfile.Tier.EMPTY, empty.profile.tier)
        assertEquals("Getting to know you", empty.profile.caption)
        val fav = PocketProfile(PocketProfile.Tier.EMPTY, caption = "Getting to know you", detail = "Favorite songs", collections = mapOf("fav_songs" to 1.0))
        assertEquals("fav_songs", PocketBestMatch.best(thin, now(8.5, 2), PocketBestMatch.Fallbacks(empty = fav)).profile.dominantCollectionId)
    }

    @Test fun totallyEmptySnapshotIsTheEmptyTier() {
        val r = PocketBestMatch.best(PocketWheelSnapshot(), now(8.5, 2))
        assertEquals(PocketProfile.Tier.EMPTY, r.profile.tier)
        assertNull(r.winner)
        assertTrue(r.alternatives.isEmpty())
    }

    @Test fun recentActivity() {
        val t = 1_793_115_000_000.0
        fun ev(minsAgo: Double, skipped: Boolean = false, game: Boolean = false) = PlayEvent(
            id = "e$minsAgo", songId = "s", playedAt = t - minsAgo * 60_000,
            source = if (game) PlaySource.GAME else PlaySource.PLAYLIST, originCollectionId = "c1",
            wasSkipped = if (skipped) true else null,
        )
        val (colls, rate) = PocketBestMatch.recentActivity(
            listOf(ev(90.0), ev(40.0), ev(30.0, skipped = true), ev(10.0), ev(5.0, game = true)), t,
            { mapOf((it.originCollectionId ?: "") to 1.0) },
        )
        assertEquals("two unskipped plays inside 45 min", 2.0, colls["c1"]!!, 0.0)
        assertEquals(1.0 / 3, rate!!, 1e-9)
        assertNull(PocketBestMatch.recentActivity(emptyList(), t, { emptyMap() }).second)
    }

    // PocketProfile builders

    @Test fun fromListeningBuildsADerivedProfile() {
        val p = PocketProfile.fromListening(
            title = "Friday groove",
            features = listOf(
                ListeningPocketFeature("artist", "a1", "A1", 0.5, lift = 2.0, score = 0.8),
                ListeningPocketFeature("genre", "disco", "Disco", 0.5, lift = 2.0, score = 0.4),
                ListeningPocketFeature("collection", "ignored", "x", 0.5, lift = 2.0, score = 0.9),
                ListeningPocketFeature("artist", "zero", "Z", 0.5, lift = 2.0, score = 0.0),
            ),
            numeric = mapOf(
                "bpm" to ListeningPocketNumeric(120.0, 118.0, 122.0, 0.2, null, null, defining = true),
                "year" to ListeningPocketNumeric(1980.0, 1979.0, 1981.0, 0.9, null, null, defining = false),
            ),
            membership = listOf(ListeningPocketMembershipWeight("c1", 3.0), ListeningPocketMembershipWeight("c2", 1.0)),
            candidates = listOf(ListeningPocketCollectionCandidate("s9", 0.7)),
            songIds = listOf("s1", "s2", "s1"),
        )
        assertEquals(PocketProfile.Tier.CLOUD, p.tier)
        assertEquals("Friday groove", p.caption)
        assertEquals("A fresh mix from this pocket", p.detail)
        assertEquals("membership wins over the collection feature", setOf("c1", "c2"), p.collections.keys)
        assertEquals(0.75, p.collections["c1"]!!, 1e-6)
        assertEquals(setOf("a1"), p.artists.keys)
        assertEquals(setOf("disco"), p.genres.keys)
        assertEquals("a 4-BPM band widens to 6", 6.0, p.bpmHi!! - p.bpmLo!!, 0.0)
        assertEquals(1977.0, p.eraLo!!, 0.0)
        assertEquals(1983.0, p.eraHi!!, 0.0)
        assertEquals(mapOf("s1" to 1.0, "s2" to 1.0), p.seeds)
        assertEquals(mapOf("s9" to 0.7), p.candidateBoost)
        assertNull(p.key)
    }

    @Test fun fromListeningSkipsWeakNumericsAndUsesCollectionFeatureWithoutMembership() {
        val p = PocketProfile.fromListening(
            "t",
            listOf(ListeningPocketFeature("collection", "c7", "C7", 0.5, lift = 1.0, score = 1.0)),
            mapOf("bpm" to ListeningPocketNumeric(100.0, 90.0, 110.0, 0.3, null, null, defining = false)),
            emptyList(), songIds = emptyList(),
        )
        assertEquals(setOf("c7"), p.collections.keys)
        assertNull(p.bpmBand)
        assertNull(p.era)
    }

    @Test fun profileJsonRoundTripsInTheIosShape() {
        val p = PocketBestMatch.best(fixtureWheel(), now(8.5, 2, CAR_PLAY)).profile
        val json = PdjJson.lenient.encodeToString(PocketProfile.serializer(), p)
        assertTrue(json, json.contains("\"tier\":\"rich\""))
        assertEquals(p, PdjJson.lenient.decodeFromString(PocketProfile.serializer(), json))
    }

    @Test fun fromMomentAliasMatchesFrom() {
        val snap = fixtureWheel()
        val m = snap.moments.first()
        assertEquals(PocketProfile.from(m, snap.collectionNames), PocketProfile.fromMoment(m, snap.collectionNames))
    }

    // Controller

    private fun controller(snap: PocketWheelSnapshot, nowMs: Double, events: List<PlayEvent> = emptyList()) =
        PocketWheelController({ snap }, { events }).also {
            it.clockMs = { nowMs }
            it.tzOffsetMin = { 0 }
        }

    /** Tuesday 2026-10-06 (ISO 2) 08:30 UTC. */
    private val tuesday0830 = 1_791_275_400_000.0

    @Test fun controllerForcesCarModeWhenAndroidAutoIsConnected() = runBlocking {
        val c = controller(fixtureWheel(), tuesday0830)
        val t = PocketClock.local(tuesday0830, 0)
        assertEquals(2, t.dow)
        c.carConnected = { true }
        c.motionNow = { "running" }
        val r = c.refresh()
        assertEquals(CAR_PLAY, c.lastNow!!.mode)
        assertEquals(key(2, 8, CAR_PLAY), r.profile.key)
        assertEquals(r, c.result.value)
    }

    @Test fun controllerFallsBackToMotionThenTripGuess() = runBlocking {
        val c = controller(fixtureWheel(), tuesday0830)
        c.motionNow = { "walking" }
        c.refresh()
        assertEquals(WALKING, c.lastNow!!.mode)
        c.motionNow = { null }
        c.contextGuess = { ListeningContextTag(ListeningContextTag.KIND_TRIP, tripId = "trp_ab", origin = "a") }
        c.refresh()
        assertEquals(TRIP, c.lastNow!!.mode)
        assertEquals("trip:trp_ab", c.lastNow!!.ctx)
        c.contextGuess = { ListeningContextTag.place("p1") }
        c.refresh()
        assertNull(c.lastNow!!.mode)
        assertEquals("place:p1", c.lastNow!!.ctx)
        // A throwing motion source never breaks the refresh.
        c.motionNow = { error("sensor") }
        c.refresh()
        assertNull(c.lastNow!!.mode)
    }

    @Test fun controllerPlaysTheBestMomentAndAlternatives() = runBlocking {
        val c = controller(fixtureWheel(), tuesday0830)
        val played = ArrayList<PocketProfile>()
        c.play = { played += it; true }
        c.carConnected = { true }
        assertTrue(c.playBest())
        assertEquals(key(2, 8, CAR_PLAY), played.last().key)
        val alt = c.alternativeSummaries.firstOrNull()
        assertNotNull(alt)
        assertTrue(c.playAlternative(alt!!))
        assertEquals(alt.key, played.last().key)
        assertFalse("an unknown key plays nothing", c.playMoment(key(1, 3, BROWSE)))
        assertFalse(c.playAlternative(PocketWheelBestMatchSummary(null, "x", "y", null)))
        assertEquals(c.bestSummary?.caption, "Tue 8 AM · CarPlay")
    }

    @Test fun controllerProfileForModeReturnsNullOnTheEmptyTier() = runBlocking {
        val c = controller(PocketWheelSnapshot(), tuesday0830)
        assertNull(c.profileForMode(RUNNING))
        val c2 = controller(fixtureWheel(), tuesday0830)
        assertEquals(RUNNING, c2.profileForMode(RUNNING)?.mode ?: RUNNING)
        assertNotNull(c2.profileForMode(CAR_PLAY))
    }

    @Test fun momentsNowIsWithinAnHourAcrossModes() = runBlocking {
        val c = controller(fixtureWheel(), tuesday0830)
        assertTrue("before the first refresh there is no NOW", c.momentsNow().isEmpty())
        c.refresh()
        val ms = c.momentsNow(10)
        assertTrue(ms.isNotEmpty())
        for (m in ms) assertTrue(PocketBestMatch.circularHours(c.lastNow!!.hour, m.key.hour + 0.5) <= 1.5)
        val scores = ms.map { PocketBestMatch.score(it, c.lastNow!!, emptySet()).score }
        assertEquals(scores.sortedDescending(), scores)
        assertTrue(c.momentsNow(2).size <= 2)
    }

    @Test fun refreshIfStaleOnlyRecomputesAfterAMinute() = runBlocking {
        var t = tuesday0830
        val c = PocketWheelController({ fixtureWheel() }, { emptyList() })
        c.clockMs = { t }; c.tzOffsetMin = { 0 }
        c.refresh()
        val first = c.computedAtMs
        t += 30_000
        c.refreshIfStale()
        assertEquals(first, c.computedAtMs, 0.0)
        t += 40_000
        c.refreshIfStale()
        assertEquals(t, c.computedAtMs, 0.0)
    }

    @Test fun controllerFeedsRecentSkipsIntoTheNow() = runBlocking {
        val evs = listOf(
            PlayEvent("a", "s1", tuesday0830 - 10 * 60_000, PlaySource.PLAYLIST, originCollectionId = "pl_potential", wasSkipped = true),
            PlayEvent("b", "s2", tuesday0830 - 5 * 60_000, PlaySource.PLAYLIST, originCollectionId = "pl_potential"),
        )
        val c = controller(fixtureWheel(), tuesday0830, evs)
        c.refresh()
        assertEquals(0.5, c.lastNow!!.recentSkipRate!!, 1e-12)
        assertEquals(1.0, c.lastNow!!.recentCollections["pl_potential"]!!, 0.0)
    }

    @Test fun emptyFallbackPrefersTheMostRecentCollectionThenFavorites() {
        val ev = PlayEvent("a", "s", 1.0, PlaySource.PLAYLIST, contextName = "Chill", originCollectionId = "pl_chill")
        val game = PlayEvent("g", "s", 2.0, PlaySource.GAME, originCollectionId = "pl_game")
        val recent = PocketsGraph.emptyFallbackProfile(listOf(ev, game), hasFavorites = true)!!
        assertEquals("pl_chill", recent.dominantCollectionId)
        assertEquals("Chill", recent.detail)
        assertEquals(PocketProfile.Tier.EMPTY, recent.tier)
        val fav = PocketsGraph.emptyFallbackProfile(emptyList(), hasFavorites = true)!!
        assertEquals(PocketWheelIds.FAVORITES, fav.dominantCollectionId)
        assertNull(PocketsGraph.emptyFallbackProfile(emptyList(), hasFavorites = false))
    }
}

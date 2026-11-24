package com.levi.pocketdj.data.pockets.wheel

import com.levi.pocketdj.data.PdjJson
import com.levi.pocketdj.data.history.PlayEvent
import com.levi.pocketdj.data.history.PlaySource
import com.levi.pocketdj.data.history.PocketRunTag
import kotlinx.serialization.Serializable
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNotNull
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test
import com.levi.pocketdj.data.pockets.wheel.PocketMode.*

/** One-to-one port of iOS `PocketMomentEngineTests`, on the shared `pocket-wheel-history.json` fixture. */
class PocketMomentEngineTest {

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

    private fun input(f: Fixture) = PocketMomentEngine.Input(
        events = f.events,
        collections = f.collections.map { PocketMomentEngine.CollectionInfo(it.id, it.name, it.songIds.toSet()) },
        songs = f.songs.mapValues { PocketMomentEngine.SongInfo(it.value.artist, it.value.genre, it.value.bpm, it.value.year) },
        librarySize = f.librarySize,
        nowMs = f.nowMs,
    )

    private fun wheel(): Pair<PocketWheelSnapshot, Map<PocketMomentKey, PocketMoment>> {
        val snap = PocketMomentEngine.build(input(fixture()))
        return snap to snap.index()
    }

    private fun k(dow: Int, hour: Int, mode: PocketMode) = PocketMomentKey.of(hour, dow, mode)

    // Fixture-level behaviour

    @Test fun eachScenarioPaintsItsCellWithItsCollection() {
        val (_, m) = wheel()
        assertEquals("pl_potential", m[k(2, 8, CAR_PLAY)]?.dominantCollectionId)
        assertEquals("fav_songs", m[k(6, 9, RUNNING)]?.dominantCollectionId)
        assertEquals("pkt_late", m[k(3, 21, MIX)]?.dominantCollectionId)
        assertEquals("pkt_chill", m[k(2, 12, BROWSE)]?.dominantCollectionId)
        assertEquals("pls_road", m[k(7, 15, TRIP)]?.dominantCollectionId)
        assertEquals(1.0, m[k(7, 15, TRIP)]?.ctx?.get("trip:trp_ab"))
    }

    @Test fun megaCollectionNeverColoursACell() {
        val (snap, _) = wheel()
        for (moment in snap.moments) assertNull("mega excluded (${moment.key.token})", moment.collections["pl_library"])
        assertFalse(snap.dominanceOrder.contains("pl_library"))
    }

    @Test fun distinctDaysCountDirectCreditOnly() {
        val (_, m) = wheel()
        val tue8 = m[k(2, 8, CAR_PLAY)]!!
        assertEquals(3, tue8.distinctDays)
        assertTrue(tue8.isRecurring)
        val tue7 = m[k(2, 7, CAR_PLAY)]!!
        assertTrue(tue7.plays > 0)
        assertEquals(0, tue7.distinctDays)
        assertEquals(0, tue7.directPlays)
        val oneOff = m[k(4, 3, BROWSE)]!!
        assertEquals(1, oneOff.distinctDays)
        assertFalse(oneOff.isRecurring)
    }

    @Test fun skipsAndGames() {
        val (_, m) = wheel()
        val mon8 = m[k(1, 8, CAR_PLAY)]!!
        assertEquals(3, mon8.directSkips)
        assertTrue(mon8.skipRate > 0)
        for (mode in PocketMode.entries) assertEquals("games excluded ($mode)", 0, m[k(1, 10, mode)]?.directPlays ?: 0)
    }

    @Test fun dominanceOrderAndWeekShare() {
        val (snap, _) = wheel()
        assertEquals("pl_potential", snap.dominanceOrder.first())
        assertTrue(snap.dominanceOrder.containsAll(listOf("pl_potential", "pkt_late", "fav_songs", "pls_road", "pkt_chill")))
        assertTrue(snap.weekShare.values.sum() <= 1.0 + 1e-9)
        assertTrue((snap.weekShare["pl_potential"] ?: 0.0) > (snap.weekShare["pls_road"] ?: 0.0))
        assertEquals("Potential", snap.collectionNames["pl_potential"])
    }

    @Test fun featureAggregates() {
        val (_, m) = wheel()
        val tue8 = m[k(2, 8, CAR_PLAY)]!!
        assertNotNull(tue8.bpmBand)
        assertNotNull(tue8.era)
        assertEquals(listOf("hip-hop", "r&b"), tue8.genres.keys.sorted())
        assertTrue(tue8.seeds.isNotEmpty())
        assertEquals(1.0, tue8.collections.values.sum(), 1e-6)
    }

    @Test fun deterministicAndCacheRoundTrips() {
        val a = PocketMomentEngine.build(input(fixture()))
        val b = PocketMomentEngine.build(input(fixture()))
        assertEquals(a, b)
        val back = PdjJson.lenient.decodeFromString(
            PocketWheelSnapshot.serializer(), PdjJson.lenient.encodeToString(PocketWheelSnapshot.serializer(), a),
        )
        assertEquals(a, back)
    }

    // Hand-built rules. Tuesday 2026-10-27 08:30 PDT.

    private val tue830 = 1_793_115_000_000.0
    private var n = 0

    private fun play(
        song: String = "s1", at: Double, tz: Int? = -420, source: PlaySource = PlaySource.PLAYLIST,
        origin: String? = "pl_a", carPlay: Boolean? = true, skipped: Boolean = false, run: Boolean = false,
    ) = PlayEvent(
        id = "e${n++}", songId = song, playedAt = at, source = source, contextId = "set_now_playing", tzOffsetMin = tz,
        carPlay = carPlay, originCollectionId = origin, wasSkipped = if (skipped) true else null,
        pocketRun = if (run) PocketRunTag("RUN-1", "h08|d2|carPlay", null, 1) else null,
    )

    private fun build(events: List<PlayEvent>, now: Double = tue830) = PocketMomentEngine.build(
        PocketMomentEngine.Input(events, listOf(PocketMomentEngine.CollectionInfo("pl_a", "A", setOf("s1"))), nowMs = now),
    ).index()

    @Test fun kernelWeights() {
        val m = build(listOf(play(at = tue830)))
        assertEquals(1.0, m[k(2, 8, CAR_PLAY)]?.plays ?: 0.0, 1e-6)
        assertEquals(0.5, m[k(2, 9, CAR_PLAY)]?.plays ?: 0.0, 1e-6)
        assertEquals(0.5, m[k(2, 7, CAR_PLAY)]?.plays ?: 0.0, 1e-6)
        assertEquals(0.15, m[k(2, 10, CAR_PLAY)]?.plays ?: 0.0, 1e-6)
        assertEquals(0.25, m[k(3, 8, CAR_PLAY)]?.plays ?: 0.0, 1e-6)
        assertEquals(0.25, m[k(5, 8, CAR_PLAY)]?.plays ?: 0.0, 1e-6)
        assertNull("a weekday play never credits the weekend", m[k(6, 8, CAR_PLAY)])
        assertEquals(0.3, m[k(2, 8, TRIP)]?.plays ?: 0.0, 1e-6)
        assertNull(m[k(2, 8, MIX)])
        assertEquals(1 + 4 + 4 + 1, m.size)
    }

    @Test fun hourWrapsAcrossTheWeek() {
        val mon0030 = tue830 - 32 * 3_600_000.0
        val m = build(listOf(play(at = mon0030)), now = mon0030)
        assertEquals(1, m[k(1, 0, CAR_PLAY)]?.directPlays)
        assertEquals(0.5, m[k(7, 23, CAR_PLAY)]?.plays ?: 0.0, 1e-6)
        assertEquals(0.15, m[k(7, 22, CAR_PLAY)]?.plays ?: 0.0, 1e-6)
    }

    @Test fun decayHalvesAtFortyFiveDays() {
        val m = build(listOf(play(at = tue830 - 45 * 86_400_000.0)), now = tue830)
        val direct = m.values.first { it.directPlays == 1 }
        assertEquals(0.5, direct.plays, 1e-6)
    }

    @Test fun runPlaysHalfWeightRunSkipsFullWeight() {
        val m = build(listOf(play(at = tue830, run = true), play("s2", at = tue830 + 60_000, skipped = true, run = true)))
        val cell = m[k(2, 8, CAR_PLAY)]
        assertEquals(0.5, cell?.plays ?: 0.0, 1e-6)
        assertEquals(1.0, cell?.skips ?: 0.0, 1e-6)
    }

    @Test fun localHourFollowsEachPlaysOwnZone() {
        val m = build(listOf(play("s1", at = tue830, tz = 0), play("s2", at = tue830 + 3_600_000, tz = -420)))
        assertEquals(1, m[k(2, 15, CAR_PLAY)]?.directPlays)
        assertEquals(1, m[k(2, 9, CAR_PLAY)]?.directPlays)
        val m2 = build(listOf(play("s1", at = tue830, tz = -420), play("s2", at = tue830 + 7_200_000, tz = null)))
        assertEquals(1, m2[k(2, 10, CAR_PLAY)]?.directPlays)
    }

    @Test fun mixedCellHasNoDominantCollection() {
        val ids = listOf("pl_1", "pl_2", "pl_3", "pl_4", "pl_5")
        val events = ids.mapIndexed { i, id -> play("s$i", at = tue830 + i * 60_000.0, origin = id) }
        val snap = PocketMomentEngine.build(
            PocketMomentEngine.Input(events, ids.map { PocketMomentEngine.CollectionInfo(it, it, emptySet()) }, nowMs = tue830),
        )
        val cell = snap.index()[k(2, 8, CAR_PLAY)]
        assertEquals(5, cell?.collections?.size)
        assertNull(cell?.dominantCollectionId)
    }

    @Test fun fallbackSpreadsOverHardMembershipsAndSkipsMega() {
        val events = listOf(play("s1", at = tue830, source = PlaySource.BROWSER, origin = null, carPlay = null))
        val colls = listOf(
            PocketMomentEngine.CollectionInfo("pkt_a", "A", setOf("s1")),
            PocketMomentEngine.CollectionInfo("pkt_b", "B", setOf("s1")),
            PocketMomentEngine.CollectionInfo("pl_all", "All", (0 until 4000).map { "x$it" }.toSet() + "s1"),
        )
        val snap = PocketMomentEngine.build(PocketMomentEngine.Input(events, colls, librarySize = 10_000, nowMs = tue830))
        val cell = snap.index()[k(2, 8, BROWSE)]
        assertEquals(0.5, cell?.collections?.get("pkt_a") ?: 0.0, 1e-6)
        assertEquals(0.5, cell?.collections?.get("pkt_b") ?: 0.0, 1e-6)
        assertNull("> 3,000 songs => mega => never the fallback", cell?.collections?.get("pl_all"))
    }

    @Test fun libraryShareAlsoMakesAMegaCollection() {
        // 30 of a 100-song library is 30 % > 25 %.
        val colls = listOf(PocketMomentEngine.CollectionInfo("pl_big", "Big", (0 until 30).map { "x$it" }.toSet() + "s1"))
        val events = listOf(play("s1", at = tue830, source = PlaySource.BROWSER, origin = null, carPlay = null))
        val snap = PocketMomentEngine.build(PocketMomentEngine.Input(events, colls, librarySize = 100, nowMs = tue830))
        assertNull(snap.index()[k(2, 8, BROWSE)]?.collections?.get("pl_big"))
    }

    @Test fun membershipScaleCurve() {
        assertEquals(0.75, PocketMomentEngine.membershipScale(null, tue830), 1e-12)
        assertEquals(1.0, PocketMomentEngine.membershipScale(tue830, tue830), 1e-12)
        assertEquals(0.5 + 0.5 * Math.exp(-1.0), PocketMomentEngine.membershipScale(tue830 - 45 * 86_400_000.0, tue830), 1e-9)
    }

    @Test fun originPrecedence() {
        val input = PocketMomentEngine.Input(
            events = emptyList(),
            collections = listOf(
                PocketMomentEngine.CollectionInfo("pls_x", "X", emptySet()), PocketMomentEngine.CollectionInfo("pkt_y", "Y", emptySet()),
            ),
            setlistToPlaylist = mapOf("set_1" to "pls_x"), nowMs = tue830,
        )
        val idx = PocketMomentEngine.MembershipIndex(input, emptySet())
        var e = play(at = tue830, origin = null).copy(contextId = "set_1")
        assertEquals("pls_x", PocketMomentEngine.origin(e, input, idx))
        e = e.copy(originCollectionId = "pkt_y")
        assertEquals("pkt_y", PocketMomentEngine.origin(e, input, idx))
        e = e.copy(pocketRun = PocketRunTag("R", "", "pls_x", 1))
        assertEquals("pls_x", PocketMomentEngine.origin(e, input, idx))
        val single = play(at = tue830, origin = null).copy(contextId = "set_now_playing")
        assertNull(PocketMomentEngine.origin(single, input, idx))
    }

    @Test fun round6AndPercentile() {
        assertEquals(0.333333, PocketMomentEngine.round6(1.0 / 3), 0.0)
        assertEquals(2.0, PocketMomentEngine.weightedPercentile(listOf(1.0 to 1.0, 2.0 to 1.0, 3.0 to 1.0, 4.0 to 1.0), 0.25) + 1.0, 0.0)
        assertEquals(3.0, PocketMomentEngine.weightedPercentile(listOf(4.0 to 1.0, 1.0 to 1.0, 2.0 to 1.0, 3.0 to 1.0), 0.75), 0.0)
    }
}

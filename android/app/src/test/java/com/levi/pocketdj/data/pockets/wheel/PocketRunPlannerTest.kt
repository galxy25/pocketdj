package com.levi.pocketdj.data.pockets.wheel

import com.levi.pocketdj.data.recs.RecVersionIdentity
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNotNull
import org.junit.Assert.assertNotEquals
import org.junit.Assert.assertTrue
import org.junit.Test

/** iOS PocketRunPlannerTests (planner half): the run planner, the live re-plan (Drake scenario), top-up, tuning maths. */
class PocketRunPlannerTest {

    companion object {
        val rnbArtists = listOf(
            "Drake", "Bryson Tiller", "6LACK", "dvsn", "Majid Jordan", "PARTYNEXTDOOR", "SZA",
            "Frank Ocean", "Jhené Aiko", "Kehlani", "Brent Faiyaz", "Daniel Caesar",
        )
        val otherArtists = (0 until 24).map { "Artist $it" }

        fun candidate(
            id: String, artist: String, genre: String, bpm: Double, year: Int,
            memberships: Map<String, Double>, instant: Boolean = false, camelot: String? = null,
        ) = PocketRunPlanner.Candidate(
            id = id, title = id, artist = artist, lengthMs = 200_000,
            features = PocketTuning.Features(
                artistKeys = RecVersionIdentity.creditArtistKeys(artist), album = "alb_${id.take(5)}",
                genre = genre, year = year, bpm = bpm,
            ),
            camelot = camelot, memberships = memberships, startsInstantly = instant,
        )

        fun universe(): Map<String, PocketRunPlanner.Candidate> {
            val out = LinkedHashMap<String, PocketRunPlanner.Candidate>()
            for (i in 0 until 160) {
                val id = "pot_$i"
                out[id] = candidate(
                    id, rnbArtists[i % rnbArtists.size], if (i % 4 == 0) "hip-hop" else "r&b", 86 + (i % 9) * 3.0,
                    2012 + i % 10, mapOf("pl_pot" to 1.0), instant = i % 7 == 0, camelot = "${i % 12 + 1}A",
                )
            }
            out["feat_1"] = candidate("feat_1", "Rihanna feat. Drake", "r&b", 92.0, 2016, mapOf("pl_pot" to 1.0))
            for (i in 0 until 80) {
                val id = "late_$i"
                out[id] = candidate(id, otherArtists[i % 12], "electronic", 70 + (i % 10) * 2.0, 1994 + i % 8, mapOf("pkt_late" to 1.0))
            }
            for (i in 0 until 120) {
                val id = "misc_$i"
                out[id] = candidate(id, otherArtists[12 + i % 12], if (i % 2 == 0) "r&b" else "rock", 100 + (i % 5).toDouble(), 2014 + i % 6, emptyMap())
            }
            return out
        }

        fun profile() = PocketProfile(
            tier = PocketProfile.Tier.RICH, key = PocketMomentKey(8, 2, PocketMode.CAR_PLAY),
            momentKeys = listOf(PocketMomentKey(8, 2, PocketMode.CAR_PLAY)),
            caption = "Tue 8 AM · CarPlay", detail = "Potential · 23 plays",
            collections = mapOf("pl_pot" to 0.7, "pkt_late" to 0.3),
            artists = rnbArtists.take(6).associate { it.lowercase() to 1.0 / 6 },
            genres = mapOf("r&b" to 0.6, "hip-hop" to 0.3, "electronic" to 0.1),
            bpmLo = 88.0, bpmHi = 100.0, eraLo = 2012.0, eraHi = 2022.0, mode = PocketMode.CAR_PLAY,
        )

        fun plan(seed: ULong = 42u, excluded: Set<String> = emptySet(), tuning: PocketTuning.Multipliers = PocketTuning.Multipliers.NEUTRAL) =
            PocketRunPlanner.plan(PocketRunPlanner.Input(profile(), universe(), excluded, tuning = tuning, seed = seed))
    }

    @Test fun everyPrefixStaysAtLeastSixtyPercentFreshOnAHeavilyRecentPocket() {
        val u = universe()
        // 70% of the pocket's own crate was played recently; the rest of the library is fresh.
        val recency = u.keys.filter { it.startsWith("pot_") && it.removePrefix("pot_").toInt() % 10 < 7 }.associateWith { 1.0 }
        for (seed in listOf(1uL, 42uL, 99uL)) {
            val rows = PocketRunPlanner.plan(PocketRunPlanner.Input(profile(), u, emptySet(), recency = recency, seed = seed)).rows
            assertEquals(100, rows.size)
            var fresh = 0
            rows.forEachIndexed { i, r ->
                if ((recency[r.songId] ?: 0.0) <= 0) fresh++
                val k = i + 1
                assertTrue("seed $seed prefix $k has $fresh fresh", fresh >= Math.floor(PocketRunPlanner.FRESH_FLOOR * k).toInt())
            }
        }
    }

    @Test fun constantsMatchIos() {
        with(PocketRunPlanner) {
            assertEquals(100, SLOTS); assertEquals(6, ARTIST_CAP); assertEquals(4, ARTIST_SPACING)
            assertEquals(0.2, NEWCOMER_FLOOR, 0.0); assertEquals(0.4, DOMINANT_MIN_SLOT_SHARE, 0.0)
            assertEquals(0.25, SOFT_CAP, 0.0); assertEquals(0.6, SOFT_MIN_FIT, 0.0)
            assertEquals(400, BENCH_CAP); assertEquals(600, POOL_CAP); assertEquals(8, FIRST_DRAW_FROM); assertEquals(6, NEXT_DRAW_FROM)
            assertEquals(3, INSTANT_LEAD_SLOTS); assertEquals(0.6, REPLAN_FLOOR_SHARE_OF_MEDIAN, 0.0); assertEquals(0.3, MIN_POCKET_FIT, 0.0)
            assertEquals(0.3, SEED_WEIGHT, 0.0); assertEquals(0.25, SEED_SLOT_SHARE, 0.0); assertEquals(3, NEIGHBOUR_MAX_COUNT)
            assertEquals(0.3, NEIGHBOUR_SHARE, 0.0); assertEquals(0.55, NEIGHBOUR_MIN_SIM, 0.0)
            assertEquals(5, NEIGHBOUR_MIN_MEMBERS); assertEquals(1500, NEIGHBOUR_MAX_MEMBERS)
            assertEquals(30.0, FRESH_DAYS, 0.0); assertEquals(0.6, FRESH_FLOOR, 0.0); assertEquals(0.6, FRESH_WEIGHT, 0.0)
        }
    }

    @Test fun hundredSlotsUniqueSongs() {
        val p = plan()
        assertEquals(100, p.rows.size)
        assertEquals(100, p.rows.map { it.songId }.toSet().size)
        assertEquals((1..100).toList(), p.rows.map { it.slot })
        assertTrue("the bench holds what wasn't placed", p.bench.map { it.songId }.toSet().intersect(p.rows.map { it.songId }.toSet()).isEmpty())
        assertTrue(p.bench.isNotEmpty())
    }

    @Test fun collectionQuotaKeepsTheRunAboutItsColour() {
        val p = plan()
        val pot = p.rows.count { it.collectionId == "pl_pot" }
        val late = p.rows.count { it.collectionId == "pkt_late" }
        assertTrue("dominant collection >= 40 %", pot >= 40)
        assertTrue(pot > late)
        assertTrue("the second collection gets its share", late > 0)
        assertEquals(mapOf("pl_pot" to 70, "pkt_late" to 30), PocketRunPlanner.quotas(profile(), 100))
        val thin = profile().copy(collections = mapOf("a" to 0.3, "b" to 0.35, "c" to 0.35))
        assertTrue((PocketRunPlanner.quotas(thin, 100)["b"] ?: 0) >= 35)
    }

    @Test fun dominantCollectionIsLiftedToFortyPercent() {
        // 0.3 dominant share is >= 0.25 but < 0.4: raised to 40, others scaled into the remaining 60.
        val p = profile().copy(collections = mapOf("a" to 0.3, "b" to 0.3, "c" to 0.2, "d" to 0.2))
        val q = PocketRunPlanner.quotas(p, 100)
        assertEquals(40, q["a"])
        assertEquals(60, q.values.sum() - q.getValue("a"))
    }

    @Test fun artistCapSpacingAndNewcomerFloor() {
        val p = plan()
        val u = universe()
        val keys = p.rows.map { u.getValue(it.songId).features.artistKeys }
        val counts = HashMap<String, Int>()
        for (k in keys.flatten()) counts[k] = (counts[k] ?: 0) + 1
        assertTrue("<= 6 per artist", (counts.values.maxOrNull() ?: 0) <= PocketRunPlanner.ARTIST_CAP)
        for (i in 1 until keys.size) {
            for (j in maxOf(0, i - 3) until i) {
                assertTrue("no artist twice within 4 slots (${j + 1}->${i + 1})", keys[i].toSet().intersect(keys[j].toSet()).isEmpty())
            }
        }
        val top = profile().artists.keys
        assertTrue(">= 20 % newcomers", keys.count { ks -> ks.none { it in top } } >= 20)
    }

    @Test fun deterministicBySeedAndInstantFirstRows() {
        assertEquals(plan(7u), plan(7u))
        assertNotEquals(plan(7u).rows.map { it.songId }, plan(8u).rows.map { it.songId })
        val u = universe()
        for (r in plan().rows.take(3)) assertTrue("first audio is instant (${r.songId})", u.getValue(r.songId).startsInstantly)
    }

    @Test fun exclusionsAndBans() {
        val excluded = setOf("pot_0", "pot_1", "pot_2")
        val p = plan(excluded = excluded, tuning = PocketTuning.Multipliers(bannedArtists = setOf("drake")))
        val u = universe()
        assertTrue(p.rows.map { it.songId }.toSet().intersect(excluded).isEmpty())
        assertFalse("banned incl. features", p.rows.any { "drake" in u.getValue(it.songId).features.artistKeys })
    }

    @Test fun scoresAreRoundedToSixPlaces() {
        for (r in plan().rows) assertEquals(r.score, Math.round(r.score * 1e6) / 1e6, 0.0)
        assertEquals(0.123457, PocketRunPlanner.round6(0.1234565), 0.0)
        assertEquals(-0.123457, PocketRunPlanner.round6(-0.1234565), 0.0)
    }

    // The Drake scenario

    @Test fun drakeFastSkipBansAndReplacesUpcomingDrakeWithSimilarOtherArtists() {
        val u = universe()
        val p = plan()
        val drakeRows = p.rows.filter { "drake" in u.getValue(it.songId).features.artistKeys }
        assertTrue("precondition: Drake is in the run", drakeRows.size >= 2)
        val first = drakeRows[0]
        val v = PocketTuning.Verdict(first.songId, skipped = true, fraction = 0.08, atMs = 0.0, momentKey = "h08|d2|carPlay", rowCollectionId = first.collectionId)
        assertEquals(-1.0, v.strength!!, 0.0)
        val ev = PocketTuning.runEvidence(listOf(v)) { u[it]?.features }
        val m = PocketTuning.multipliers(ev, allowBans = true)
        assertEquals(0.333, m.byKey["artist:drake"] ?: 1.0, 0.001)
        assertTrue("drake" in m.bannedArtists)
        assertEquals("the genre drops one notch", 0.667, m.byKey["genre:" + (u.getValue(first.songId).features.genre ?: "")] ?: 1.0, 0.001)
        assertEquals("the colour barely moves", 0.8, m.byKey["collection:pl_pot"] ?: 1.0, 0.001)

        val upcoming = p.rows.filter { it.slot > first.slot }
        val live = upcoming.mapIndexed { i, r -> PocketRunPlanner.LiveRow("uid$i", r.songId, r.slot, r.collectionId) }
        val neighbours = live.mapIndexed { i, r ->
            r.uid to PocketRunPlanner.Neighbours(live.getOrNull(i - 1)?.songId, live.getOrNull(i + 1)?.songId)
        }.toMap()
        val result = PocketRunPlanner.replan(
            profile = profile(), candidates = u, tuning = m, familiarity = emptyMap(), live = live,
            inRun = p.rows.map { it.songId }.toSet(), neighbours = neighbours,
        )
        assertEquals(listOf("drake"), result.banned)
        val byUid = result.replacements.associateBy { it.uid }
        for (r in live.filter { "drake" in u.getValue(it.songId).features.artistKeys }) {
            val rep = byUid[r.uid]
            if (rep == null) { assertTrue(r.uid in result.removals); continue }
            val x = u.getValue(rep.songId)
            assertFalse("no Drake, no Drake features", "drake" in x.features.artistKeys)
            assertEquals("slot-wise substitution keeps the arc", r.slot, rep.slot)
            assertTrue("musically similar (${rep.songId})", x.features.genre in listOf("r&b", "hip-hop"))
            assertFalse("never a song already in the run", rep.songId in p.rows.map { it.songId }.toSet())
        }
        assertFalse("Rihanna feat. Drake is banned too", result.replacements.any { it.songId == "feat_1" })
        assertEquals("no duplicate replacements", result.replacements.size, result.replacements.map { it.songId }.toSet().size)
    }

    @Test fun rowsAreRemovedWhenNothingClearsTheFitFloor() {
        val u = mapOf(
            "d1" to candidate("d1", "Drake", "r&b", 90.0, 2016, mapOf("pl_pot" to 1.0)),
            "d2" to candidate("d2", "Drake", "r&b", 92.0, 2017, mapOf("pl_pot" to 1.0)),
        )
        val t = PocketTuning.Multipliers(bannedArtists = setOf("drake"))
        val row = PocketRunPlanner.LiveRow("u1", "d2", 5, "pl_pot")
        val r = PocketRunPlanner.replan(profile(), u, t, emptyMap(), live = listOf(row), inRun = setOf("d1", "d2"), neighbours = emptyMap())
        assertEquals(listOf("u1"), r.removals)
        assertTrue(r.replacements.isEmpty())
    }

    /** Levi's 2026-11-10 drive: a replacement keeps the spacing rule against the live rows around it. */
    @Test fun replacementsKeepArtistSpacingWithNeighbours() {
        val u = mapOf(
            "d1" to candidate("d1", "Drake", "r&b", 90.0, 2016, mapOf("pl_pot" to 1.0)),
            "g1" to candidate("g1", "GoldLink", "r&b", 90.0, 2016, mapOf("pl_pot" to 1.0)),
            "g2" to candidate("g2", "GoldLink", "r&b", 90.0, 2016, mapOf("pl_pot" to 1.0)),
            "c1" to candidate("c1", "Cousin Stizz", "r&b", 90.0, 2016, mapOf("pl_pot" to 1.0)),
            "c2" to candidate("c2", "Cousin Stizz", "r&b", 90.0, 2016, mapOf("pl_pot" to 1.0)),
            "x1" to candidate("x1", "Phonte", "r&b", 94.0, 2014, mapOf("pl_pot" to 1.0)),
        )
        val t = PocketTuning.Multipliers(bannedArtists = setOf("drake"))
        val drake = PocketRunPlanner.LiveRow("ud", "d1", 5, "pl_pot")
        val after = PocketRunPlanner.LiveRow("ua", "c1", 7, "pl_pot")
        val r = PocketRunPlanner.replan(
            profile(), u, t, emptyMap(), live = listOf(drake, after), inRun = setOf("d1", "c1", "g1"),
            neighbours = mapOf("ud" to PocketRunPlanner.Neighbours(prev = "g1", next = null)),
        )
        val rep = r.replacements.first { it.uid == "ud" }
        assertEquals("GoldLink is next door and Cousin Stizz two slots on", "x1", rep.songId)
    }

    @Test fun inFlightRipRowsTakeOnlyInstantReplacements() {
        val u = universe()
        val t = PocketTuning.Multipliers(bannedArtists = setOf("drake"))
        val row = PocketRunPlanner.LiveRow("u", "pot_0", 9, "pl_pot", requiresInstant = true)
        val r = PocketRunPlanner.replan(profile(), u, t, emptyMap(), live = listOf(row), inRun = setOf("pot_0"), neighbours = emptyMap())
        val rep = r.replacements.first()
        assertTrue(u.getValue(rep.songId).startsInstantly)
    }

    @Test fun topUpRespectsBansCapAndRun() {
        val u = universe()
        val t = PocketTuning.Multipliers(bannedArtists = setOf("drake"))
        val picks = PocketRunPlanner.topUp(5, profile(), u, t, emptyMap(), inRun = setOf("pot_1", "pot_13"), tail = listOf("pot_13"))
        assertEquals(5, picks.size)
        assertFalse(picks.any { "drake" in u.getValue(it.songId).features.artistKeys })
        assertFalse(picks.any { it.songId in setOf("pot_1", "pot_13") })
        assertEquals(0, PocketRunPlanner.topUp(0, profile(), u, t, emptyMap(), inRun = emptySet(), tail = emptyList()).size)
        // spacing after the tail: nobody from the tail's artist first
        val tailArtist = u.getValue("pot_13").features.artistKeys.toSet()
        assertTrue(u.getValue(picks[0].songId).features.artistKeys.none { it in tailArtist })
    }

    @Test fun musicalSimPrefersSameGenreEraTempo() {
        val a = candidate("a", "A", "r&b", 90.0, 2015, emptyMap(), camelot = "8A")
        val near = candidate("n", "B", "r&b", 91.0, 2016, emptyMap(), camelot = "8A")
        val far = candidate("f", "C", "rock", 150.0, 1980, emptyMap(), camelot = "3B")
        assertTrue(PocketRunPlanner.musicalSim(near, a) > PocketRunPlanner.musicalSim(far, a))
        assertEquals(0.0, PocketRunPlanner.musicalSim(
            PocketRunPlanner.Candidate("x", "x", "x", features = PocketTuning.Features(listOf("x"))),
            PocketRunPlanner.Candidate("y", "y", "y", features = PocketTuning.Features(listOf("y"))),
        ), 0.0)
    }

    // Tuning maths the planner depends on

    @Test fun tuningStrengthsAndMultipliers() {
        fun v(skipped: Boolean, f: Double?) = PocketTuning.Verdict("s", skipped, f, 0.0, "")
        assertEquals(-1.0, v(true, 0.1).strength!!, 0.0)
        assertEquals(-0.6, v(true, 0.3).strength!!, 0.0)
        assertEquals(0.5, v(false, 0.95).strength!!, 0.0)
        assertEquals(0.2, v(false, 0.7).strength!!, 0.0)
        assertEquals(null, v(false, null).strength)
        assertEquals(0.333, PocketTuning.artistMultiplier(0.0, 1.0), 0.001)
        assertEquals(0.294, PocketTuning.artistMultiplier(0.0, 2 * 0.6), 0.001)
        assertTrue(PocketTuning.artistMultiplier(0.0, 1.2) <= PocketTuning.BAN_AT_OR_BELOW)
        assertTrue(PocketTuning.artistMultiplier(0.0, 0.6) > PocketTuning.BAN_AT_OR_BELOW)
        val keys = PocketTuning.Features(listOf("a", "b"), album = "x", genre = "r&b", year = 2013, bpm = 100.0, collectionId = "c").keys
        assertEquals(listOf("artist:a", "artist:b", "album:x", "genre:r&b", "era:2010", "bpm:96", "collection:c"), keys)
        assertNotNull(PocketTuning.Multipliers.NEUTRAL)
    }
}

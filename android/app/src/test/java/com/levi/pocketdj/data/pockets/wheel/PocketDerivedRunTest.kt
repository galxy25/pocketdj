package com.levi.pocketdj.data.pockets.wheel

import com.levi.pocketdj.data.recs.RecVersionIdentity
import org.junit.Assert.assertEquals
import org.junit.Assert.assertNotNull
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test

/** iOS PocketDerivedRunTests: a run is DERIVED from its pocket, not a replay. */
class PocketDerivedRunTest {

    private fun song(id: String, artist: String, genre: String, bpm: Double, year: Int, vararg cols: String) =
        PocketRunPlanner.Candidate(
            id = id, title = id, artist = artist, lengthMs = 200_000,
            features = PocketTuning.Features(RecVersionIdentity.creditArtistKeys(artist), "alb_$id", genre, year, bpm),
            memberships = cols.associateWith { 1.0 },
        )

    private fun universe(): Map<String, PocketRunPlanner.Candidate> {
        val out = LinkedHashMap<String, PocketRunPlanner.Candidate>()
        for (i in 0 until 150) out["hh90_$i"] = song("hh90_$i", "HH Artist ${i % 30}", "hip-hop", 88.0 + i % 8, 1990 + i % 11, "pl_hh90")
        for (i in 0 until 80) out["boom_$i"] = song("boom_$i", "Boom Artist ${i % 20}", "hip-hop", 89.0 + i % 6, 1992 + i % 8, "pl_boom")
        for (i in 0 until 80) out["trap_$i"] = song("trap_$i", "Trap Artist ${i % 20}", "hip-hop", 140.0 + i % 6, 2018 + i % 6, "pl_trap")
        for (i in 0 until 80) out["rock_$i"] = song("rock_$i", "Rock Artist ${i % 20}", "rock", 92.0, 1995, "pl_rock")
        return out
    }

    private fun profile(seeds: Map<String, Double> = emptyMap()) = PocketProfile(
        tier = PocketProfile.Tier.RICH, caption = "Fri 9 PM", detail = "Hip-hop 90s",
        collections = mapOf("pl_hh90" to 1.0), genres = mapOf("hip-hop" to 1.0),
        bpmLo = 88.0, bpmHi = 96.0, eraLo = 1990.0, eraHi = 2000.0, seeds = seeds,
    )

    @Test fun similarCollectionsJoinTheRunAndUnlikeOnesDoNot() {
        val u = universe()
        val d = PocketRunPlanner.derived(profile(), u)
        assertNotNull("90s boom-bap crate is a neighbour", d.collections["pl_boom"])
        assertNull("a different genre is never a neighbour", d.collections["pl_rock"])
        assertNull("same genre, wrong era + tempo", d.collections["pl_trap"])
        val neighbourMass = d.collections.filter { it.key != "pl_hh90" }.values.sum()
        assertTrue(neighbourMass > 0)
        assertTrue(neighbourMass <= PocketRunPlanner.NEIGHBOUR_SHARE + 1e-9)
        assertEquals("pl_hh90", d.dominantCollectionId)

        val plan = PocketRunPlanner.plan(PocketRunPlanner.Input(d, u, seed = 3u))
        val ids = plan.rows.map { it.songId }
        assertTrue("the neighbour crate gets slots", ids.count { it.startsWith("boom_") } > 5)
        assertTrue("the pocket's own crate leads", ids.count { it.startsWith("hh90_") } > ids.size / 2)
        assertTrue(ids.none { it.startsWith("rock_") })
    }

    @Test fun noCollectionsMeansNoExpansion() {
        val p = profile().copy(collections = emptyMap())
        assertEquals(p, PocketRunPlanner.withNeighbourCollections(p, universe()))
    }

    @Test fun seedsAreCappedSoTheRunIsNotAReplay() {
        val u = universe()
        val seeds = (0 until 60).associate { "hh90_$it" to 5.0 }
        val plan = PocketRunPlanner.plan(PocketRunPlanner.Input(PocketRunPlanner.derived(profile(seeds), u), u, seed = 11u))
        assertEquals(PocketRunPlanner.SLOTS, plan.rows.size)
        val seeded = plan.rows.count { it.songId in seeds }
        assertTrue(seeded <= Math.round(PocketRunPlanner.SLOTS * PocketRunPlanner.SEED_SLOT_SHARE).toInt())
        assertTrue("the captured songs still appear, lightly", seeded > 0)
    }

    @Test fun seedGapsFillAndNeverOverwriteKnownDimensions() {
        val u = universe()
        val p = profile(mapOf("rock_1" to 1.0, "rock_2" to 1.0, "rock_3" to 1.0))
        val f = PocketRunPlanner.fillingGapsFromSeeds(p, u)
        assertEquals(p.genres, f.genres)
        assertEquals(p.bpmBand, f.bpmBand)
        assertEquals(p.era, f.era)

        // A thin profile: genre, era and a >= 3-BPM band come from the seeds themselves.
        val thin = PocketProfile(PocketProfile.Tier.CLOUD, caption = "x", detail = "y", seeds = mapOf("hh90_1" to 1.0, "hh90_2" to 1.0, "hh90_3" to 1.0, "hh90_4" to 1.0))
        val g = PocketRunPlanner.fillingGapsFromSeeds(thin, u)
        assertEquals(mapOf("hip-hop" to 1.0), g.genres)
        assertNotNull(g.era)
        assertNotNull(g.bpmBand)
        assertTrue(g.bpmBand!!.endInclusive - g.bpmBand!!.start >= 6.0)
        // No seeds known to the catalog: unchanged.
        val none = thin.copy(seeds = mapOf("ghost" to 1.0))
        assertEquals(none, PocketRunPlanner.fillingGapsFromSeeds(none, u))
    }

    @Test fun threeSongPocketStillYieldsAFullDerivedRun() {
        val u = universe()
        val thin = PocketProfile(PocketProfile.Tier.CLOUD, caption = "x", detail = "y", collections = mapOf("pl_hh90" to 1.0),
            seeds = mapOf("hh90_1" to 1.0, "hh90_2" to 1.0, "hh90_3" to 1.0))
        val d = PocketRunPlanner.derived(thin, u)
        assertNotNull("era filled from the seeds' years", d.era)
        assertNotNull(d.collections["pl_boom"])
        assertEquals(PocketRunPlanner.SLOTS, PocketRunPlanner.plan(PocketRunPlanner.Input(d, u, seed = 5u)).rows.size)
    }

    // Freshness

    @Test fun recencyIsLinearOverFreshDays() {
        val day = 86_400_000.0
        val now = 100 * day
        val r = PocketRunPlanner.recency(mapOf("a" to now, "b" to now - 15 * day, "c" to now - 31 * day), now)
        assertEquals(1.0, r.getValue("a"), 1e-9)
        assertEquals(0.5, r.getValue("b"), 1e-9)
        assertNull("older than freshDays = fresh", r["c"])
    }

    @Test fun runsStayFreshEvenWhenThePocketWasHeardRecently() {
        val u = universe()
        val recency = HashMap<String, Double>()
        for (i in 0 until 120) recency["hh90_$i"] = 0.9
        for (i in 0 until 40) recency["boom_$i"] = 0.5
        val d = PocketRunPlanner.derived(profile(), u)
        val plan = PocketRunPlanner.plan(PocketRunPlanner.Input(d, u, recency = recency, seed = 9u))
        assertEquals(PocketRunPlanner.SLOTS, plan.rows.size)
        var fresh = 0
        for ((n, row) in plan.rows.withIndex()) {
            if (row.songId !in recency) fresh++
            if (n >= 4) assertTrue("prefix ${n + 1} is too stale", fresh.toDouble() / (n + 1) >= PocketRunPlanner.FRESH_FLOOR - 0.2)
        }
        assertTrue(fresh.toDouble() / plan.rows.size >= PocketRunPlanner.FRESH_FLOOR)
    }

    @Test fun playingASongALotNeverLiftsItButSkippingStillSinksIt() {
        val u = universe()
        val scorer = PocketRunPlanner.Scorer(profile(), PocketTuning.Multipliers.NEUTRAL, mapOf("hh90_1" to 0.45, "hh90_2" to -0.3), pool = u.values.toList())
        val base = scorer.score(u.getValue("hh90_3"))
        assertEquals("familiar ~ unfamiliar peer", base, scorer.score(u.getValue("hh90_1")), 0.2)
        assertTrue(scorer.score(u.getValue("hh90_1")) - base <= 0.2)
        assertTrue("skipped sinks", scorer.score(u.getValue("hh90_2")) < scorer.score(u.getValue("hh90_1")))
        val fresh = PocketRunPlanner.Scorer(profile(), PocketTuning.Multipliers.NEUTRAL, emptyMap(), mapOf("hh90_1" to 1.0), u.values.toList())
        assertTrue("just heard < fresh peer", fresh.score(u.getValue("hh90_1")) < fresh.score(u.getValue("hh90_9")))
    }
}

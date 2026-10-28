package com.levi.pocketdj.data.games.puzzle

import com.levi.pocketdj.data.collections.Prng
import com.levi.pocketdj.data.history.PlayEvent
import com.levi.pocketdj.data.rips.RipManifestEntry
import com.levi.pocketdj.screens.browse.Genre
import kotlin.math.ln
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNotEquals
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test

/** Port of PuzzleSamplerTests + PuzzlePlayabilityTests (sampler half). */
class PuzzleSamplerTest {
    private val now = 1_700_000_000_000.0
    private val day = 86_400_000.0
    private fun ids(p: List<PuzzleCandidate>) = p.map { it.song.id }
    private fun log2(x: Double) = ln(x) / ln(2.0)

    private fun recencies(lastPlayed: Map<String, Double>): Map<String, Double> =
        lastPlayed.mapNotNull { (k, ms) -> PlayRecency.score(ms, now).takeIf { it > 0 }?.let { k to it } }.toMap()

    // MARK: hard filters

    @Test fun yearRangeHardFilter() {
        val s = PuzzleSettings(yearMin = 1990, yearMax = 1999)
        val pool = PuzzleSampler.pool(s, inputs(listOf(song("a", year = 1980), song("b", year = 1995), song("c", year = 2005))))
        assertEquals(listOf("b"), ids(pool))
    }

    @Test fun nilYearDropsOnlyWhenABoundIsSet() {
        val songs = listOf(song("dated", year = 1995), song("undated"))
        assertEquals(2, PuzzleSampler.poolCount(PuzzleSettings(), inputs(songs)))
        assertEquals(listOf("dated"), ids(PuzzleSampler.pool(PuzzleSettings(yearMin = 1990), inputs(songs))))
        assertEquals(listOf("dated"), ids(PuzzleSampler.pool(PuzzleSettings(yearMax = 2000), inputs(songs))))
    }

    @Test fun genreCategoryFilterWithOtherFallback() {
        val songs = listOf(song("h"), song("j"), song("x"))
        val genres = mapOf("h" to "hip-hop", "j" to "jazz") // x unmapped -> Other
        val s = PuzzleSettings(genreCategories = setOf("hip-hop"))
        assertEquals(listOf("h"), ids(PuzzleSampler.pool(s, inputs(songs, genres = genres))))
        val other = PuzzleSettings(genreCategories = setOf(Genre.OTHER))
        assertEquals(listOf("x"), ids(PuzzleSampler.pool(other, inputs(songs, genres = genres))))
    }

    @Test fun membershipInAny() {
        val s = PuzzleSettings(membershipMode = PuzzleSettings.MembershipMode.IN_ANY, membershipCollectionIds = setOf("pkt_x"))
        assertEquals(listOf("in"), ids(PuzzleSampler.pool(s, inputs(listOf(song("in"), song("out")), membershipUnion = setOf("in")))))
    }

    @Test fun membershipNotInAnyIsNoneOf() {
        val s = PuzzleSettings(membershipMode = PuzzleSettings.MembershipMode.NOT_IN_ANY, membershipCollectionIds = setOf("pkt_x"))
        assertEquals(listOf("out"), ids(PuzzleSampler.pool(s, inputs(listOf(song("in"), song("out")), membershipUnion = setOf("in")))))
    }

    @Test fun excludesSongsInAllTargets() {
        val pool = PuzzleSampler.pool(
            PuzzleSettings(),
            inputs(listOf(song("both"), song("one"), song("none")), perTarget = listOf(setOf("both", "one"), setOf("both"))),
        )
        assertEquals(setOf("one", "none"), ids(pool).toSet())
    }

    @Test fun suppressedForTargetsIsExcluded() {
        val base = inputs(listOf(song("a"), song("b")))
        val pool = PuzzleSampler.pool(PuzzleSettings(), base.copy(suppressedForTargets = setOf("a")))
        assertEquals(listOf("b"), ids(pool))
    }

    @Test fun excludingParamDropsIds() {
        val pool = PuzzleSampler.pool(PuzzleSettings(), inputs(listOf(song("a"), song("b"))), excluding = setOf("a"))
        assertEquals(listOf("b"), ids(pool))
    }

    // MARK: soft weights

    @Test fun favoriteWeightsAreFourAndQuarter() {
        val songs = listOf(song("fav"), song("plain"))
        val favor = PuzzleSampler.pool(PuzzleSettings(favoriteBias = PuzzleSettings.Bias.FAVOR), inputs(songs, favorites = setOf("fav")))
        assertEquals(4.0, favor.first { it.song.id == "fav" }.weight, 1e-12)
        assertEquals(1.0, favor.first { it.song.id == "plain" }.weight, 1e-12)
        val avoid = PuzzleSampler.pool(PuzzleSettings(favoriteBias = PuzzleSettings.Bias.AVOID), inputs(songs, favorites = setOf("fav")))
        assertEquals(0.25, avoid.first { it.song.id == "fav" }.weight, 1e-12)
        assertEquals(1.0, avoid.first { it.song.id == "plain" }.weight, 1e-12)
    }

    @Test fun playCountWeightFormulas() {
        val songs = listOf(song("zero"), song("seven"))
        val counts = mapOf("seven" to 7)
        val favor = PuzzleSampler.pool(PuzzleSettings(playCountBias = PuzzleSettings.Bias.FAVOR), inputs(songs, playCounts = counts))
        assertEquals(1.0, favor.first { it.song.id == "zero" }.weight, 1e-12)
        assertEquals(1 + log2(8.0), favor.first { it.song.id == "seven" }.weight, 1e-12) // = 4
        val avoid = PuzzleSampler.pool(PuzzleSettings(playCountBias = PuzzleSettings.Bias.AVOID), inputs(songs, playCounts = counts))
        assertEquals(4.0, avoid.first { it.song.id == "zero" }.weight, 1e-12)
        assertEquals(1 / (1 + log2(8.0)), avoid.first { it.song.id == "seven" }.weight, 1e-12)
    }

    @Test fun recencyWeightFormulas() {
        val songs = listOf(song("fresh"), song("never"))
        val rec = recencies(mapOf("fresh" to now))
        val favor = PuzzleSampler.pool(PuzzleSettings(recencyBias = PuzzleSettings.Bias.FAVOR), inputs(songs, recencies = rec))
        assertEquals(9.0, favor.first { it.song.id == "fresh" }.weight, 1e-9)
        assertEquals(1.0, favor.first { it.song.id == "never" }.weight, 1e-12)
        val avoid = PuzzleSampler.pool(PuzzleSettings(recencyBias = PuzzleSettings.Bias.AVOID), inputs(songs, recencies = rec))
        assertEquals(1 / 9.0, avoid.first { it.song.id == "fresh" }.weight, 1e-9)
        assertEquals(4.0, avoid.first { it.song.id == "never" }.weight, 1e-12)
    }

    @Test fun biasesComposeMultiplicatively() {
        val songs = listOf(song("s"))
        val s = PuzzleSettings(
            favoriteBias = PuzzleSettings.Bias.FAVOR, playCountBias = PuzzleSettings.Bias.FAVOR,
            recencyBias = PuzzleSettings.Bias.FAVOR,
        )
        val rec = recencies(mapOf("s" to now - 730 * day)) // 0.5
        val w = PuzzleSampler.pool(s, inputs(songs, favorites = setOf("s"), playCounts = mapOf("s" to 3), recencies = rec)).single().weight
        assertEquals(4.0 * (1 + log2(4.0)) * (1 + 8 * 0.5), w, 1e-9)
    }

    @Test fun favoriteFavorRaisesSelectionShare() {
        val songs = (0 until 1000).map { song("s$it") }
        val favorites = (0 until 500).map { "s$it" }.toSet()
        val picked = PuzzleSampler.sample(500, PuzzleSettings(favoriteBias = PuzzleSettings.Bias.FAVOR), inputs(songs, favorites = favorites), Prng.seededRng("test"))
        assertEquals(500, picked.size)
        val share = picked.count { it.id in favorites } / 500.0
        assertTrue("♥ x4 dominates (got $share)", share > 0.65)
    }

    @Test fun playCountAvoidPrefersUnplayed() {
        val songs = (0 until 200).map { song("s$it") }
        val counts = (0 until 100).associate { "s$it" to 50 }
        val picked = PuzzleSampler.sample(60, PuzzleSettings(playCountBias = PuzzleSettings.Bias.AVOID), inputs(songs, playCounts = counts), Prng.seededRng("avoid"))
        val share = picked.count { counts[it.id] == null } / 60.0
        assertTrue("got $share", share > 0.8)
    }

    @Test fun recencyFavorRaisesRecentShare() {
        val songs = (0 until 200).map { song("s$it") }
        val dates = HashMap<String, Double>()
        for (i in 0 until 100) dates["s$i"] = now - 10 * day
        for (i in 100 until 200) dates["s$i"] = now - 2190 * day
        val picked = PuzzleSampler.sample(60, PuzzleSettings(recencyBias = PuzzleSettings.Bias.FAVOR), inputs(songs, recencies = recencies(dates)), Prng.seededRng("recent"))
        val share = picked.count { it.id.drop(1).toInt() < 100 } / 60.0
        assertTrue("got $share", share > 0.7)
    }

    @Test fun recencyAvoidPrefersLongUnplayedAndNeverPlayed() {
        val songs = (0 until 200).map { song("s$it") }
        val dates = (0 until 100).associate { "s$it" to now - 5 * day }
        val picked = PuzzleSampler.sample(60, PuzzleSettings(recencyBias = PuzzleSettings.Bias.AVOID), inputs(songs, recencies = recencies(dates)), Prng.seededRng("avoid-recent"))
        val share = picked.count { it.id.drop(1).toInt() >= 100 } / 60.0
        assertTrue("got $share", share > 0.8)
    }

    @Test fun playsAndRecencyAreSeparableAxes() {
        val heavyOld = song("heavy-old")
        val lightNew = song("light-new")
        val counts = mapOf("heavy-old" to 200, "light-new" to 1)
        val recs = recencies(mapOf("heavy-old" to now - 1825 * day, "light-new" to now - day))
        fun weightOf(s: PuzzleSettings, id: String) =
            PuzzleSampler.pool(s, inputs(listOf(heavyOld, lightNew), playCounts = counts, recencies = recs)).first { it.song.id == id }.weight
        val byPlays = PuzzleSettings(playCountBias = PuzzleSettings.Bias.FAVOR)
        assertTrue(weightOf(byPlays, "heavy-old") > weightOf(byPlays, "light-new"))
        val byRecency = PuzzleSettings(recencyBias = PuzzleSettings.Bias.FAVOR)
        assertTrue(weightOf(byRecency, "light-new") > weightOf(byRecency, "heavy-old"))
        val both = byPlays.copy(recencyBias = PuzzleSettings.Bias.FAVOR)
        assertNotEquals(weightOf(both, "heavy-old"), weightOf(byPlays, "heavy-old"), 1e-4)
    }

    @Test fun emptyRecencyMapLeavesTheSampleUnchanged() {
        val songs = (0 until 200).map { song("s$it") }
        val counts = (0 until 100).associate { "s$it" to 20 }
        val base = PuzzleSettings(playCountBias = PuzzleSettings.Bias.FAVOR)
        val shipped = PuzzleSampler.sample(60, base, inputs(songs, playCounts = counts), Prng.seededRng("compat")).map { it.id }
        for (bias in listOf(PuzzleSettings.Bias.FAVOR, PuzzleSettings.Bias.AVOID)) {
            val out = PuzzleSampler.sample(60, base.copy(recencyBias = bias), inputs(songs, playCounts = counts), Prng.seededRng("compat")).map { it.id }
            // FAVOR with no dates is a x1 no-op; AVOID with no dates is a flat x4 uniform scale.
            assertEquals("recencyBias $bias with no dates must not reorder", shipped, out)
        }
    }

    @Test fun suppliedDatesChangeNothingWhileRecencyBiasIsOff() {
        val s = PuzzleSettings(playCountBias = PuzzleSettings.Bias.FAVOR)
        assertEquals(PuzzleSettings.Bias.OFF, s.recencyBias)
        val songs = (0 until 50).map { song("s$it") }
        val counts = (0 until 25).associate { "s$it" to 30 }
        val dates = songs.associate { it.id to now - 400 * day }
        val without = PuzzleSampler.pool(s, inputs(songs, playCounts = counts))
        val with = PuzzleSampler.pool(s, inputs(songs, playCounts = counts, recencies = recencies(dates)))
        assertEquals(ids(without), ids(with))
        for ((a, b) in without.zip(with)) assertEquals(a.weight, b.weight, 1e-12)
    }

    // MARK: sample()

    @Test fun sampleWithoutReplacementNoDuplicates() {
        val songs = (0 until 60).map { song("s$it") }
        val picked = PuzzleSampler.sample(50, PuzzleSettings(), inputs(songs), Prng.seededRng("dupes"))
        assertEquals(50, picked.size)
        assertEquals(50, picked.map { it.id }.toSet().size)
        val all = PuzzleSampler.sample(100, PuzzleSettings(), inputs(songs), Prng.seededRng("dupes"))
        assertEquals(60, all.map { it.id }.toSet().size)
        val topped = PuzzleSampler.sample(100, PuzzleSettings(), inputs(songs), Prng.seededRng("dupes"), excluding = (0 until 50).map { "s$it" }.toSet())
        assertEquals((50 until 60).map { "s$it" }.toSet(), topped.map { it.id }.toSet())
    }

    @Test fun deterministicWithSeed() {
        val songs = (0 until 100).map { song("s$it") }
        val s = PuzzleSettings(favoriteBias = PuzzleSettings.Bias.FAVOR)
        val fav = (0 until 30).map { "s$it" }.toSet()
        val a = PuzzleSampler.sample(40, s, inputs(songs, favorites = fav), Prng.seededRng("seed-x"))
        val b = PuzzleSampler.sample(40, s, inputs(songs, favorites = fav), Prng.seededRng("seed-x"))
        assertEquals(a.map { it.id }, b.map { it.id })
        val c = PuzzleSampler.sample(40, s, inputs(songs, favorites = fav), Prng.seededRng("seed-y"))
        assertNotEquals(a.map { it.id }, c.map { it.id })
    }

    @Test fun emptyPoolReturnsEmpty() {
        assertTrue(PuzzleSampler.sample(10, PuzzleSettings(), inputs(emptyList()), Prng.seededRng("e")).isEmpty())
        val allFiltered = PuzzleSettings(yearMin = 2100)
        assertTrue(PuzzleSampler.sample(10, allFiltered, inputs(listOf(song("a", year = 1990))), Prng.seededRng("e")).isEmpty())
    }

    @Test fun singleSongIsDrawnOnceThenThePoolIsDrained() {
        // an rng pinned at 0.0 still terminates: one draw, then the pool is empty
        val out = PuzzleSampler.sample(5, PuzzleSettings(), inputs(listOf(song("a"))), { 0.0 })
        assertEquals(listOf("a"), out.map { it.id }) // weight 1 -> drawn once, then pool empty
    }

    // MARK: Inputs(raw)

    @Test fun inputsFromRawBuildsTheDerivedStructures() {
        val raw = PuzzleSampler.RawInputs(
            songs = listOf(song("s1", albumId = "alb_rock"), song("s2", albumId = "alb_jazz"), song("s3", albumId = null)),
            albumsById = mapOf("alb_rock" to album("alb_rock", "Classic Rock"), "alb_jazz" to album("alb_jazz", "Bebop Jazz")),
            favoriteIds = setOf("s1"), playCounts = mapOf("s2" to 3),
            membershipCollections = listOf(listOf("s1", "s2"), listOf("s2", "s3")),
            targetCollections = listOf(listOf("s1"), listOf("s2", "s3")),
        )
        val built = PuzzleSampler.Inputs.fromRaw(raw)
        assertEquals(listOf("s1", "s2", "s3"), built.songs.map { it.id })
        assertEquals(Genre.category("Classic Rock"), built.genreBySongId["s1"])
        assertEquals(Genre.category("Bebop Jazz"), built.genreBySongId["s2"])
        assertNull(built.genreBySongId["s3"])
        assertEquals(setOf("s1", "s2", "s3"), built.membershipUnion)
        assertEquals(listOf(setOf("s1"), setOf("s2", "s3")), built.perTargetMembership)
        assertEquals(setOf("s1"), built.favoriteIds)
        assertEquals(mapOf("s2" to 3), built.playCounts)
        val s = PuzzleSettings(genreCategories = setOf(Genre.category("Classic Rock")))
        assertEquals(1, PuzzleSampler.poolCount(s, built))
    }

    /** Counts album lookups so we can assert the category is computed ONCE per album. */
    private class CountingAlbums(private val inner: Map<String, com.levi.pocketdj.data.catalog.IndexAlbum>) :
        Map<String, com.levi.pocketdj.data.catalog.IndexAlbum> by inner {
        var gets = 0
        override fun get(key: String): com.levi.pocketdj.data.catalog.IndexAlbum? { gets++; return inner[key] }
    }

    @Test fun genreMapIsBuiltOncePerAlbumNotPerSong() {
        val albums = CountingAlbums(mapOf("alb" to album("alb", "Hip Hop")))
        val songs = (0 until 500).map { song("s$it", albumId = "alb") }
        val built = PuzzleSampler.Inputs.fromRaw(
            PuzzleSampler.RawInputs(songs, albums, emptySet(), emptyMap(), emptyList(), emptyList()),
        )
        assertEquals("one album lookup for 500 songs", 1, albums.gets)
        assertEquals(500, built.genreBySongId.size)
        assertTrue(built.genreBySongId.values.all { it == "hip-hop" })
    }

    @Test fun recencyIsDerivedOnceFromRawDatesAndZerosAreDropped() {
        val raw = PuzzleSampler.RawInputs(
            songs = listOf(song("a"), song("b"), song("c")), albumsById = emptyMap(),
            favoriteIds = emptySet(), playCounts = emptyMap(),
            membershipCollections = emptyList(), targetCollections = emptyList(),
            lastPlayedMs = mapOf("a" to now, "b" to now - 730 * day, "c" to 0.0, "ghost" to Double.NaN),
            hasRecency = true, nowMs = now,
        )
        val built = PuzzleSampler.Inputs.fromRaw(raw)
        assertEquals(1.0, built.recencies.getValue("a"), 1e-12)
        assertEquals(0.5, built.recencies.getValue("b"), 1e-12)
        assertFalse("c" in built.recencies)
        assertFalse("ghost" in built.recencies)
        assertTrue(built.hasRecency)
    }

    @Test fun rawInputsBuildTheSimilarityProfileOnlyWhenTargetsExist() {
        val songs = listOf(song("t1", artist = "Chromatics"), song("x"))
        val withTargets = PuzzleSampler.Inputs.fromRaw(
            PuzzleSampler.RawInputs(songs, emptyMap(), emptySet(), emptyMap(), emptyList(), listOf(listOf("t1"))),
        )
        assertFalse(withTargets.similarityProfile.isEmpty)
        val noTargets = PuzzleSampler.Inputs.fromRaw(
            PuzzleSampler.RawInputs(songs, emptyMap(), emptySet(), emptyMap(), emptyList(), emptyList()),
        )
        assertTrue(noTargets.similarityProfile.isEmpty)
        val skipped = PuzzleSampler.Inputs.fromRaw(
            PuzzleSampler.RawInputs(songs, emptyMap(), emptySet(), emptyMap(), emptyList(), listOf(listOf("t1")), buildSimilarityProfile = false),
        )
        assertTrue(skipped.similarityProfile.isEmpty)
    }

    @Test fun rawPlaysFeedTheCoPlayGraph() {
        val songs = listOf(song("t1"), song("neighbour"))
        val plays = listOf(PlayEvent("1", "t1", now), PlayEvent("2", "neighbour", now + 60_000))
        val built = PuzzleSampler.Inputs.fromRaw(
            PuzzleSampler.RawInputs(songs, emptyMap(), emptySet(), emptyMap(), emptyList(), listOf(listOf("t1")), plays = plays, nowMs = now),
        )
        assertTrue(built.similarityProfile.coPlayWeight.getValue("neighbour") > 0.99)
    }

    // MARK: playability

    private fun five() = listOf("a", "b", "c", "d").map { song(it) }

    @Test fun poolKeepsOnlySongsWhoseAudioCanStartNow() {
        val pool = PuzzleSampler.pool(PuzzleSettings(), inputs(five(), playable = setOf("b", "d")))
        assertEquals(listOf("b", "d"), ids(pool).sorted())
    }

    @Test fun streamableSongsCountAsPlayableWhenAppleMusicIsReady() {
        val all = listOf(song("a"), song("b"), song("c", appleMusicId = "1234"))
        val ready = PuzzleSampler.pool(PuzzleSettings(), inputs(all, playable = setOf("a"), canStream = true))
        assertEquals(listOf("a", "c"), ids(ready).sorted())
        val notReady = PuzzleSampler.pool(PuzzleSettings(), inputs(all, playable = setOf("a"), canStream = false))
        assertEquals(listOf("a"), ids(notReady))
    }

    @Test fun playabilityDegradesToOffWhenNothingIsPlayableAnywhere() {
        assertEquals(3, PuzzleSampler.pool(PuzzleSettings(), inputs(listOf("a", "b", "c").map { song(it) })).size)
    }

    @Test fun playabilityFallbackKeysOnTheEmptyResultNotTheInputs() {
        val s = PuzzleSettings(yearMin = 1990, yearMax = 1999)
        val inp = inputs(listOf(song("old", year = 1995), song("playable")), playable = setOf("playable"))
        assertEquals(listOf("old"), ids(PuzzleSampler.pool(s, inp)))
    }

    @Test fun ripOnDemandIsNeverPlayable() {
        // Only the manifest + burned files count; a song merely present in the catalog is not.
        val raw = PuzzleSampler.RawInputs(
            songs = listOf(song("ripped"), song("catalog-only")), albumsById = emptyMap(),
            favoriteIds = emptySet(), playCounts = emptyMap(),
            membershipCollections = emptyList(), targetCollections = emptyList(),
            ripManifest = mapOf("ripped" to RipManifestEntry(key = "rips/ripped.mp3")),
        )
        val pool = PuzzleSampler.pool(PuzzleSettings(), PuzzleSampler.Inputs.fromRaw(raw))
        assertEquals(listOf("ripped"), ids(pool))
    }

    @Test fun rawInputsBuildThePlayableSetFromManifestAndBurns() {
        val raw = PuzzleSampler.RawInputs(
            songs = listOf(song("a"), song("b")), albumsById = emptyMap(), favoriteIds = emptySet(),
            playCounts = emptyMap(), membershipCollections = emptyList(), targetCollections = emptyList(),
            ripManifest = mapOf("a" to RipManifestEntry(key = "rips/a.mp3")),
            burnedIds = setOf("b"), canStreamAppleMusic = true,
        )
        val built = PuzzleSampler.Inputs.fromRaw(raw)
        assertEquals(setOf("a", "b"), built.playableNowIds)
        assertTrue(built.canStreamAppleMusic)
    }

    @Test fun poolStatsReportsMatchedAndShortlisted() {
        val members = listOf(song("t1", artist = "Chromatics", year = 1994))
        val cat = (0 until 30).map { song("s$it", artist = if (it % 2 == 0) "Chromatics" else "Other $it", year = 1994) }
        val p = PuzzleSimilarity.profile(listOf(members.map { it.id }), (members + cat).associateBy { it.id }, emptyMap(), emptyList(), emptyList())
        val inp = inputs(cat, perTarget = listOf(setOf("t1")), profile = p)
        val on = PuzzleSampler.poolStats(PuzzleSettings(), inp)
        assertEquals(30, on.matched)
        assertTrue(on.similar != null && on.similar!! in 1..30)
        val off = PuzzleSampler.poolStats(PuzzleSettings(similarity = PuzzleSettings.Similarity.OFF), inp)
        assertNull(off.similar)
        assertNull(PuzzleSampler.poolStats(PuzzleSettings(), inputs(cat)).similar)
    }
}

package com.levi.pocketdj.data.games.puzzle

import com.levi.pocketdj.data.catalog.IndexSong
import com.levi.pocketdj.data.collections.Prng
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNotEquals
import org.junit.Assert.assertNull
import org.junit.Assert.assertSame
import org.junit.Assert.assertTrue
import org.junit.Test

/** Port of PuzzleSimilarityTests: ranking BEHAVIOUR, not "returned N rows". */
class PuzzleSimilarityTest {
    private val Sim = PuzzleSimilarity
    private fun ids(r: List<PuzzleCandidate>) = r.map { it.song.id }

    private fun profile(
        members: List<IndexSong>,
        genres: Map<String, String> = emptyMap(),
        otherCollections: List<List<String>> = emptyList(),
        plays: List<PuzzleSimilarity.Play> = emptyList(),
        catalog: List<IndexSong> = emptyList(),
        hasRecency: Boolean = false,
        nowMs: Double = 1_000_000.0,
    ): PuzzleSimilarity.TargetProfile {
        val all = catalog.ifEmpty { members }
        return Sim.profile(listOf(members.map { it.id }), all.associateBy { it.id }, genres, otherCollections, plays, hasRecency, nowMs = nowMs)
    }

    // MARK: no-targets guarantee

    @Test fun emptyProfileIsIdentitySameListObject() {
        val r = rows(listOf(song("a"), song("b"), song("c")))
        val empty = PuzzleSimilarity.TargetProfile()
        assertTrue(empty.isEmpty)
        val out = Sim.shortlist(r, empty, emptyMap(), mode = PuzzleSettings.Similarity.ON, wanted = 60)
        assertSame(r, out)
    }

    @Test fun offModeIsIdentityEvenWithARealProfile() {
        val p = profile(listOf(song("t1", artist = "Chromatics", year = 1994)))
        assertFalse(p.isEmpty)
        val r = rows(listOf(song("x", artist = "Nobody", year = 2020), song("y", artist = "Chromatics", year = 1994)))
        val out = Sim.shortlist(r, p, emptyMap(), mode = PuzzleSettings.Similarity.OFF, wanted = 60)
        assertSame(r, out)
        assertEquals(listOf("x", "y"), ids(out))
    }

    @Test fun emptyCandidatesReturnTheSameList() {
        val p = profile(listOf(song("t1")))
        val r = emptyList<PuzzleCandidate>()
        assertSame(r, Sim.shortlist(r, p, emptyMap(), mode = PuzzleSettings.Similarity.ON, wanted = 60))
    }

    @Test fun targetsThatResolveToNothingGiveAnEmptyProfile() {
        val p = Sim.profile(listOf(listOf("ghost")), emptyMap(), emptyMap(), emptyList(), emptyList())
        assertTrue(p.isEmpty)
        assertTrue(Sim.profile(emptyList(), emptyMap(), emptyMap(), emptyList(), emptyList()).isEmpty)
    }

    // MARK: the signals

    @Test fun artistRanksAboveUnrelated() {
        val p = profile(listOf(song("t1", artist = "Chromatics")))
        val r = rows(listOf(song("stranger", artist = "Nobody At All"), song("same-artist", artist = "Chromatics")))
        val out = Sim.shortlist(r, p, emptyMap(), mode = PuzzleSettings.Similarity.ON, wanted = 60)
        assertEquals("same-artist", out.first().song.id)
        assertTrue(Sim.score(r[1].song, p, null) > 0.9)
        assertEquals(0.0, Sim.score(r[0].song, p, null), 0.0)
    }

    @Test fun artistKeyIsCaseDiacriticAndLeadingTheInsensitive() {
        assertEquals(Sim.artistKey("The Chromatics"), Sim.artistKey("chromatics"))
        assertEquals(Sim.artistKey("Beyoncé"), Sim.artistKey("BEYONCE"))
        assertEquals(Sim.artistKey("  Björk "), Sim.artistKey("bjork"))
        assertNotEquals(Sim.artistKey("Portishead"), Sim.artistKey("Radiohead"))
    }

    @Test fun genreRanksAboveUnrelated() {
        val genres = mapOf("t1" to "hip-hop", "t2" to "hip-hop", "hh" to "hip-hop", "country" to "country")
        val p = profile(listOf(song("t1"), song("t2")), genres = genres)
        val r = rows(listOf(song("country", artist = "X"), song("hh", artist = "Y")))
        val out = Sim.shortlist(r, p, genres, mode = PuzzleSettings.Similarity.ON, wanted = 60)
        assertEquals("hh", out.first().song.id)
        assertTrue(Sim.score(r[1].song, p, "hip-hop") > Sim.score(r[0].song, p, "country"))
    }

    @Test fun yearDecayRanksTheNearerEraHigher() {
        val p = profile(listOf(song("t1", year = 1994), song("t2", year = 1994)))
        val near = song("near", artist = "Q", year = 1995)
        val far = song("far", artist = "Q", year = 1975)
        val none = song("undated", artist = "Q")
        val sNear = Sim.score(near, p, null)
        val sFar = Sim.score(far, p, null)
        val sNone = Sim.score(none, p, null)
        assertTrue(sNear > sFar)
        assertTrue(sFar > 0)
        assertTrue(sNone < sNear)
        val out = Sim.shortlist(rows(listOf(far, none, near)), p, emptyMap(), mode = PuzzleSettings.Similarity.ON, wanted = 60)
        assertEquals("near", out.first().song.id)
    }

    @Test fun yearSigmaIsFlooredAtEightAndTracksWideSpreads() {
        val tight = profile(listOf(song("a", year = 1994), song("b", year = 1994)))
        assertEquals(8.0, tight.yearSigma, 1e-12)
        assertEquals(1994.0, tight.yearMean!!, 1e-12)
        val wide = profile(listOf(song("a", year = 1950), song("b", year = 2000)))
        assertEquals(25.0, wide.yearSigma, 1e-9)
    }

    @Test fun coMembershipAndCoPlayTerms() {
        val plays = listOf(
            PuzzleSimilarity.Play("t1", 1_000_000.0),
            PuzzleSimilarity.Play("recent", 1_000_000.0 + 10 * 60 * 1000),
            PuzzleSimilarity.Play("later", 1_000_000.0 + 3 * 60 * 60 * 1000),
        )
        val p = profile(
            listOf(song("t1")),
            otherCollections = listOf(listOf("t1", "shared"), listOf("loner-elsewhere")),
            plays = plays, nowMs = 1_000_000.0 + 10 * 60 * 1000,
        )
        assertTrue("shared" in p.coMemberIds)
        assertFalse("loner" in p.coMemberIds)
        assertEquals(1.0, p.coPlayWeight["recent"] ?: 0.0, 1e-4)
        assertNull(p.coPlayWeight["later"])
        val shared = song("shared", artist = "Z")
        val recent = song("recent", artist = "Z")
        val loner = song("loner", artist = "Z")
        assertTrue(Sim.score(shared, p, null) > Sim.score(loner, p, null))
        assertTrue(Sim.score(recent, p, null) > Sim.score(loner, p, null))
        assertTrue("co-membership (0.12) outranks co-play (0.08)", Sim.score(shared, p, null) > Sim.score(recent, p, null))
    }

    @Test fun targetCollectionsThemselvesAreNotCoMembers() {
        val p = Sim.profile(
            targetMemberIds = listOf(listOf("t1", "t2")),
            songsById = listOf(song("t1"), song("t2")).associateBy { it.id },
            genreBySongId = emptyMap(),
            otherCollections = listOf(listOf("t2", "t1")), // the target itself, reordered
            plays = emptyList(),
        )
        assertTrue(p.coMemberIds.isEmpty())
    }

    @Test fun lyricalKeywordsRankAboveUnrelatedWhenPresent() {
        val p = profile(listOf(song("t1", keywords = listOf("melancholy", "rain", "night")), song("t2", keywords = listOf("melancholy", "night"))))
        assertFalse(p.keywordShare.isEmpty())
        val moody = song("moody", artist = "Q", keywords = listOf("Melancholy", "night"))
        val sunny = song("sunny", artist = "Q", keywords = listOf("party", "sunshine"))
        assertTrue(Sim.score(moody, p, null) > Sim.score(sunny, p, null))
    }

    @Test fun keywordShareKeepsOnlyTheTopTwenty() {
        val kws = (0 until 30).map { "k%02d".format(it) }
        val p = profile(listOf(song("t1", keywords = kws)))
        assertEquals(20, p.keywordShare.size)
    }

    // MARK: sparse-feature guard

    @Test fun profileLevelDenominatorDoesNotRewardMissingMetadata() {
        val p = profile(listOf(song("t1", artist = "Chromatics", year = 1994)))
        assertTrue(p.keywordShare.isEmpty())
        assertEquals(Sim.W_ARTIST + Sim.W_YEAR, p.availableWeight, 1e-4)
        val bare = song("bare", artist = "Chromatics", year = 1994)
        val rich = song("rich", artist = "Chromatics", year = 1994, keywords = listOf("melancholy", "rain"))
        assertEquals(Sim.score(bare, p, null), Sim.score(rich, p, null), 1e-4)
        val kp = profile(listOf(song("t1", artist = "Chromatics", year = 1994, keywords = listOf("melancholy", "rain"))))
        assertTrue(Sim.score(rich, kp, null) > Sim.score(bare, kp, null))
    }

    @Test fun denominatorSumsExactlyTheTermsTheProfileCanSpeak() {
        val members = listOf(song("t1", artist = "A1", year = 1990, keywords = listOf("k")))
        val p = profile(
            members, genres = mapOf("t1" to "jazz"),
            otherCollections = listOf(listOf("t1", "x")),
            plays = listOf(PuzzleSimilarity.Play("t1", 1_000_000.0), PuzzleSimilarity.Play("y", 1_000_000.0)),
            hasRecency = true,
        )
        val all = Sim.W_ARTIST + Sim.W_GENRE + Sim.W_YEAR + Sim.W_LYRICS + Sim.W_CO_MEMBER + Sim.W_CO_PLAY + Sim.W_RECENCY
        assertEquals(all, p.availableWeight, 1e-12)
        assertEquals(0.30 + 0.25 + 0.15 + 0.10 + 0.12 + 0.08 + 0.05, all, 1e-12)
    }

    // MARK: shortlist

    @Test fun shortlistNeverStarves() {
        val p = profile(listOf(song("t1", artist = "Nobody Else", year = 1900)))
        val r = rows((0 until 50).map { song("s$it", artist = "Other $it") })
        val out = Sim.shortlist(r, p, emptyMap(), mode = PuzzleSettings.Similarity.ON, wanted = 60)
        assertTrue(out.size >= 30)
        assertEquals(out.size, ids(out).toSet().size)
    }

    @Test fun starvationGuardRefillsToExactlyMinOfCountAndMax20HalfWanted() {
        val p = profile(listOf(song("t1", artist = "Nobody Else")))
        // Nothing scores > 0 ⇒ shortlist empty ⇒ filler = min(count, max(20, wanted/2)).
        val r40 = rows((0 until 40).map { song("s%02d".format(it), artist = "Other $it") })
        assertEquals(30, Sim.shortlist(r40, p, emptyMap(), mode = PuzzleSettings.Similarity.ON, wanted = 60).size)
        assertEquals(20, Sim.shortlist(r40, p, emptyMap(), mode = PuzzleSettings.Similarity.ON, wanted = 10).size)
        val r5 = rows((0 until 5).map { song("s$it", artist = "Other $it") })
        assertEquals(5, Sim.shortlist(r5, p, emptyMap(), mode = PuzzleSettings.Similarity.ON, wanted = 60).size)
    }

    @Test fun fillerIsOrderedByWeightThenId() {
        val p = profile(listOf(song("t1", artist = "Nobody Else")))
        val r = listOf(
            PuzzleCandidate(song("c", artist = "o1"), 1.0),
            PuzzleCandidate(song("a", artist = "o2"), 1.0),
            PuzzleCandidate(song("heavy", artist = "o3"), 4.0),
            PuzzleCandidate(song("fresh", artist = "o4"), 1.0),
        )
        // (a candidate with recency > 0 always scores > 0, so it is shortlisted, never filler)
        val out = Sim.shortlist(r, p, emptyMap(), mode = PuzzleSettings.Similarity.ON, wanted = 1)
        assertEquals(listOf("heavy", "a", "c", "fresh"), ids(out))
        // filler keeps the ORIGINAL weights (no similarity re-weighting)
        assertEquals(4.0, out.first().weight, 0.0)
    }

    @Test fun strictModeDropsWeakMatchesThenTopsUp() {
        val p = profile(listOf(song("t1", artist = "Chromatics", year = 1994)))
        val r = rows(listOf(song("strong", artist = "Chromatics", year = 1994)) + (0 until 40).map { song("weak$it", artist = "Other $it") })
        val out = Sim.shortlist(r, p, emptyMap(), mode = PuzzleSettings.Similarity.STRICT, wanted = 60)
        assertEquals("strong", out.first().song.id)
        assertTrue(out.size >= 20)
    }

    @Test fun strictFloorIsFifteenPercentAndExclusive() {
        assertEquals(0.15, Sim.STRICT_FLOOR, 0.0)
        // A year-only profile: score = exp(-|dy|/8). At dy chosen so score < floor, strict drops
        // it from the scored set (it can only come back as starvation filler), ON keeps it scored.
        val p = profile(listOf(song("t1", year = 2000)))
        val farYear = 2000 - 40 // exp(-5) = 0.0067 < 0.15
        val far = song("far", artist = "Q", year = farYear)
        val near = song("near", artist = "Q", year = 2001)
        val r = rows(listOf(far, near))
        val strict = Sim.shortlist(r, p, emptyMap(), mode = PuzzleSettings.Similarity.STRICT, wanted = 60)
        assertEquals("near", strict.first().song.id)
        val farRow = strict.first { it.song.id == "far" } // present only as filler, weight unchanged
        assertEquals(1.0, farRow.weight, 0.0)
        val on = Sim.shortlist(r, p, emptyMap(), mode = PuzzleSettings.Similarity.ON, wanted = 60)
        val farOn = on.first { it.song.id == "far" }
        assertEquals(Sim.score(far, p, null) + 0.25, farOn.weight, 1e-12) // re-weighted (0.25 + sim)
    }

    @Test fun shortlistKIsMaxOf400And8TimesWanted() {
        val members = (0 until 3).map { song("t$it", artist = "Chromatics", year = 1994) }
        val p = profile(members)
        val r = rows((0 until 1000).map { song("m%04d".format(it), artist = "Chromatics", year = 1994) })
        assertEquals(400, Sim.shortlist(r, p, emptyMap(), mode = PuzzleSettings.Similarity.ON, wanted = 10).size)
        assertEquals(480, Sim.shortlist(r, p, emptyMap(), mode = PuzzleSettings.Similarity.ON, wanted = 60).size)
        assertEquals(800, Sim.shortlist(r, p, emptyMap(), mode = PuzzleSettings.Similarity.ON, wanted = 100).size)
    }

    @Test fun shortlistActuallyRestrictsALargePool() {
        val p = profile((0 until 5).map { song("t$it", artist = "Chromatics", year = 1994) })
        val r = rows(
            (0 until 20).map { song("hit$it", artist = "Chromatics", year = 1994) } +
                (0 until 5000).map { song("miss$it", artist = "Other $it") },
        )
        val out = Sim.shortlist(r, p, emptyMap(), mode = PuzzleSettings.Similarity.ON, wanted = 60)
        assertTrue(out.size < 600)
        assertEquals((0 until 20).map { "hit$it" }.toSet(), ids(out).take(20).toSet())
    }

    @Test fun orderIsDeterministicSimThenWeightThenRecencyThenId() {
        val p = profile(listOf(song("t1", artist = "Chromatics")), hasRecency = true)
        val r = listOf(
            PuzzleCandidate(song("b", artist = "Chromatics"), 1.0),
            PuzzleCandidate(song("a", artist = "Chromatics"), 1.0),
            PuzzleCandidate(song("w", artist = "Chromatics"), 2.0),
            PuzzleCandidate(song("r", artist = "Chromatics"), 1.0),
        )
        // r has the highest recency => highest sim (recency feeds the score too); w beats a/b on weight
        val out = Sim.shortlist(r, p, emptyMap(), recencies = mapOf("r" to 0.5), mode = PuzzleSettings.Similarity.ON, wanted = 60)
        assertEquals("r", out.first().song.id)
        assertEquals(listOf("w", "a", "b"), ids(out).drop(1))
    }

    @Test fun existingWeightsSurviveInsideTheShortlist() {
        val p = profile(listOf(song("t1", artist = "Chromatics")))
        val out = Sim.shortlist(
            listOf(PuzzleCandidate(song("plain", artist = "Chromatics"), 1.0), PuzzleCandidate(song("hearted", artist = "Chromatics"), 4.0)),
            p, emptyMap(), mode = PuzzleSettings.Similarity.ON, wanted = 60,
        )
        val by = out.associate { it.song.id to it.weight }
        assertTrue(by.getValue("hearted") > by.getValue("plain"))
        assertEquals(4.0 * (0.25 + 1.0), by.getValue("hearted"), 1e-9)
    }

    // MARK: cloud

    @Test fun cloudRanksOnlyReorderSongsAlreadyInThePool() {
        val p = profile(listOf(song("t1", artist = "Chromatics")))
        val r = rows(listOf(song("known-a", artist = "Zed"), song("known-b", artist = "Zed")))
        val out = Sim.shortlist(r, p, emptyMap(), cloudRanks = mapOf("ghost-not-in-catalog" to 1.0, "known-b" to 1.0), mode = PuzzleSettings.Similarity.ON, wanted = 60)
        assertFalse(out.any { it.song.id == "ghost-not-in-catalog" })
        assertEquals("known-b", out.first().song.id)
    }

    @Test fun cloudRankCanOnlyRaiseAScoreAndNeverExceedOne() {
        val p = profile(listOf(song("t1", artist = "Chromatics", year = 1994)))
        for (s in listOf(song("m", artist = "Chromatics", year = 1994), song("s", artist = "Other", year = 1930))) {
            val bare = Sim.score(s, p, null, cloudRank = 0.0)
            val lifted = Sim.score(s, p, null, cloudRank = 1.0)
            assertTrue(lifted >= bare)
            assertTrue(lifted <= 1.0)
        }
    }

    @Test fun cloudRankZeroIsExactlyTheLocalScoreAndFormulaIsPinned() {
        val p = profile(listOf(song("t1", artist = "Chromatics", year = 1994)))
        val s = song("x", artist = "Other", year = 1990)
        val local = Sim.score(s, p, null)
        assertEquals(local, Sim.score(s, p, null, cloudRank = 0.0), 0.0)
        assertEquals(local, Sim.score(s, p, null, cloudRank = -3.0), 0.0)
        assertEquals(local + 0.25 * 0.5 * (1 - local), Sim.score(s, p, null, cloudRank = 0.5), 1e-12)
        assertEquals(local + 0.25 * (1 - local), Sim.score(s, p, null, cloudRank = 9.0), 1e-12) // rank clamped to 1
    }

    @Test fun cloudOffProducesTheSameOrderAsAnEmptyCloudMap() {
        val p = profile(listOf(song("t1", artist = "Chromatics", year = 1994)))
        val r = rows(listOf(song("a", artist = "Other", year = 1970), song("b", artist = "Chromatics", year = 1994), song("c", artist = "Other", year = 1993)))
        val a = Sim.shortlist(r, p, emptyMap(), mode = PuzzleSettings.Similarity.ON, wanted = 60)
        val b = Sim.shortlist(r, p, emptyMap(), cloudRanks = emptyMap(), mode = PuzzleSettings.Similarity.ON, wanted = 60)
        assertEquals(ids(a), ids(b))
        assertEquals(listOf("b", "c", "a"), ids(a))
    }

    // MARK: composition with the sampler

    @Test fun similarityNeverAdmitsAnUnplayableSong() {
        val members = listOf(song("t1", artist = "Chromatics", year = 1994))
        val silent = (0 until 5).map { song("silent$it", artist = "Chromatics", year = 1994) }
        val loud = (0 until 5).map { song("loud$it", artist = "Other $it", year = 2020) }
        val byId = (members + silent + loud).associateBy { it.id }
        val p = Sim.profile(listOf(members.map { it.id }), byId, emptyMap(), emptyList(), emptyList())
        val s = PuzzleSettings(targetCollectionIds = listOf("pkt_t"))
        val inp = inputs(silent + loud, perTarget = listOf(members.map { it.id }.toSet()), playable = loud.map { it.id }.toSet(), profile = p)
        val pool = PuzzleSampler.pool(s, inp)
        assertTrue(pool.isNotEmpty())
        assertTrue(pool.all { it.song.id.startsWith("loud") })
    }

    @Test fun seededSampleIsDeterministicAndBiasedTowardTheCratesArtist() {
        val members = listOf(song("t1", artist = "Chromatics", year = 1994))
        val catalog = (0 until 200).map { song("s$it", artist = if (it % 3 == 0) "Chromatics" else "Other $it", year = 1990 + it % 20) }
        val p = Sim.profile(listOf(members.map { it.id }), (members + catalog).associateBy { it.id }, emptyMap(), emptyList(), emptyList())
        val inp = inputs(catalog, perTarget = listOf(setOf("t1")), profile = p)
        val a = PuzzleSampler.sample(30, PuzzleSettings(), inp, Prng.seededRng("sim"))
        val b = PuzzleSampler.sample(30, PuzzleSettings(), inp, Prng.seededRng("sim"))
        assertEquals(a.map { it.id }, b.map { it.id })
        val same = a.count { it.artist == "Chromatics" }
        assertTrue("got $same/${a.size}", same.toDouble() / a.size > 0.4)
    }

    // MARK: recency term

    @Test fun noRecencyDataLeavesScoresExactlyAsBefore() {
        val members = listOf(song("t1", artist = "Chromatics", year = 1994))
        val without = profile(members, hasRecency = false)
        val with = profile(members, hasRecency = true)
        assertEquals(Sim.W_ARTIST + Sim.W_YEAR, without.availableWeight, 1e-9)
        assertEquals(Sim.W_ARTIST + Sim.W_YEAR + Sim.W_RECENCY, with.availableWeight, 1e-9)
        val c = song("c", artist = "Chromatics", year = 1994)
        assertEquals(Sim.score(c, without, null), Sim.score(c, without, null, recency = 0.9), 1e-12)
    }

    @Test fun recencyCannotOutrankAStrongerSignal() {
        val p = profile(listOf(song("t1", artist = "Chromatics", year = 1994)), hasRecency = true)
        val match = song("match", artist = "Chromatics", year = 1994)
        val stranger = song("stranger", artist = "Nobody", year = 1994)
        assertTrue(Sim.score(match, p, null, recency = 0.0) > Sim.score(stranger, p, null, recency = 1.0))
    }

    @Test fun recencyBreaksTiesBetweenOtherwiseIdenticalSongs() {
        val p = profile(listOf(song("t1", artist = "Chromatics", year = 1994)), hasRecency = true)
        val stale = song("stale", artist = "Chromatics", year = 1994)
        val fresh = song("fresh", artist = "Chromatics", year = 1994)
        assertTrue(Sim.score(fresh, p, null, recency = 1.0) > Sim.score(stale, p, null, recency = 0.0))
        val out = Sim.shortlist(rows(listOf(stale, fresh)), p, emptyMap(), recencies = mapOf("fresh" to 1.0, "stale" to 0.0), mode = PuzzleSettings.Similarity.ON, wanted = 60)
        assertEquals("fresh", out.first().song.id)
    }

    @Test fun coPlayEdgesDecayWithAge() {
        val base = 1_700_000_000_000.0
        val day = 86_400_000.0
        val p = profile(
            listOf(song("t1")),
            plays = listOf(
                PuzzleSimilarity.Play("t1", base), PuzzleSimilarity.Play("fresh", base + 60_000),
                PuzzleSimilarity.Play("t1", base - 1460 * day), PuzzleSimilarity.Play("stale", base - 1460 * day + 60_000),
            ),
            nowMs = base,
        )
        val freshEdge = p.coPlayWeight["fresh"] ?: 0.0
        val staleEdge = p.coPlayWeight["stale"] ?: 0.0
        assertTrue(freshEdge > 0.99)
        assertTrue(staleEdge > 0)
        assertTrue("got $staleEdge", staleEdge < 0.3)
        assertTrue(Sim.score(song("fresh"), p, null) > Sim.score(song("stale"), p, null))
    }

    @Test fun memberWeightsWeightTheProfileAndZeroWeightsAreSkipped() {
        val a = song("a", artist = "Alpha")
        val b = song("b", artist = "Beta")
        val c = song("c", artist = "Gamma")
        val p = Sim.profile(
            listOf(listOf("a", "b", "c")), listOf(a, b, c).associateBy { it.id }, emptyMap(), emptyList(), emptyList(),
            memberWeights = mapOf("a" to 3.0, "b" to 1.0, "c" to 0.0),
        )
        assertEquals(0.75, p.artistShare.getValue("alpha"), 1e-12)
        assertEquals(0.25, p.artistShare.getValue("beta"), 1e-12)
        assertFalse("gamma" in p.artistShare)
    }
}

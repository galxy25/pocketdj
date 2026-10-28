package com.levi.pocketdj.data.games.inthepocket

import com.levi.pocketdj.data.games.inthepocket.InThePocketScorer.BuildResult
import com.levi.pocketdj.data.pockets.ListeningContextTag
import com.levi.pocketdj.data.pockets.ListeningPocketsResults
import com.levi.pocketdj.data.pockets.ListeningPocketsRoundLearning
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNotNull
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test

/** Port of InThePocketScorerTests.swift + the pockets × collections membership rules. */
class InThePocketScorerTest {

    companion object {
        // 2026-10-13 (Tue) 19:30 local at UTC−7 = 2026-10-14T02:30Z.
        const val NOW = 1_791_945_000_000.0
        const val TZ = -420
        const val PLACE_A = "plc_0f1e2d3c4b5a6978"
        const val PLACE_B = "plc_8899aabbccddeeff"

        val catalog: Map<String, InThePocketScorer.Song> = buildMap {
            fun add(id: String, artist: String, genre: String, bpm: Double) {
                put(id, InThePocketScorer.Song(id, "T-$id", artist, 200_000, genre, bpm))
            }
            add("f1", "Ada", "funk", 118.0); add("f2", "Bix", "funk", 120.0); add("f3", "Cleo", "funk", 122.0)
            add("f4", "Dax", "funk", 124.0); add("f5", "Eve", "funk", 126.0); add("f6", "Fin", "funk", 119.0)
            add("s1", "Gus", "soul", 121.0); add("s2", "Hal", "soul", 123.0); add("s3", "Ivy", "soul", 60.0)
            add("r1", "Jet", "rock", 150.0); add("r2", "Kai", "rock", 155.0); add("r3", "Lux", "rock", 148.0)
            add("j1", "Mo", "jazz", 90.0); add("j2", "Nia", "jazz", 95.0)
        }

        val evening = InThePocketContext.make(NOW, TZ, ListeningContextTag.place(PLACE_A))

        fun results(json: String) = ListeningPocketsResults.parse(json)!!

        val cloudJSON = """
        {"v":1,"generatedAtMs":1791940000000,"stale":false,"algo":{"version":1,"params":{}},
         "pockets":[],
         "patterns":[
          {"id":"pt_000000000001","key":"weekday|evening|place:${PLACE_A}|funk","title":"Weekday evenings · Location A · Funk",
           "pocketIds":["pk_1","pk_2","pk_3"],"occurrences":3,"distinctDays":3,"dayType":"weekday","timeBucket":"evening",
           "ctx":{"kind":"place","placeId":"${PLACE_A}"},
           "features":[{"dim":"genre","value":"funk","label":"Funk","share":0.8,"lift":3,"score":0.88},
                       {"dim":"place","value":"${PLACE_A}","label":"Location A","share":1,"lift":2,"score":0.69}],
           "numeric":{"bpm":{"center":121,"lo":118,"hi":126,"coverage":1,"dispersionRatio":0.2,"defining":true}},
           "topSongs":[{"songId":"f1","plays":3},{"songId":"s1","plays":2}]},
          {"id":"pt_000000000002","key":"weekend|morning|*|rock","title":"Weekend mornings · Rock",
           "pocketIds":["pk_4","pk_5"],"occurrences":2,"distinctDays":2,"dayType":"weekend","timeBucket":"morning",
           "features":[{"dim":"genre","value":"rock","label":"Rock","share":0.9,"lift":4,"score":1.2}],
           "numeric":{"bpm":{"center":150,"lo":145,"hi":156,"coverage":1,"dispersionRatio":0.1,"defining":true}},
           "topSongs":[{"songId":"r1","plays":2}]}
         ]}
        """.trimIndent()

        fun input(
            results: ListeningPocketsResults? = results(cloudJSON),
            plays: List<InThePocketScorer.Play> = emptyList(), seed: ULong = 42uL,
            playable: Set<String>? = null, context: InThePocketContext = evening,
            pastRounds: List<InThePocketRound> = emptyList(),
            collections: List<InThePocketScorer.CollectionInfo> = emptyList(),
            catalog: Map<String, InThePocketScorer.Song> = Companion.catalog,
        ) = InThePocketScorer.Input(
            context = context, contextLabel = "Location A", results = results, catalog = catalog,
            playableIds = playable ?: catalog.keys, plays = plays, pastRounds = pastRounds,
            nowMs = NOW, seed = seed, collections = collections,
        )

        fun play(id: String, hoursAgo: Double, skipped: Boolean = false, tz: Int = TZ) =
            InThePocketScorer.Play(id, NOW - hoursAgo * 3_600_000, tz, if (skipped) "skipped" else "completed", null)
    }

    private fun picks(input: InThePocketScorer.Input): InThePocketScorer.Output {
        val r = InThePocketScorer.build(input)
        assertTrue("expected a round, got $r", r is BuildResult.Success)
        return (r as BuildResult.Success).output
    }

    // MARK: - Context

    @Test fun contextUsesTheCloudBucketsInLocalTime() {
        val c = evening
        assertEquals("evening", c.timeBucket)
        assertEquals("weekday", c.dayType)
        assertEquals("Tuesday", 2, c.dow)
        assertEquals("place:$PLACE_A", c.ctxKey)
        assertEquals(listOf("weekday|evening|place:$PLACE_A", "weekday|evening|*"), c.learningKeys)
        // The same instant in UTC is Wednesday 02:30 — night, still a weekday.
        val utc = InThePocketContext.make(NOW, 0, null)
        assertEquals(listOf("night", "weekday"), listOf(utc.timeBucket, utc.dayType))
        assertEquals(3, utc.dow)
        assertNull(utc.ctx)
        assertEquals("Weekday evening", c.timePhrase)
    }

    @Test fun timeBucketBoundariesIncludingNightWrap() {
        val t = InThePocketContext.Companion
        assertEquals("night", t.timeBucket(4.99)); assertEquals("morning", t.timeBucket(5.0))
        assertEquals("morning", t.timeBucket(9.99)); assertEquals("midday", t.timeBucket(10.0))
        assertEquals("midday", t.timeBucket(13.99)); assertEquals("afternoon", t.timeBucket(14.0))
        assertEquals("afternoon", t.timeBucket(17.99)); assertEquals("evening", t.timeBucket(18.0))
        assertEquals("evening", t.timeBucket(21.99)); assertEquals("night", t.timeBucket(22.0))
        assertEquals("night", t.timeBucket(0.0)); assertEquals("night", t.timeBucket(23.5))
    }

    @Test fun dowAndDayTypeFromEpochAndOffset() {
        // 1970-01-01 00:00Z was a Thursday.
        assertEquals(4, InThePocketContext.make(0.0, 0, null).dow)
        // 2026-10-18 15:30Z is Sunday afternoon; at UTC−7 Sunday morning.
        val sun = InThePocketContext.make(1_792_337_400_000.0, TZ, null)
        assertEquals(listOf("weekend", "morning", 0), listOf(sun.dayType, sun.timeBucket, sun.dow))
        val sat = InThePocketContext.make(1_792_337_400_000.0 - 86_400_000, TZ, null)
        assertEquals(listOf("weekend", 6), listOf(sat.dayType, sat.dow))
        // Before the epoch (negative local seconds) still lands on a valid weekday: 1969-12-31 = Wednesday.
        assertEquals(3, InThePocketContext.make(-1_000.0 * 3600, 0, null).dow)
        // A `none` tag is no context; a trip with origin keeps it.
        assertNull(InThePocketContext.make(NOW, 0, ListeningContextTag.NONE).ctx)
        val trip = ListeningContextTag.trip("trp_1", "plc_a", null)
        assertEquals("trip:trp_1", InThePocketContext.make(NOW, 0, trip).ctxKey)
        assertEquals(listOf("weekday|night|trip:trp_1", "weekday|night|*"), InThePocketContext.make(NOW, 0, trip).learningKeys)
    }

    @Test fun contextMatchRequiresTheTimeBucketAndRewardsDayAndPlace() {
        val now = evening
        val m = { b: String, d: String, c: ListeningContextTag? -> InThePocketScorer.contextMatch(b, d, c, now) }
        assertEquals(0.0, m("morning", "weekday", null), 0.0)
        assertEquals(2.0, m("evening", "weekend", null), 0.0)
        assertEquals(3.0, m("evening", "weekday", null), 0.0)
        assertEquals(5.0, m("evening", "weekday", ListeningContextTag.place(PLACE_A)), 0.0)
        assertEquals(3.0, m("evening", "weekday", ListeningContextTag.place(PLACE_B)), 0.0)
    }

    // MARK: - Cloud mode

    @Test fun cloudModeAimsAtTheMatchingPatternOnly() {
        val out = picks(input())
        assertEquals(InThePocketMode.CLOUD, out.mode)
        assertEquals("cloud rounds are four songs", 4, out.picks.size)
        assertEquals(listOf("funk"), out.targets.map { it.value })
        assertEquals(118.0..126.0, out.bpmBand)
        for (p in out.picks) { assertTrue(p.song.genre != "rock"); assertTrue(p.song.genre != "jazz") }
        assertEquals(listOf("Weekday evening", "Location A", "118–126 BPM", "Funk"), out.chips)
        assertEquals("one song per artist", out.picks.size, out.picks.map { it.song.artist }.toSet().size)
    }

    @Test fun sameSeedSameRoundAndSeedsVary() {
        assertEquals(picks(input(seed = 7uL)), picks(input(seed = 7uL)))
        val distinct = (1..12).map { picks(input(seed = it.toULong())).picks.map { p -> p.song.id } }.toSet()
        assertTrue("the seed is what varies a round", distinct.size > 1)
    }

    @Test fun recentlyPlayedAndUnplayableSongsAreNeverPicked() {
        val recent = listOf("f1", "f2", "s1").map { play(it, 3.0) }
        val out = picks(input(plays = recent, playable = catalog.keys - "f3"))
        assertTrue(out.picks.map { it.song.id }.toSet().intersect(setOf("f1", "f2", "s1", "f3")).isEmpty())
        // The last three rounds' songs are rested too.
        val past = TestRounds.round(listOf("f4", "f5", "f6"), InThePocketOutcome.Pocket).copy(createdAtMs = NOW - 3_600_000)
        val rested = picks(input(pastRounds = listOf(past)))
        assertTrue(rested.picks.map { it.song.id }.toSet().intersect(setOf("f4", "f5", "f6")).isEmpty())
    }

    @Test fun onlyTheLastThreeRoundsRestTheirSongs() {
        val rounds = listOf("f1", "f2", "f3", "f4").mapIndexed { i, s ->
            TestRounds.round(listOf(s), InThePocketOutcome.Pocket).copy(createdAtMs = NOW - (10 - i) * 3_600_000.0)
        }
        val ex = InThePocketScorer.scoreCandidates(input(pastRounds = rounds)).scored.map { it.song.id }.toSet()
        // f1 is the OLDEST of four rounds: not rested; f2..f4 are.
        assertTrue("f1" in ex)
        assertTrue(ex.intersect(setOf("f2", "f3", "f4")).isEmpty())
    }

    @Test fun nothingPlayableAndTooFewCandidatesFail() {
        assertEquals(BuildResult.Failed(InThePocketScorer.Failure.NOTHING_PLAYABLE), InThePocketScorer.build(input(playable = emptySet())))
        assertEquals(
            BuildResult.Failed(InThePocketScorer.Failure.NOT_ENOUGH_CANDIDATES),
            InThePocketScorer.build(input(playable = setOf("f1", "j1"))),
        )
    }

    @Test fun aCandidateThatMatchesNothingIsDropped() {
        val ids = InThePocketScorer.scoreCandidates(input()).scored.map { it.song.id }.toSet()
        assertFalse("r1" in ids); assertFalse("j1" in ids)
        assertTrue("f2" in ids)
    }

    @Test fun cloudProfileNeedsGeneratedAtAndAMatchingBucket() {
        val empty = ListeningPocketsResults.EMPTY
        assertNull(InThePocketScorer.cloudProfile(input(results = empty)))
        // A morning context matches neither pattern's bucket except the weekend-morning rock one on a weekend.
        val night = InThePocketContext.make(NOW, 0, null)    // weekday night
        assertNull(InThePocketScorer.cloudProfile(input(context = night)))
        val noGen = results(cloudJSON.replace("\"generatedAtMs\":1791940000000", "\"generatedAtMs\":null"))
        assertNull(InThePocketScorer.cloudProfile(input(results = noGen)))
    }

    // MARK: - Fallbacks

    @Test fun withoutCloudResultsTheRoundComesFromThisContextsHistory() {
        val plays = mutableListOf<InThePocketScorer.Play>()
        for (day in 1..4) {
            val h = day * 24.0
            plays += play("s1", h); plays += play("s2", h - 0.1); plays += play("j1", h - 0.2, skipped = true)
        }
        for (day in 1..4) plays += play("r1", day * 24.0 + 11)   // mornings are rock — ignored
        val out = picks(input(results = null, plays = plays))
        assertEquals(InThePocketMode.HISTORY, out.mode)
        assertEquals("history rounds are three songs", 3, out.picks.size)
        assertEquals("soul", out.targets.first { it.dim == "genre" }.value)
        assertFalse(out.targets.any { it.value == "rock" })
        assertFalse(out.picks.any { it.song.id == "j1" })
    }

    @Test fun coldModeWhenThisContextHasNoHistory() {
        val plays = (1..6).map { play(if (it % 2 == 0) "f1" else "f2", it * 24.0 + 11) }   // mornings only
        val out = picks(input(results = null, plays = plays))
        assertEquals(InThePocketMode.COLD, out.mode)
        assertEquals("funk", out.targets.first().value)
    }

    @Test fun historyNarrowsToThisPlaceOnlyAtFivePlays() {
        // Six evening-weekday plays total; only four were stamped at place A -> stays on the wider set.
        val atA = ListeningContextTag.place(PLACE_A)
        val plays = (1..6).map { d ->
            val p = play("f1", d * 24.0)
            if (d <= 4) p.copy(ctx = atA) else p
        }
        val (mode, basis) = InThePocketScorer.contextBasis(input(results = null, plays = plays))
        assertEquals(InThePocketMode.HISTORY, mode)
        assertEquals(6, basis.size)
        val plays5 = (1..7).map { d -> play("f1", d * 24.0).let { if (d <= 5) it.copy(ctx = atA) else it } }
        assertEquals(5, InThePocketScorer.contextBasis(input(results = null, plays = plays5)).second.size)
        // Fewer than five anywhere ⇒ cold, every play.
        val few = (1..3).map { play("f1", it * 24.0) }
        val (m3, b3) = InThePocketScorer.contextBasis(input(results = null, plays = few))
        assertEquals(InThePocketMode.COLD, m3); assertEquals(3, b3.size)
    }

    // MARK: - Round learning

    @Test fun cloudRoundLearningMultipliesTargetsForThisContext() {
        val r = results(cloudJSON).copy(roundLearning = ListeningPocketsRoundLearning(contexts = listOf(
            ListeningPocketsRoundLearning.Context("weekday|evening|place:$PLACE_A", 5, listOf(
                ListeningPocketsRoundLearning.Weight("genre", "funk", 0, 3, 0.4),
                ListeningPocketsRoundLearning.Weight("genre", "soul", 3, 0, 1.6),
            )),
        )))
        val out = picks(input(results = r))
        assertEquals(0.4, out.targets.first { it.value == "funk" }.weight, 0.0)
        assertEquals("a target that keeps predicting well is added (0.3 × 1.6)", 0.48, out.targets.first { it.value == "soul" }.weight, 1e-9)
        assertEquals("re-sorted by weight", "soul", out.targets.first().value)
    }

    @Test fun learningFallsBackFromExactKeyToRelaxedKey() {
        val r = results(cloudJSON).copy(roundLearning = ListeningPocketsRoundLearning(contexts = listOf(
            ListeningPocketsRoundLearning.Context("weekday|evening|*", 5, listOf(
                ListeningPocketsRoundLearning.Weight("genre", "funk", 0, 3, 0.5),
            )),
        )))
        assertEquals(0.5, picks(input(results = r)).targets.first { it.value == "funk" }.weight, 0.0)
    }

    @Test fun addRuleNeedsAtLeastTwoPositivesAndMultiplierOver125() {
        fun withWeight(pos: Int, mult: Double) = results(cloudJSON).copy(roundLearning = ListeningPocketsRoundLearning(contexts = listOf(
            ListeningPocketsRoundLearning.Context("weekday|evening|*", 5, listOf(
                ListeningPocketsRoundLearning.Weight("genre", "soul", pos, 0, mult),
            )),
        )))
        assertTrue(picks(input(results = withWeight(2, 1.25))).targets.any { it.value == "soul" })
        assertFalse("one positive is not enough", picks(input(results = withWeight(1, 1.5))).targets.any { it.value == "soul" })
        assertFalse("multiplier below 1.25", picks(input(results = withWeight(3, 1.2))).targets.any { it.value == "soul" })
    }

    @Test fun localRoundsLearnWhenTheCloudHasNoRoundsSection() {
        val pocket = TestRounds.round(listOf("a", "b", "c"), InThePocketOutcome.Pocket)
        val early = TestRounds.round(listOf("a", "b", "c"), InThePocketOutcome.Broke(1),
            targets = listOf(InThePocketTarget("genre", "funk", "Funk", 1.0)))
        // Same context as the evening-at-A round: the relaxed key matches ("weekday|evening|*").
        val l = InThePocketScorer.learning(input(pastRounds = listOf(pocket, pocket, early)))
        assertEquals(InThePocketLearning.multiplier(2, 1), l[InThePocketLearning.targetKey("genre", "funk")]!!.multiplier, 0.0)
        assertEquals(2, l[InThePocketLearning.targetKey("genre", "funk")]!!.pos)
    }

    @Test fun normalizeKeepsTopSixStrongestIsOneWithDimValueTiebreak() {
        val ts = listOf(
            InThePocketTarget("genre", "b", "B", 2.0), InThePocketTarget("genre", "a", "A", 2.0),
            InThePocketTarget("artist", "z", "Z", 1.0), InThePocketTarget("mood", "m", "M", 0.5),
            InThePocketTarget("genre", "c", "C", 0.4), InThePocketTarget("genre", "d", "D", 0.3),
            InThePocketTarget("genre", "e", "E", 0.2), InThePocketTarget("genre", "zero", "0", 0.0),
        )
        val n = InThePocketScorer.normalize(ts)
        assertEquals(6, n.size)
        assertEquals(listOf("a", "b", "z", "m", "c", "d"), n.map { it.value })
        assertEquals(listOf(1.0, 1.0, 0.5, 0.25, 0.2, 0.15), n.map { it.weight })
        assertTrue(InThePocketScorer.normalize(emptyList()).isEmpty())
    }

    @Test fun bandIsAtLeastSixWideAndRoundedToWholeBeats() {
        assertEquals(118.0..126.0, InThePocketScorer.normalizedBand(118.2, 125.6))
        assertEquals(117.0..123.0, InThePocketScorer.normalizedBand(120.0, 120.0))
        assertEquals(117.0..124.0, InThePocketScorer.normalizedBand(120.0, 121.0))   // mid 120.5 -> floor(117.5), ceil(123.5)
        assertEquals("swapped lo/hi", 100.0..110.0, InThePocketScorer.normalizedBand(110.0, 100.0))
    }

    @Test fun foldBpmAndGenreLabels() {
        assertEquals(120.0, InThePocketScorer.foldBpm(60.0)!!, 0.0)
        assertEquals(87.5, InThePocketScorer.foldBpm(175.0)!!, 0.0)
        assertNull(InThePocketScorer.foldBpm(0.0)); assertNull(InThePocketScorer.foldBpm(null))
        assertEquals("R&B", InThePocketScorer.genreLabel("r&b")); assertEquals("EDM", InThePocketScorer.genreLabel("edm"))
        assertEquals("Hip-Hop", InThePocketScorer.genreLabel("hip-hop")); assertEquals("Funk", InThePocketScorer.genreLabel("funk"))
    }

    @Test fun familiarityIsLaplaceSmoothedAndNeverPlayedIsZero() {
        val f = InThePocketScorer.familiarity(listOf(play("a", 1.0), play("a", 2.0), play("b", 1.0, skipped = true)))
        // a: n=2,k=0 -> rate 3/4 -> 0.6*0.25 + 0.3*2/5
        assertEquals(0.6 * 0.25 + 0.3 * 0.4, f["a"]!!, 1e-12)
        // b: n=0,k=1 -> rate 1/3 -> negative
        assertEquals(0.6 * (1.0 / 3 - 0.5), f["b"]!!, 1e-12)
        assertNull(f["never"])
    }

    @Test fun coherencePenalisesSameArtistAndRewardsSharedGenreAndTempo() {
        val a = catalog["f1"]!!
        val pick = InThePocketScorer.Pick(a, 1.0, emptyList())
        val sameArtist = a.copy(id = "x")
        assertEquals(0.3 + 0.3 - 1.0, InThePocketScorer.coherence(sameArtist, listOf(pick)), 1e-12)
        val other = catalog["f2"]!!
        assertEquals(0.3 + 0.3 * Math.exp(-2.0 / 10), InThePocketScorer.coherence(other, listOf(pick)), 1e-12)
        // Different genre, tempo 90 vs 118: only the tempo term.
        assertEquals(0.3 * Math.exp(-28.0 / 10), InThePocketScorer.coherence(catalog["j1"]!!, listOf(pick)), 1e-12)
    }

    // MARK: - Membership (pockets × collections)

    @Test fun addScaleHalvesTowardHalfAsAddsAge() {
        val m = InThePocketMembership
        assertEquals(0.75, m.addScale(null, NOW), 0.0)
        assertEquals(1.0, m.addScale(NOW, NOW), 1e-12)
        assertEquals("a future add clamps to age 0", 1.0, m.addScale(NOW + 1e9, NOW), 1e-12)
        assertEquals(0.5 + 0.5 * Math.exp(-1.0), m.addScale(NOW - 45 * 86_400_000.0, NOW), 1e-12)
    }

    @Test fun normalizeMembershipKeepsTop12L1AndRoundsTo1e4() {
        val raw = (1..15).associate { "c%02d".format(it) to it.toDouble() } + ("neg" to -1.0) + ("nan" to Double.NaN)
        val n = InThePocketMembership.normalizeMembership(raw)
        assertEquals(12, n.size)
        assertTrue("c15" in n && "c04" in n); assertFalse("c03" in n)
        assertEquals(1.0, n.values.sum(), 2e-3)
        assertEquals(Math.round(15.0 / 114.0 * 10_000) / 10_000.0, n["c15"]!!, 1e-12)
        assertTrue(InThePocketMembership.normalizeMembership(mapOf("a" to 0.0)).isEmpty())
    }

    private fun funkCollections(): List<InThePocketScorer.CollectionInfo> = listOf(
        InThePocketScorer.CollectionInfo("pl_funk", "Funk Night", setOf("f1", "f2", "f3")),
    )

    private fun eveningFunkPlays() = (1..4).flatMap { d ->
        listOf(play("f1", d * 24.0), play("f2", d * 24.0 - 0.1), play("f3", d * 24.0 - 0.2))
    }

    @Test fun centroidNeedsThreeResolvableMembersAndSimilarityNeedsCoverage() {
        val two = InThePocketScorer.CollectionInfo("c", null, setOf("f1", "f2"))
        assertNull(Centroid.of(two, catalog))
        val cen = Centroid.of(funkCollections()[0], catalog)!!
        assertEquals(1.0, cen.genreShare["funk"]!!, 0.0)
        assertEquals(120.0, cen.bpmMedian!!, 0.0)
        assertEquals(0, cen.keyed)
        // genre (0.35) + bpm (0.25) = 0.6 >= 0.45 coverage.
        val sim = InThePocketMembership.similarity(catalog["f4"]!!, cen)
        assertTrue(sim > 0.5 && sim <= 1.0)
        // Only a mood on the song, none on the collection -> too little shared to judge.
        val moodOnly = InThePocketScorer.Song("m", "m", "m", moods = listOf("happy"))
        assertEquals(0.0, InThePocketMembership.similarity(moodOnly, cen), 0.0)
    }

    @Test fun softMembershipIsSixTenthsOfSimilarityAboveThreshold() {
        val index = MembershipIndex(input(collections = funkCollections()))
        val pull = MembershipPull.create(mapOf("pl_funk" to 1.0), index, input(collections = funkCollections()))!!
        val cen = Centroid.of(funkCollections()[0], catalog)!!
        val v = pull.vector(catalog["f4"]!!, NOW)
        assertEquals(0.6 * InThePocketMembership.similarity(catalog["f4"]!!, cen), v["pl_funk"]!!, 1e-12)
        // A hard member gets the add-scale (unknown add => 0.75), not the soft value.
        assertEquals(0.75, pull.vector(catalog["f1"]!!, NOW)["pl_funk"]!!, 0.0)
        // Jazz at 90 BPM is nowhere near the funk centroid -> no soft membership -> no cosine.
        assertNull(pull.cosine(catalog["j1"]!!, NOW))
    }

    @Test fun collectionPlaysPullSimilarSongsInAndRecordCollectionTargets() {
        val inp = input(results = null, plays = eveningFunkPlays(), collections = funkCollections())
        val scored = InThePocketScorer.scoreCandidates(inp)
        assertTrue(scored.profile.membership.containsKey("pl_funk"))
        val f4 = scored.scored.first { it.song.id == "f4" }
        assertTrue(f4.why.contains("Like Funk Night"))
        val out = picks(inp)
        val ct = out.targets.filter { it.dim == "collection" }
        assertEquals(1, ct.size)
        assertEquals("pl_funk", ct[0].value); assertEquals("Funk Night", ct[0].label); assertEquals(1.0, ct[0].weight, 0.0)
        // No collections on the device -> the scorer is untouched (no membership, no collection targets).
        val plain = InThePocketScorer.scoreCandidates(input(results = null, plays = eveningFunkPlays()))
        assertTrue(plain.profile.membership.isEmpty())
    }

    @Test fun liveSessionPullNudgesTheProfileFromTheLastHour() {
        // Plays > 48h ago are not excluded but irrelevant; a play 30 minutes ago in the collection adds live pull.
        val plays = listOf(play("f1", 0.5))
        val scored = InThePocketScorer.scoreCandidates(input(results = null, plays = plays, collections = funkCollections()))
        assertEquals(setOf("pl_funk"), scored.profile.membership.keys)
        // A skipped or older-than-an-hour play adds nothing.
        val none = InThePocketScorer.scoreCandidates(
            input(results = null, plays = listOf(play("f1", 0.5, skipped = true), play("j1", 2.0)), collections = funkCollections()))
        assertTrue(none.profile.membership.isEmpty())
    }

    @Test fun collectionLearningReweightsOrAddsMembership() {
        val r = results(cloudJSON).copy(roundLearning = ListeningPocketsRoundLearning(contexts = listOf(
            ListeningPocketsRoundLearning.Context("weekday|evening|*", 6, listOf(
                ListeningPocketsRoundLearning.Weight("collection", "pl_funk", 3, 0, 1.6),
                ListeningPocketsRoundLearning.Weight("collection", "pl_gone", 3, 0, 1.6),
            )),
        )))
        val scored = InThePocketScorer.scoreCandidates(input(results = r, collections = funkCollections()))
        // pl_funk joins (>=2 positives, multiplier >= 1.25, the device still has it); pl_gone does not.
        assertEquals(setOf("pl_funk"), scored.profile.membership.keys)
    }

    @Test fun candidateBoostFromCloudCollectionCandidatesMakesASongRelated() {
        val json = cloudJSON.replace("\"topSongs\":[{\"songId\":\"f1\",\"plays\":3},{\"songId\":\"s1\",\"plays\":2}]",
            "\"topSongs\":[{\"songId\":\"f1\",\"plays\":3}],\"collectionCandidates\":[{\"songId\":\"j2\",\"score\":2.0,\"via\":[\"pl_x\"]}]")
        val scored = InThePocketScorer.scoreCandidates(input(results = results(json)))
        val j2 = scored.scored.firstOrNull { it.song.id == "j2" }
        assertNotNull(j2)
        assertTrue(j2!!.why.contains("From your collections"))
    }

    @Test fun camelotAdjacencyIsNeighbourNumbersAndRelativeMode() {
        val a = InThePocketMembership::camelotAdjacent
        assertTrue(a("8A", "8B")); assertTrue(a("8A", "9A")); assertTrue(a("12A", "1A")); assertTrue(a(" 1b", "12B"))
        assertFalse(a("8A", "9B")); assertFalse(a("8A", "10A")); assertFalse(a("13A", "1A")); assertFalse(a("8C", "8A"))
    }
}

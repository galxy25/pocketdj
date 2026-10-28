package com.levi.pocketdj.data.recs

import com.levi.pocketdj.data.catalog.IndexSong
import kotlinx.serialization.json.Json
import kotlinx.serialization.json.JsonArray
import kotlinx.serialization.json.JsonObject
import kotlinx.serialization.json.doubleOrNull
import kotlinx.serialization.json.jsonArray
import kotlinx.serialization.json.jsonObject
import kotlinx.serialization.json.jsonPrimitive
import org.junit.Assert.assertEquals
import org.junit.Assert.assertNotNull
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test
import kotlin.math.sqrt

class SimilarityParityTest {
    private val eps = 1e-9
    private val F = SimilarityFamilies

    private val fx: JsonObject by lazy {
        val text = javaClass.getResourceAsStream("/recs/similarity-parity.json")!!.bufferedReader().readText()
        Json.parseToJsonElement(text).jsonObject
    }

    private fun JsonObject.d(k: String) = getValue(k).jsonPrimitive.content.toDouble()
    private fun vec(o: JsonObject): Map<String, Double> = o.mapValues { it.value.jsonPrimitive.content.toDouble() }

    @Test fun constantsAreVerbatim() {
        assertEquals(
            listOf("bright", "brightVar", "air", "width", "noisy", "fizz", "punch", "busy", "dynamic", "loud", "m1", "m2", "m3", "m4"),
            F.TIMBRE_AXES,
        )
        assertEquals(8, F.TIMBRE_MIN_SHARED_AXES)
        assertEquals(0.12, F.TIMBRE_DECAY, 0.0)
        assertEquals(1, F.TIMBRE_VERSION) // pinned: bumping the calibration must be a conscious edit here too
        assertEquals(3, F.TIMBRE_MIN_VECTORS)
        assertEquals(2.0, F.TIMBRE_PRIOR, 0.0)
        assertEquals(2.0, F.MUSICAL_PRIOR, 0.0)
        assertEquals(25, F.MIN_OBSERVATIONS_FOR_ROUND_NEUTRAL)
        assertEquals(0.70, F.familyTotal, eps)
    }

    @Test fun eraWindowMatchesFixture() {
        val era = fx.getValue("era").jsonObject
        val years = era.getValue("years").jsonArray.map { it.jsonPrimitive.content.toDouble() }
        val w = F.eraWindow(years)!!
        assertEquals(era.d("lo"), w.lo, eps)
        assertEquals(era.d("hi"), w.hi, eps)
        for (p in era.getValue("probes").jsonArray) {
            val o = p.jsonObject
            assertEquals(o.d("fit"), F.eraFit(o.d("y"), w), eps)
        }
    }

    @Test fun eraWindowIsP15P85PaddedAndFlatInside() {
        // 808 & Swinging-style spread: a 1970s core with tails.
        val w = F.eraWindow(listOf(1969.0, 1972.0, 1973.0, 1975.0, 1975.0, 1976.0, 1979.0, 1981.0, 1984.0, 1990.0, 1994.0, 2001.0))!!
        assertEquals(1970.0, w.lo, 0.0) // p15 -> ceil(1.8)-1 = idx1 = 1972, minus 2
        assertEquals(1996.0, w.hi, 0.0) // p85 -> ceil(10.2)-1 = idx10 = 1994, plus 2
        assertEquals(1.0, F.eraFit(1970.0, w), 0.0)
        assertEquals(1.0, F.eraFit(1996.0, w), 0.0)
        assertEquals(Math.exp(-1.0), F.eraFit(2000.0, w), eps)
        assertEquals(Math.exp(-0.5), F.eraFit(1968.0, w), eps)
        assertNull(F.eraWindow(emptyList()))
        assertNull(F.eraWindow(listOf(0.0, -4.0, Double.NaN)))
    }

    @Test fun undatedCandidateScoresRoundNeutralNeverZero() {
        val w = SimilarityFamilies.EraWindow(1970.0, 1990.0)
        val fallback = F.eraCalibrate(listOf(1975.0, null), w)
        assertEquals(F.FALLBACK_NEUTRAL_ERA_FIT, fallback.neutral, 0.0)
        assertTrue(!fallback.usedRoundMean)
        assertEquals(0.76, F.eraFit(null, w, fallback), 0.0)
        assertEquals(0.76, F.eraFit(0.0, w, fallback), 0.0)
        // 25 observations => the round's own mean.
        val years = List(25) { if (it < 20) 1980.0 else 2000.0 }
        val cal = F.eraCalibrate(years, w)
        assertTrue(cal.usedRoundMean)
        val expected = (20 * 1.0 + 5 * Math.exp(-10.0 / 4)) / 25
        assertEquals(expected, cal.neutral, eps)
        assertEquals(expected, F.eraFit(null, w, cal), eps)
        assertTrue(F.eraFit(null, w, cal) > 0)
    }

    @Test fun camelotRelatednessTable() {
        for (r in fx.getValue("musical").jsonObject.getValue("rel").jsonArray) {
            val o = r.jsonObject
            assertEquals(o.d("r"), F.camelotRelatedness(o.getValue("a").jsonPrimitive.content, o.getValue("b").jsonPrimitive.content), 0.0)
        }
        assertEquals(1.0, F.camelotRelatedness("8a", " 8A "), 0.0)
        assertEquals(0.75, F.camelotRelatedness("8A", "8B"), 0.0)
        assertEquals(0.6, F.camelotRelatedness("12A", "1A"), 0.0) // wheel wraps
        assertEquals(0.6, F.camelotRelatedness("1A", "12A"), 0.0)
        assertEquals(0.0, F.camelotRelatedness("8A", "9B"), 0.0)
        assertEquals(0.0, F.camelotRelatedness("13A", "1A"), 0.0)
        assertEquals(0.0, F.camelotRelatedness("junk", "1A"), 0.0)
    }

    @Test fun musicalProfileAndDensitiesMatchFixture() {
        val m = fx.getValue("musical").jsonObject
        val members = m.getValue("members").jsonArray.map {
            val o = it.jsonObject
            SimilarityFamilies.MusicalMember(
                o["bpm"]?.jsonPrimitive?.doubleOrNull,
                o["camelot"]?.jsonPrimitive?.takeIf { p -> p.content != "null" }?.content,
                o.d("weight"),
            )
        }
        val p = F.musicalProfile(members)
        val modes = m.getValue("modes").jsonArray
        assertEquals(modes.size, p.tempoModes.size)
        modes.forEachIndexed { i, e ->
            assertEquals(e.jsonObject.d("bpm"), p.tempoModes[i].bpm, 0.0)
            assertEquals(e.jsonObject.d("weight"), p.tempoModes[i].weight, eps)
        }
        assertTrue(p.tempoModes.size <= F.MAX_TEMPO_MODES)
        assertEquals(m.d("tempoPeak"), p.tempoPeak, eps)
        assertEquals(m.d("camelotPeak"), p.camelotPeak, eps)
        for (b in m.getValue("bpmProbes").jsonArray) {
            assertEquals(b.jsonObject.d("aff"), F.bpmAffinity(b.jsonObject.d("bpm"), p), eps)
        }
        for (c in m.getValue("camProbes").jsonArray) {
            assertEquals(c.jsonObject.d("aff"), F.camelotAffinity(c.jsonObject.getValue("code").jsonPrimitive.content, p), eps)
        }
    }

    @Test fun bpmDensityHalfDoubleAndTriplet() {
        val p = F.musicalProfile(listOf(SimilarityFamilies.MusicalMember(120.0, null, 1.0)))
        assertEquals(1.0, F.bpmAffinity(120.0, p), eps)
        assertEquals(1.0, F.bpmAffinity(60.0, p), eps)  // half-time
        assertEquals(1.0, F.bpmAffinity(240.0, p), eps) // double-time
        assertEquals(0.6, F.bpmAffinity(80.0, p), eps)  // 2:3 triplet
        assertEquals(0.6, F.bpmAffinity(180.0, p), eps) // 3:2 triplet
        assertTrue(F.bpmAffinity(100.0, p) < 0.1)
        assertEquals(0.0, F.bpmAffinity(null, p), 0.0)
        assertEquals(0.0, F.bpmAffinity(0.0, p), 0.0)
        // bpm 119.6 and 120.4 round to 120 and 120 -> one mode; half-away rounding at .5
        val q = F.musicalProfile(listOf(SimilarityFamilies.MusicalMember(119.5, null, 1.0)))
        assertEquals(120.0, q.tempoModes.single().bpm, 0.0)
    }

    @Test fun musicalFitShrinksTowardNeutralAndEmptyProfileFallsBack() {
        val p = F.musicalProfile(listOf(SimilarityFamilies.MusicalMember(120.0, "8A", 1.0)))
        val cal = SimilarityFamilies.MusicalCalibration(neutral = 0.4, observations = 30)
        // both axes perfect: raw 1.0, n=2 -> (2*0.4 + 2*1)/4
        assertEquals((2 * 0.4 + 2 * 1.0) / 4, F.musicalFit(120.0, "8A", p, cal), eps)
        // one axis only: n=1
        assertEquals((2 * 0.4 + 1 * 1.0) / 3, F.musicalFit(120.0, null, p, cal), eps)
        // nothing to compare -> the round neutral, not 0
        assertEquals(0.4, F.musicalFit(null, null, p, cal), 0.0)
        assertTrue(F.musicalProfile(emptyList()).isEmpty)
        assertEquals(SimilarityFamilies.MusicalCalibration(), F.calibrate(listOf(SimilarityFamilies.BpmCamelot(120.0, "8A")), SimilarityFamilies.MusicalProfile()))
    }

    @Test fun timbreRmsNotEuclidean() {
        val a = F.TIMBRE_AXES.associateWith { 0.0 }
        val b = F.TIMBRE_AXES.associateWith { 0.3 }
        // 14 shared axes, each diff 0.3 -> RMS 0.3 (euclidean would be 0.3*sqrt(14)).
        assertEquals(0.3, F.timbreDistance(a, b)!!, eps)
        assertEquals(0.3, F.timbreDistance(F.pack(a), F.pack(b))!!, eps)
        assertTrue(0.3 * sqrt(14.0) > 1.0)
        // 8 shared axes is exactly enough, 7 is not.
        val eight = F.TIMBRE_AXES.take(8).associateWith { 0.5 }
        val seven = F.TIMBRE_AXES.take(7).associateWith { 0.5 }
        assertNotNull(F.timbreDistance(eight, b))
        assertNull(F.timbreDistance(seven, b))
        assertNull(F.timbreDistance(F.pack(seven), F.pack(b)))
    }

    @Test fun timbreProfileAndFitMatchFixture() {
        val t = fx.getValue("timbre").jsonObject
        val vs = t.getValue("vectors").jsonArray.map { vec(it.jsonObject) }
        val ws = t.getValue("weights").jsonArray.map { it.jsonPrimitive.content.toDouble() }
        val prof = F.timbreProfile(vs.zip(ws).map { SimilarityFamilies.TimbreMember(it.first, it.second) })!!
        assertEquals(t.d("spread"), prof.spread, eps)
        assertEquals(vs.size, prof.vectors)
        for ((k, v) in vec(t.getValue("centroid").jsonObject)) assertEquals(v, prof.centroid.getValue(k), eps)
        for (p in t.getValue("probes").jsonArray) {
            val o = p.jsonObject
            val v = vec(o.getValue("v").jsonObject)
            assertEquals(o.d("dist"), F.timbreDistance(v, prof.centroid)!!, eps)
            assertEquals(o.d("fit"), F.timbreFit(v, prof)!!, eps)
        }
        val sp = t.getValue("sparse").jsonObject
        assertEquals(sp.d("fit"), F.timbreFit(vec(sp.getValue("v").jsonObject), prof)!!, eps)
    }

    @Test fun timbreFitSaturatesInsideSpreadAndDecaysOutside() {
        val c = F.TIMBRE_AXES.associateWith { 0.5 }
        val prof = SimilarityFamilies.TimbreProfile(c, spread = 0.1, vectors = 5)
        assertEquals(1.0, F.timbreFit(F.TIMBRE_AXES.associateWith { 0.55 }, prof)!!, 0.0)
        assertEquals(1.0, F.timbreFit(F.TIMBRE_AXES.associateWith { 0.6 }, prof)!!, 1e-12) // d == spread
        assertEquals(Math.exp(-0.1 / 0.12), F.timbreFit(F.TIMBRE_AXES.associateWith { 0.7 }, prof)!!, eps)
        assertNull(F.timbreFit(mapOf("bright" to 0.5), prof))
    }

    @Test fun profileBelowMinVectorsIsNullAndDegenerateRowsExcluded() {
        val good = F.TIMBRE_AXES.associateWith { 0.4 }
        val degenerate = F.TIMBRE_AXES.associateWith { 0.0 }
        assertNull(F.timbreProfile(listOf(SimilarityFamilies.TimbreMember(good, 1.0), SimilarityFamilies.TimbreMember(good, 1.0))))
        // third member is degenerate (all zeros) => only 2 usable => still null
        assertNull(F.timbreProfile(listOf(SimilarityFamilies.TimbreMember(good, 1.0), SimilarityFamilies.TimbreMember(good, 1.0), SimilarityFamilies.TimbreMember(degenerate, 1.0))))
        // zero-weight members don't count
        assertNull(F.timbreProfile(listOf(SimilarityFamilies.TimbreMember(good, 1.0), SimilarityFamilies.TimbreMember(good, 1.0), SimilarityFamilies.TimbreMember(good, 0.0))))
        val p = F.timbreProfile(List(3) { SimilarityFamilies.TimbreMember(good, 1.0) })!!
        assertEquals(0.0, p.spread, eps)
        assertEquals(3, p.vectors)
        assertNotNull(F.timbreProfile(listOf(SimilarityFamilies.TimbreMember(good, 1.0)), minVectors = 1))
    }

    @Test fun timbreCalibrationNeutralAndNetFit() {
        val c = F.TIMBRE_AXES.associateWith { 0.5 }
        val pos = SimilarityFamilies.TimbreProfile(c, 0.1, 5)
        val neg = SimilarityFamilies.TimbreProfile(c, 0.1, 5)
        val near = F.TIMBRE_AXES.associateWith { 0.5 }
        assertEquals(0.5, F.timbreNetFit(near, pos, neg, 0.5)!!, eps) // 1 - 0.5*1
        assertEquals(0.0, F.timbreNetFit(near, pos, neg, 2.0)!!, 0.0) // clamped at 0
        assertEquals(1.0, F.timbreNetFit(near, pos, null, 0.5)!!, 0.0)
        val cal0 = F.timbreCalibrate(listOf(near, null), pos, null, 0.5)
        assertEquals(F.FALLBACK_NEUTRAL_TIMBRE_FIT, cal0.neutral, 0.0)
        assertEquals(1, cal0.observations)
        val cal = F.timbreCalibrate(List(30) { near }, pos, null, 0.5)
        assertTrue(cal.usedRoundMean)
        assertEquals(1.0, cal.neutral, eps)
        val low = SimilarityFamilies.TimbreCalibration(neutral = 0.3, observations = 40)
        assertEquals(0.3, F.timbreFit(null, pos, null, 0.5, low), 0.0) // unanalysed -> neutral
        assertEquals((2 * 0.3 + 1.0) / 3, F.timbreFit(near, pos, null, 0.5, low), eps)
    }

    @Test fun timbreAdjectivesStrongestFirstWithTieBreak() {
        assertEquals(listOf("punchy", "dark", "sparse"), F.timbreAdjectives(mapOf("punch" to 0.95, "bright" to 0.2, "busy" to 0.25, "loud" to 0.55)))
        assertEquals(emptyList<String>(), F.timbreAdjectives(mapOf("punch" to 0.6)))
        // equal strength -> alphabetical
        assertEquals(listOf("dark", "punchy"), F.timbreAdjectives(mapOf("punch" to 0.75, "bright" to 0.25), maxCount = 2))
        assertEquals(listOf("dark"), F.timbreAdjectives(mapOf("punch" to 0.75, "bright" to 0.25), maxCount = 1))
    }

    @Test fun soundAdmitGate() {
        val ok = SimilarityFamilies.TimbreProfile(emptyMap(), spread = 0.2, vectors = 8)
        assertTrue(F.timbreProfileAdmits(ok, 16))
        assertTrue(!F.timbreProfileAdmits(ok, 17)) // < 50% analysed
        assertTrue(!F.timbreProfileAdmits(ok.copy(vectors = 7), 10))
        assertTrue(!F.timbreProfileAdmits(ok.copy(spread = 0.21), 10))
        assertTrue(!F.timbreProfileAdmits(null, 10))
        assertEquals(0.06, F.soundAdmitRadius(0.01), eps) // noise floor .12 - .06
        assertEquals(0.14, F.soundAdmitRadius(0.20), eps)
    }

    @Test fun termWeightsMatchFixtureAndSumToFamilyTotal() {
        for (c in fx.getValue("termWeights").jsonArray) {
            val o = c.jsonObject
            val bal = (o.getValue("balance") as JsonArray).map { it.jsonPrimitive.content.toDouble() }
            val w = F.termWeights(SimilarityFamilies.Balance(bal[0], bal[1], bal[2]), o.d("g") == 1.0, o.d("y") == 1.0, o.d("m") == 1.0)
            val e = o.getValue("w").jsonArray.map { it.jsonPrimitive.content.toDouble() }
            assertEquals(e[0], w.artist, eps)
            assertEquals(e[1], w.genre, eps)
            assertEquals(e[2], w.year, eps)
            assertEquals(e[3], w.musical, eps)
            assertEquals(0.70, w.total, eps)
        }
        val all = F.termWeights(SimilarityFamilies.Balance.EVEN, true, true, true)
        assertEquals(0.25 / 1.0 * 0.70, all.artist, eps)
        assertEquals(0.0, F.termWeights(SimilarityFamilies.Balance(0.0, 0.0, 0.0), true, true, true).total, 0.0)
        assertEquals(0.0, SimilarityFamilies.Balance.of(-1.0, 2.0, -3.0).artist, 0.0)
    }

    @Test fun familyScoresAndLeading() {
        val s = F.scores(artistFit = 0.9, genreFit = 0.5, yearFit = 0.7, musicalFit = null)
        assertEquals(0.9, s.artist!!, 0.0)
        assertEquals(0.6, s.genreYear!!, eps)
        assertEquals(0.5, s.genreMusical!!, eps) // lone field carries the family
        assertEquals("artist", s.leading)
        assertNull(F.scores(null, null, null, null).leading)
        assertEquals("artist", SimilarityFamilies.Scores(0.5, 0.5, 0.5).leading) // first wins on ties
        assertEquals("groove", SimilarityFamilies.Scores(0.1, 0.2, 0.3).leading)
    }

    @Test fun canonicalGenreBlankIsNull() {
        assertNull(F.canonicalGenre(null))
        assertNull(F.canonicalGenre("   "))
        assertNotNull(F.canonicalGenre("Hip-Hop/Rap"))
    }

    @Test fun balancedProfileScoresAndNilBalanceIsSevenTerm() {
        fun song(id: String, artist: String, year: Int?, bpm: Double?, cam: String?) =
            IndexSong(id = id, artist = artist, name = id, year = year, bpm = bpm, camelot = cam)
        val songs = listOf(
            song("a", "Artist One", 1975, 120.0, "8A"),
            song("b", "Artist One", 1977, 122.0, "9A"),
            song("c", "The Other", 1980, 118.0, "8A"),
        ).associateBy { it.id }
        val genres = mapOf("a" to "Rock", "b" to "Rock", "c" to "Jazz")
        val plain = Similarity.profile(listOf(listOf("a", "b", "c")), songs, genres, emptyList(), emptyList())
        assertNull(plain.terms)
        assertEquals(0.70, plain.availableWeight, eps)
        val bal = Similarity.profile(listOf(listOf("a", "b", "c")), songs, genres, emptyList(), emptyList(), balance = SimilarityFamilies.Balance.EVEN)
        assertNotNull(bal.terms)
        assertEquals(0.70, bal.availableWeight, eps)
        assertTrue(!bal.musical.isEmpty)
        // member song scores high; a far-off song scores lower
        val near = Similarity.score(songs.getValue("a"), bal, "Rock")
        val far = Similarity.score(song("z", "Nobody", 2020, 60.0, "3B"), bal, "Classical")
        assertTrue(near > far)
        assertTrue(near in 0.0..1.0)
        // plain (no balance) ignores musical entirely: same score regardless of bpm.
        assertEquals(
            Similarity.score(song("q", "Artist One", 1976, 60.0, "3B"), plain, "Rock"),
            Similarity.score(song("q", "Artist One", 1976, 200.0, "9B"), plain, "Rock"),
            0.0,
        )
        val fam = Similarity.familyScores(songs.getValue("a"), bal, "Rock")
        assertNotNull(fam.genreMusical)
        assertTrue(plain.musical.isEmpty) // no balance => no musical profile
        assertTrue(Similarity.profile(emptyList(), songs, genres, emptyList(), emptyList()).isEmpty)
    }
}

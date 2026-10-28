package com.levi.pocketdj.data.pockets

import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNotNull
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test

/** Lenient `GET /pockets/results` decode (the iOS `lp*` rules), incl. the captured lambda fixture. */
class PocketsModelsTest {

    private fun parse(json: String) = ListeningPocketsResults.parse(json)!!

    @Test fun capturedLambdaResultsFixtureDecodes() {
        val text = javaClass.classLoader!!.getResource("fixtures/pockets_results_sample.json")!!.readText()
        val r = parse(text)
        assertEquals(1, r.v)
        assertNotNull(r.generatedAtMs)
        assertEquals("algo.version is nested", 2, r.algoVersion)
        assertEquals(38, r.pockets.size)
        assertEquals(7, r.patterns.size)
        assertEquals(259, r.baseline!!.plays); assertEquals(false, r.baseline!!.thin)
        assertEquals(0, r.collectionsSeen)
        assertNull("no rounds section => no round learning", r.roundLearning)
        assertEquals(3, r.labels!!.places.size); assertEquals(2, r.labels!!.trips.size)
        assertEquals("Location A", r.snapshotLabel(ListeningContextTag.place("plc_78da6e61747eab53")))
        assertEquals("A → B", r.snapshotLabel(ListeningContextTag(ListeningContextTag.KIND_TRIP, tripId = "trp_f2207a561d231522")))
        assertNull(r.snapshotLabel(ListeningContextTag.place("plc_unknown")))
        val p = r.pockets[0]
        assertEquals("pk_65313e13ce15", p.id)
        assertEquals(6, p.members.size)
        assertEquals(p.members.map { it.songId }, p.songIds)
        assertEquals("morning", p.timeBucket)
        assertTrue(p.numeric.containsKey("bpm"))
        assertNotNull(p.harmonic)
        assertTrue("every pocket kept its id", r.pockets.all { it.id.isNotEmpty() })
        assertTrue(r.patterns.all { it.topSongs.isNotEmpty() })
    }

    @Test fun emptyShapeHasNoGeneratedAt() {
        val r = parse("""{"v":1,"generatedAtMs":null,"stale":false,"pockets":[],"patterns":[]}""")
        assertNull(r.generatedAtMs); assertNull(r.roundLearning); assertNull(r.algoVersion)
        assertEquals(ListeningPocketsResults.EMPTY.v, r.v)
        assertNull("not an object", ListeningPocketsResults.parse("[1,2]"))
        assertNull("not json", ListeningPocketsResults.parse("<html>"))
    }

    @Test fun aBadElementIsDroppedNotTheDocument() {
        val r = parse("""
        {"v":1,"generatedAtMs":1,"stale":true,
         "pockets":[{"id":"pk_1","startMs":1,"title":"ok"}, {"startMs":1}, 7, null, {"id":5}, {"id":"pk_2"}],
         "patterns":[{"id":"pt_1","topSongs":[{"songId":"a","plays":2},{"plays":3},"x",{"songId":"b"}],
                      "features":[{"dim":"genre","value":"funk"},{"dim":"genre"},{"value":"x"}]},
                     {"key":"no id"}]}
        """)
        assertTrue(r.stale)
        assertEquals(listOf("pk_1", "pk_2"), r.pockets.map { it.id })
        assertEquals(1, r.patterns.size)
        assertEquals(listOf("a", "b"), r.patterns[0].topSongs.map { it.songId })
        assertEquals(listOf(2, 0), r.patterns[0].topSongs.map { it.plays })
        assertEquals(1, r.patterns[0].features.size)
        // Defaults for the optional bits.
        assertEquals("Listening pocket", r.pockets[1].title)
        assertEquals("pt_1", r.patterns[0].key); assertEquals("Recurring pocket", r.patterns[0].title)
        assertEquals("endMs falls back to startMs", r.pockets[0].startMs, r.pockets[0].endMs, 0.0)
        assertEquals("Funk-less label falls back to value", "funk", r.patterns[0].features[0].label)
        assertEquals(1.0, r.patterns[0].features[0].lift, 0.0)
    }

    @Test fun numbersReadIntegralOrNotAndStringsAreRejected() {
        val r = parse("""
        {"v":1.0,"generatedAtMs":"soon","stale":"yes","algo":{"version":3.0},
         "baseline":{"plays":259.0,"windowDays":90,"thin":"no"},
         "pockets":[{"id":"pk_1","tzOffsetMin":-420.0,"dow":3.2,"memberCount":"6","skippedCount":2}],"patterns":[]}
        """)
        assertEquals("3.0 reads as an Int", 3, r.algoVersion)
        assertEquals(1, r.v)
        assertNull("a string is not a number", r.generatedAtMs)
        assertFalse("a string is not a bool", r.stale)
        assertEquals(259, r.baseline!!.plays); assertNull(r.baseline!!.thin)
        val p = r.pockets[0]
        assertEquals(-420, p.tzOffsetMin); assertEquals("3.2 rounds", 3, p.dow)
        assertEquals("string memberCount falls back to members.size", 0, p.memberCount)
        assertEquals(2, p.skippedCount)
    }

    @Test fun missingRoundsIsNullAndPresentRoundsDecodeLeniently() {
        val json = """
        {"v":1,"generatedAtMs":1,"stale":false,"pockets":[],"patterns":[],
         "rounds":{"v":1,"total":3,"pocket":2,"broke":1,"abandoned":0,"pocketRate":0.667,
           "contexts":[{"key":"weekday|evening|*","rounds":3,
              "weights":[{"dim":"genre","value":"funk","pos":2,"neg":1,"multiplier":1.2},{"dim":"genre"}]},
            {"rounds":1}]}}
        """
        val l = parse(json).roundLearning!!
        assertEquals(listOf(3, 2, 1), listOf(l.total, l.pocket, l.broke))
        assertEquals(0.667, l.pocketRate!!, 0.0)
        assertEquals("a context without a key is dropped, not the document", 1, l.contexts.size)
        assertEquals(listOf(ListeningPocketsRoundLearning.Weight("genre", "funk", 2, 1, 1.2)), l.contexts[0].weights)
        assertNull(parse("""{"v":1,"generatedAtMs":null,"stale":false,"pockets":[],"patterns":[]}""").roundLearning)
        assertNull("rounds that is not an object", parse("""{"v":1,"rounds":5}""").roundLearning)
    }

    @Test fun numericMapDropsBadKeysOneByOne() {
        val r = parse("""
        {"v":1,"generatedAtMs":1,"pockets":[{"id":"pk_1","numeric":{
           "bpm":{"center":121,"lo":118,"hi":126,"coverage":1,"defining":true},
           "energy":{"lo":1},"year":"x","key":{"center":5}}}],"patterns":[]}
        """)
        val n = r.pockets[0].numeric
        assertEquals(setOf("bpm", "key"), n.keys)
        assertEquals(118.0, n["bpm"]!!.lo, 0.0); assertTrue(n["bpm"]!!.defining)
        assertEquals("lo/hi default to center", 5.0, n["key"]!!.lo, 0.0)
        assertEquals(0.0, n["key"]!!.coverage, 0.0)
    }

    @Test fun contextKeepsOnlyPlaceOrTripAndUnknownDimStaysRaw() {
        val r = parse("""
        {"v":1,"generatedAtMs":1,"patterns":[],"pockets":[
          {"id":"a","ctx":{"kind":"place","placeId":"plc_1"}},
          {"id":"b","ctx":{"kind":"none"}},
          {"id":"c","ctx":{"kind":"trip","tripId":"trp_1","origin":"plc_1","destination":null}},
          {"id":"d","ctx":{"kind":"trip","tripId":"trp_1"}},
          {"id":"e","ctx":"garbage"},
          {"id":"f","features":[{"dim":"tempo-feel","value":"x","label":"X","score":1},{"dim":"collection","value":"pl_1","score":2}]}]}
        """)
        val by = r.pockets.associateBy { it.id }
        assertEquals("plc_1", by["a"]!!.ctx!!.placeId)
        assertNull(by["b"]!!.ctx); assertNull("trip without origin", by["d"]!!.ctx); assertNull(by["e"]!!.ctx)
        assertTrue(by["c"]!!.ctx!!.isTrip); assertNull(by["c"]!!.ctx!!.destination)
        val f = by["f"]!!.features
        assertEquals("tempo-feel", f[0].dim); assertNull(f[0].kind)
        assertEquals(ListeningPocketDim.COLLECTION, f[1].kind)
        assertFalse(ListeningPocketDim.COLLECTION.isMusical); assertTrue(ListeningPocketDim.GENRE.isMusical)
        assertEquals(ListeningContextTag.place("p"), ListeningPocketFeature("place", "p", "P", 0.0, null, 1.0, 0.0).contextTag)
        assertEquals("trp_9", ListeningPocketFeature("trip", "trp_9", "T", 0.0, null, 1.0, 0.0).contextTag!!.tripId)
        assertNull(ListeningPocketFeature("genre", "funk", "F", 0.0, null, 1.0, 0.0).contextTag)
    }

    @Test fun membershipAndCollectionCandidatesDecode() {
        val r = parse("""
        {"v":1,"generatedAtMs":1,"collectionsSeen":4,"pockets":[
           {"id":"pk","membership":[{"collectionId":"pl_1","weight":0.6},{"collectionId":"pl_2"},{"weight":1}]}],
         "patterns":[{"id":"pt","membership":[{"collectionId":"pl_1","weight":1.0}],
           "collectionCandidates":[{"songId":"s1","score":2.5,"via":["pl_1",3,"pl_2"]},{"score":1}]}]}
        """)
        assertEquals(4, r.collectionsSeen)
        assertEquals(listOf(ListeningPocketMembershipWeight("pl_1", 0.6)), r.pockets[0].membership)
        val c = r.patterns[0].collectionCandidates
        assertEquals(listOf(ListeningPocketCollectionCandidate("s1", 2.5, listOf("pl_1", "pl_2"))), c)
    }

    @Test fun contextTagEncodesOnlyTheIdsItsKindUses() {
        val j = ListeningContextTag.place("plc_1").toJson()
        assertEquals(setOf("kind", "placeId"), j.keys)
        val t = ListeningContextTag.trip("trp_1", "plc_1", null).toJson()
        assertEquals("a nil destination is omitted", setOf("kind", "tripId", "origin"), t.keys)
    }
}

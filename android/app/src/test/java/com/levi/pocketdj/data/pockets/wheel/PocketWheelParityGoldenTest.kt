package com.levi.pocketdj.data.pockets.wheel

import com.levi.pocketdj.data.PdjJson
import com.levi.pocketdj.data.history.PlayEvent
import kotlinx.serialization.Serializable
import kotlinx.serialization.json.Json
import kotlinx.serialization.json.JsonArray
import kotlinx.serialization.json.JsonElement
import kotlinx.serialization.json.JsonNull
import kotlinx.serialization.json.JsonObject
import kotlinx.serialization.json.JsonPrimitive
import kotlinx.serialization.json.boolean
import kotlinx.serialization.json.contentOrNull
import kotlinx.serialization.json.double
import kotlinx.serialization.json.doubleOrNull
import kotlinx.serialization.json.int
import kotlinx.serialization.json.jsonArray
import kotlinx.serialization.json.jsonObject
import kotlinx.serialization.json.jsonPrimitive
import kotlinx.serialization.json.long
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNotNull
import org.junit.Assert.assertTrue
import org.junit.Test
import kotlin.math.abs

/**
 * Cross-platform golden (P2-POC-14): `fixtures/pocket-wheel-parity.json` is dumped from the REAL Swift
 * implementation (`apple/Tests/Unit/PocketWheelParityDumpTests.swift`, run with `PDJ_DUMP_PARITY=1`; this
 * resource is a copy of `apple/Tests/Fixtures/pocket-wheel-parity.json`). The Kotlin wheel must reproduce it
 * at 1e-9 with identical ids / tokens / strings: the moments, the best match at fixed Nows, the first 100
 * rows for fixed seeds and the post-Drake re-plan.
 */
class PocketWheelParityGoldenTest {

    private val eps = 1e-9

    private val golden: JsonObject by lazy {
        val s = javaClass.classLoader!!.getResourceAsStream("fixtures/pocket-wheel-parity.json") ?: error("missing golden")
        Json.parseToJsonElement(s.readBytes().decodeToString()).jsonObject
    }

    // History fixture -> engine input (same as PocketMomentEngineTest)

    @Serializable
    private data class FxSong(val artist: String, val genre: String? = null, val bpm: Double? = null, val year: Int? = null)

    @Serializable
    private data class FxColl(val id: String, val name: String, val songIds: List<String>)

    @Serializable
    private data class Fixture(
        val nowMs: Double, val tzOffsetMin: Int, val librarySize: Int,
        val songs: Map<String, FxSong>, val collections: List<FxColl>, val events: List<PlayEvent>,
    )

    private fun snapshot(): PocketWheelSnapshot {
        val s = javaClass.classLoader!!.getResourceAsStream("fixtures/pocket-wheel-history.json") ?: error("missing fixture")
        val f = PdjJson.lenient.decodeFromString(Fixture.serializer(), s.readBytes().decodeToString())
        return PocketMomentEngine.build(
            PocketMomentEngine.Input(
                events = f.events,
                collections = f.collections.map { PocketMomentEngine.CollectionInfo(it.id, it.name, it.songIds.toSet()) },
                songs = f.songs.mapValues { PocketMomentEngine.SongInfo(it.value.artist, it.value.genre, it.value.bpm, it.value.year) },
                librarySize = f.librarySize, nowMs = f.nowMs,
            ),
        )
    }

    // Generic tolerant JSON comparison: numbers at 1e-9, everything else exact; null == absent.

    private fun JsonElement?.isNullish() = this == null || this is JsonNull

    private fun assertJsonClose(path: String, expected: JsonElement?, actual: JsonElement?) {
        if (expected.isNullish() || actual.isNullish()) {
            assertTrue("$path: expected=$expected actual=$actual", expected.isNullish() && actual.isNullish())
            return
        }
        when (expected) {
            is JsonObject -> {
                val a = actual as? JsonObject ?: error("$path: expected object, got $actual")
                val keys = (expected.keys + a.keys).filter { !(expected[it].isNullish() && a[it].isNullish()) }.toSortedSet()
                for (k in keys) assertJsonClose("$path.$k", expected[k], a[k])
            }
            is JsonArray -> {
                val a = actual as? JsonArray ?: error("$path: expected array, got $actual")
                assertEquals("$path size", expected.size, a.size)
                expected.indices.forEach { assertJsonClose("$path[$it]", expected[it], a[it]) }
            }
            is JsonPrimitive -> {
                val a = actual as? JsonPrimitive ?: error("$path: expected primitive, got $actual")
                val ed = if (expected.isString) null else expected.doubleOrNull
                if (ed != null) {
                    val ad = a.doubleOrNull ?: error("$path: expected number $expected, got $a")
                    assertEquals("$path expected=$ed actual=$ad", ed, ad, eps)
                } else {
                    assertEquals(path, expected.contentOrNull, a.contentOrNull)
                }
            }
        }
    }

    // Moments

    @Test fun momentsMatchTheSwiftSnapshotAt1e9() {
        val expected = PdjJson.lenient.decodeFromString(PocketWheelSnapshot.serializer(), golden["snapshot"]!!.toString())
        val actual = snapshot()
        assertTrue("the golden carries moments", expected.moments.size > 20)
        assertEquals("cell count", expected.moments.size, actual.moments.size)
        fun enc(s: PocketWheelSnapshot) = PdjJson.lenient.encodeToJsonElement(PocketWheelSnapshot.serializer(), s).jsonObject
        val e = enc(expected)
        val a = enc(actual)
        // builtAtMs / historyRevision are bookkeeping of the build, not maths.
        for (k in listOf("moments", "collectionNames", "dominanceOrder", "weekShare", "totalDirectPlays")) {
            assertJsonClose(k, e[k], a[k])
        }
    }

    @Test fun momentOrderAndKeysAreIdentical() {
        val expected = PdjJson.lenient.decodeFromString(PocketWheelSnapshot.serializer(), golden["snapshot"]!!.toString())
        assertEquals(expected.moments.map { it.key.token }, snapshot().moments.map { it.key.token })
    }

    // Best match

    private fun assertProfile(path: String, e: JsonObject, p: PocketProfile) {
        assertEquals("$path tier", e["tier"]!!.jsonPrimitive.content, p.tier.name.lowercase())
        assertEquals("$path caption", e["caption"]!!.jsonPrimitive.content, p.caption)
        assertEquals("$path detail", e["detail"]!!.jsonPrimitive.content, p.detail)
        assertEquals("$path momentKeys", e["momentKeys"]!!.jsonArray.map { it.jsonPrimitive.content }, p.momentKeys.map { it.token })
        assertEquals("$path key", e["key"]?.jsonPrimitive?.content, p.key?.token)
        assertEquals("$path mode", e["mode"]?.jsonPrimitive?.content, p.mode?.token)
        assertEquals("$path dominant", e["dominantCollectionId"]?.jsonPrimitive?.content, p.dominantCollectionId)
        for ((name, m) in listOf("collections" to p.collections, "artists" to p.artists, "genres" to p.genres)) {
            val em = e[name]!!.jsonObject
            assertEquals("$path $name keys", em.keys, m.keys)
            em.forEach { (k, v) -> assertEquals("$path $name[$k]", v.jsonPrimitive.double, m.getValue(k), eps) }
        }
        for ((name, v) in listOf("bpmLo" to p.bpmLo, "bpmHi" to p.bpmHi, "eraLo" to p.eraLo, "eraHi" to p.eraHi)) {
            val ev = e[name]?.jsonPrimitive?.double
            if (ev == null) assertEquals("$path $name absent", null, v) else assertEquals("$path $name", ev, v ?: Double.NaN, eps)
        }
    }

    @Test fun bestMatchAtFixedNowsMatches() {
        val snap = snapshot()
        val cases = golden["bestMatch"]!!.jsonArray
        assertTrue(cases.size >= 6)
        val tiers = HashSet<String>()
        for (c in cases) {
            val co = c.jsonObject
            val name = co["name"]!!.jsonPrimitive.content
            val n = co["now"]!!.jsonObject
            val now = PocketBestMatch.Now(
                hour = n["hour"]!!.jsonPrimitive.double, dow = n["dow"]!!.jsonPrimitive.int,
                mode = n["mode"]?.jsonPrimitive?.content?.let { t -> PocketMode.entries.first { it.token == t } },
                ctx = n["ctx"]?.jsonPrimitive?.content,
                recentCollections = n["recentCollections"]!!.jsonObject.mapValues { it.value.jsonPrimitive.double },
                recentSkipRate = n["recentSkipRate"]?.jsonPrimitive?.double,
            )
            val r = PocketBestMatch.best(snap, now)
            assertProfile("$name profile", co["profile"]!!.jsonObject, r.profile)
            tiers += r.profile.tier.name
            val eAlts = co["alternatives"]!!.jsonArray
            assertEquals("$name alternatives", eAlts.size, r.alternatives.size)
            eAlts.forEachIndexed { i, e -> assertProfile("$name alt$i", e.jsonObject, r.alternatives[i]) }
            val ew = co["winner"]?.jsonObject
            if (ew == null) {
                assertEquals("$name no winner", null, r.winner)
            } else {
                val w = assertNotNull("$name winner", r.winner).let { r.winner!! }
                assertEquals("$name winner key", ew["key"]!!.jsonPrimitive.content, w.key.token)
                assertEquals("$name match", ew["match"]!!.jsonPrimitive.double, w.match, eps)
                assertEquals("$name quality", ew["quality"]!!.jsonPrimitive.double, w.quality, eps)
                assertEquals("$name continuity", ew["continuity"]!!.jsonPrimitive.double, w.continuity, eps)
                assertEquals("$name score", ew["score"]!!.jsonPrimitive.double, w.score, eps)
            }
        }
        assertTrue("the golden exercises more than one tier: $tiers", tiers.size >= 2)
    }

    // First 100 rows

    @Test fun firstHundredRowsPerSeedMatch() {
        val u = PocketRunPlannerTest.universe()
        val runs = golden["runs"]!!.jsonArray
        assertTrue(runs.size >= 2)
        for (run in runs) {
            val ro = run.jsonObject
            val seed = ro["seed"]!!.jsonPrimitive.long.toULong()
            val plan = PocketRunPlanner.plan(PocketRunPlanner.Input(PocketRunPlannerTest.profile(), u, seed = seed))
            val rows = ro["rows"]!!.jsonArray
            assertEquals("seed $seed rows", 100, rows.size)
            assertEquals("seed $seed row count", rows.size, plan.rows.size)
            rows.forEachIndexed { i, e ->
                val eo = e.jsonObject
                val r = plan.rows[i]
                assertEquals("seed $seed slot $i song", eo["songId"]!!.jsonPrimitive.content, r.songId)
                assertEquals("seed $seed slot $i slot", eo["slot"]!!.jsonPrimitive.int, r.slot)
                assertEquals("seed $seed slot $i collection", eo["collectionId"]?.jsonPrimitive?.content, r.collectionId)
                assertEquals("seed $seed slot $i score", eo["score"]!!.jsonPrimitive.double, r.score, eps)
            }
            assertEquals("seed $seed bench count", ro["benchCount"]!!.jsonPrimitive.int, plan.bench.size)
            ro["bench"]!!.jsonArray.forEachIndexed { i, e ->
                assertEquals("seed $seed bench $i", e.jsonObject["songId"]!!.jsonPrimitive.content, plan.bench[i].songId)
                assertEquals("seed $seed bench $i score", e.jsonObject["score"]!!.jsonPrimitive.double, plan.bench[i].score, eps)
            }
        }
        val orders = runs.map { r -> r.jsonObject["rows"]!!.jsonArray.map { it.jsonObject["songId"]!!.jsonPrimitive.content } }
        assertTrue("different seeds give different runs", orders.toSet().size == orders.size)
    }

    // The post-Drake re-plan

    @Test fun postDrakeReplanMatches() {
        val g = golden["replan"]!!.jsonObject
        val u = PocketRunPlannerTest.universe()
        val profile = PocketRunPlannerTest.profile()
        val plan = PocketRunPlanner.plan(PocketRunPlanner.Input(profile, u, seed = g["seed"]!!.jsonPrimitive.long.toULong()))
        val first = plan.rows.first { "drake" in u.getValue(it.songId).features.artistKeys }
        assertEquals(g["skippedSongId"]!!.jsonPrimitive.content, first.songId)
        assertEquals(g["skippedSlot"]!!.jsonPrimitive.int, first.slot)
        val v = PocketTuning.Verdict(first.songId, skipped = true, fraction = 0.08, atMs = 0.0, momentKey = "h08|d2|carPlay", rowCollectionId = first.collectionId)
        assertEquals(g["verdictStrength"]!!.jsonPrimitive.double, v.strength!!, eps)
        val m = PocketTuning.multipliers(PocketTuning.runEvidence(listOf(v)) { u[it]?.features }, allowBans = true)
        val em = g["multipliers"]!!.jsonObject
        assertEquals("multiplier keys", em.keys, m.byKey.keys)
        em.forEach { (k, ev) -> assertEquals("multiplier $k", ev.jsonPrimitive.double, m.byKey.getValue(k), eps) }
        assertEquals(g["bannedArtists"]!!.jsonArray.map { it.jsonPrimitive.content }, m.bannedArtists.sorted())

        val live = plan.rows.filter { it.slot > first.slot }
            .map { PocketRunPlanner.LiveRow("slot${it.slot}", it.songId, it.slot, it.collectionId) }
        val neighbours = live.mapIndexed { i, r ->
            r.uid to PocketRunPlanner.Neighbours(live.getOrNull(i - 1)?.songId, live.getOrNull(i + 1)?.songId)
        }.toMap()
        val result = PocketRunPlanner.replan(
            profile = profile, candidates = u, tuning = m, familiarity = emptyMap(), live = live,
            inRun = plan.rows.map { it.songId }.toSet(), neighbours = neighbours,
        )
        assertEquals(g["banned"]!!.jsonArray.map { it.jsonPrimitive.content }, result.banned)
        val reps = g["replacements"]!!.jsonArray
        assertTrue("the golden replaces some rows", reps.isNotEmpty())
        assertEquals("replacement count", reps.size, result.replacements.size)
        reps.forEachIndexed { i, e ->
            val eo = e.jsonObject
            val r = result.replacements[i]
            assertEquals("rep $i slot", eo["slot"]!!.jsonPrimitive.int, r.slot)
            assertEquals("rep $i song", eo["songId"]!!.jsonPrimitive.content, r.songId)
            assertEquals("rep $i collection", eo["collectionId"]?.jsonPrimitive?.content, r.collectionId)
            assertEquals("rep $i score", eo["score"]!!.jsonPrimitive.double, r.score, eps)
        }
        assertEquals(
            g["removedSlots"]!!.jsonArray.map { it.jsonPrimitive.int },
            result.removals.map { it.removePrefix("slot").toInt() }.sorted(),
        )
        assertFalse(result.replacements.any { "drake" in u.getValue(it.songId).features.artistKeys })
    }

    @Test fun goldenIsVersionedAndNonTrivial() {
        assertEquals(1, golden["v"]!!.jsonPrimitive.int)
        assertTrue(abs(golden["nowMs"]!!.jsonPrimitive.double) > 0)
        assertEquals(setOf("v", "nowMs", "snapshot", "bestMatch", "runs", "replan"), golden.keys)
    }
}

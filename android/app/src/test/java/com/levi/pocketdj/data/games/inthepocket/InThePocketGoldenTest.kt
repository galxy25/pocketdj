package com.levi.pocketdj.data.games.inthepocket

import com.levi.pocketdj.data.games.inthepocket.InThePocketScorer.BuildResult
import com.levi.pocketdj.data.pockets.ListeningContextTag
import com.levi.pocketdj.data.pockets.ListeningPocketsResults
import kotlinx.serialization.json.Json
import kotlinx.serialization.json.JsonArray
import kotlinx.serialization.json.JsonElement
import kotlinx.serialization.json.JsonNull
import kotlinx.serialization.json.JsonObject
import kotlinx.serialization.json.JsonPrimitive
import kotlinx.serialization.json.contentOrNull
import kotlinx.serialization.json.double
import kotlinx.serialization.json.int
import kotlinx.serialization.json.jsonArray
import kotlinx.serialization.json.jsonObject
import kotlinx.serialization.json.jsonPrimitive
import org.junit.Assert.assertEquals
import org.junit.Assert.assertTrue
import org.junit.Test
import java.util.UUID

/**
 * CROSS-PLATFORM GOLDEN (ANS-GM-1 / Q31): the Kotlin [InThePocketScorer] must build exactly what
 * the Swift scorer builds. `fixtures/inthepocket-golden-input.json` (shared byte-for-byte with
 * `apple/Tests/Fixtures`) is run through [InThePocketScorer.build]; the result is compared to
 * `fixtures/inthepocket-golden-expected.json`, which the Swift `InThePocketGoldenTests` WRITES
 * (`PDJ_WRITE_GOLDEN=1`) on My Mac. Picks / modes / targets / chips / why-strings must be equal;
 * doubles within 1e-9. Regenerate the expected file from Swift — never edit it by hand.
 */
class InThePocketGoldenTest {

    private fun resource(name: String): JsonObject {
        val s = javaClass.classLoader!!.getResourceAsStream("fixtures/$name")
            ?: error("missing test resource fixtures/$name")
        return Json.parseToJsonElement(s.readBytes().decodeToString()).jsonObject
    }

    private fun num(e: JsonElement?): Double? = (e as? JsonPrimitive)?.takeIf { it !is JsonNull }?.double
    private fun str(e: JsonElement?): String? = (e as? JsonPrimitive)?.takeIf { it !is JsonNull }?.contentOrNull

    private fun tag(e: JsonElement?): ListeningContextTag? {
        val o = e as? JsonObject ?: return null
        return ListeningContextTag(
            kind = str(o["kind"]) ?: ListeningContextTag.KIND_NONE, placeId = str(o["placeId"]),
            tripId = str(o["tripId"]), origin = str(o["origin"]), destination = str(o["destination"]),
        )
    }

    private fun context(o: JsonObject) = InThePocketContext(
        timeBucket = str(o["timeBucket"])!!, dayType = str(o["dayType"])!!,
        dow = o["dow"]!!.jsonPrimitive.int, ctx = tag(o["ctx"]),
    )

    private fun song(o: JsonObject) = InThePocketScorer.Song(
        id = str(o["id"])!!, title = str(o["title"])!!, artist = str(o["artist"])!!,
        lengthMs = num(o["lengthMs"])?.toInt(), genre = str(o["genre"]), bpm = num(o["bpm"]),
        camelot = str(o["camelot"]), moods = (o["moods"] as? JsonArray)?.map { str(it)!! } ?: emptyList(),
    )

    private fun round(o: JsonObject): InThePocketRound {
        val created = num(o["createdAtMs"])!!
        val outcome = when (str(o["outcome"])) {
            "pocket" -> InThePocketOutcome.Pocket
            "broke" -> InThePocketOutcome.Broke(o["brokeAt"]!!.jsonPrimitive.int)
            else -> InThePocketOutcome.Abandoned
        }
        return InThePocketRound(
            id = UUID.randomUUID(), createdAtMs = created, startedAtMs = created, endedAtMs = created + 900_000,
            updatedAtMs = created + 900_000, tzOffsetMin = -420, context = context(o["context"]!!.jsonObject),
            contextLabel = null, mode = InThePocketMode.CLOUD, seed = "1", algoVersion = 1,
            targets = o["targets"]!!.jsonArray.map {
                val t = it.jsonObject
                InThePocketTarget(str(t["dim"])!!, str(t["value"])!!, str(t["label"])!!, num(t["weight"])!!)
            },
            songs = o["songIds"]!!.jsonArray.map {
                val id = str(it)!!
                InThePocketSong(id, id, "A-$id", null, 1.0, emptyList())
            },
            outcome = outcome, rating = null, feedback = null, appVersion = "golden",
        )
    }

    private fun input(o: JsonObject, catalog: Map<String, InThePocketScorer.Song>): InThePocketScorer.Input {
        val results = (o["results"] as? JsonObject)?.let { ListeningPocketsResults.parse(it.toString()) }
        return InThePocketScorer.Input(
            context = context(o["context"]!!.jsonObject), contextLabel = str(o["contextLabel"]), results = results,
            catalog = catalog, playableIds = o["playableIds"]!!.jsonArray.map { str(it)!! }.toSet(),
            plays = o["plays"]!!.jsonArray.map {
                val p = it.jsonObject
                InThePocketScorer.Play(
                    songId = str(p["songId"])!!, atMs = num(p["atMs"])!!, tzOffsetMin = p["tzOffsetMin"]!!.jsonPrimitive.int,
                    outcome = str(p["outcome"])!!, ctx = tag(p["ctx"]),
                )
            },
            pastRounds = o["pastRounds"]!!.jsonArray.map { round(it.jsonObject) },
            nowMs = num(o["nowMs"])!!, seed = str(o["seed"])!!.toULong(),
            collections = o["collections"]!!.jsonArray.map {
                val c = it.jsonObject
                InThePocketScorer.CollectionInfo(
                    id = str(c["id"])!!, name = str(c["name"]),
                    songIds = c["songIds"]!!.jsonArray.map { s -> str(s)!! }.toSet(),
                    addedAtMs = (c["addedAtMs"] as? JsonObject)?.mapValues { (_, v) -> num(v)!! } ?: emptyMap(),
                )
            },
        )
    }

    private class Built(val name: String, val result: BuildResult)

    private fun buildAll(): List<Built> {
        val root = resource("inthepocket-golden-input.json")
        val catalog = root["catalog"]!!.jsonArray.map { song(it.jsonObject) }.associateBy { it.id }
        return root["cases"]!!.jsonArray.map {
            val c = it.jsonObject
            Built(str(c["name"])!!, InThePocketScorer.build(input(c, catalog)))
        }
    }

    private fun assertNear(path: String, want: Double, got: Double) =
        assertEquals("$path: want $want got $got", want, got, 1e-9)

    private fun check(want: JsonObject, built: Built) {
        val n = built.name
        when (val r = built.result) {
            is BuildResult.Failed -> assertEquals(
                "$n result", str(want["result"]),
                if (r.failure == InThePocketScorer.Failure.NOTHING_PLAYABLE) "nothingPlayable" else "notEnoughCandidates",
            )
            is BuildResult.Success -> {
                val o = r.output
                assertEquals("$n result", "success", str(want["result"]))
                assertEquals("$n mode", str(want["mode"]), o.mode.raw)
                assertEquals("$n chips", want["chips"]!!.jsonArray.map { str(it) }, o.chips)

                val band = want["bpmBand"]
                if (band is JsonArray) {
                    assertTrue("$n bpmBand missing", o.bpmBand != null)
                    assertNear("$n band.lo", band[0].jsonPrimitive.double, o.bpmBand!!.start)
                    assertNear("$n band.hi", band[1].jsonPrimitive.double, o.bpmBand.endInclusive)
                } else assertTrue("$n bpmBand should be null", o.bpmBand == null)

                val wt = want["targets"]!!.jsonArray
                assertEquals("$n target count", wt.size, o.targets.size)
                wt.zip(o.targets).forEachIndexed { i, (w, g) ->
                    val t = w.jsonObject
                    assertEquals("$n targets[$i].dim", str(t["dim"]), g.dim)
                    assertEquals("$n targets[$i].value", str(t["value"]), g.value)
                    assertEquals("$n targets[$i].label", str(t["label"]), g.label)
                    assertNear("$n targets[$i].weight", num(t["weight"])!!, g.weight)
                }

                val wp = want["picks"]!!.jsonArray
                assertEquals("$n pick ids", wp.map { str(it.jsonObject["id"]) }, o.picks.map { it.song.id })
                wp.zip(o.picks).forEachIndexed { i, (w, g) ->
                    assertNear("$n picks[$i].score", num(w.jsonObject["score"])!!, g.score)
                    assertEquals("$n picks[$i].why", w.jsonObject["why"]!!.jsonArray.map { str(it) }, g.why)
                }
            }
        }
    }

    @Test fun kotlinScorerMatchesTheSwiftGoldenOnEveryCase() {
        val want = resource("inthepocket-golden-expected.json")["cases"]!!.jsonArray.map { it.jsonObject }
        val built = buildAll()
        assertEquals("expected file out of date vs the input fixture", want.map { str(it["name"]) }, built.map { it.name })
        want.zip(built).forEach { (w, b) -> check(w, b) }
    }

    @Test fun goldenSpansEveryModeAndFailureAndEnoughCases() {
        val built = buildAll()
        assertTrue("fixture too small: ${built.size}", built.size >= 50)
        val ok = built.map { it.result }.filterIsInstance<BuildResult.Success>().map { it.output }
        for (m in InThePocketMode.entries) assertTrue("no $m case", ok.any { it.mode == m })
        assertTrue(ok.any { o -> o.targets.any { it.dim == "collection" } })
        assertTrue(ok.any { o -> o.picks.size == 4 } && ok.any { o -> o.picks.size == 3 })
        val failures = built.map { it.result }.filterIsInstance<BuildResult.Failed>().map { it.failure }.toSet()
        assertEquals(InThePocketScorer.Failure.entries.toSet(), failures)
        // The fixture seeds are exercised: same context, different seeds, more than one distinct round.
        val seeded = built.filter { it.name.startsWith("cloud-seed-") }
            .map { ((it.result as BuildResult.Success).output.picks.map { p -> p.song.id }) }.toSet()
        assertTrue("seeds all produced the same round", seeded.size > 1)
    }
}

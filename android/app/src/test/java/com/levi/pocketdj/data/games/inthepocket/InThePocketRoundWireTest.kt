package com.levi.pocketdj.data.games.inthepocket

import com.levi.pocketdj.data.PdjJson
import com.levi.pocketdj.data.pockets.ListeningContextTag
import kotlinx.serialization.encodeToString
import kotlinx.serialization.json.JsonNull
import kotlinx.serialization.json.JsonObject
import kotlinx.serialization.json.jsonArray
import kotlinx.serialization.json.jsonObject
import kotlinx.serialization.json.jsonPrimitive
import kotlinx.serialization.json.long
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNotEquals
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test
import java.util.UUID

/** Port of the model/wire cases of InThePocketUploadTests.swift (rounds.v1). */
class InThePocketRoundWireTest {
    private val nowMs = 1_791_806_400_000.0

    private fun finished(feedback: String? = "loved it", startedMinutesAgo: Double = 60.0): InThePocketRound {
        val base = TestRounds.round(listOf("sng_00000000000a", "sng_00000000000b", "sng_00000000000c"), InThePocketOutcome.Pocket)
        return base.copy(
            startedAtMs = nowMs - startedMinutesAgo * 60_000 + 12_345,
            endedAtMs = nowMs - 30 * 60_000, updatedAtMs = nowMs - 30 * 60_000,
            context = base.context.copy(ctx = ListeningContextTag.place("plc_0f1e2d3c4b5a6978")),
            feedback = feedback, rating = 5,
            songs = base.songs.map { it.copy(state = InThePocketSongState.COMPLETED, fraction = 0.97) },
        )
    }

    @Test fun unfinishedOrUnstartedRoundsHaveNoWire() {
        assertNull(finished().copy(outcome = null).wire("I"))
        assertNull(finished().copy(startedAtMs = null).wire("I"))
    }

    @Test fun feedbackIsTrimmedCappedAndNeverSplitsASurrogatePair() {
        assertNull(InThePocketRound.capFeedback(null))
        assertNull(InThePocketRound.capFeedback("   \n "))
        assertEquals("hi", InThePocketRound.capFeedback("  hi \n"))
        val emoji = "a".repeat(1999) + "😀"
        assertEquals("never split a surrogate pair", 1999, InThePocketRound.capFeedback(emoji)!!.length)
        assertEquals(2000, InThePocketRound.capFeedback("x".repeat(4000))!!.length)
        val exact = "y".repeat(2000)
        assertEquals("exactly at the cap is untouched", exact, InThePocketRound.capFeedback(exact))
        // A pair that ENDS exactly at the cap is whole and kept.
        val pairAtEnd = "a".repeat(1998) + "😀" + "tail"
        assertEquals(2000, InThePocketRound.capFeedback(pairAtEnd)!!.length)
    }

    @Test fun wireOnlyFinishedStartedAndFloorsMinutesAndRoundsTo1e3() {
        val r = finished().copy(
            targets = listOf(InThePocketTarget("genre", "funk", "Funk (local label)", 0.123456)),
            songs = finished().songs.map { it.copy(score = 1.23456, fraction = 0.97123) },
        )
        val w = r.wire("INSTALL-1")!!
        assertEquals(0L, w.startedAtMs % 60_000)
        assertEquals(0L, w.endedAtMs!! % 60_000)
        assertEquals(r.updatedAtMs.toLong(), w.updatedAtMs)
        assertEquals(r.id.toString().uppercase(), w.id)
        assertEquals("cloud", w.mode); assertEquals("pocket", w.outcome); assertNull(w.brokeAt)
        assertEquals(0.123, w.targets[0].weight, 0.0)
        assertEquals(1.235, w.songs[0].score, 0.0)
        assertEquals(0.971, w.songs[0].fraction!!, 0.0)
    }

    @Test fun flooredMinuteFloorsNegativeTooLikeSwift() {
        assertEquals(60_000L, InThePocketRound.flooredMinute(119_999.0))
        assertEquals(-60_000L, InThePocketRound.flooredMinute(-1.0))
    }

    @Test fun songOutcomesMapPlayingByHalfAndPendingToNotPlayed() {
        val states = listOf(
            InThePocketSongState.COMPLETED to null, InThePocketSongState.SKIPPED to 0.1, InThePocketSongState.NOT_PLAYED to null,
            InThePocketSongState.PENDING to null, InThePocketSongState.PLAYING to 0.5, InThePocketSongState.PLAYING to 0.49,
            InThePocketSongState.PLAYING to null,
        )
        val base = finished()
        val r = base.copy(songs = states.mapIndexed { i, (s, f) -> base.songs[0].copy(id = "s$i", state = s, fraction = f) })
        assertEquals(
            listOf("completed", "skipped", "notPlayed", "notPlayed", "completed", "partial", "partial"),
            r.wire("I")!!.songs.map { it.outcome },
        )
    }

    @Test fun encodedJsonCarriesExplicitNullsAndNoDisplayLabels() {
        val r = finished().copy(contextLabel = "Location A", endedAtMs = null, rating = null, feedback = null, appVersion = null)
        val batch = InThePocketRoundsBatch(deviceId = null, installId = "I", sentAtMs = 5, rounds = listOf(r.wire("I")!!))
        val j: JsonObject = batch.toJson()
        assertEquals(1, j["v"]!!.jsonPrimitive.long.toInt())
        assertFalse("nil deviceId is omitted", j.containsKey("deviceId"))
        val round = j["rounds"]!!.jsonArray[0].jsonObject
        for (k in listOf("endedAtMs", "algoVersion".takeIf { false } ?: "brokeAt", "rating", "feedback", "appVersion")) {
            assertEquals("$k must be an explicit null", JsonNull, round[k])
        }
        assertEquals(JsonNull.toString(), round["brokeAt"].toString())
        assertFalse("display labels never upload", round.containsKey("contextLabel"))
        val ctx = round["context"]!!.jsonObject["ctx"]!!.jsonObject
        assertEquals("place", ctx["kind"]!!.jsonPrimitive.content)
        assertFalse("only the ids the kind uses", ctx.containsKey("tripId"))
        val song = round["songs"]!!.jsonArray[0].jsonObject
        assertEquals(setOf("songId", "artist", "score", "outcome", "fraction"), song.keys)
        // No ctx at all => explicit null, not absence.
        val noCtx = finished().copy(context = finished().context.copy(ctx = null)).wire("I")!!.toJson()
        assertEquals(JsonNull, noCtx["context"]!!.jsonObject["ctx"])
        // A song with no fraction encodes fraction:null.
        val nf = finished().let { it.copy(songs = it.songs.map { s -> s.copy(fraction = null) }) }.wire("I")!!.toJson()
        assertEquals(JsonNull, nf["songs"]!!.jsonArray[0].jsonObject["fraction"])
        assertEquals(
            listOf("id", "originInstallId", "startedAtMs", "endedAtMs", "updatedAtMs", "tzOffsetMin", "context", "mode", "seed",
                "algoVersion", "targets", "songs", "outcome", "brokeAt", "rating", "feedback", "appVersion"),
            round.keys.toList(),
        )
    }

    @Test fun brokeRoundsWireTheirSongIndex() {
        val r = finished().copy(outcome = InThePocketOutcome.Broke(2))
        val w = r.wire("I")!!
        assertEquals("broke", w.outcome); assertEquals(2, w.brokeAt)
        assertEquals(2L, w.toJson()["brokeAt"]!!.jsonPrimitive.long)
    }

    @Test fun fingerprintMovesWhenAnythingMutableChanges() {
        val r = finished()
        val fp = r.wire("I")!!.fingerprint
        assertEquals(fp, r.wire("I")!!.fingerprint)
        assertNotEquals(fp, r.copy(feedback = "actually too slow", updatedAtMs = r.updatedAtMs + 1000).wire("I")!!.fingerprint)
        assertNotEquals("feedback length alone moves it", fp, r.copy(feedback = "loved it!!").wire("I")!!.fingerprint)
        assertNotEquals(fp, r.copy(rating = 2).wire("I")!!.fingerprint)
        assertNotEquals(fp, r.copy(outcome = InThePocketOutcome.Broke(3)).wire("I")!!.fingerprint)
        assertNotEquals(fp, r.copy(songs = r.songs.mapIndexed { i, s -> if (i == 0) s.copy(state = InThePocketSongState.SKIPPED) else s }).wire("I")!!.fingerprint)
        assertNotEquals(fp, r.copy(songs = r.songs.map { it.copy(fraction = 0.5) }).wire("I")!!.fingerprint)
        assertTrue(fp.startsWith("${r.updatedAtMs.toLong()}|pocket|0|5|8|"))
        assertTrue(fp.endsWith("completed97,completed97,completed97"))
    }

    @Test fun roundJsonRoundTripsInTheIosShapeIncludingOutcome() {
        for (o in listOf(InThePocketOutcome.Pocket, InThePocketOutcome.Broke(3), InThePocketOutcome.Abandoned, null)) {
            val r = finished().copy(outcome = o, songs = finished().songs.map { it.copy(eventId = UUID.randomUUID()) })
            val text = PdjJson.lenient.encodeToString(r)
            val back = PdjJson.lenient.decodeFromString<InThePocketRound>(text)
            assertEquals(r, back)
        }
        val text = PdjJson.lenient.encodeToString(finished().copy(outcome = InThePocketOutcome.Broke(3)))
        val o = PdjJson.lenient.parseToJsonElement(text).jsonObject
        assertEquals("""{"outcome":"broke","brokeAt":3}""", o["outcome"].toString())
        assertEquals("cloud", o["mode"]!!.jsonPrimitive.content)
        assertEquals(o["id"]!!.jsonPrimitive.content, o["id"]!!.jsonPrimitive.content.uppercase())
    }

    @Test fun decodesAnIosPersistedRoundAndToleratesUnknownOutcomeTokens() {
        val ios = """
        {"id":"0F8B7C5E-2D1A-4C3B-9E6F-112233445566","createdAtMs":1700000000000,"startedAtMs":1700000001000,
         "updatedAtMs":1700000900000,"tzOffsetMin":-420,
         "context":{"timeBucket":"evening","dayType":"weekday","dow":2,"ctx":{"kind":"place","placeId":"plc_1"}},
         "mode":"history","seed":"18446744073709551615","algoVersion":1,
         "targets":[{"dim":"genre","value":"funk","label":"Funk","weight":1}],
         "songs":[{"id":"a","title":"A","artist":"X","score":1.5,"why":["Funk"],"state":"skipped",
                   "eventId":"AAAAAAAA-0000-4000-8000-000000000001","fraction":0.2}],
         "outcome":{"outcome":"mystery"},"rating":4,"unknownFutureKey":true}
        """
        val r = PdjJson.lenient.decodeFromString<InThePocketRound>(ios)
        assertEquals(InThePocketMode.HISTORY, r.mode)
        assertEquals(InThePocketOutcome.Abandoned, r.outcome)
        assertEquals(InThePocketSongState.SKIPPED, r.songs[0].state)
        assertEquals(ULong.MAX_VALUE, SplitMix64.parseSeed(r.seed))
        assertEquals("plc_1", r.context.ctx!!.placeId)
        val broke = PdjJson.lenient.decodeFromString<InThePocketRound>(ios.replace("""{"outcome":"mystery"}""", """{"outcome":"broke"}"""))
        assertEquals("a broke outcome with no brokeAt is song 1", InThePocketOutcome.Broke(1), broke.outcome)
        assertTrue(r.isFinished); assertFalse(r.isActive)
    }
}

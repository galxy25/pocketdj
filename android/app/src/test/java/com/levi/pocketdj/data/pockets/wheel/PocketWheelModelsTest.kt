package com.levi.pocketdj.data.pockets.wheel

import com.levi.pocketdj.data.PdjJson
import com.levi.pocketdj.data.history.PlaySource
import com.levi.pocketdj.data.pockets.ListeningContextTag
import org.junit.Assert.assertEquals
import org.junit.Assert.assertNotNull
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test
import com.levi.pocketdj.data.pockets.wheel.PocketMode.*

class PocketWheelModelsTest {
    private val json = PdjJson.lenient

    @Test fun modeTokensAreThePersistedIosTokens() {
        assertEquals(listOf("carPlay", "running", "walking", "trip", "mix", "browse", "collection"), PocketMode.precedence.map { it.token })
        for (m in PocketMode.entries) {
            assertEquals("\"${m.token}\"", json.encodeToString(PocketMode.serializer(), m))
            assertEquals(m, json.decodeFromString(PocketMode.serializer(), "\"${m.token}\""))
        }
        assertEquals("Home", COLLECTION.label)
        assertEquals(0, CAR_PLAY.rank)
        assertEquals(6, COLLECTION.rank)
    }

    @Test fun relatedPairs() {
        assertEquals(TRIP, CAR_PLAY.related); assertEquals(CAR_PLAY, TRIP.related)
        assertEquals(WALKING, RUNNING.related); assertEquals(RUNNING, WALKING.related)
        assertEquals(COLLECTION, MIX.related); assertEquals(MIX, COLLECTION.related)
        assertNull(BROWSE.related)
    }

    private val trip = ListeningContextTag.trip("t1", "o", null)

    @Test fun deriveFirstMatchWins() {
        assertNull("games excluded", PocketMode.derive(PlaySource.GAME, true, "running", null))
        assertEquals(CAR_PLAY, PocketMode.derive(PlaySource.MIX, true, "running", trip))
        assertEquals(RUNNING, PocketMode.derive(PlaySource.PLAYLIST, false, "running", trip))
        assertEquals(WALKING, PocketMode.derive(PlaySource.PLAYLIST, null, "walking", null))
        assertEquals(TRIP, PocketMode.derive(PlaySource.PLAYLIST, null, null, trip))
        assertEquals(TRIP, PocketMode.derive(PlaySource.PLAYLIST, null, "automotive", null))
        assertEquals("cycling folds into trip", TRIP, PocketMode.derive(PlaySource.BROWSER, null, "cycling", null))
        assertEquals(MIX, PocketMode.derive(PlaySource.MIX, null, "stationary", null))
        assertEquals(BROWSE, PocketMode.derive(PlaySource.BROWSER, null, null, null))
        assertEquals(BROWSE, PocketMode.derive(PlaySource.ALBUM, null, null, null))
        assertEquals(BROWSE, PocketMode.derive(PlaySource.ARTIST, null, null, null))
        assertEquals(COLLECTION, PocketMode.derive(PlaySource.PLAYLIST, null, null, null))
        assertEquals(COLLECTION, PocketMode.derive(PlaySource.POCKET, null, null, ListeningContextTag.NONE))
        assertEquals(COLLECTION, PocketMode.derive(PlaySource.SETLIST, null, null, null))
    }

    @Test fun motionActivityRank() {
        assertTrue(MotionToken.activityRank("running") < MotionToken.activityRank("walking"))
        assertTrue(MotionToken.activityRank("automotive") < MotionToken.activityRank("stationary"))
        assertEquals(5, MotionToken.activityRank("flying"))
    }

    @Test fun momentKeyTokenAndParse() {
        val key = PocketMomentKey.of(8, 2, CAR_PLAY)
        assertEquals("h08|d2|carPlay", key.token)
        assertEquals(key, PocketMomentKey.fromToken("h08|d2|carPlay"))
        assertEquals("h23|d7|collection", PocketMomentKey.of(23, 7, COLLECTION).token)
        for (bad in listOf("", "h08|d2", "h24|d2|mix", "h08|d0|mix", "h08|d8|mix", "x08|d2|mix", "h08|e2|mix", "h08|d2|nope", "hxx|d2|mix")) {
            assertNull(bad, PocketMomentKey.fromToken(bad))
        }
    }

    @Test fun momentKeyNormalisesAndOrders() {
        assertEquals(PocketMomentKey(23, 1, MIX), PocketMomentKey.of(-1, 0, MIX))
        assertEquals(PocketMomentKey(1, 7, MIX), PocketMomentKey.of(25, 9, MIX))
        val a = PocketMomentKey.of(8, 1, MIX)
        val b = PocketMomentKey.of(7, 2, CAR_PLAY)
        assertTrue("dow before hour", a < b)
        assertTrue("same cell: precedence", PocketMomentKey.of(8, 1, CAR_PLAY) < PocketMomentKey.of(8, 1, BROWSE))
        assertTrue(PocketMomentKey.of(0, 6, MIX).isWeekend)
        assertEquals(false, PocketMomentKey.of(0, 5, MIX).isWeekend)
    }

    @Test fun labels() {
        assertEquals("12 AM", PocketMomentKey.hourLabel(0))
        assertEquals("8 AM", PocketMomentKey.hourLabel(8))
        assertEquals("12 PM", PocketMomentKey.hourLabel(12))
        assertEquals("11 PM", PocketMomentKey.hourLabel(23))
        assertEquals("Tue 8 AM · CarPlay", PocketMomentKey.of(8, 2, CAR_PLAY).shortLabel)
        assertEquals("Sunday 11 PM · Home", PocketMomentKey.of(23, 7, COLLECTION).longLabel)
    }

    @Test fun momentKeyJsonIsIosShape() {
        val s = json.encodeToString(PocketMomentKey.serializer(), PocketMomentKey.of(8, 2, CAR_PLAY))
        assertEquals("""{"hour":8,"dow":2,"mode":"carPlay"}""", s)
        assertEquals(PocketMomentKey(8, 2, CAR_PLAY), json.decodeFromString(PocketMomentKey.serializer(), s))
    }

    @Test fun clockEpochIsThursday() {
        val c = PocketClock.local(0.0, 0)
        assertEquals(4, c.dow)
        assertEquals(0, c.hour)
        assertEquals(0, c.dayIndex)
        // Tuesday 2026-10-27 08:30 PDT.
        val t = PocketClock.local(1_793_115_000_000.0, -420)
        assertEquals(2, t.dow); assertEquals(8, t.hour); assertEquals(8.5, t.fractionalHour, 1e-9)
    }

    @Test fun clockNegativeOffsetsRollBackADay() {
        // 1970-01-01 00:30Z at UTC-1 is Wed 1969-12-31 23:30.
        val c = PocketClock.local(30 * 60_000.0, -60)
        assertEquals(3, c.dow); assertEquals(23, c.hour); assertEquals(-1, c.dayIndex)
        // Sunday -> Monday wrap: 1970-01-04 (Sunday) 23:00Z at UTC+2 is Monday.
        val sun = PocketClock.local(3 * 86_400_000.0 + 23 * 3_600_000.0, 120)
        assertEquals(1, sun.dow); assertEquals(1, sun.hour)
        assertEquals(7, PocketClock.local(3 * 86_400_000.0 + 12 * 3_600_000.0, 0).dow)
    }

    @Test fun runTagIds() {
        val id = "5F2B8A10-1C3D-4E5F-8A9B-0C1D2E3F4A5B"
        assertEquals("pwr_$id", PocketWheelIds.runTag(id))
        assertEquals(id, PocketWheelIds.runId("pwr_$id"))
        assertNull(PocketWheelIds.runId("pwr_notauuid"))
        assertNull(PocketWheelIds.runId("pl_$id"))
        assertNull(PocketWheelIds.runId(null))
        assertEquals("fav_songs", PocketWheelIds.FAVORITES)
        assertNotNull(PocketWheelIds.FAVORITES_NAME)
    }

    @Test fun profileIosShapeRoundTripAndDefaults() {
        val m = PocketMoment(PocketMomentKey.of(8, 2, CAR_PLAY), plays = 2.0, directPlays = 5, collections = mapOf("pl_a" to 1.0),
            dominantCollectionId = "pl_a", bpmLo = 100.0, bpmHi = 120.0)
        val p = PocketProfile.from(m, mapOf("pl_a" to "Potential"))
        assertEquals("Tue 8 AM · CarPlay", p.caption)
        assertEquals("Potential · 5 plays", p.detail)
        assertEquals(PocketProfile.Tier.RICH, p.tier)
        assertEquals("pl_a", p.dominantCollectionId)
        assertEquals(100.0..120.0, p.bpmBand)
        val s = json.encodeToString(PocketProfile.serializer(), p)
        assertTrue(s.contains(""""tier":"rich""""))
        assertTrue(s.contains(""""key":{"hour":8,"dow":2,"mode":"carPlay"}"""))
        assertEquals(p, json.decodeFromString(PocketProfile.serializer(), s))
        // Written without the optional fields (older iOS): decodes with defaults.
        val old = json.decodeFromString(PocketProfile.serializer(), """{"tier":"empty","caption":"c","detail":"d"}""")
        assertEquals(PocketProfile.Tier.EMPTY, old.tier)
        assertNull(old.key); assertNull(old.mode); assertTrue(old.momentKeys.isEmpty())
        assertEquals("Mixed · 1 play", PocketProfile.detail(null, 1, emptyMap()))
    }

    @Test fun tokenIsLocaleIndependent() {
        val old = java.util.Locale.getDefault()
        try {
            java.util.Locale.setDefault(java.util.Locale("ar", "EG"))
            val k = PocketMomentKey.of(8, 2, CAR_PLAY)
            assertEquals("h08|d2|carPlay", k.token)
            assertEquals(k, PocketMomentKey.fromToken(k.token))
        } finally { java.util.Locale.setDefault(old) }
        assertEquals(PocketMode.precedence, PocketMode.entries.toList())
    }
}

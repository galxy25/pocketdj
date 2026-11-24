package com.levi.pocketdj.screens.history.wheel

import com.levi.pocketdj.data.pockets.ListeningContextTag
import com.levi.pocketdj.data.pockets.wheel.PocketMode
import com.levi.pocketdj.data.pockets.wheel.PocketMoment
import com.levi.pocketdj.data.pockets.wheel.PocketMomentKey
import com.levi.pocketdj.data.pockets.wheel.PocketRunStore
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test
import java.time.ZoneId
import java.time.ZonedDateTime

class PocketMomentCardTest {
    private val key = PocketMomentKey(8, 2, PocketMode.CAR_PLAY)
    private fun moment(
        collections: Map<String, Double> = emptyMap(), dominant: String? = null, days: Int = 3,
        plays: Double = 8.0, skips: Double = 2.0, ctx: Map<String, Double> = emptyMap(),
    ) = PocketMoment(key, plays = plays, skips = skips, distinctDays = days, directPlays = 8, collections = collections,
        dominantCollectionId = dominant, ctx = ctx, bpmLo = 120.4, bpmHi = 128.9, eraLo = 1999.6, eraHi = 2004.2,
        artists = mapOf("daft punk" to 3.0, "justice" to 2.0, "air" to 1.0, "moby" to 0.5),
        genres = mapOf("electronic" to 2.0))

    @Test fun collectionsSortByShareThenIdAndPercentRounds() {
        val m = moment(collections = mapOf("b" to 0.3, "a" to 0.3, "c" to 0.405))
        assertEquals(listOf("c", "a", "b"), PocketCardText.sortedCollections(m).map { it.first })
        assertEquals("41 %", PocketCardText.percent(0.405))
        assertEquals("30 %", PocketCardText.percent(0.3))
    }

    @Test fun featureRowsTruncateAndFormat() {
        val m = moment()
        assertEquals(listOf("Daft punk", "Justice", "Air"), PocketCardText.topArtists(m))
        assertEquals("120–128 BPM", PocketCardText.tempo(m))
        assertEquals("2000–2004", PocketCardText.eraText(m))
        assertNull(PocketCardText.tempo(PocketMoment(key)))
    }

    @Test fun placeChipsSkipNoneRelabelAndCapAtThree() {
        val m = moment(ctx = mapOf("none" to 9.0, "place:p1" to 5.0, "trip:t1" to 4.0, "place:p2" to 3.0, "place:p3" to 2.0, "bogus" to 1.0))
        val chips = PocketCardText.placeChips(m) { tag -> if (tag.placeId == "p1") "Location A" else null }
        assertEquals(listOf("Location A", "A trip", "Earlier place"), chips)
        assertNull(PocketCardText.tagOf("none"))
        assertNull(PocketCardText.tagOf("nocolon"))
        assertEquals("t1", PocketCardText.tagOf("trip:t1")?.tripId)
        assertEquals(ListeningContextTag.KIND_TRIP, PocketCardText.tagOf("trip:t1")?.kind)
    }

    @Test fun statsRecurringVsOneOff() {
        assertEquals("8" to "plays", PocketCardText.plays(moment()))
        assertEquals("20 %" to "skips", PocketCardText.skips(moment()))
        assertEquals("3 days" to "recurring", PocketCardText.recurrence(moment(days = 3)))
        assertEquals("once" to "one-off", PocketCardText.recurrence(moment(days = 1)))
    }

    @Test fun whyTextCoversMixedRecurringAndOneOff() {
        val names = mapOf("a" to "Roadtrip")
        assertTrue(PocketCardText.whyText(moment(), names).startsWith("No single playlist or pocket made up a quarter"))
        val rec = PocketCardText.whyText(moment(collections = mapOf("a" to 0.62), dominant = "a", days = 4), names)
        assertEquals("Roadtrip is where 62 % of the music you played here came from, across 4 different days. " +
            "Colours are assigned automatically and stay the same on all your devices.", rec)
        val once = PocketCardText.whyText(moment(collections = mapOf("z" to 0.5), dominant = "z", days = 1), names)
        assertTrue(once.startsWith("This collection is where 50 % "))
        assertTrue(once.contains("It happened once, so it's drawn paler."))
    }

    @Test fun pastRunStripAndLabels() {
        assertEquals("12 played · 25 % skipped", PocketCardText.runSummary(12, 0.25))
        val zone = ZoneId.of("UTC")
        val now = ZonedDateTime.of(2026, 11, 24, 12, 0, 0, 0, zone).toInstant().toEpochMilli()
        fun at(d: Int) = ZonedDateTime.of(2026, 11, d, 9, 0, 0, 0, zone).toInstant().toEpochMilli().toDouble()
        assertEquals("Today", PocketCardText.runLabel(at(24), now, zone))
        assertEquals("Yesterday", PocketCardText.runLabel(at(23), now, zone))
        assertEquals("Mon, Nov 16", PocketCardText.runLabel(at(16), now, zone))
    }

    @Test fun clearOnlyWhenThisCellIsPlayingAndHostWiredClear() {
        val other = PocketMomentKey(9, 3, PocketMode.WALKING)
        val playingThis = PocketWheelActions(runProgress = PocketWheelActions.RunProgress(3, 15, key), clearRun = {})
        val playingOther = PocketWheelActions(runProgress = PocketWheelActions.RunProgress(3, 15, other), clearRun = {})
        val idle = PocketWheelActions(clearRun = {})
        val noClear = PocketWheelActions(runProgress = PocketWheelActions.RunProgress(3, 15, key))
        assertTrue(PocketCardText.isPlaying(playingThis, moment()))
        assertFalse(PocketCardText.isPlaying(playingOther, moment()))
        assertTrue(PocketCardText.canClear(playingOther))     // long-press Clear works on any live run
        assertFalse(PocketCardText.canClear(idle))
        assertFalse(PocketCardText.canClear(noClear))
        assertFalse(PocketCardText.isPlaying(idle, moment()))
    }

    @Test fun finishedRunIsNotPlayingProgress() {
        val run = PocketRunStore.RunState(runId = "r", label = "l", seed = "s", profile = com.levi.pocketdj.data.pockets.wheel.PocketProfile(
            tier = com.levi.pocketdj.data.pockets.wheel.PocketProfile.Tier.CLOUD, caption = "c", detail = "d"),
            startedAtMs = 0.0, finished = true, playedThrough = 14, skips = 6)
        assertNull(PocketWheelActions.progressOf(run))
        assertEquals("Pocket finished · 14 played · 30 % skipped", com.levi.pocketdj.screens.history.PocketFinishedText.headline(run))
    }
}

package com.levi.pocketdj.data.games.inthepocket

import com.levi.pocketdj.data.games.inthepocket.InThePocketRoundEvaluator.Observation
import com.levi.pocketdj.data.games.inthepocket.InThePocketSongState.COMPLETED
import com.levi.pocketdj.data.games.inthepocket.InThePocketSongState.NOT_PLAYED
import com.levi.pocketdj.data.games.inthepocket.InThePocketSongState.PENDING
import com.levi.pocketdj.data.games.inthepocket.InThePocketSongState.PLAYING
import com.levi.pocketdj.data.games.inthepocket.InThePocketSongState.SKIPPED
import org.junit.Assert.assertEquals
import org.junit.Assert.assertNotNull
import org.junit.Assert.assertNull
import org.junit.Test
import java.util.UUID

/** Port of InThePocketRoundEvaluatorTests.swift, case for case (+ the acceptance edge cases). */
class RoundEvaluatorTest {
    private val songs = listOf("a", "b", "c", "d")
    private val t0 = 1_000_000_000_000.0
    private val minute = 60_000.0

    private fun obs(song: String, at: Double, skipped: Boolean = false, fraction: Double? = null) =
        Observation(UUID.randomUUID(), song, t0 + at * minute, skipped, fraction)

    private fun eval(events: List<Observation>, lostAt: Double? = null, now: Double) =
        InThePocketRoundEvaluator.evaluate(
            songs, t0, events, lostAt?.let { t0 + it * minute }, t0 + now * minute,
        )

    @Test fun notStartedYetIsPending() {
        val v = eval(emptyList(), now = 0.5)
        assertNull(v.outcome)
        assertEquals(listOf(PENDING, PENDING, PENDING, PENDING), v.states)
        assertNull(v.currentIndex)
    }

    @Test fun allFourPlayedThroughIsInThePocket() {
        val mid = eval(listOf(obs("a", 0.0, fraction = 1.0), obs("b", 4.0, fraction = 1.0), obs("c", 8.0)), now = 9.0)
        assertNull(mid.outcome)
        assertEquals(listOf(COMPLETED, COMPLETED, PLAYING, PENDING), mid.states)
        assertEquals(2, mid.currentIndex)
        val done = eval(listOf(obs("a", 0.0), obs("b", 4.0), obs("c", 8.0), obs("d", 12.0, fraction = 0.95)), now = 16.0)
        assertEquals(InThePocketOutcome.Pocket, done.outcome)
        assertEquals(listOf(COMPLETED, COMPLETED, COMPLETED, COMPLETED), done.states)
        assertNull(done.currentIndex)
    }

    @Test fun theSetEndingNaturallyWaitsForTheCheckpointThenPockets() {
        val events = listOf(obs("a", 0.0), obs("b", 4.0), obs("c", 8.0), obs("d", 12.0))
        assertNull("never guess 'done' before the last song's fraction arrives", eval(events, lostAt = 16.0, now = 17.0).outcome)
        val withFraction = events.dropLast(1) + events.last().copy(fraction = 0.7)
        assertEquals(InThePocketOutcome.Pocket, eval(withFraction, lostAt = 16.0, now = 17.0).outcome)
    }

    @Test fun aSkipBreaksThePocketAtThatSongImmediately() {
        val v = eval(listOf(obs("a", 0.0), obs("b", 4.0, skipped = true, fraction = 0.2), obs("c", 5.0)), now = 5.1)
        assertEquals(InThePocketOutcome.Broke(2), v.outcome)
        assertEquals(listOf(COMPLETED, SKIPPED, PLAYING, NOT_PLAYED), v.states)
        val first = eval(listOf(obs("a", 0.0, skipped = true, fraction = 0.1), obs("b", 0.5)), now = 0.6)
        assertEquals(InThePocketOutcome.Broke(1), first.outcome)
    }

    @Test fun aLateSkipVerdictStillBreaksTheRound() {
        var events = listOf(obs("a", 0.0), obs("b", 4.0))
        assertNull(eval(events, now = 4.01).outcome)
        events = listOf(events[0].copy(wasSkipped = true), events[1])
        assertEquals(InThePocketOutcome.Broke(1), eval(events, now = 4.02).outcome)
    }

    @Test fun pausingIsNotSkipping() {
        val v = eval(listOf(obs("a", 0.0), obs("b", 4.0, fraction = 0.3)), now = 94.0)
        assertNull(v.outcome)
        assertEquals(listOf(COMPLETED, PLAYING, PENDING, PENDING), v.states)
    }

    @Test fun replayingAnEarlierRoundSongIsNotForeign() {
        val v = eval(listOf(obs("a", 0.0), obs("b", 4.0), obs("a", 5.0), obs("b", 6.0)), now = 7.0)
        assertNull("back to song 1 neither skips nor abandons", v.outcome)
        assertEquals(1, v.currentIndex)
    }

    @Test fun playingSomethingElseAbandonsAfterTheSettleWindow() {
        val events = listOf(obs("a", 0.0), obs("b", 4.0, fraction = 0.3), obs("zzz", 5.0))
        val settling = InThePocketRoundEvaluator.evaluate(
            songs, t0, events, null, t0 + 5 * minute + InThePocketRoundEvaluator.SETTLE_MS - 1,
        )
        assertNull("a late skip verdict may still land", settling.outcome)
        val v = eval(events, now = 6.0)
        assertEquals(InThePocketOutcome.Abandoned, v.outcome)
        assertEquals(listOf(COMPLETED, PLAYING, NOT_PLAYED, NOT_PLAYED), v.states)
        val skipped = events.toMutableList().also { it[1] = it[1].copy(wasSkipped = true) }
        assertEquals(InThePocketOutcome.Broke(2), eval(skipped, now = 6.0).outcome)
    }

    @Test fun foreignPlaySettlesAfterExactlyEightSeconds() {
        val events = listOf(obs("a", 0.0), obs("b", 4.0, fraction = 0.3), obs("zzz", 5.0))
        val at8 = InThePocketRoundEvaluator.evaluate(songs, t0, events, null, t0 + 5 * minute + 8_000)
        assertEquals(InThePocketOutcome.Abandoned, at8.outcome)
    }

    @Test fun stoppingTheSetMidSongAbandons() {
        val v = eval(listOf(obs("a", 0.0), obs("b", 4.0, fraction = 0.2)), lostAt = 5.0, now = 6.0)
        assertEquals(InThePocketOutcome.Abandoned, v.outcome)
        val before = eval(emptyList(), lostAt = 0.1, now = 1.0)
        assertEquals("taken over before song 1 started", InThePocketOutcome.Abandoned, before.outcome)
        assertEquals(listOf(NOT_PLAYED, NOT_PLAYED, NOT_PLAYED, NOT_PLAYED), before.states)
    }

    @Test fun unknownFractionAfterForeignPlayIsAPlay() {
        // Last matched song has no fraction, a foreign song followed: counts as played through.
        val v = InThePocketRoundEvaluator.evaluate(
            listOf("a", "b"), t0, listOf(obs("a", 0.0), obs("b", 1.0), obs("zzz", 2.0)), null, t0 + 3 * minute,
        )
        assertEquals(InThePocketOutcome.Pocket, v.outcome)
    }

    @Test fun idleTimeoutAbandons() {
        val v = eval(listOf(obs("a", 0.0), obs("b", 4.0, fraction = 0.3)), now = 4.0 + 181)
        assertEquals(InThePocketOutcome.Abandoned, v.outcome)
    }

    @Test fun variantIdsMatchTheirBaseSong() {
        val ids = listOf("sng_00000000000a", "sng_00000000000b", "sng_00000000000c")
        val v = InThePocketRoundEvaluator.evaluate(
            ids, t0, listOf(obs(ids[0], 0.0), obs(ids[1] + "_clean", 4.0)), null, t0 + 4.5 * minute,
        )
        assertEquals(listOf(COMPLETED, PLAYING, PENDING), v.states)
        assertNull(v.outcome)
    }

    @Test fun baseIdOnlyStripsWellFormedVariantSuffixes() {
        assertEquals("sng_1a7f6bc854af", InThePocketRoundEvaluator.baseId("sng_1a7f6bc854af_clean"))
        assertEquals("sng_1a7f6bc854af", InThePocketRoundEvaluator.baseId("sng_1a7f6bc854af_explicit"))
        assertEquals("sng_1a7f6bc854af", InThePocketRoundEvaluator.baseId("sng_1a7f6bc854af"))
        assertEquals("sng_1A7F6BC854AF_clean", InThePocketRoundEvaluator.baseId("sng_1A7F6BC854AF_clean"))
        assertEquals("amrec_12_clean", InThePocketRoundEvaluator.baseId("amrec_12_clean"))
        assertEquals("sng_short_clean", InThePocketRoundEvaluator.baseId("sng_short_clean"))
    }

    @Test fun eventsBeforeTheStartAreIgnored() {
        val v = eval(listOf(obs("zzz", -10.0), obs("a", 0.0)), now = 1.0)
        assertNull(v.outcome)
        assertEquals(PLAYING, v.states[0])
    }

    @Test fun eventsJustBeforePlayStillCountWithinTolerance() {
        val e = Observation(UUID.randomUUID(), "a", t0 - 1_500, false, null)
        val v = eval(listOf(e), now = 0.1)
        assertEquals(PLAYING, v.states[0])
        assertNotNull(v.eventIds[0])
    }
}

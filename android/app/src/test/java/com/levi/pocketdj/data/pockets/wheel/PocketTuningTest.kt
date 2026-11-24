package com.levi.pocketdj.data.pockets.wheel

import com.levi.pocketdj.data.history.PlayEvent
import com.levi.pocketdj.data.history.PocketRunTag
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test
import kotlin.math.abs

/** iOS PocketTuning: verdict strengths, ban threshold, 30-day fold, related/global scaling, History -> verdicts. */
class PocketTuningTest {
    private val day = 86_400_000.0
    private fun feat(artist: String) = PocketTuning.Features(artistKeys = listOf(artist))
    private fun v(song: String, skipped: Boolean, fraction: Double?, at: Double = 0.0, moment: String = "h08|d2|carPlay") =
        PocketTuning.Verdict(song, skipped, fraction, at, moment)

    @Test fun verdictStrengthLadder() {
        assertEquals(-1.0, v("a", true, 0.05).strength!!, 1e-9)
        assertEquals(-1.0, v("a", true, 0.149).strength!!, 1e-9)
        assertEquals(-0.6, v("a", true, 0.15).strength!!, 1e-9)
        assertEquals(-1.0, v("a", true, null).strength!!, 1e-9) // unknown fraction on a skip = 0 -> fast skip
        assertEquals(0.5, v("a", false, 0.9).strength!!, 1e-9)
        assertEquals(0.2, v("a", false, 0.6).strength!!, 1e-9)
        assertEquals(-0.6, v("a", false, 0.3).strength!!, 1e-9)
        assertNull(v("a", false, null).strength)
    }

    @Test fun banThresholdIsExactlyPointThreeFive() {
        assertEquals(0.35, PocketTuning.BAN_AT_OR_BELOW, 0.0)
        val fast = PocketTuning.runEvidence(listOf(v("a", true, 0.05))) { feat("drake") }
        assertTrue("drake" in PocketTuning.multipliers(fast, allowBans = true).bannedArtists)
        assertEquals(1.0 / 3.0, PocketTuning.multipliers(fast, true).byKey["artist:drake"]!!, 1e-3)
    }

    @Test fun oneOrdinarySkipDoesNotBanButTwoDo() {
        val one = PocketTuning.runEvidence(listOf(v("a", true, 0.3))) { feat("drake") }
        assertFalse("drake" in PocketTuning.multipliers(one, true).bannedArtists)
        val two = PocketTuning.runEvidence(listOf(v("a", true, 0.3), v("b", true, 0.3))) { feat("drake") }
        assertTrue("drake" in PocketTuning.multipliers(two, true).bannedArtists)
    }

    @Test fun banNeverCrossesRunsWhenBansAreDisallowed() {
        val fast = PocketTuning.runEvidence(listOf(v("a", true, 0.05), v("b", true, 0.05))) { feat("drake") }
        val m = PocketTuning.multipliers(fast, allowBans = false)
        assertTrue(m.bannedArtists.isEmpty())
        assertTrue("the multiplier still sinks", m.byKey["artist:drake"]!! <= 0.35)
    }

    @Test fun completionLiftsAnArtistAndCollectionMultipliers() {
        val e = PocketTuning.runEvidence(listOf(v("a", false, 1.0), v("b", false, 1.0))) { PocketTuning.Features(listOf("sza"), collectionId = "pl_x") }
        val m = PocketTuning.multipliers(e, false)
        assertTrue(m.byKey["artist:sza"]!! > 1.0)
        assertTrue(m.byKey["collection:pl_x"]!! > 1.0)
        assertTrue(m.byKey["collection:pl_x"]!! <= 1.4 && m.byKey["artist:sza"]!! <= 1.6)
    }

    @Test fun foldHalvesEvidenceEvery30Days() {
        val now = 100 * day
        val fresh = PocketTuning.fold(listOf(v("a", false, 1.0, at = now)), null, now) { feat("sza") }
        val old = PocketTuning.fold(listOf(v("a", false, 1.0, at = now - 30 * day)), null, now) { feat("sza") }
        assertEquals(fresh.pos["artist:sza"]!! / 2, old.pos["artist:sza"]!!, 1e-9)
    }

    @Test fun foldScalesOwnRelatedAndGlobalMoments() {
        val own = PocketMomentKey(8, 2, PocketMode.CAR_PLAY)
        val related = PocketMomentKey(9, 2, PocketMode.CAR_PLAY) // same mode, 1 h away
        val unrelated = PocketMomentKey(20, 6, PocketMode.RUNNING)
        fun fold(k: PocketMomentKey) =
            PocketTuning.fold(listOf(v("a", false, 1.0, at = 0.0, moment = k.token)), own, 0.0) { feat("sza") }.pos["artist:sza"]!!
        assertEquals(0.5, fold(own), 1e-9)
        assertEquals(0.5 * 0.5, fold(related), 1e-9)
        assertEquals(0.5 * 0.15, fold(unrelated), 1e-9)
        // no moment (blended profile): everything is global
        val none = PocketTuning.fold(listOf(v("a", false, 1.0, moment = own.token)), null, 0.0) { feat("sza") }.pos["artist:sza"]!!
        assertEquals(0.5 * 0.15, none, 1e-9)
    }

    @Test fun relatedKernelMatchesIos() {
        val a = PocketMomentKey(8, 2, PocketMode.CAR_PLAY)
        assertFalse(PocketTuning.isRelated(a, a))
        assertTrue(PocketTuning.isRelated(a, PocketMomentKey(10, 2, PocketMode.CAR_PLAY)))
        assertFalse(PocketTuning.isRelated(a, PocketMomentKey(11, 2, PocketMode.CAR_PLAY)))
        assertTrue("same hour, same weekend-ness, other day", PocketTuning.isRelated(a, PocketMomentKey(8, 4, PocketMode.CAR_PLAY)))
        assertTrue("related mode, same hour+day", PocketTuning.isRelated(a, PocketMomentKey(8, 2, PocketMode.TRIP)))
    }

    @Test fun verdictsFromHistoryTagsExcludesAndBaseIds() {
        fun ev(id: String, song: String, run: String?, skipped: Boolean?, frac: Double?) = PlayEvent(
            id = id, songId = song, playedAt = 5.0, wasSkipped = skipped, listenedFraction = frac,
            pocketRun = run?.let { PocketRunTag(it, "h08|d2|carPlay", "pl_x", 3) },
        )
        val events = listOf(
            ev("e1", "sng_aaaaaaaaaaaa", "R1", true, 0.1),
            ev("e2", "sng_bbbbbbbbbbbb_clean", "R1", null, 1.0),
            ev("e3", "sng_c", null, true, 0.1), // not a pocket-run play
            ev("e4", "sng_d", "R2", null, 0.6),
        )
        val all = PocketTuning.verdicts(events)
        assertEquals(listOf("R1", "R1", "R2"), all.map { it.first })
        assertEquals("sng_bbbbbbbbbbbb", all[1].second.songId)
        assertEquals("pl_x", all[0].second.rowCollectionId)
        assertTrue(all[0].second.skipped)
        assertEquals(listOf("R2"), PocketTuning.verdicts(events, excludingRun = "R1").map { it.first })
        assertEquals(2, PocketTuning.verdicts(events, excludingEvent = "e1").size)
    }

    @Test fun neutralMultipliersChangeNothing() {
        assertEquals(1.0, PocketTuning.Multipliers.NEUTRAL.factor(feat("x")), 0.0)
        assertTrue(abs(PocketTuning.clamp(5.0, 0.15, 1.6) - 1.6) < 1e-12)
    }
}

package com.levi.pocketdj.mix.graph

import com.levi.pocketdj.audio.core.Voice
import com.levi.pocketdj.mix.graph.GraphHarness.Companion.longestSilence
import com.levi.pocketdj.mix.graph.GraphHarness.Companion.maxStep
import com.levi.pocketdj.mix.graph.GraphHarness.Companion.rms
import com.levi.pocketdj.mix.model.Deck
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test
import kotlin.math.log10

class HandoverTest {
    private val TONE = 441.0
    private val STEP_LIMIT = 0.045f // tone slope is 0.031/sample; a phase slip would step by far more

    private fun rig(): Triple<GraphHarness, Voice, com.levi.pocketdj.audio.core.VoiceGroup> {
        val h = GraphHarness(512)
        val main = h.toneVoice(TONE, 0.5f)
        val stems = h.stemGroup(TONE, 0.5f) // four 0.125 stems that sum to the full mix
        h.graph.setStems(Deck.A, stems)
        h.playMain(Deck.A, main)
        h.composer.setCrossfader(0f)
        h.render(4096)
        return Triple(h, main, stems)
    }

    private fun windowDb(buf: FloatArray, from: Int, win: Int): Double {
        val r = rms(buf, from, from + win, 0)
        return 20 * log10(r / (0.5 / Math.sqrt(2.0)))
    }

    // ---------------------------------------------------------------- the pure state machine

    @Test fun fadeIsLinearAndSumsToOne() {
        val h = Handover(1000)
        h.schedule(true, 0)
        var prevM = 1f
        var landed = false
        var t = 0L
        while (!landed) {
            landed = h.advance(t, 100)
            assertEquals("main+stems stays 1 (coherent linear fade)", 1f, h.mainG1 + h.stemG1, 1e-5f)
            assertTrue(h.mainG1 <= prevM + 1e-6f)
            prevM = h.mainG1
            t += 100
        }
        assertEquals(0f, h.mainGain, 0f); assertEquals(1f, h.stemGain, 0f)
        assertEquals(1, h.landedGen); assertTrue(h.landedToStems)
        assertFalse(h.inFlight)
        // halfway point of a fresh fade is exactly 0.5 / 0.5 (equal-power would be 0.707)
        val g = Handover(1000); g.schedule(true, 0)
        g.advance(0, 500)
        assertEquals(0.5f, g.mainG1, 1e-5f)
        assertEquals(0.5f, g.stemG1, 1e-5f)
    }

    @Test fun fadeWaitsForItsStartFrame() {
        val h = Handover(100)
        h.schedule(true, 1000)
        h.advance(0, 512)
        assertEquals(1f, h.mainG1, 0f)
        h.advance(512, 512) // ends at 1024, 24 frames into the fade
        assertEquals(1f - 24f / 100f, h.mainG1, 1e-5f)
    }

    @Test fun newerPlanSupersedesFromTheCurrentGains() {
        val h = Handover(1000)
        val g1 = h.schedule(true, 0)
        h.advance(0, 400) // 40 % toward stems
        assertEquals(0.6f, h.mainGain, 1e-5f)
        val g2 = h.schedule(false, 400)
        assertTrue(g2 > g1)
        var t = 400L
        var landed = false
        while (!landed) { landed = h.advance(t, 100); assertEquals(1f, h.mainG1 + h.stemG1, 1e-5f); t += 100 }
        assertEquals("only the last intent landed", g2, h.landedGen)
        assertFalse(h.landedToStems)
        assertEquals(1f, h.mainGain, 0f)
    }

    @Test fun settleLandsOnTheNextChunkWithNoFade() {
        val h = Handover(1000)
        h.schedule(true, 5_000_000) // far in the future
        val g = h.settle(true)
        assertTrue(h.advance(0, 64))
        assertEquals(g, h.landedGen)
        assertEquals(1f, h.stemGain, 0f)
        assertTrue(h.intentStems)
    }

    @Test fun abortRestoresTheOutgoingSideAndFlipsTheIntentBack() {
        val h = Handover(1000)
        val g = h.schedule(true, 0)
        h.advance(0, 100)
        assertTrue(h.alignmentDue(0, 100))
        assertFalse("only once per plan", h.alignmentDue(0, 100))
        h.abort()
        assertEquals(1f, h.mainGain, 0f); assertEquals(0f, h.stemGain, 0f)
        assertEquals(g, h.abortedGen)
        assertFalse(h.intentStems)
        assertFalse(h.inFlight)
    }

    @Test fun abortOfAPlanThatSupersededAHalfFadeSnapsTheStillPlayingSideToFull() {
        val h = Handover(1000)
        h.schedule(true, 0); h.advance(0, 1000)               // on the stems
        h.schedule(false, 0); h.advance(1000, 500)            // half way back: 0.5 / 0.5
        assertEquals(0.5f, h.mainGain, 1e-4f)
        h.schedule(true, 0); h.advance(1500, 100)
        assertTrue(h.alignmentDue(1500, 100))
        h.abort()
        assertEquals("main keeps playing at full level, not the partial -6 dB", 1f, h.mainGain, 0f)
        assertEquals(0f, h.stemGain, 0f)
    }

    @Test fun abortNeverOverwritesANewerIntent() {
        val h = Handover(1000)
        val g1 = h.schedule(true, 0); h.advance(0, 100)
        assertTrue(h.alignmentDue(0, 100))
        h.schedule(true, 5000)                                 // newer plan (same side) published
        h.abort()                                              // stale abort: plan gen mismatch, nothing changes
        assertTrue(h.intentStems)
        assertEquals(0, h.abortedGen)
        assertTrue(g1 < h.latestGen)
    }

    // ---------------------------------------------------------------- the real graph

    @Test fun cutToStemsHasNoDeadAirAndTheSummedLevelNeverMoves() {
        val (h, main, stems) = rig()
        val gen = h.graph.crossfadeTo(Deck.A, true)
        val out = h.render(44100)
        val hd = h.graph.a.handover
        assertEquals(gen, hd.landedGen)
        assertTrue(hd.landedToStems)
        assertTrue("2 ms probe: longest silence ${longestSilence(out, 0, out.size / 2)}", longestSilence(out, 0, out.size / 2) <= 88)
        assertTrue("no phase slip at the splice: ${maxStep(out, 0, out.size / 2)}", maxStep(out, 0, out.size / 2) < STEP_LIMIT)
        // +-0.5 dB through the fade (0.25 s lead + 60 ms) and after
        var w = 0
        while (w + 400 <= out.size / 2) {
            val db = windowDb(out, w, 400)
            assertTrue("window@$w ${"%.3f".format(db)} dB", kotlin.math.abs(db) <= 0.5)
            w += 400
        }
        assertEquals("outgoing main voice was stopped when the fade landed", Voice.Status.IDLE, main.status.let { if (main.isPlaying) Voice.Status.PLAYING else Voice.Status.IDLE })
        assertTrue(stems.voices.all { it.isPlaying })
        assertTrue(h.graph.isOnStems(Deck.A))
    }

    @Test fun cutBackToTheFullMixIsAlsoSeamless() {
        val (h, main, stems) = rig()
        h.graph.crossfadeTo(Deck.A, true)
        h.render(30000)
        val gen = h.graph.crossfadeTo(Deck.A, false)
        val out = h.render(44100)
        assertEquals(gen, h.graph.a.handover.landedGen)
        assertFalse(h.graph.a.handover.landedToStems)
        assertTrue(longestSilence(out, 0, out.size / 2) <= 88)
        assertTrue(maxStep(out, 0, out.size / 2) < STEP_LIMIT)
        assertTrue(main.isPlaying)
        assertTrue(stems.voices.none { it.isPlaying })
    }

    @Test fun fadeIsLinearNotEqualPowerOnCoherentSignals() {
        val (h, _, _) = rig()
        h.graph.crossfadeTo(Deck.A, true, leadSeconds = 0.1)
        val out = h.render(8192)
        // Equal-power on coherent sources would bulge by +3 dB mid-fade; linear stays flat.
        var worst = 0.0
        var w = 0
        while (w + 200 <= out.size / 2) { worst = maxOf(worst, kotlin.math.abs(windowDb(out, w, 200))); w += 100 }
        assertTrue("worst deviation $worst dB", worst <= 0.5)
    }

    @Test fun rapidTogglesLandOnTheLastIntentWithZeroDeadAir() {
        val (h, main, stems) = rig()
        val pieces = ArrayList<FloatArray>()
        h.graph.crossfadeTo(Deck.A, true)
        pieces += h.render(1536)
        h.graph.crossfadeTo(Deck.A, false)
        pieces += h.render(1024)
        h.graph.crossfadeTo(Deck.A, true)
        pieces += h.render(512)
        h.graph.crossfadeTo(Deck.A, false)
        pieces += h.render(2048)
        val last = h.graph.crossfadeTo(Deck.A, true)
        pieces += h.render(44100)
        val all = FloatArray(pieces.sumOf { it.size }); var o = 0
        for (p in pieces) { System.arraycopy(p, 0, all, o, p.size); o += p.size }

        val hd = h.graph.a.handover
        assertEquals("only the last intent landed", last, hd.landedGen)
        assertTrue(hd.landedToStems)
        assertEquals(0, hd.abortedGen)
        assertTrue(h.graph.isOnStems(Deck.A))
        val frames = all.size / 2
        assertTrue("dead air ${longestSilence(all, 0, frames)}", longestSilence(all, 0, frames) <= 88)
        assertTrue("splice ${maxStep(all, 0, frames)}", maxStep(all, 0, frames) < STEP_LIMIT)
        assertFalse(main.isPlaying)
        assertTrue(stems.voices.all { it.isPlaying })
    }

    @Test fun togglingBackBeforeTheFadeStartedNeverLeavesTheFullMix() {
        val (h, main, stems) = rig()
        h.graph.crossfadeTo(Deck.A, true)
        h.render(2000)                       // still inside the 0.25 s lead
        h.graph.crossfadeTo(Deck.A, false)   // last intent: the full mix
        val out = h.render(30000)
        assertFalse(h.graph.isOnStems(Deck.A))
        assertTrue(main.isPlaying)
        assertTrue(longestSilence(out, 0, out.size / 2) <= 88)
        assertEquals(0.0, windowDb(out, 20000, 400), 0.3)
        assertEquals(0f, h.graph.a.handover.stemGain, 0f)
        assertTrue(stems.voices.none { it.isPlaying })
    }

    @Test fun settleBeforeTransportLandsImmediately() {
        val (h, _, stems) = rig()
        h.graph.crossfadeTo(Deck.A, true, leadSeconds = 5.0) // fade would start 5 s out
        h.render(2000)
        val gen = h.graph.settleHandover(Deck.A)
        h.render(1024)
        assertEquals(gen, h.graph.a.handover.landedGen)
        assertEquals(1f, h.graph.a.handover.stemGain, 0f)
        assertFalse(h.graph.a.handover.inFlight)
        assertTrue(stems.voices.isNotEmpty())
    }

    @Test fun incomingSideThatIsNotAlignedAbortsAndTheOutgoingKeepsPlaying() {
        val (h, main, stems) = rig()
        // Starve the stems: never pump them, so the 0.25 s lead passes without them being ready.
        val starved = stems.voices.toSet()
        val live = h.voices.filter { it !in starved }
        val total = 86 * 512
        val out = FloatArray(total * 2)
        h.graph.crossfadeTo(Deck.A, true)
        var done = 0
        while (done < total) {
            for (v in live) while (v.pump()) { }
            val b = h.sink.renderFrames(512)
            System.arraycopy(b, 0, out, done * 2, 512 * 2); done += 512
        }
        val hd = h.graph.a.handover
        assertTrue("aborted gen ${hd.abortedGen}", hd.abortedGen > 0)
        assertFalse(hd.intentStems)
        assertTrue(main.isPlaying)
        assertEquals(1f, hd.mainGain, 0f)
        assertTrue("outgoing kept sounding", longestSilence(out, 4096, total - 1024) <= 88)
    }

    @Test fun stemBalanceMutesIndividualStemsAndRidesTheHandoverGain() {
        val (h, _, _) = rig()
        h.graph.crossfadeTo(Deck.A, true)
        h.render(20000)
        h.composer.setStemBalance(Deck.A, floatArrayOf(1f, 1f, 1f, 0f)) // mute "other": 3 of 4 stems left
        h.render(2048)
        val out = h.render(4410)
        assertEquals(0.5 / Math.sqrt(2.0) * 0.75, rms(out, 0, 4410, 0), 0.005)
    }

    @Test fun mainStopsWhenTheFadeLandsSoItDoesNotKeepDecoding() {
        val (h, main, _) = rig()
        h.graph.crossfadeTo(Deck.A, true)
        h.render(20000)
        assertFalse(main.isPlaying)
    }

    @Test fun togglingStemsOnAPausedDeckStaysSilent() {
        val (h, main, stems) = rig()
        main.pause()
        h.render(2048)
        val gen = h.graph.crossfadeTo(Deck.A, true)
        val out = h.render(30000)
        val hd = h.graph.a.handover
        assertEquals(gen, hd.landedGen)
        assertTrue(hd.landedToStems)
        assertTrue(h.graph.isOnStems(Deck.A))
        assertTrue("paused deck must stay silent, peak ${GraphHarness.peak(out)}", GraphHarness.peak(out) < 1e-3f)
        assertTrue(stems.voices.none { it.isPlaying })
        assertFalse(main.isPlaying)
        // and back
        h.graph.crossfadeTo(Deck.A, false)
        val back = h.render(30000)
        assertTrue(GraphHarness.peak(back) < 1e-3f)
        assertFalse(main.isPlaying)
    }

    @Test fun togglingStemsOnAPlayingDeckStillStartsTheNewSideAudibly() {
        val (h, _, stems) = rig()
        h.graph.crossfadeTo(Deck.A, true)
        val out = h.render(30000)
        assertTrue(GraphHarness.peak(out, 20000) > 0.3f)
        assertTrue(stems.voices.all { it.isPlaying })
    }

    @Test fun anIncomingSideOffByAnyNumberOfFramesAborts() {
        for (k in intArrayOf(2, 16, 64)) {
            val (h, main, stems) = rig()
            val buf = LongArray(3)
            h.graph.crossfadeTo(Deck.A, true)
            h.graph.a.stamp.read(buf)
            val lead = Math.round(MixGraph.DEFAULT_HANDOVER_LEAD * h.sr)
            stems.seekAll(buf[1] + lead + k)              // late/early by k frames
            h.render(30000)
            assertTrue("offset $k must abort", h.graph.a.handover.abortedGen > 0)
            assertFalse(h.graph.isOnStems(Deck.A))
            assertTrue(main.isPlaying)
        }
    }
}

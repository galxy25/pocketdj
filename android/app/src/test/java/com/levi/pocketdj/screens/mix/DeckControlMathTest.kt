package com.levi.pocketdj.screens.mix

import com.levi.pocketdj.mix.model.Deck
import com.levi.pocketdj.mix.model.Effect
import com.levi.pocketdj.mix.model.EffectVariant
import com.levi.pocketdj.mix.model.FXSlot
import com.levi.pocketdj.mix.model.LoadedTrack
import com.levi.pocketdj.mix.model.ModSource
import com.levi.pocketdj.mix.model.SlotMod
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNotNull
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test

class DeckControlMathTest {
    private fun track(bpm: Double? = null, grid: Double? = null) =
        LoadedTrack("s", "T", "A", bpm = bpm, gridBpm = grid)

    // ---- BPM label ----
    @Test fun gridBpmShowsOneDecimal() = assertEquals("123.4 BPM", DeckControlMath.bpmLabel(track(bpm = 120.0, grid = 123.44)))
    @Test fun catalogBpmIsRounded() = assertEquals("128 BPM", DeckControlMath.bpmLabel(track(bpm = 127.6)))
    @Test fun noBpmIsNull() = assertNull(DeckControlMath.bpmLabel(track()))
    @Test fun zeroGridFallsBackToCatalog() = assertEquals("100 BPM", DeckControlMath.bpmLabel(track(bpm = 100.0, grid = 0.0)))

    // ---- readouts ----
    @Test fun tempoAndPitchAndEq() {
        assertEquals("1.05×", DeckControlMath.tempoLabel(1.05))
        assertEquals("0", DeckControlMath.pitchLabel(0.0))
        assertEquals("+1.5", DeckControlMath.pitchLabel(1.5))
        assertEquals("-2.0", DeckControlMath.pitchLabel(-2.0))
        assertEquals("0", DeckControlMath.eqLabel(0.0))
        assertEquals("+6", DeckControlMath.eqLabel(6.0))
        assertEquals("-12", DeckControlMath.eqLabel(-12.0))
    }

    @Test fun volBelowAndAtUnityIsPlainPercent() {
        assertEquals("50%", DeckControlMath.volReadout(0.5).text)
        val u = DeckControlMath.volReadout(1.0)
        assertEquals("100%", u.text)
        assertFalse(u.boosted)
    }

    @Test fun volAboveUnityShowsGoldBoostWithDb() {
        val r = DeckControlMath.volReadout(1.5)
        assertTrue(r.boosted)
        assertEquals("150% · +3.5dB", r.text)
        assertEquals("150 percent, plus 3.5 decibels", r.spoken)
        assertEquals("200% · +6.0dB", DeckControlMath.volReadout(2.0).text)
    }

    @Test fun volDragSnapsToUnityWithin003() {
        assertEquals(1.0, DeckControlMath.snapVolume(1.029), 0.0)
        assertEquals(1.0, DeckControlMath.snapVolume(0.971), 0.0)
        assertEquals(1.031, DeckControlMath.snapVolume(1.031), 0.0)
        assertEquals(0.96, DeckControlMath.snapVolume(0.96), 0.0)
    }

    @Test fun clocks() {
        assertEquals("0:00", DeckControlMath.clock(Double.NaN))
        assertEquals("0:00", DeckControlMath.clock(-3.0))
        assertEquals("3:05", DeckControlMath.clock(185.2))
        assertEquals("1:00", DeckControlMath.clock(59.6))
        assertEquals("2:03", DeckControlMath.cueClock(123_999))
        assertEquals("0:00", DeckControlMath.cueClock(-5))
    }

    // ---- steppers ----
    @Test fun stepperClampsAndDisablesAtBounds() {
        val r = 0.5..2.0
        assertEquals(1.01, DeckControlMath.stepTarget(true, 1.0, r, 0.01), 1e-9)
        assertEquals(2.0, DeckControlMath.stepTarget(true, 1.995, r, 0.01), 1e-9)
        assertEquals(0.5, DeckControlMath.stepTarget(false, 0.505, r, 0.01), 1e-9)
        assertFalse(DeckControlMath.stepEnabled(true, 2.0, r))
        assertFalse(DeckControlMath.stepEnabled(false, 0.5, r))
        assertTrue(DeckControlMath.stepEnabled(true, 1.0, r))
        assertTrue(DeckControlMath.stepEnabled(false, 1.0, r))
    }

    // ---- knob ----
    @Test fun knobAngleSpansTheSweep() {
        val r = -12.0..12.0
        assertEquals(-135.0, DeckControlMath.knobAngle(-12.0, r), 1e-9)
        assertEquals(0.0, DeckControlMath.knobAngle(0.0, r), 1e-9)
        assertEquals(135.0, DeckControlMath.knobAngle(12.0, r), 1e-9)
    }

    @Test fun knobDragIsMeasuredFromTheGestureOriginAndClamped() {
        val r = -12.0..12.0
        // dragging up 60 px of 120 = half the span (12 dB) from the origin
        assertEquals(12.0, DeckControlMath.knobValue(0.0, -60.0, r), 1e-9)
        assertEquals(12.0, DeckControlMath.knobValue(0.0, -600.0, r), 1e-9)
        assertEquals(-12.0, DeckControlMath.knobValue(0.0, 600.0, r), 1e-9)
        // the same total translation from the same origin never compounds
        assertEquals(DeckControlMath.knobValue(3.0, -30.0, r), DeckControlMath.knobValue(3.0, -30.0, r), 0.0)
        assertEquals(9.0, DeckControlMath.knobValue(3.0, -30.0, r), 1e-9)
    }

    @Test fun knobAdjustStepsOneTwentieth() {
        val r = -12.0..12.0
        assertEquals(1.2, DeckControlMath.knobAdjust(0.0, true, r), 1e-9)
        assertEquals(12.0, DeckControlMath.knobAdjust(11.5, true, r), 1e-9)
        assertEquals(-12.0, DeckControlMath.knobAdjust(-11.5, false, r), 1e-9)
    }

    // ---- seek slider ----
    @Test fun seekFollowsPlaybackWhenNotDragging() {
        // drag == null (gesture ended / cancelled) -> the live playhead, never a stranded finger value
        assertEquals(0.25, DeckControlMath.shownFraction(null, 50.0, 200.0), 1e-9)
        assertEquals(0.9, DeckControlMath.shownFraction(0.9, 50.0, 200.0), 1e-9)
        assertEquals(0.0, DeckControlMath.shownFraction(null, 50.0, 0.0), 0.0)
        assertEquals(1.0, DeckControlMath.liveFraction(999.0, 200.0), 0.0)
    }

    @Test fun seekFractionFromTouchX() {
        assertEquals(0.5, DeckControlMath.fractionAt(150f, 300f), 1e-9)
        assertEquals(0.0, DeckControlMath.fractionAt(-20f, 300f), 0.0)
        assertEquals(1.0, DeckControlMath.fractionAt(900f, 300f), 0.0)
        assertEquals(0.0, DeckControlMath.fractionAt(10f, 0f), 0.0)
    }

    // ---- VU ----
    @Test fun vuNormalisesOnTheMinus48To3Window() {
        assertEquals(0f, DeckControlMath.vuNorm(0f), 0f)
        assertEquals(1f, DeckControlMath.vuNorm(10f), 0f)       // above +3 dB clamps
        // -12 dBFS and -3 dBFS land on the pinned gradient stops
        assertEquals(DeckControlMath.VU_BLUE_END, DeckControlMath.vuNorm(Math.pow(10.0, -12.0 / 20).toFloat()), 0.001f)
        assertEquals(DeckControlMath.VU_GOLD_END, DeckControlMath.vuNorm(Math.pow(10.0, -3.0 / 20).toFloat()), 0.001f)
        assertEquals(0.706f, DeckControlMath.VU_BLUE_END, 0f)
        assertEquals(0.882f, DeckControlMath.VU_GOLD_END, 0f)
    }

    @Test fun vuPeakLabelAndHotZone() {
        assertEquals("−∞", DeckControlMath.peakDbLabel(-60f))
        assertEquals("−∞", DeckControlMath.peakDbLabel(-48f))
        assertEquals("-6 dB", DeckControlMath.peakDbLabel(-6f))
        assertEquals("+2 dB", DeckControlMath.peakDbLabel(2f))
        assertTrue(DeckControlMath.vuHot(-1f))
        assertFalse(DeckControlMath.vuHot(-1.5f))
    }

    @Test fun vuLivenessAndFill() {
        assertFalse(DeckControlMath.vuLive(0L, 1_000_000_000L))                   // never published
        assertTrue(DeckControlMath.vuLive(1_000_000_000L, 1_200_000_000L))        // 0.2 s old
        assertFalse(DeckControlMath.vuLive(1_000_000_000L, 1_400_000_000L))       // 0.4 s old -> silence
        assertEquals(0f, DeckControlMath.vuFillWidth(0.4f), 0f)
        assertEquals(3f, DeckControlMath.vuFillWidth(1.5f), 0f)
        assertEquals(40f, DeckControlMath.vuFillWidth(40f), 0f)
    }

    // ---- loop ----
    @Test fun loopLabels() {
        assertEquals("2 beats", DeckControlMath.loopLengthLabel(2.0, true))
        assertEquals("1 beat", DeckControlMath.loopLengthLabel(1.0, true))
        assertEquals("4 secs — no beat grid on this track", DeckControlMath.loopLengthLabel(4.0, false))
        assertEquals("On, 8 beats", DeckControlMath.loopSpokenValue(true, 8.0, true))
        assertEquals("On, 2 seconds", DeckControlMath.loopSpokenValue(true, 2.0, false))
        assertEquals("Off", DeckControlMath.loopSpokenValue(false, 2.0, true))
    }

    // ---- cues ----
    @Test fun nextFreeCueSlotFillsGapsAndCapsAtEight() {
        assertEquals(0, DeckControlMath.nextFreeCueSlot(emptySet()))
        assertEquals(2, DeckControlMath.nextFreeCueSlot(setOf(0, 1, 3)))
        assertNull(DeckControlMath.nextFreeCueSlot((0..7).toSet()))
    }

    @Test fun cueSlotColorsAreStableAndWrap() {
        assertEquals(CueSlotColors.argb(0), CueSlotColors.argb(8))
        assertNotNull(CueSlotColors.argb(-1))
        assertEquals(8, (0..7).map { CueSlotColors.argb(it) }.toSet().size)
    }

    // ---- stems + fx chip ----
    @Test fun stemColorsMatchTheSpec() {
        assertEquals(DeckColors.stemRed, DeckColors.stem("bass"))
        assertEquals(DeckColors.stemYellow, DeckColors.stem("drums"))
        assertEquals(DeckColors.stemGreen, DeckColors.stem("other"))
        assertEquals(DeckColors.stemPurple, DeckColors.stem("vocals"))
        assertEquals(DeckColors.accent, DeckColors.stem("mystery"))
    }

    @Test fun fxChipShowsTheVarietyNotTheFamily() {
        val s = FXSlot(Effect.REVERB, EffectVariant.HALL)
        assertEquals("Hall", FxChipRules.chipLabel(s))
        assertEquals("Slot 2, Reverb, Hall", FxChipRules.spoken(1, s))
        assertEquals("off", FxChipRules.state(s))
        assertEquals("on", FxChipRules.state(s.setEnabled(true)))
        val modded = s.setEnabled(true).setMod(SlotMod(source = ModSource.LFO))
        assertTrue(FxChipRules.state(modded).startsWith("on, "))
        assertTrue(FxChipRules.state(modded).endsWith("modulation"))
    }

    @Test fun duplicateFamiliesInTwoSlotsAreIndependent() {
        val a = FXSlot(Effect.FILTER, EffectVariant.LOW_PASS).setEnabled(true)
        val b = FXSlot(Effect.FILTER, EffectVariant.HIGH_PASS)
        assertEquals("LP", FxChipRules.chipLabel(a))
        assertEquals("HP", FxChipRules.chipLabel(b))
    }

    // ---- layout ----
    @Test fun landscapeAlwaysSideBySide() {
        for (p in DeckLayout.entries) assertEquals(DeckLayout.SIDE_BY_SIDE, DeckLayoutRules.effective(p, landscape = true))
        assertEquals(DeckLayout.STACKED, DeckLayoutRules.effective(DeckLayout.STACKED, false))
        assertEquals(DeckLayout.SINGLE, DeckLayoutRules.effective(DeckLayout.SINGLE, false))
        assertTrue(DeckLayoutRules.isLandscape(2400f, 1080f))
        assertFalse(DeckLayoutRules.isLandscape(1080f, 2400f))
    }

    @Test fun singleDeckChevronsFlipBetweenTheTwoDecks() {
        assertEquals(Deck.B, DeckLayoutRules.flip(Deck.A))
        assertEquals(Deck.A, DeckLayoutRules.flip(Deck.B))
    }

    @Test fun layoutRawRoundTripsAndDefaultsToStacked() {
        for (l in DeckLayout.entries) assertEquals(l, DeckLayout.fromRaw(l.raw))
        assertEquals(DeckLayout.STACKED, DeckLayout.fromRaw("garbage"))
        assertEquals(DeckLayout.STACKED, DeckLayout.fromRaw(null))
    }

    @Test fun masterTransport() {
        assertEquals("Pause both decks", DeckLayoutRules.masterLabel(true))
        assertEquals("Play both decks", DeckLayoutRules.masterLabel(false))
        assertFalse(DeckLayoutRules.masterEnabled(false, false))
        assertTrue(DeckLayoutRules.masterEnabled(false, true))
        assertTrue(DeckLayoutRules.compactControls(landscape = false, widthDp = 400))
        assertFalse(DeckLayoutRules.compactControls(landscape = true, widthDp = 400))
        assertFalse(DeckLayoutRules.compactControls(landscape = false, widthDp = 800))
    }

    @Test fun stemChipFollowsPendingHandover() {
        // Loading stems: committed mode still false, chip must read ON so a second tap sends OFF (cancel).
        assertTrue(DeckControlMath.stemChipOn(com.levi.pocketdj.mix.engine.StemHandover.TO_STEMS, false))
        // Returning to full mix: committed still true, chip reads OFF so a tap returns to stems.
        assertFalse(DeckControlMath.stemChipOn(com.levi.pocketdj.mix.engine.StemHandover.TO_FULL_MIX, true))
        assertTrue(DeckControlMath.stemChipOn(null, true))
        assertFalse(DeckControlMath.stemChipOn(null, false))
    }

    @Test fun seekStepIsOneTwentiethMinOneSecond() {
        assertEquals(10.0, DeckControlMath.seekStep(200.0), 1e-9)
        assertEquals(1.0, DeckControlMath.seekStep(10.0), 1e-9)
    }
}

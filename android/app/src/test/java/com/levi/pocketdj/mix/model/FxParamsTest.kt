package com.levi.pocketdj.mix.model

import org.junit.Assert.assertEquals
import org.junit.Assert.assertNotNull
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test

class FxParamsTest {
    private val eps = 1e-3f

    // filter curves

    @Test fun lowPassSweepsLogDown18kTo250() {
        assertEquals(18_000f, FxParams.filterFrequency(EffectVariant.LOW_PASS, 0.0), 0.5f)
        assertEquals(250f, FxParams.filterFrequency(EffectVariant.LOW_PASS, 1.0), 0.01f)
        // geometric midpoint
        assertEquals(Math.sqrt(18_000.0 * 250.0).toFloat(), FxParams.filterFrequency(EffectVariant.LOW_PASS, 0.5), 0.5f)
    }

    @Test fun highPassSweepsLogUp30To2k() {
        assertEquals(30f, FxParams.filterFrequency(EffectVariant.HIGH_PASS, 0.0), 1e-3f)
        assertEquals(2_000f, FxParams.filterFrequency(EffectVariant.HIGH_PASS, 1.0), 0.01f)
    }

    @Test fun bandPassSweepsDown4kTo300AndTightens() {
        assertEquals(4_000f, FxParams.filterFrequency(EffectVariant.BAND_PASS, 0.0), 0.01f)
        assertEquals(300f, FxParams.filterFrequency(EffectVariant.BAND_PASS, 1.0), 0.01f)
        assertEquals(1.5f, FxParams.filterBandwidth(EffectVariant.BAND_PASS, 0.0), eps)
        assertEquals(0.5f, FxParams.filterBandwidth(EffectVariant.BAND_PASS, 1.0), eps)
        assertEquals(0.5f, FxParams.filterBandwidth(EffectVariant.LOW_PASS, 0.7), 0f)
        assertEquals(0.5f, FxParams.filterBandwidth(EffectVariant.HIGH_PASS, 0.2), 0f)
    }

    @Test fun filterStrengthIsClampedAndMonotone() {
        assertEquals(FxParams.filterFrequency(EffectVariant.LOW_PASS, 0.0), FxParams.filterFrequency(EffectVariant.LOW_PASS, -5.0), 0f)
        assertEquals(FxParams.filterFrequency(EffectVariant.LOW_PASS, 1.0), FxParams.filterFrequency(EffectVariant.LOW_PASS, 9.0), 0f)
        var prevLp = Float.MAX_VALUE
        var prevHp = 0f
        var s = 0.0
        while (s <= 1.0) {
            val lp = FxParams.filterFrequency(EffectVariant.LOW_PASS, s)
            val hp = FxParams.filterFrequency(EffectVariant.HIGH_PASS, s)
            assertTrue(lp <= prevLp)
            assertTrue(hp >= prevHp)
            prevLp = lp; prevHp = hp
            s += 0.05
        }
        assertEquals(1_000f, FxParams.filterFrequency(EffectVariant.HALL, 0.5), 0f)   // non-filter variant fallback
    }

    @Test fun filterShapes() {
        assertEquals(FxParams.FilterShape.RESONANT_LOW_PASS, FxParams.filterType(EffectVariant.LOW_PASS))
        assertEquals(FxParams.FilterShape.RESONANT_HIGH_PASS, FxParams.filterType(EffectVariant.HIGH_PASS))
        assertEquals(FxParams.FilterShape.BAND_PASS, FxParams.filterType(EffectVariant.BAND_PASS))
    }

    // reverb

    @Test fun reverbPresets() {
        assertEquals(FxParams.ReverbPreset.MEDIUM_ROOM, FxParams.reverbPreset(EffectVariant.ROOM))
        assertEquals(FxParams.ReverbPreset.PLATE, FxParams.reverbPreset(EffectVariant.PLATE))
        assertEquals(FxParams.ReverbPreset.CATHEDRAL, FxParams.reverbPreset(EffectVariant.CATHEDRAL))
        assertEquals(FxParams.ReverbPreset.MEDIUM_HALL, FxParams.reverbPreset(EffectVariant.HALL))
    }

    // modulation delay

    @Test fun modDelayTimes() {
        assertEquals(0.004, FxParams.modDelayTime(EffectVariant.FLANGE, 0.0), 0.0)
        assertEquals(0.004, FxParams.modDelayTime(EffectVariant.FLANGE, 1.0), 0.0)   // never strength-dependent
        assertEquals(0.012, FxParams.modDelayTime(EffectVariant.CHORUS, 0.0), 1e-12)
        assertEquals(0.025, FxParams.modDelayTime(EffectVariant.CHORUS, 1.0), 1e-12)
        assertEquals(0.15, FxParams.modDelayTime(EffectVariant.ECHO, 0.0), 1e-12)
        assertEquals(0.5, FxParams.modDelayTime(EffectVariant.ECHO, 1.0), 1e-12)
    }

    @Test fun modFeedbackWetDryAndCutoff() {
        assertEquals(60f, FxParams.modFeedback(EffectVariant.FLANGE, 1.0), eps)
        assertEquals(15f, FxParams.modFeedback(EffectVariant.CHORUS, 1.0), eps)
        assertEquals(70f, FxParams.modFeedback(EffectVariant.ECHO, 1.0), eps)
        assertEquals(0f, FxParams.modFeedback(EffectVariant.ECHO, 0.0), 0f)
        assertEquals(50f, FxParams.modWetDryMix(EffectVariant.FLANGE, 1.0), eps)
        assertEquals(45f, FxParams.modWetDryMix(EffectVariant.CHORUS, 1.0), eps)
        assertEquals(50f, FxParams.modWetDryMix(EffectVariant.ECHO, 1.0), eps)
        assertEquals(15_000f, FxParams.modLowPassCutoff(EffectVariant.FLANGE), 0f)
        assertEquals(12_000f, FxParams.modLowPassCutoff(EffectVariant.CHORUS), 0f)
        assertEquals(8_000f, FxParams.modLowPassCutoff(EffectVariant.ECHO), 0f)
    }

    // compressor

    @Test fun compressorThresholdAndMakeupCurves() {
        for (s in listOf(0.0, 0.25, 0.5, 1.0)) {
            assertEquals(-30f * s.toFloat(), FxParams.compThreshold(EffectVariant.PUNCH, s), eps)
            assertEquals(15f * s.toFloat(), FxParams.compMakeup(EffectVariant.PUNCH, s), eps)
            assertEquals(-20f * s.toFloat(), FxParams.compThreshold(EffectVariant.GLUE, s), eps)
            assertEquals(-20f * s.toFloat(), FxParams.compThreshold(EffectVariant.LIMIT, s), eps)
            assertEquals(8f * s.toFloat(), FxParams.compMakeup(EffectVariant.GLUE, s), eps)
            assertEquals(6f * s.toFloat(), FxParams.compMakeup(EffectVariant.LIMIT, s), eps)
        }
        assertEquals(-30f, FxParams.compThreshold(EffectVariant.PUNCH, 5.0), eps)   // clamped
    }

    @Test fun compressorTimings() {
        assertEquals(5f, FxParams.compHeadRoom(EffectVariant.PUNCH), 0f)
        assertEquals(10f, FxParams.compHeadRoom(EffectVariant.GLUE), 0f)
        assertEquals(0.5f, FxParams.compHeadRoom(EffectVariant.LIMIT), 0f)
        assertEquals(0.020f, FxParams.compAttack(EffectVariant.PUNCH), 0f)
        assertEquals(0.030f, FxParams.compAttack(EffectVariant.GLUE), 0f)
        assertEquals(0.001f, FxParams.compAttack(EffectVariant.LIMIT), 0f)
        assertEquals(0.15f, FxParams.compRelease(EffectVariant.PUNCH), 0f)
        assertEquals(0.40f, FxParams.compRelease(EffectVariant.GLUE), 0f)
        assertEquals(0.05f, FxParams.compRelease(EffectVariant.LIMIT), 0f)
    }

    // modulation math

    @Test fun rateBeatsAreMusical() {
        assertEquals(4.0, ModRate.BAR.beats, 0.0)
        assertEquals(2.0, ModRate.HALF.beats, 0.0)
        assertEquals(1.0, ModRate.QUARTER.beats, 0.0)
        assertEquals(2.0 / 3.0, ModRate.QUARTER_TRIPLET.beats, 1e-12)
        assertEquals(0.5, ModRate.EIGHTH.beats, 0.0)
        assertEquals(0.5, ModRate.entries.minOf { it.beats }, 0.0)
    }

    @Test fun waveShapesAtCanonicalPhases() {
        val w = FxParams::wave
        assertEquals(0.0, w(ModShape.SINE, 0.0), 1e-9)
        assertEquals(0.5, w(ModShape.SINE, 0.25), 1e-9)
        assertEquals(1.0, w(ModShape.SINE, 0.5), 1e-9)
        assertEquals(0.5, w(ModShape.SINE, 0.75), 1e-9)
        assertEquals(0.0, w(ModShape.TRIANGLE, 0.0), 1e-9)
        assertEquals(0.5, w(ModShape.TRIANGLE, 0.25), 1e-9)
        assertEquals(1.0, w(ModShape.TRIANGLE, 0.5), 1e-9)
        assertEquals(0.5, w(ModShape.TRIANGLE, 0.75), 1e-9)
        assertEquals(1.0, w(ModShape.SAW, 0.0), 1e-9)
        assertEquals(0.5, w(ModShape.SAW, 0.5), 1e-9)
        assertEquals(0.0, w(ModShape.RAMP, 0.0), 1e-9)
        assertEquals(0.75, w(ModShape.RAMP, 0.75), 1e-9)
        assertEquals(1.0, w(ModShape.SQUARE, 0.25), 0.0)
        assertEquals(0.0, w(ModShape.SQUARE, 0.75), 0.0)
    }

    @Test fun everyWaveStaysInUnitRangeAndIsPeriodic() {
        for (shape in ModShape.entries) {
            var p = -2.0
            while (p <= 3.0) {
                val v = FxParams.wave(shape, p)
                assertTrue("$shape at $p: $v", v in 0.0..1.0)
                assertEquals(v, FxParams.wave(shape, p + 1), 1e-9)
                p += 0.09
            }
        }
    }

    @Test fun modulatedIsExactIdentityWhenOffOrZeroDepth() {
        for (base in listOf(0.0, 0.3, 0.5, 1.0)) {
            assertEquals(base, FxParams.modulated(base, SlotMod(), 0.7, 0.9), 0.0)
            assertEquals(base, FxParams.modulated(base, SlotMod(ModSource.LFO, depth = 0.0), 0.7, 0.9), 0.0)
            assertEquals(base, FxParams.modulated(base, SlotMod(ModSource.ENVELOPE, depth = 0.0), null, 0.9), 0.0)
        }
        assertEquals(1.0, FxParams.modulated(5.0, SlotMod(), null, 0.0), 0.0)   // base itself clamped
    }

    @Test fun lfoNilPhaseIsIdentity() {
        assertEquals(0.4, FxParams.modulated(0.4, SlotMod(ModSource.LFO, depth = 0.8), null, 0.5), 0.0)
    }

    @Test fun lfoIsBipolarAroundBase() {
        val m = SlotMod.of(ModSource.LFO, ModRate.BAR, 0.3, ModShape.SINE)
        assertEquals(0.8, FxParams.modulated(0.5, m, 0.5, 0.0), 1e-9)
        assertEquals(0.2, FxParams.modulated(0.5, m, 0.0, 0.0), 1e-9)
    }

    @Test fun envelopeIsUnipolarAndNegativeDepthDucks() {
        var m = SlotMod(ModSource.ENVELOPE, depth = 0.4)
        assertEquals(0.7, FxParams.modulated(0.3, m, null, 1.0), 1e-9)
        assertEquals(0.3, FxParams.modulated(0.3, m, null, 0.0), 1e-9)
        m = SlotMod(ModSource.ENVELOPE, depth = -0.4)
        assertEquals(0.1, FxParams.modulated(0.5, m, null, 1.0), 1e-9)
    }

    @Test fun modulatedClampsAtBothRails() {
        val deep = SlotMod(ModSource.LFO, depth = 1.0, shape = ModShape.SINE)
        assertEquals(1.0, FxParams.modulated(0.9, deep, 0.5, 0.0), 1e-9)
        assertEquals(0.0, FxParams.modulated(0.1, deep, 0.0, 0.0), 1e-9)
        assertEquals(0.0, FxParams.modulated(0.2, SlotMod(ModSource.ENVELOPE, depth = -1.0), null, 1.0), 1e-9)
    }

    @Test fun modulatesTableScopesTargets() {
        assertEquals(FxParams.ModTarget.CUTOFF, FxParams.modulates(Effect.FILTER))
        assertEquals(FxParams.ModTarget.WET_FEEDBACK, FxParams.modulates(Effect.FLANGER))
        assertNull(FxParams.modulates(Effect.REVERB))
        assertNull(FxParams.modulates(Effect.COMPRESSOR))
        assertNotNull(FxParams.modulates(Effect.FILTER))
    }

    @Test fun envelopeCurveEndpointsAndMonotone() {
        assertEquals(0.0, FxParams.envelopeCurve(0f), 0.0)
        assertEquals(0.0, FxParams.envelopeCurve(-1f), 0.0)
        assertEquals(1.0, FxParams.envelopeCurve(1.0f), 1e-6)
        assertEquals(0.0, FxParams.envelopeCurve(0.01f), 1e-6)
        assertEquals(0.5, FxParams.envelopeCurve(0.1f), 1e-6)
        assertEquals(1.0, FxParams.envelopeCurve(4.0f), 0.0)   // clamped above full scale
        var last = -1.0
        var rms = 0.001
        while (rms <= 1.0) {
            val v = FxParams.envelopeCurve(rms.toFloat())
            assertTrue(v >= last)
            last = v
            rms += 0.013
        }
    }

    @Test fun ballisticsAreBufferSizeIndependent() {
        fun settle(buf: Int, seconds: Double, tau: Double, target: Float): Float {
            val dt = buf / 44_100.0
            val steps = Math.round(seconds / dt).toInt()
            var v = 0f
            val coef = FxParams.ballisticsCoef(dt, tau)
            repeat(steps) { v += (target - v) * coef }
            return v
        }
        assertEquals(settle(1024, 0.5, 0.18, 1f), settle(4096, 0.5, 0.18, 1f), 0.02f)
        assertTrue(settle(1024, 1.0, 0.18, 1f) > 0.99f)
        assertEquals(1f, FxParams.ballisticsCoef(0.0, 0.1), 0f)
        assertEquals(1f, FxParams.ballisticsCoef(0.01, 0.0), 0f)
    }
}

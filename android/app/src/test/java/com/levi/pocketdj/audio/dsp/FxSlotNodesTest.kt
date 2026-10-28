package com.levi.pocketdj.audio.dsp

import com.levi.pocketdj.mix.model.Effect
import com.levi.pocketdj.mix.model.EffectVariant
import com.levi.pocketdj.mix.model.FXSlot
import org.junit.Assert.assertArrayEquals
import org.junit.Assert.assertEquals
import org.junit.Assert.assertTrue
import org.junit.Test

class FxSlotNodesTest {
    @Test fun offSlotIsFullyBypassedAndBitIdentical() {
        val n = FxSlotNodes(SR)
        n.applySlot(FXSlot(Effect.REVERB, enabled = false), 0.5)
        assertEquals(0, n.activeNodeCount)
        val x = sine(500f, 2048, 0.7f)
        val y = x.copyOf(); n.run(y)
        assertArrayEquals(x, y, 0f)
    }

    @Test fun exactlyOneNodeLivePerEffect() {
        val n = FxSlotNodes(SR)
        for (e in Effect.entries) {
            n.applySlot(FXSlot(e, enabled = true, strength = 0.5), 0.5)
            assertEquals("$e", 1, n.activeNodeCount)
        }
        n.applySlot(FXSlot(Effect.FILTER, enabled = false), 0.5)
        assertEquals(0, n.activeNodeCount)
    }

    @Test fun switchingFamilyMovesTheLiveNode() {
        val n = FxSlotNodes(SR)
        n.applySlot(FXSlot(Effect.COMPRESSOR, enabled = true), 0.5)
        assertTrue(!n.comp.bypass && n.filter.bypass && n.reverb.bypass && n.mod.bypass)
        n.applySlot(FXSlot(Effect.FLANGER, enabled = true), 0.5)
        assertTrue(n.comp.bypass && n.filter.bypass && n.reverb.bypass && !n.mod.bypass)
    }

    @Test fun lowPassCutoffFollowsLogCurve() {
        val n = FxSlotNodes(SR)
        val slot = FXSlot(Effect.FILTER, EffectVariant.LOW_PASS, enabled = true, strength = 0.0)
        n.applySlot(slot, 0.0)
        assertEquals(18_000f, n.filter.frequency, 1f)
        n.applySlot(slot, 1.0)
        assertEquals(250f, n.filter.frequency, 0.5f)
        n.applySlot(slot, 0.5)
        assertEquals(Math.sqrt(18_000.0 * 250.0).toFloat(), n.filter.frequency, 1f) // log midpoint
        assertEquals(Biquad.Type.LOW_PASS, n.filter.type)
    }

    @Test fun filterVariantsPickShape() {
        val n = FxSlotNodes(SR)
        n.applySlot(FXSlot(Effect.FILTER, EffectVariant.HIGH_PASS, enabled = true), 0.5)
        assertEquals(Biquad.Type.HIGH_PASS, n.filter.type)
        n.applySlot(FXSlot(Effect.FILTER, EffectVariant.BAND_PASS, enabled = true), 0.5)
        assertEquals(Biquad.Type.BAND_PASS, n.filter.type)
    }

    @Test fun reverbRebuildsOnVariantChangeOnly() {
        val n = FxSlotNodes(SR)
        val hall = FXSlot(Effect.REVERB, EffectVariant.HALL, enabled = true, strength = 0.3)
        n.applySlot(hall, 0.3)
        assertEquals(1, n.reverb.presetLoads)
        n.applySlot(hall.setStrength(0.9), 0.9) // strength only
        n.applySlot(hall, 0.4)                  // modulation-style write
        n.writeSlotParams(hall, 0.7)
        assertEquals(1, n.reverb.presetLoads)
        assertEquals(70f, n.reverb.wetDryMix, 1e-3f)
        n.applySlot(hall.setVariant(EffectVariant.CATHEDRAL), 0.5)
        assertEquals(2, n.reverb.presetLoads)
    }

    @Test fun delayTimeComesFromBaseStrengthNotModulated() {
        val n = FxSlotNodes(SR)
        val chorus = FXSlot(Effect.FLANGER, EffectVariant.CHORUS, enabled = true, strength = 0.2)
        n.applySlot(chorus, 0.9) // modulated value 0.9, base 0.2
        assertEquals(0.012 + 0.013 * 0.2, n.mod.delayTime, 1e-9)
        assertEquals(0.9f * 45f, n.mod.wetDryMix, 1e-3f)
    }

    @Test fun compressorParamsMirrorFxParams() {
        val n = FxSlotNodes(SR)
        n.applySlot(FXSlot(Effect.COMPRESSOR, EffectVariant.GLUE, enabled = true), 0.5)
        assertEquals(-10f, n.comp.thresholdDb, 1e-4f)
        assertEquals(10f, n.comp.headroomDb, 0f)
        assertEquals(4f, n.comp.makeupDb, 1e-4f)
    }

    @Test fun liveFilterSlotAttenuatesHighs() {
        val n = FxSlotNodes(SR)
        n.applySlot(FXSlot(Effect.FILTER, EffectVariant.LOW_PASS, enabled = true), 1.0) // 250 Hz
        assertTrue(gainDbAt(n, 5_000f) < -30)
        assertEquals(0.0, gainDbAt(n, 60f), 1.0)
    }

    @Test fun lowPassFilterIsResonantLikeIos() {
        val n = FxSlotNodes(48_000f)
        val slot = FXSlot(Effect.FILTER, enabled = true, strength = 0.5)
        n.applySlot(slot, 0.5)
        val f = com.levi.pocketdj.mix.model.FxParams.filterFrequency(slot.variant, 0.5)
        val x = FloatArray(2 * 48_000)
        for (i in 0 until 48_000) { val v = (0.1 * Math.sin(2 * Math.PI * f * i / 48_000)).toFloat(); x[2 * i] = v; x[2 * i + 1] = v }
        n.run(x)
        var pk = 0f
        for (i in 24_000 until 48_000) pk = maxOf(pk, Math.abs(x[2 * i]))
        assertTrue("resonant peak at cutoff, got $pk", pk > 0.1f * 1.5f) // Q ~2.9 => ~+9 dB
    }

    @Test fun echoEngageDoesNotGlideFromDefaultDelay() {
        val n = FxSlotNodes()
        n.applySlot(FXSlot(Effect.FLANGER, enabled = true, strength = 1.0), 1.0)
        val target = (n.mod.delayTime * 44_100).toInt()
        val x = FloatArray(2 * 40_000); x[0] = 1f; x[1] = 1f
        n.run(x)
        var best = 0; var bv = 0f
        for (i in 100 until 40_000) if (Math.abs(x[2 * i]) > bv) { bv = Math.abs(x[2 * i]); best = i }
        assertTrue("echo at $best vs $target", Math.abs(best - target) <= 3)
    }
}

package com.levi.pocketdj.playback.dj

import com.levi.pocketdj.mix.model.AutoMixItem
import com.levi.pocketdj.mix.model.Effect
import com.levi.pocketdj.mix.model.MixMath
import com.levi.pocketdj.mix.model.SplitMix64
import kotlin.math.abs
import kotlin.math.sqrt
import kotlin.test.Test
import kotlin.test.assertEquals
import kotlin.test.assertFalse
import kotlin.test.assertNotNull
import kotlin.test.assertNull
import kotlin.test.assertTrue

/** iOS AutoTransitionTests vectors as goldens (1e-9). */
class AutoTransitionTest {
    private val eps = 1e-9

    private fun near(e: Double, a: Double, tol: Double = eps, msg: String = "") =
        assertTrue(abs(e - a) <= tol, "$msg expected $e got $a")

    @Test fun advanceNormalNoGlide() {
        val p = AutoTransition.advancePlan(15.0, 3.0, 10.0, false, false)
        assertFalse(p.isGlide); assertEquals(3.0, p.fadeSeconds); assertEquals(0.0, p.preRollSeconds)
        assertEquals(0.0, p.postRollSeconds); assertNull(p.fadeRestore)
        assertFalse(p.hasPreRoll); assertFalse(p.hasPostRoll)
    }

    @Test fun advanceMixGlideUsesHeadroom() {
        val full = AutoTransition.advancePlan(15.0, 3.0, 10.0, false, true)
        assertTrue(full.isGlide); near(10.0, full.preRollSeconds); assertEquals(10.0, full.postRollSeconds)
        assertTrue(full.hasPreRoll); assertTrue(full.hasPostRoll)
        val fit = AutoTransition.advancePlan(10.0, 3.0, 10.0, false, true)
        near(10 / 1.12 - 3 - 0.3, fit.preRollSeconds)
    }

    @Test fun advanceFxGlideOnlyNoHeadroom() {
        val p = AutoTransition.advancePlan(10.0, 3.0, 10.0, true, false)
        assertTrue(p.isGlide); near(10 - 3 - 0.3, p.preRollSeconds)
        assertEquals(1.0, AutoTransition.headroom(false)); assertEquals(1.12, AutoTransition.headroom(true))
    }

    @Test fun advanceShortRunwayCapsFade() {
        val p = AutoTransition.advancePlan(2.0, 3.0, 10.0, false, false)
        assertEquals(2.0, p.fadeSeconds); assertEquals(3.0, p.fadeRestore)
        val tiny = AutoTransition.advancePlan(0.1, 3.0, 10.0, false, false)
        assertEquals(0.5, tiny.fadeSeconds); assertEquals(3.0, tiny.fadeRestore)
    }

    @Test fun advanceRespectsPendingOverride() {
        val p = AutoTransition.advancePlan(2.0, 3.0, 10.0, false, false, fadeOverridePending = true)
        assertEquals(3.0, p.fadeSeconds); assertNull(p.fadeRestore)
    }

    @Test fun advancePreRollClampsAtZero() {
        for (left in listOf(0.0, 0.2, 1.0, 2.0, 3.2)) {
            val p = AutoTransition.advancePlan(left, 3.0, 10.0, true, true)
            assertTrue(p.preRollSeconds >= 0, "left=$left"); assertFalse(p.hasPreRoll, "left=$left")
        }
        val z = AutoTransition.advancePlan(30.0, 3.0, 0.0, true, true)
        assertEquals(0.0, z.preRollSeconds); assertFalse(z.hasPostRoll)
    }

    @Test fun immediatePlanSkipFade() {
        val p = AutoTransition.immediatePlan(1.0, 3.0, 10.0, false, true)
        assertTrue(p.isGlide); assertEquals(0.0, p.preRollSeconds); assertEquals(1.0, p.fadeSeconds)
        assertEquals(3.0, p.fadeRestore); assertEquals(10.0, p.postRollSeconds)
        val f = AutoTransition.immediatePlan(0.0, 3.0, 10.0, false, false)
        assertEquals(0.2, f.fadeSeconds); assertEquals(0.0, f.postRollSeconds)
        assertNull(AutoTransition.immediatePlan(1.0, 3.0, 10.0, false, false, fadeOverridePending = true).fadeRestore)
    }

    @Test fun leadWindow() {
        assertTrue(AutoTransition.inLeadWindow(15.0, 15.0)); assertTrue(AutoTransition.inLeadWindow(3.0, 15.0))
        assertFalse(AutoTransition.inLeadWindow(15.1, 15.0))
    }

    @Test fun equalPowerEndpointsAndMidpoint() {
        val s = AutoTransition.equalPowerGains(0f)
        near(1.0, s.outgoing.toDouble(), 1e-6); near(0.0, s.incoming.toDouble(), 1e-6)
        val e = AutoTransition.equalPowerGains(1f)
        near(0.0, e.outgoing.toDouble(), 1e-6); near(1.0, e.incoming.toDouble(), 1e-6)
        val m = AutoTransition.equalPowerGains(0.5f)
        near(sqrt(0.5), m.outgoing.toDouble(), 1e-6); near(m.outgoing.toDouble(), m.incoming.toDouble(), 1e-6)
        for (i in 0..20) {
            val g = AutoTransition.equalPowerGains(i / 20f)
            near(1.0, (g.outgoing * g.outgoing + g.incoming * g.incoming).toDouble(), 1e-5)
        }
    }

    @Test fun phaseAlignBoundedByHalfBeatAndLands() {
        val out = AutoTransition.BeatRef(128.0, 250)
        val inc = AutoTransition.BeatRef(120.0, 400)
        for (i in 0 until 200) {
            val outPos = 30 + i * 0.037
            val incPos = 1 + i * 0.011
            val off = AutoTransition.phaseAlignOffset(out, outPos, inc, incPos)
            assertTrue(abs(off) <= 0.25 + 1e-9)
            val lead = AutoTransition.beatPhase(out, outPos)!!.phase
            val after = AutoTransition.beatPhase(inc, incPos + off)!!.phase
            var d = (lead - after) % 1.0
            if (d > 0.5) d -= 1 else if (d < -0.5) d += 1
            near(0.0, d, 1e-6)
        }
    }

    @Test fun phaseAlignMissingBpmIsZero() {
        val known = AutoTransition.BeatRef(120.0, 0)
        val unknown = AutoTransition.BeatRef(null, 300)
        assertEquals(0.0, AutoTransition.phaseAlignOffset(known, 10.13, unknown, 0.4))
        assertEquals(0.0, AutoTransition.phaseAlignOffset(unknown, 10.13, known, 0.4))
        assertEquals(0.0, AutoTransition.phaseAlignOffset(AutoTransition.BeatRef(0.0), 10.13, known, 0.4))
    }

    @Test fun phaseAlignMissingDownbeatIsZero() {
        val a = AutoTransition.phaseAlignOffset(AutoTransition.BeatRef(128.0), 42.3, AutoTransition.BeatRef(120.0), 0.7)
        val b = AutoTransition.phaseAlignOffset(
            AutoTransition.BeatRef(128.0, 0), 42.3, AutoTransition.BeatRef(120.0, 0), 0.7,
        )
        assertEquals(a, b)
        near(-0.08, a)
    }

    @Test fun phaseAlignMsMatchesSeconds() {
        val out = AutoTransition.BeatRef(126.0, 120)
        val inc = AutoTransition.BeatRef(124.0, 80)
        val s = AutoTransition.phaseAlignOffset(out, 61.234, inc, 2.5)
        near(s * 1000, AutoTransition.phaseAlignOffsetMs(out, 61_234.0, inc, 2_500.0), 1e-6)
    }

    @Test fun phaseAlignBeforeDownbeatWithinOneBeat() {
        val out = AutoTransition.BeatRef(120.0, 0)
        val inc = AutoTransition.BeatRef(120.0, 450)
        for (i in 0 until 50) {
            val off = AutoTransition.phaseAlignOffset(out, 60 + i * 0.01, inc, 0.0)
            assertTrue(off > -0.25 - 1e-9); assertTrue(off < 0.5)
        }
    }

    @Test fun beatPhaseUsesGridWhenItBrackets() {
        val ref = AutoTransition.BeatRef(120.0, 0, listOf(0, 500, 1100, 1600))
        val p = AutoTransition.beatPhase(ref, 0.8)!!
        near(0.5, p.phase); near(0.6, p.beatSeconds)
        val after = AutoTransition.beatPhase(ref, 2.25)!!
        near(0.5, after.phase); near(0.5, after.beatSeconds)
        assertNull(AutoTransition.beatPhase(AutoTransition.BeatRef(null, null, listOf(0, 500)), 0.2))
    }

    @Test fun glideParamsMissingData() {
        val keyOnly = AutoTransition.glideParams("8A", "9A", null, 124.0)
        assertEquals(1.0, keyOnly.outRate); assertEquals(1.0, keyOnly.inRate)
        near(AutoTransition.SEMITONES_PER_KEY * 0.5, keyOnly.outPitch)
        near(-AutoTransition.SEMITONES_PER_KEY * 0.5, keyOnly.inPitch)
        val bpmOnly = AutoTransition.glideParams(null, "9A", 120.0, 130.0)
        assertEquals(0.0, bpmOnly.outPitch); assertEquals(0.0, bpmOnly.inPitch)
        near(120 * bpmOnly.outRate, 130 * bpmOnly.inRate, 1e-6)
        assertEquals(AutoTransition.identityGlide, AutoTransition.glideParams(null, null, null, null))
        assertEquals(AutoTransition.identityGlide, AutoTransition.glideParams(null, null, 0.0, 120.0))
    }

    @Test fun glideParamsClampsAndOctaveFold() {
        near(1.0, AutoTransition.octaveFolded(Double.NaN)); near(1.0, AutoTransition.octaveFolded(-3.0))
        near(1.0, AutoTransition.octaveFolded(4.0)); near(0.5, AutoTransition.octaveFolded(0.5))
        near(1.6, AutoTransition.octaveFolded(0.8 * 2))
        near(1.5, AutoTransition.glideRate(5.0).coerceAtMost(1.5))
        near(12.0, AutoTransition.glidePitch(100.0)); near(-12.0, AutoTransition.glidePitch(-100.0))
        // Mix wrapper agrees with the shared module.
        val a = MixMath.glideParams("8A", "11B", 120.0, 133.0)
        val b = AutoTransition.glideParams("8A", "11B", 120.0, 133.0)
        assertEquals(b.outRate, a.outRate); assertEquals(b.inPitch, a.inPitch)
    }

    @Test fun rampsEndpoints() {
        val o0 = AutoTransition.outgoingRamp(0.0, 1.05, 1.6, 0.7)
        assertEquals(1.0, o0.rate); assertEquals(0.0, o0.pitch); assertEquals(0.0, o0.fxStrength)
        val o1 = AutoTransition.outgoingRamp(1.0, 1.05, 1.6, 0.7)
        near(1.05, o1.rate, 1e-12); assertEquals(1.6, o1.pitch); assertEquals(0.7, o1.fxStrength)
        val i0 = AutoTransition.incomingRamp(0.0, 0.95, -1.6, 0.7)
        assertEquals(0.95, i0.rate); assertEquals(-1.6, i0.pitch); assertEquals(0.7, i0.fxStrength)
        val i1 = AutoTransition.incomingRamp(1.0, 0.95, -1.6, 0.7)
        near(1.0, i1.rate, 1e-12); near(0.0, i1.pitch, 1e-12); assertEquals(0.0, i1.fxStrength)
    }

    @Test fun splitmix64KnownVectors() {
        // Reference splitmix64 outputs for seed 0 (published test vectors).
        val r = AutoTransition.Rng(0uL)
        assertEquals(0xE220A8397B1DCDAFuL, AutoTransition.splitmix64(r))
        assertEquals(0x6E789E6AA1B965F4uL, AutoTransition.splitmix64(r))
        assertEquals(0x06C45D188009454FuL, AutoTransition.splitmix64(r))
    }

    @Test fun textureRollIsDeterministicAndInRange() {
        val a = AutoTransition.Rng(AutoTransition.fxSeed("song-a", 4))
        val b = AutoTransition.Rng(AutoTransition.fxSeed("song-a", 4))
        val seen = HashSet<AutoTransition.TextureEffect>()
        repeat(200) {
            val ta = AutoTransition.rollTexture(a); val tb = AutoTransition.rollTexture(b)
            assertEquals(ta, tb)
            assertTrue(ta.peak >= 0.5 && ta.peak < 0.8); assertTrue(ta.run in 3..5)
            seen += ta.effect
        }
        assertEquals(3, seen.size)
        assertEquals(listOf("filter", "reverb", "flanger"), AutoTransition.texturePool.map { it.raw })
    }

    @Test fun fxSeedFnvAndMixAdapter() {
        // FNV-1a of "seed" xor count 0, computed independently.
        var h = 0xcbf29ce484222325uL
        for (c in "seed".toByteArray()) h = (h xor c.toULong()) * 0x100000001b3uL
        assertEquals(h, AutoTransition.fxSeed(null, 0))
        assertEquals(h xor 7uL, AutoTransition.fxSeed(null, 7))
        assertEquals(AutoTransition.fxSeed(null, 0), MixMath.fxSeed(emptyList<AutoMixItem>()))
        // Mix adapter rolls the same texture as the shared module and advances the state identically.
        val m = SplitMix64(123uL); val r = AutoTransition.Rng(123uL)
        val tm = MixMath.rollTexture(m); val tr = AutoTransition.rollTexture(r)
        assertEquals(r.state, m.state); assertEquals(tr.peak, tm.peak); assertEquals(tr.run, tm.run)
        assertEquals(Effect.valueOf(tr.effect.name), tm.effect)
        assertNotNull(tm)
    }
}

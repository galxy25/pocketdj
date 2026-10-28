package com.levi.pocketdj.studio.dsp

import org.junit.Assert.assertEquals
import org.junit.Assert.assertTrue
import org.junit.Test
import kotlin.math.PI
import kotlin.math.abs
import kotlin.math.cos
import kotlin.math.max
import kotlin.math.sin
import kotlin.math.sqrt

class KernelsTest {
    private val sr = 44_100.0

    private class Golden(val track: Array<FloatArray>, val master: Array<FloatArray>)

    /** fx-golden.txt is emitted by the C++ kernels (cpp/pdjdsp/tools/golden.cpp) — the native truth. */
    private fun golden(): Golden {
        val lines = javaClass.getResourceAsStream("/studio/fx-golden.txt")!!.bufferedReader().readLines()
        var i = 0
        fun section(tag: String): Array<FloatArray> {
            check(lines[i].startsWith(tag)) { "expected $tag at line $i" }
            val n = lines[i].split(" ")[1].toInt(); i++
            val l = FloatArray(n); val r = FloatArray(n)
            for (k in 0 until n) { val p = lines[i++].split(" "); l[k] = p[0].toFloat(); r[k] = p[1].toFloat() }
            return arrayOf(l, r)
        }
        val t = section("TRACK"); val m = section("MASTER")
        return Golden(t, m)
    }

    /** Must match tools/golden.cpp. */
    private fun trackInput(n: Int) = arrayOf(FloatArray(n).also { it[0] = 1f }, FloatArray(n).also { it[0] = 0.5f })
    private fun masterInput(n: Int) = arrayOf(
        FloatArray(n) { (0.5 * sin(it * 0.05)).toFloat() }, FloatArray(n) { (0.3 * sin(it * 0.03)).toFloat() },
    )

    private fun maxDiff(a: FloatArray, b: FloatArray): Double {
        assertEquals(a.size, b.size)
        var m = 0.0
        for (i in a.indices) m = max(m, abs(a[i].toDouble() - b[i]))
        return m
    }

    @Test fun trackFxMatchesNativeGoldenImpulseWithin1e5() {
        val g = golden()
        val n = g.track[0].size
        val k = TrackFxKernel(sr, 2)
        k.update(TrackFxParams(eqLowDb = 6.0, eqMidDb = -4.0, eqHighDb = 3.0, reverb = 0.5, delay = 0.4, chorus = 0.5, bpm = 1500.0))
        val d = trackInput(n)
        k.process(d, n)
        assertTrue("L diff ${maxDiff(d[0], g.track[0])}", maxDiff(d[0], g.track[0]) < 1e-5)
        assertTrue("R diff ${maxDiff(d[1], g.track[1])}", maxDiff(d[1], g.track[1]) < 1e-5)
        // sanity: the golden is not silent (the comparison would be vacuous)
        assertTrue(g.track[0].any { abs(it) > 0.01f })
    }

    @Test fun masterFxMatchesNativeGoldenAcrossBlocksWithin1e5() {
        val g = golden()
        val n = g.master[0].size
        val k = MasterFxKernel(sr, 2)
        k.update(MasterFxParams(phaser = true, ringMod = true, brazil = true, drive = true, masterGain = 0.8, bpm = 120.0))
        val d = masterInput(n)
        val half = n / 2
        val first = arrayOf(d[0].copyOfRange(0, half), d[1].copyOfRange(0, half))
        val second = arrayOf(d[0].copyOfRange(half, n), d[1].copyOfRange(half, n))
        k.process(first, half, 0.0)
        k.process(second, half, half.toDouble())
        val outL = first[0] + second[0]; val outR = first[1] + second[1]
        assertTrue("L diff ${maxDiff(outL, g.master[0])}", maxDiff(outL, g.master[0]) < 1e-5)
        assertTrue("R diff ${maxDiff(outR, g.master[1])}", maxDiff(outR, g.master[1]) < 1e-5)
    }

    @Test fun neutralShelvesAndPeakAreIdentityFilters() {
        for (c in listOf(Biquad.lowShelf(0.0, 120.0, sr), Biquad.highShelf(0.0, 8000.0, sr), Biquad.peaking(0.0, 1000.0, 0.9, sr))) {
            assertEquals(1.0, c[0], 1e-12)
            assertEquals(c[3], c[1], 1e-12) // b1 == a1 and b2 == a2 => H(z) == 1
            assertEquals(c[4], c[2], 1e-12)
        }
    }

    /** |H| at [freq] for normalized coefficients {b0,b1,b2,a1,a2}. */
    private fun magDb(c: DoubleArray, freq: Double): Double {
        val w = 2 * PI * freq / sr
        val (nr, ni) = Pair(c[0] + c[1] * cos(w) + c[2] * cos(2 * w), -(c[1] * sin(w) + c[2] * sin(2 * w)))
        val (dr, di) = Pair(1 + c[3] * cos(w) + c[4] * cos(2 * w), -(c[3] * sin(w) + c[4] * sin(2 * w)))
        return 20 * kotlin.math.log10(sqrt(nr * nr + ni * ni) / sqrt(dr * dr + di * di))
    }

    @Test fun eqBandsBoostWhereTheyShould() {
        assertEquals(6.0, magDb(Biquad.lowShelf(6.0, 120.0, sr), 20.0), 0.2)       // low shelf full gain at LF
        assertEquals(0.0, magDb(Biquad.lowShelf(6.0, 120.0, sr), 10_000.0), 0.2)   // flat above
        assertEquals(6.0, magDb(Biquad.highShelf(6.0, 8000.0, sr), 20_000.0), 0.3) // high shelf at HF
        assertEquals(-4.0, magDb(Biquad.peaking(-4.0, 1000.0, 0.9, sr), 1000.0), 0.05) // centre of the peak
    }

    @Test fun inactiveTrackLeavesSignalUntouched() {
        val k = TrackFxKernel(sr, 2)
        val d = masterInput(256)
        val ref = arrayOf(d[0].copyOf(), d[1].copyOf())
        k.process(d, 256)
        assertTrue(d[0].contentEquals(ref[0]) && d[1].contentEquals(ref[1]))
        assertTrue(!k.active)
    }

    @Test fun freeverbWarmUpIsNonSilentAndTailRingsPastTheInput() {
        val dry = trackInput(4096)
        val wet = trackInput(4096)
        TrackFxKernel(sr, 2).apply { update(TrackFxParams(reverb = 0.6)) }.process(wet, 4096)
        // dry impulse has no energy after frame 0; the reverb tail must
        var tailEnergy = 0.0
        for (i in 2000 until 4096) tailEnergy += wet[0][i] * wet[0][i].toDouble()
        assertTrue("tail energy $tailEnergy", tailEnergy > 1e-8)
        for (i in 1 until 4096) assertEquals(0f, dry[0][i], 0f)
    }

    @Test fun delayEchoLandsAnEighthNoteLater() {
        val n = 40_000
        val d = trackInput(n)
        TrackFxKernel(sr, 2).apply { update(TrackFxParams(delay = 1.0, bpm = 120.0)) }.process(d, n)
        val eighth = (60.0 / 120.0 / 2 * sr).toInt() // 11025
        assertTrue("echo at +$eighth: ${d[0][eighth]}", abs(d[0][eighth]) > 0.5f)
        assertTrue(abs(d[0][eighth / 2]) < 1e-6f)
    }

    @Test fun driveSoftClipPeakIsBelowDry() {
        val dry = FloatArray(2048) { (0.9 * sin(it * 0.1)).toFloat() }
        val d = arrayOf(dry.copyOf(), dry.copyOf())
        MasterFxKernel(sr, 2).apply { update(MasterFxParams(drive = true, driveAmount = 0.5)) }.process(d, 2048, 0.0)
        val peak = d[0].maxOf { abs(it) }
        assertTrue("peak $peak", peak < 0.9f && peak > 0.3f)
    }

    private fun bassBlock(): Array<FloatArray> = Array(2) { FloatArray(400) { i -> (0.4 * sin(2 * PI * 60 * i / sr)).toFloat() } }

    @Test fun brazilianBassPumpPhaseIsPositionalSoItSurvivesASeek() {
        val beat = 60.0 / 120.0 * sr
        fun run(framePos: Double, warm: Boolean): FloatArray {
            val k = MasterFxKernel(sr, 2).apply { update(MasterFxParams(brazil = true, brazilAmount = 1.0, bpm = 120.0)) }
            if (warm) k.process(bassBlock(), 400, framePos - 400) // let the one-pole sub LP settle
            val b = bassBlock(); k.process(b, 400, framePos); return b[0]
        }
        val onBeat = run(beat * 8, true)
        val seeked = run(beat * 3, true)     // a different beat, same phase
        val midBeat = run(beat * 3 + beat / 2, true)
        var dOnSeek = 0.0; var dMid = 0.0
        for (i in 0 until 400) { dOnSeek = max(dOnSeek, abs(onBeat[i] - seeked[i]).toDouble()); dMid = max(dMid, abs(onBeat[i] - midBeat[i]).toDouble()) }
        assertTrue("same phase differs by $dOnSeek", dOnSeek < 1e-4)
        assertTrue("mid-beat should pump less ($dMid)", dMid > 0.05)
        // and the beat start pumps harder than the dry input
        assertTrue(onBeat.maxOf { abs(it) } > 0.4f * 1.3f)
    }

    @Test fun neutralMasterIsPassthroughAndFreezeHoldsTheWarmRing() {
        val k = MasterFxKernel(sr, 2)
        val n = 20_000 // > the 0.25 s freeze ring (11025)
        val d = masterInput(n)
        val ref = d[0].copyOf()
        k.process(d, n, 0.0)
        assertTrue(d[0].contentEquals(ref))
        k.update(MasterFxParams(freeze = true))
        val z = Array(2) { FloatArray(11025) }
        k.process(z, 11025, n.toDouble())
        // the frozen output replays the most recent 0.25 s of REAL audio
        val expected = ref.copyOfRange(n - 11025, n)
        assertTrue(maxDiff(z[0], expected) < 1e-6)
    }

    @Test fun masterGainAndSoftClamp() {
        val d = arrayOf(floatArrayOf(0.3f, 1.0f, 1.0f), floatArrayOf(0f, 0f, 0f))
        MasterFxKernel(sr, 2).apply { update(MasterFxParams(masterGain = MasterFxParams.gainFromDb(12.0))) }.process(d, 3, 0.0)
        assertEquals(0.3f * 3.981f, d[0][0], 0.01f)
        assertEquals(1.8f, d[0][1], 0f) // soft clamp at +-1.8; the limiter finishes
    }

    @Test fun masterParamsNativeLayoutIsStable() {
        val a = MasterFxParams(phaser = true, phaserRate = 1.0, ringMod = true, freeze = true, brazil = true, drive = true, masterGain = 2.0, bpm = 90.0).toNativeArray()
        assertEquals(13, a.size)
        assertEquals(listOf(1.0, 1.0, 0.6, 1.0, 200.0, 0.5, 1.0, 1.0, 0.6, 1.0, 0.5, 2.0, 90.0), a.toList())
    }
}

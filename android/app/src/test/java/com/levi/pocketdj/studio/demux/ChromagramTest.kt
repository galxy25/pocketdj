package com.levi.pocketdj.studio.demux

import kotlin.math.PI
import kotlin.math.sin
import org.junit.Assert.assertEquals
import org.junit.Assert.assertTrue
import org.junit.Test

class ChromagramTest {
    private fun tone(freq: Double, n: Int, rate: Int = 44_100) = FloatArray(n) { (0.5 * sin(2 * PI * freq * it / rate)).toFloat() }

    @Test fun binMapFoldsBandOnlyAndMapsA440ToPitchClass9() {
        val cg = Chromagram(44_100)
        val bin = Math.round(440.0 * Chromagram.FFT_SIZE / 44_100).toInt()
        assertEquals(9, cg.binPc[bin])
        assertEquals(-1, cg.binPc[0])
        val tooHigh = Math.ceil(1500.0 * Chromagram.FFT_SIZE / 44_100).toInt()
        assertEquals(-1, cg.binPc[tooHigh])
        val tooLow = (30.0 * Chromagram.FFT_SIZE / 44_100).toInt()
        assertEquals(-1, cg.binPc[tooLow])
    }

    @Test fun frameCountIsIndependentOfBlockSizeAndCarriesAcrossBlocks() {
        val x = tone(440.0, Chromagram.FFT_SIZE * 5 + 1000)
        fun run(block: Int): List<ChromaFrame> {
            val cg = Chromagram(44_100); val out = ArrayList<ChromaFrame>()
            var i = 0
            while (i < x.size) { val n = minOf(block, x.size - i); cg.push(x.copyOfRange(i, i + n), n) { out.add(it) }; i += n }
            return out
        }
        val a = run(x.size); val b = run(777); val c = run(Chromagram.FFT_SIZE)
        assertEquals(5, a.size); assertEquals(5, b.size); assertEquals(5, c.size)
        for (k in 0 until 12) assertEquals(a[2].chroma[k], b[2].chroma[k], 1e-9)
    }

    @Test fun sinePeaksAtItsPitchClassAndReportsRms() {
        val cg = Chromagram(44_100)
        val out = ArrayList<ChromaFrame>()
        cg.push(tone(440.0, Chromagram.FFT_SIZE)) { out.add(it) }
        val f = out.single()
        assertEquals(9, f.chroma.indices.maxBy { f.chroma[it] })
        assertEquals(0.5 / Math.sqrt(2.0), f.rms.toDouble(), 0.01)
        assertEquals(Chromagram.FFT_SIZE * 1000.0 / 44_100, cg.frameMs, 1e-9)
    }

    @Test fun toMonoAveragesChannels() {
        val m = Chromagram.toMono(floatArrayOf(1f, 3f, -1f, 1f), 2)
        assertEquals(2f, m[0], 1e-6f); assertEquals(0f, m[1], 1e-6f)
        assertTrue(Chromagram.toMono(floatArrayOf(), 2).isEmpty())
    }
}

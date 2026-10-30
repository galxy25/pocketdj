package com.levi.pocketdj.mix.graph

import com.levi.pocketdj.audio.dsp.MixDeckLevels
import com.levi.pocketdj.mix.graph.GraphHarness.Companion.peak
import com.levi.pocketdj.mix.graph.GraphHarness.Companion.rms
import com.levi.pocketdj.mix.model.Deck
import com.levi.pocketdj.mix.model.Effect
import com.levi.pocketdj.mix.model.FXSlot
import kotlin.math.abs
import kotlin.math.cos
import kotlin.math.log10
import kotlin.math.PI
import org.junit.Assert.assertArrayEquals
import org.junit.Assert.assertEquals
import org.junit.Assert.assertSame
import org.junit.Assert.assertTrue
import org.junit.Test

class MixGraphRenderTest {
    private val TONE = 441.0 // exactly 100 samples per cycle at 44.1 kHz

    private fun single(amp: Float = 0.5f): GraphHarness {
        val h = GraphHarness()
        h.playMain(Deck.A, h.toneVoice(TONE, amp))
        h.composer.setCrossfader(0f)
        h.render(4096)
        return h
    }

    @Test fun deckAThroughTheWholeChainKeepsTheSourceLevelAtUnity() {
        val h = single(0.5f)
        val out = h.render(8192)
        assertEquals(0.5f, peak(out, 1000), 2e-3f)
    }

    @Test fun silentDeckBAddsNothingToTheHouse() {
        val h = single(0.5f)
        assertEquals(0f, peak(h.graph.b.out, 0, 256), 0f)
    }

    @Test fun gainIdentitySplitForVolumeRange() {
        for (v in listOf(0.0, 0.25, 0.5, 1.0, 1.5, 2.0)) for (x in listOf(0f, 0.3f, 1f)) {
            val main = Routing.mainGain(v, x)
            assertEquals(minOf(v, 1.0).toFloat() * x, main, 1e-6f)
            assertEquals((20 * log10(maxOf(v, 1.0))).toFloat(), Routing.trimDb(v), 1e-5f)
        }
        assertEquals(6.0206f, Routing.trimDb(2.0), 1e-3f)
        assertEquals(0f, Routing.trimDb(0.4), 0f)
    }

    @Test fun renderedLevelFollowsVolumeAndBoost() {
        val h = single(0.4f)
        h.composer.setVolume(Deck.A, 0.5)
        var out = h.render(8192)
        assertEquals(0.2f, peak(out, 2000), 2e-3f)
        h.composer.setVolume(Deck.A, 2.0) // main fader 1.0, trim +6.02 dB
        h.render(4096)
        out = h.render(8192)
        assertEquals(0.4f * 1.9953f, peak(out, 2000), 6e-3f)
    }

    @Test fun equalPowerCrossfadeKeepsPowerConstantAcrossTheTravel() {
        val h = GraphHarness()
        h.playMain(Deck.A, h.toneVoice(441.0, 0.5f))
        h.playMain(Deck.B, h.toneVoice(882.0, 0.5f))
        val expected = 0.5 / Math.sqrt(2.0)
        for (x in listOf(0f, 0.2f, 0.5f, 0.8f, 1f)) {
            h.composer.setCrossfader(x)
            h.render(4096)
            val out = h.render(8820)
            val r = rms(out, 0, 8820, 0)
            assertEquals("crossfader $x", expected, r, expected * 0.02)
        }
        // factors themselves: cos/sin law
        h.composer.setCrossfader(0.5f)
        assertEquals(cos(PI / 4).toFloat(), h.composer.current.a.mainGain, 1e-5f)
        assertEquals(cos(PI / 4).toFloat(), h.composer.current.b.mainGain, 1e-5f)
    }

    @Test fun limiterHoldsTwoBoostedDecksUnderTheCeiling() {
        val h = GraphHarness()
        h.playMain(Deck.A, h.toneVoice(441.0, 0.9f))
        h.playMain(Deck.B, h.toneVoice(441.0, 0.9f))
        h.composer.setCrossfader(0.5f)
        h.composer.setVolume(Deck.A, 2.0)
        h.composer.setVolume(Deck.B, 2.0)
        h.render(8192)
        val out = h.render(16384)
        val p = peak(out, 0)
        assertTrue("limited $p", p <= 1.0f)
        assertTrue("still loud $p", p > 0.9f)
    }

    @Test fun disabledSlotsAreBitIdenticalToNoSlotsAndSwapsNeverReallocate() {
        val plain = single(0.5f).render(8192)
        val h2 = GraphHarness()
        h2.playMain(Deck.A, h2.toneVoice(TONE, 0.5f))
        h2.composer.setCrossfader(0f)
        val before = h2.graph.a.slotNodes.map { it }
        h2.composer.setSlots(Deck.A, listOf(SlotParams(FXSlot(Effect.FILTER, enabled = false), 0.5), null, null, null))
        h2.render(4096)
        val withBypassed = h2.render(8192)
        assertEquals(plain.size, withBypassed.size)
        // swap through every family on slot 0: nodes are the same instances, <=1 active
        for (e in listOf(Effect.COMPRESSOR, Effect.REVERB, Effect.FLANGER, Effect.FILTER)) {
            h2.composer.setSlots(Deck.A, listOf(SlotParams(FXSlot(e, enabled = true, strength = 0.5), 0.5), null, null, null))
            h2.render(1024)
            assertTrue(h2.graph.a.slotNodes[0].activeNodeCount <= 1)
        }
        h2.composer.setSlots(Deck.A, emptyList())
        h2.render(1024)
        assertTrue(h2.graph.a.slotNodes.all { it.activeNodeCount == 0 })
        h2.graph.a.slotNodes.forEachIndexed { i, n -> assertSame(before[i], n) }
    }

    @Test fun bypassedSlotsDoNotChangeTheSignalBitForBit() {
        fun run(slots: List<SlotParams?>): FloatArray {
            val h = GraphHarness()
            h.playMain(Deck.A, h.toneVoice(TONE, 0.5f))
            h.composer.setCrossfader(0f)
            h.composer.setSlots(Deck.A, slots)
            return h.render(16384)
        }
        val none = run(emptyList())
        val off = run(listOf(SlotParams(FXSlot(Effect.REVERB, enabled = false), 0.5), SlotParams(FXSlot(Effect.COMPRESSOR, enabled = false), 0.5), null, null))
        assertArrayEquals(none, off, 0f)
    }

    @Test fun vuTapsReportPreAndPostFaderLevels() {
        val h = single(0.5f)
        h.composer.setVolume(Deck.A, 0.5)
        h.render(65536)
        val lv: MixDeckLevels = h.graph.levelsOf(Deck.A)
        assertEquals(0.5f, lv.prePeak, 0.02f)
        assertEquals(0.25f, lv.postPeak, 0.02f)
        assertTrue(lv.updates > 0)
        assertTrue("envelope follows the signal", h.graph.a.envelope.value > 0.1f)
    }

    @Test fun tapPulseAdvancesOnlyWhileAudible() {
        val h = single(0.5f)
        val t1 = h.graph.pulse.lastAudibleAt
        assertTrue(t1 > 0)
        Thread.sleep(2)
        h.render(2048)
        assertTrue(h.graph.pulse.lastAudibleAt > t1)
        // a graph with nothing loaded renders but is never audible
        val silent = GraphHarness()
        silent.render(4096)
        assertTrue(silent.graph.pulse.lastRenderAt > 0)
        assertEquals(0L, silent.graph.pulse.lastAudibleAt)
    }

    @Test fun deckCaptureSeamSeesThePostTrimBlocks() {
        val h = single(0.5f)
        var frames = 0
        var pk = 0f
        h.graph.deckCapture = MixDeckCapture { d, buf, n -> if (d == Deck.A) { frames += n; for (i in 0 until n * 2) pk = maxOf(pk, abs(buf[i])) } }
        h.render(4096)
        assertEquals(4096, frames)
        assertEquals(0.5f, pk, 2e-3f)
    }

    @Test fun renderLoopAllocatesNothingPerBlock() {
        val h = GraphHarness(256)
        h.playMain(Deck.A, h.toneVoice(441.0, 0.5f))
        h.playMain(Deck.B, h.toneVoice(882.0, 0.5f))
        h.graph.deckCapture = null
        h.composer.setCrossfader(0.5f)
        h.composer.setSlots(Deck.A, listOf(SlotParams(FXSlot(Effect.FILTER, enabled = true, strength = 0.5), 0.5), null, null, null))
        // a stems deck, a cued deck and periodic handovers are part of the measured loop
        h.graph.setStems(Deck.B, h.stemGroup(882.0, 0.5f))
        h.composer.setCued(Deck.B, true)
        val bean = Class.forName("java.lang.management.ManagementFactory").getMethod("getThreadMXBean").invoke(null)
        val getAlloc = Class.forName("com.sun.management.ThreadMXBean").getMethod("getThreadAllocatedBytes", Long::class.javaPrimitiveType)
        val tid = Thread.currentThread().id
        fun now(): Long = getAlloc.invoke(bean, tid) as Long
        val buf = FloatArray(256 * 2)
        // warm up the JIT and every lazily-initialised path
        repeat(300) { h.pumpAll(); h.graph.render(buf, 256); h.sink.clock.advance(256) }
        // per-measurement overhead of the reflective probe itself (boxing), taken as the minimum of empty pairs
        var overhead = Long.MAX_VALUE
        repeat(200) { val a0 = now(); val d = now() - a0; if (d < overhead) overhead = d }
        var allocated = 0L
        var allocatingBlocks = 0
        val blocks = 10_000
        var i = 0
        while (i < blocks) {
            h.pumpAll()
            if (i % 1500 == 0) h.graph.crossfadeTo(Deck.B, (i / 1500) % 2 == 0) // control-side, outside the probe
            val a0 = now()
            h.graph.render(buf, 256)
            val d = maxOf(0L, now() - a0 - overhead)
            if (d > 0) allocatingBlocks++
            allocated += d
            h.sink.clock.advance(256)
            i++
        }
        // Steady state is zero. A handful of blocks may show bytes from JIT/OSR bookkeeping that is
        // not ours (they vary run to run and never recur per block): <= 0.1 % of blocks.
        assertTrue("render allocated $allocated bytes in $allocatingBlocks of $blocks blocks", allocatingBlocks <= blocks / 1000)
    }

    @Test fun idleChainDrainsTheTailThenSkipsTheStretcherWithConstantLatency() {
        val h = single(0.5f)
        val lat = h.graph.b.latencyFrames
        h.graph.setMain(Deck.A, null)
        val out = h.render(sr44 * 2)
        // tail drained: silence at the end, latency unchanged, clock still advances
        assertEquals(0f, peak(out, sr44 * 2 - 2048, sr44 * 2), 1e-6f)
        val clock = h.graph.a.inputClock
        h.render(4096)
        assertTrue(h.graph.a.inputClock > clock)
        assertEquals(lat, h.graph.a.latencyFrames)
        // a voice installed afterwards plays at full level again
        h.playMain(Deck.A, h.toneVoice(TONE, 0.5f))
        assertEquals(0.5f, peak(h.render(8192), 4000), 2e-3f)
    }
    private val sr44 = 44_100
}

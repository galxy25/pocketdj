package com.levi.pocketdj.mix.engine

import com.levi.pocketdj.audio.dsp.FxSlotNodes
import com.levi.pocketdj.mix.model.Deck
import com.levi.pocketdj.mix.model.Effect
import com.levi.pocketdj.mix.model.FXSlot
import com.levi.pocketdj.mix.model.FxParams
import com.levi.pocketdj.mix.model.LoadedTrack
import com.levi.pocketdj.mix.model.ModRate
import com.levi.pocketdj.mix.model.ModShape
import com.levi.pocketdj.mix.model.ModSource
import com.levi.pocketdj.mix.model.SlotMod
import com.levi.pocketdj.mix.store.FXSlotSnapshot
import com.levi.pocketdj.screens.mix.SlotModSheetRules
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNotNull
import org.junit.Assert.assertNull
import org.junit.Assert.assertSame
import org.junit.Assert.assertTrue
import org.junit.Test

class ModControllerTest {
    private val A = Deck.A
    private val grid120 = LoadedTrack("s", "t", "a", bpm = 120.0, gridBpm = 120.0, firstDownbeatMs = 0)
    private fun filterSlot(mod: SlotMod, strength: Double = 0.5, enabled: Boolean = true) =
        FXSlot(Effect.FILTER, null, enabled, strength, mod)

    private class Rig {
        val A = Deck.A
        val h = EngineHarness()
        val driver = ManualTickDriver()
        var pos: Double? = 0.0
        var env = 0.0
        var nano = 1_000_000_000L
        val mc = ModController(h.engine, driver, hydrator = null, nanoClock = { nano }, playhead = { pos }, envelope = { env })
            .also { it.install() }

        fun startPlaying(gridBpm: Double = 120.0, mod: SlotMod, strength: Double = 0.5, effect: Effect = Effect.FILTER) {
            h.engine.load(h.addSong("s", gridBpm = gridBpm, firstDownbeatMs = 0), A)
            h.engine.setSlotEffect(effect, 0, A)
            h.engine.setSlotStrength(0, strength, A)
            h.engine.setSlot(0, true, A)
            h.engine.setSlotMod(mod, 0, A)
            h.engine.play(A)
        }
        fun step(atSec: Double): Boolean { pos = atSec; nano += 16_000_000; return driver.block?.invoke() ?: false }
        val live: Double get() = h.engine.params.inputs(A).slots[0]!!.strength
    }

    // ------------------------------------------------------------------ pure phase math

    @Test fun oneBarAt120BpmIsTwoSecondsOfSourceTime() {
        val s = filterSlot(SlotMod(ModSource.LFO, ModRate.BAR))
        assertEquals(0.0, ModMath.lfoPhase(grid120, s, 0.0)!!, 1e-9)
        assertEquals(0.25, ModMath.lfoPhase(grid120, s, 0.5)!!, 1e-9)
        assertEquals(0.5, ModMath.lfoPhase(grid120, s, 1.0)!!, 1e-9)
        assertEquals(0.0, ModMath.lfoPhase(grid120, s, 2.0)!!, 1e-9)   // one full cycle per 2 s
        assertEquals(0.25, ModMath.lfoPhase(grid120, s, 2.5)!!, 1e-9)
    }

    @Test fun tempoFollowsBecauseThePhaseIsSourceTime() {
        // 1.5x tempo: 2 s of SOURCE passes in 1.333 s wall; the clock extrapolates at rate x wall.
        val step = ModMath.clockPosition(null, 4.0, 4.0, 0L, 100_000_000L, 1.5)
        assertEquals(4.15, step.seconds, 1e-9)                           // 0.1 s wall x 1.5
        val s = filterSlot(SlotMod(ModSource.LFO, ModRate.BAR))
        val wallForCycle = 2.0 / 1.5
        assertEquals(1.3333, wallForCycle, 1e-3)
        assertEquals(ModMath.lfoPhase(grid120, s, 0.0)!!, ModMath.lfoPhase(grid120, s, 2.0)!!, 1e-9)
    }

    @Test fun extrapolationIsClampedAndTruePlayheadWins() {
        assertEquals(10.15, ModMath.clockPosition(null, 10.0, 10.0, 0L, 5_000_000_000L, 1.0).seconds, 1e-9)
        assertEquals(7.0, ModMath.clockPosition(7.0, 10.0, 10.0, 0L, 5_000_000_000L, 1.0).seconds, 1e-9)
        // a fresh position restamps and is returned as is
        val fresh = ModMath.clockPosition(null, 11.0, 10.0, 0L, 9L, 1.0)
        assertEquals(11.0, fresh.seconds, 1e-9); assertEquals(9L, fresh.stamp)
    }

    @Test fun phaseOffsetAndRateShiftTheCycle() {
        val half = filterSlot(SlotMod(ModSource.LFO, ModRate.BAR, phase = 0.5))
        assertEquals(0.5, ModMath.lfoPhase(grid120, half, 0.0)!!, 1e-9)
        val eighth = filterSlot(SlotMod(ModSource.LFO, ModRate.EIGHTH))
        assertEquals(0.0, ModMath.lfoPhase(grid120, eighth, 0.25)!!, 1e-9)   // 1/8 note = 0.25 s at 120
        val noBpm = LoadedTrack("s", "t", "a")
        assertNull(ModMath.lfoPhase(noBpm, half, 1.0))
    }

    @Test fun measuredGridBeatsTheLattice() {
        // beats every 600 ms (100 bpm measured) while the catalog says 120
        val t = LoadedTrack("s", "t", "a", bpm = 120.0, beatsMs = (0..40).map { it * 600 }, downbeatsMs = listOf(0, 2400))
        val s = filterSlot(SlotMod(ModSource.LFO, ModRate.BAR))
        assertEquals(0.25, ModMath.lfoPhase(t, s, 0.6)!!, 1e-6)
    }

    // ------------------------------------------------------------------ strength composition

    @Test fun envelopePushesWithPositiveDepthAndDucksWithNegative() {
        val up = filterSlot(SlotMod(ModSource.ENVELOPE, depth = 0.4))
        val down = filterSlot(SlotMod(ModSource.ENVELOPE, depth = -0.4))
        assertEquals(0.5, ModMath.effectiveStrength(up, true, null, 0.0), 1e-9)
        assertEquals(0.7, ModMath.effectiveStrength(up, true, null, 0.5), 1e-9)
        assertEquals(0.9, ModMath.effectiveStrength(up, true, null, 1.0), 1e-9)
        assertEquals(0.3, ModMath.effectiveStrength(down, true, null, 0.5), 1e-9)
        assertEquals(0.1, ModMath.effectiveStrength(down, true, null, 1.0), 1e-9)
    }

    @Test fun reverbAndCompressorDoNotModulate() {
        for (e in listOf(Effect.REVERB, Effect.COMPRESSOR)) {
            val s = FXSlot(e, null, true, 0.5, SlotMod(ModSource.ENVELOPE, depth = 1.0))
            assertFalse(ModMath.isLive(s))
            assertEquals(0.5, ModMath.effectiveStrength(s, true, null, 1.0), 1e-12)
            assertNotNull(SlotModSheetRules.unsupportedNote(e))
        }
        assertNull(SlotModSheetRules.unsupportedNote(Effect.FILTER))
        assertNull(SlotModSheetRules.unsupportedNote(Effect.FLANGER))
    }

    @Test fun pausedDeckAndOffSourceSitOnTheStoredValue() {
        val lfo = filterSlot(SlotMod(ModSource.LFO, ModRate.BAR, depth = 1.0))
        assertEquals(0.5, ModMath.effectiveStrength(lfo, false, 0.0, 1.0), 1e-12)
        val off = filterSlot(SlotMod(ModSource.OFF, depth = 1.0))
        assertEquals(0.5, ModMath.effectiveStrength(off, true, 0.0, 1.0), 1e-12)
        val zero = filterSlot(SlotMod(ModSource.LFO, depth = 0.0))
        assertEquals(0.5, ModMath.effectiveStrength(zero, true, 0.5, 0.0), 1e-12)
    }

    // ------------------------------------------------------------------ the tick, on a real engine

    @Test fun lfoTickWobblesTheRenderSnapshotButNeverTheStoredStrength() {
        val r = Rig()
        r.startPlaying(mod = SlotMod(ModSource.LFO, ModRate.BAR, depth = 0.5, shape = ModShape.SINE))
        assertTrue(r.mc.isTicking)
        r.step(0.0)      // phase 0 -> sine wave 0 -> base - depth
        assertEquals(0.0, r.live, 1e-9)
        r.step(1.0)      // phase .5 -> wave 1 -> base + depth
        assertEquals(1.0, r.live, 1e-9)
        r.step(0.5)      // phase .25 -> wave .5 -> base
        assertEquals(0.5, r.live, 1e-9)
        assertEquals(0.5, r.h.engine.deckState(A).slots[0].strength, 0.0)   // strength untouched
    }

    @Test fun phaseIsDerivedFromThePlayheadNotIntegrated() {
        val r = Rig()
        r.startPlaying(mod = SlotMod(ModSource.LFO, ModRate.BAR, depth = 0.5))
        r.step(0.0); val a = r.live
        repeat(50) { r.step(0.0) }                      // 50 ticks with a frozen playhead: no drift
        assertEquals(a, r.live, 1e-12)
        r.step(2.0)                                     // a whole cycle later
        assertEquals(a, r.live, 1e-9)
        r.step(0.7); r.step(0.0)                        // a seek back lands on the same phase again
        assertEquals(a, r.live, 1e-12)
    }

    @Test fun envelopeDrivesTheTickAndAStaleTapReadsAsSilence() {
        val r = Rig()
        r.startPlaying(mod = SlotMod(ModSource.ENVELOPE, depth = 0.4))
        r.env = 1.0; r.step(1.0)
        assertEquals(0.9, r.live, 1e-9)
        r.env = 0.0; r.step(1.0)
        assertEquals(0.5, r.live, 1e-9)
        // the default envelope reader treats a never-updated follower as silence
        val e = Rig()
        val defaultEnv = ModController(e.h.engine, ManualTickDriver())
        e.startPlaying(mod = SlotMod(ModSource.ENVELOPE, depth = 1.0))
        assertEquals(0.5, defaultEnv.strengthFor(A, 0, e.h.engine.deckState(A).slots[0]), 1e-9)
    }

    @Test fun pausingSnapsEveryNodeBackOntoTheStoredValuesAndTheTickExits() {
        val r = Rig()
        r.startPlaying(mod = SlotMod(ModSource.LFO, ModRate.BAR, depth = 0.5))
        r.step(1.0)
        assertEquals(1.0, r.live, 1e-9)
        r.h.engine.pause(A)
        assertEquals(false, r.step(1.0))                // snap-back then self-terminate
        assertEquals(0.5, r.live, 1e-9)
        assertFalse(r.mc.isTicking)
        // a paused deck's stored and live values agree for every later write too
        r.h.engine.setSlotStrength(0, 0.8, A)
        assertEquals(0.8, r.live, 1e-9)
    }

    @Test fun glideMovesTheBaseWhileTheLfoWobblesAroundIt() {
        val r = Rig()
        r.startPlaying(mod = SlotMod(ModSource.LFO, ModRate.BAR, depth = 0.2, shape = ModShape.SINE))
        r.step(1.0)                                      // wave 1 => +depth
        assertEquals(0.7, r.live, 1e-9)
        r.h.engine.setSlotStrength(0, 0.6, A)            // base moved (what a glide step does)
        assertEquals(0.8, r.live, 1e-9)                  // composed, not stomped
        r.step(0.0)                                      // trough
        assertEquals(0.4, r.live, 1e-9)
        assertEquals(0.6, r.h.engine.deckState(A).slots[0].strength, 1e-12)
        // the glide machine's own write path composes through the same provider
        val viaList = r.h.engine.slotParamList(A)[0]!!.strength
        assertEquals(r.live, viaList, 1e-12)
    }

    @Test fun idleLfoDoesNotRepublishInsideTheDeadBand() {
        val r = Rig()
        r.startPlaying(mod = SlotMod(ModSource.LFO, ModRate.BAR, depth = 0.5))
        r.step(1.0)
        val snap = r.h.engine.params.current
        r.step(1.0); r.step(1.0)
        assertSame(snap, r.h.engine.params.current)
    }

    @Test fun noTickWithoutALivePlayingSlot() {
        val r = Rig()
        r.h.engine.load(r.h.addSong("s", gridBpm = 120.0), A)
        r.h.engine.setSlotEffect(Effect.REVERB, 0, A)
        r.h.engine.setSlot(0, true, A)
        r.h.engine.setSlotMod(SlotMod(ModSource.LFO), 0, A)
        r.h.engine.play(A)
        assertFalse(r.mc.isTicking)                      // reverb does not modulate
        r.h.engine.setSlotEffect(Effect.FILTER, 0, A)
        assertTrue(r.mc.isTicking)                       // switching family makes it worth ticking
        r.h.engine.setSlotMod(SlotMod(ModSource.OFF), 0, A)
        assertEquals(false, r.step(0.0))                 // source Off: the tick exits on its own
    }

    @Test fun flangerPumpsWetAndFeedbackButDelayTimeStaysOnTheBase() {
        val v = FXSlot(Effect.FLANGER).variant
        val nodes = FxSlotNodes()
        val slot = FXSlot(Effect.FLANGER, v, true, 0.3, SlotMod(ModSource.LFO, depth = 0.5))
        val expected = FxParams.modDelayTime(v, 0.3)
        for (live in listOf(0.0, 0.3, 0.8, 1.0)) {
            nodes.applySlot(slot, live)
            assertEquals(expected, nodes.mod.delayTime, 1e-12)   // never at tick rate
        }
        val r = Rig()
        r.startPlaying(mod = SlotMod(ModSource.LFO, ModRate.BAR, depth = 0.5), effect = Effect.FLANGER)
        r.step(0.0); val lo = r.h.engine.params.inputs(A).slots[0]!!
        r.step(1.0); val hi = r.h.engine.params.inputs(A).slots[0]!!
        assertTrue(hi.strength > lo.strength)
        assertEquals(lo.slot.strength, hi.slot.strength, 0.0)      // the node sees the same BASE
    }

    // ------------------------------------------------------------------ persistence + sheet rules

    @Test fun modPersistsAsOptionalStringsAndUnknownValuesDegradeToOff() {
        val s = filterSlot(SlotMod(ModSource.LFO, ModRate.QUARTER_TRIPLET, -0.6, ModShape.SAW, 0.25))
        val snap = FXSlotSnapshot.from(s)
        assertEquals("lfo", snap.modSource); assertEquals("quarterTriplet", snap.modRate); assertEquals("saw", snap.modShape)
        assertEquals(s.mod, snap.toSlot().mod)
        val future = snap.copy(modSource = "chaos", modRate = "13/7", modShape = "fractal")
        assertEquals(SlotMod(ModSource.OFF, ModRate.BAR, -0.6, ModShape.SINE, 0.25), future.toSlot().mod)
        val old = FXSlotSnapshot(effect = "filter", variant = snap.variant, on = true, strength = 0.5)
        assertEquals(ModSource.OFF, old.toSlot().mod.source)
    }

    @Test fun sheetCopyAndRules() {
        val gridded = grid120.copy(beatsMs = listOf(0, 500, 1000))
        assertEquals("1/2", SlotModSheetRules.rateLabel(ModRate.HALF, gridded))
        assertEquals("1/2 est.", SlotModSheetRules.rateLabel(ModRate.HALF, grid120))
        assertNull(SlotModSheetRules.gridHint(gridded))
        assertTrue(SlotModSheetRules.gridHint(grid120)!!.contains("catalog BPM"))
        assertTrue(SlotModSheetRules.gridHint(LoadedTrack("s", "t", "a"))!!.contains("No BPM"))
        assertTrue(SlotModSheetRules.gridHint(null)!!.contains("No BPM"))
        assertEquals("+50%", SlotModSheetRules.depthLabel(0.5))
        assertEquals("-30%", SlotModSheetRules.depthLabel(-0.3))
        assertEquals("+0%", SlotModSheetRules.depthLabel(0.0))
        assertEquals(0.25, SlotModSheetRules.nextPhase(0.0), 1e-12)
        assertEquals(0.0, SlotModSheetRules.nextPhase(0.75), 1e-12)
        assertEquals("φ 50%", SlotModSheetRules.phaseLabel(0.5))
        assertTrue(SlotModSheetRules.envelopeNote(0.3).contains("push"))
        assertTrue(SlotModSheetRules.envelopeNote(-0.3).contains("DUCK"))
    }
}

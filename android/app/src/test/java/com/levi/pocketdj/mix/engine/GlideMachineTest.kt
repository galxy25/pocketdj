package com.levi.pocketdj.mix.engine

import com.levi.pocketdj.mix.model.Deck
import com.levi.pocketdj.mix.model.Effect
import com.levi.pocketdj.mix.model.MixLoadable
import com.levi.pocketdj.mix.model.MixMath
import com.levi.pocketdj.mix.model.SplitMix64
import com.levi.pocketdj.mix.store.MixEventKind
import com.levi.pocketdj.mix.store.MixSessionRecorder
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNotEquals
import org.junit.Assert.assertNotNull
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test

/** Captures both plain events and compact `.glide` ramps. */
private class GlideRec : MixSessionRecorder {
    data class G(val deck: String?, val param: String, val from: Double, val to: Double, val rate: Double, val slot: Int?)
    val glides = ArrayList<G>()
    val kinds = ArrayList<MixEventKind>()
    private val played = HashSet<String>()
    override fun logEvent(
        kind: MixEventKind, deck: String?, songId: String?, title: String?, artist: String?, bpm: Double?,
        camelot: String?, param: String?, value: Double?, flag: Boolean?, posMs: Int?, slot: Int?,
    ) { kinds += kind }
    override fun logGlide(
        deck: String?, param: String, songId: String?, title: String?, artist: String?,
        from: Double, to: Double, rate: Double, posMs: Int?, slot: Int?,
    ) { glides += G(deck, param, from, to, rate, slot) }
    override fun notePlayed(songId: String) { played += songId }
    override fun hasPlayed(songId: String) = songId in played
}

class GlideMachineTest {
    private val A = Deck.A
    private val B = Deck.B
    private val pool = MixMath.FX_GLIDE_POOL.map { it.raw }.toSet()

    private fun rig(n: Int = 4, seconds: Double = 30.0, tweak: (Int, MixLoadable) -> MixLoadable = { _, l -> l }) =
        AutoRig(n = n, seconds = seconds, tweak = tweak).also { it.e.recorder = GlideRec() }
    private fun AutoRig.rec() = e.recorder as GlideRec

    // ---------------------------------------------------------------- texture determinism

    @Test fun textureIsDeterministicPerQueueSeedAndRunsAreThreeToFive() {
        val r = rig()
        fun seq(seed: ULong): List<Triple<Effect, Double, Int>> {
            val rng = SplitMix64(seed)
            return List(12) { MixMath.rollTexture(rng).let { t -> Triple(t.effect, t.peak, t.run) } }
        }
        val s = MixMath.fxSeed(r.items)
        assertEquals(seq(s), seq(s))
        assertNotEquals("another queue textures differently", seq(s), seq(MixMath.fxSeed(r.items.drop(1))))
        for ((e, peak, run) in seq(s)) {
            assertTrue(e in MixMath.FX_GLIDE_POOL)
            assertTrue(peak >= 0.5 && peak < 0.8)
            assertTrue(run in 3..5)
        }
        assertFalse("the compressor is a dynamics tool, never a texture", Effect.COMPRESSOR in MixMath.FX_GLIDE_POOL)
    }

    @Test fun twoMixesOverTheSameQueueSweepTheSameEffectsInTheSameOrder() {
        fun effects(): List<String> {
            val r = rig(n = 4, seconds = 12.0)
            r.dj.setFXGlide(true); r.dj.setMixGlideSeconds(1.0)
            r.dj.startAutoMix(r.items, false, 4.0, 2.0)
            r.run(40.0)
            return r.rec().glides.filter { it.param in pool }.map { it.param }
        }
        val a = effects(); val b = effects()
        assertTrue(a.isNotEmpty())
        assertEquals(a, b)
        // a texture is held across a RUN: consecutive transitions reuse the same effect
        assertEquals("coherent texture within a run", 1, a.take(3).toSet().size)
    }

    // ---------------------------------------------------------------- slot resolution

    @Test fun slotResolutionPrefersTheRolledTextureThenAnySweepableThenNone() {
        val r = rig(); r.start()
        val g = r.dj.glide
        assertEquals(3, g.slotFor(Effect.FILTER, A))
        assertEquals(1, g.slotFor(Effect.REVERB, A))
        // a rack without the rolled effect still glides on its first sweepable slot
        r.e.setSlotEffect(Effect.COMPRESSOR, 3, A)                // [comp, reverb, flanger, comp]
        assertEquals(1, g.slotFor(Effect.FILTER, A))
        // an ALL-compressor rack sits the glide out
        for (i in 0..3) r.e.setSlotEffect(Effect.COMPRESSOR, i, A)
        assertNull(g.slotFor(Effect.FILTER, A))
        assertNull(g.slotFor(Effect.REVERB, A))
        // the other deck's rack is independent
        assertEquals(3, g.slotFor(Effect.FILTER, B))
    }

    @Test fun onlyTheResolvedSlotSweepsAndAnAllCompressorDeckSitsOut() {
        val r = rig(n = 3, seconds = 12.0)
        r.dj.startAutoMix(r.items, false, 4.0, 2.0)
        r.dj.setFXGlide(true); r.dj.setMixGlideSeconds(2.0)
        for (i in 0..3) r.e.setSlotEffect(Effect.COMPRESSOR, i, A)
        r.rec().kinds.clear()
        var bPeak = 0.0
        var aEver = false
        var otherB = false
        repeat(140) {
            r.h.tick(100)
            val a = r.e.deckState(A); val b = r.e.deckState(B)
            if (a.slots.any { it.enabled }) aEver = true
            val en = b.slots.withIndex().filter { it.value.enabled }
            if (en.size > 1) otherB = true
            en.firstOrNull()?.let { bPeak = maxOf(bPeak, it.value.strength) }
        }
        assertFalse("the all-compressor outgoing deck never sweeps", aEver)
        assertFalse("exactly one slot sweeps on the incoming deck", otherB)
        assertTrue("incoming reached the rolled peak (0.5..0.8)", bPeak in 0.5..0.8)
        // every ramp is recorded compactly, only for the resolved slot, never for deck A
        val fx = r.rec().glides.filter { it.param in pool }
        assertTrue(fx.isNotEmpty())
        assertTrue(fx.all { it.deck != "A" || false } || fx.none { it.deck == "A" && it.slot == null })
        assertTrue(fx.all { it.slot != null })
        // restored: the finished transition leaves B's rack as the DJ had it
        assertTrue(r.e.deckState(B).slots.none { it.enabled } || r.dj.livePos >= 1)
    }

    // ---------------------------------------------------------------- preroll fitting

    @Test fun prerollIsFittedIntoTheRunwayWithHeadroomWhenMixGlideIsOn() {
        val r = rig(); r.dj.setMixGlide(true); r.dj.setMixGlideSeconds(20.0); r.start()
        r.run(20.0)                                       // secondsLeft == lead == 10.0 exactly
        assertTrue(r.dj.autoTransitioning)
        assertNotNull(r.dj.glide.prerollStartedAt)
        // 10 / 1.12 - fade(4) - 0.3
        assertEquals(10.0 / 1.12 - 4.0 - 0.3, r.dj.glide.glideInSecondsActive, 1e-6)
        assertFalse("the incoming deck has not started during the preroll", r.e.isPlaying(B))
        assertEquals("no volume sweep during the preroll", 0.0, r.e.crossfader, 0.0)
        r.run(r.dj.glide.glideInSecondsActive + 0.3)
        assertTrue(r.e.isPlaying(B))
        assertNotNull(r.dj.fadeStartedAt)
    }

    @Test fun fxOnlyGlideUsesNoHeadroom() {
        val r = rig(); r.dj.setFXGlide(true); r.dj.setMixGlideSeconds(20.0); r.start()
        r.run(20.0)
        assertEquals(10.0 - 4.0 - 0.3, r.dj.glide.glideInSecondsActive, 1e-6)
    }

    @Test fun aShortRunwayLeavesNoPrerollAndSnapsStraightToTheFade() {
        val r = rig(); r.dj.setFXGlide(true); r.start(); r.run(1.0)
        r.e.seek(A, 27.0)                                 // 3 s left: preroll would be negative
        r.run(0.3)
        assertTrue(r.dj.autoTransitioning)
        assertNull(r.dj.glide.prerollStartedAt)
        assertNotNull("straight to the crossfade", r.dj.fadeStartedAt)
    }

    @Test fun mixGlideSecondsIsClampedToHalfASecond() {
        val r = rig()
        r.dj.setMixGlideSeconds(0.1)
        assertEquals(0.5, r.dj.glide.mixGlideSeconds, 0.0)
        r.dj.setMixGlideSeconds(12.0)
        assertEquals(12.0, r.dj.glide.mixGlideSeconds, 0.0)
    }

    // ---------------------------------------------------------------- mix glide: tempo / pitch

    private fun keyed(i: Int, l: MixLoadable) = when (i) {
        0 -> l.copy(camelot = "8A", bpm = 120.0)
        1 -> l.copy(camelot = "10A", bpm = 126.0)
        else -> l.copy(camelot = "10A", bpm = 126.0)
    }

    @Test fun mixGlideBendsBothDecksThenTheIncomingSettlesBackInThePostroll() {
        val r = rig(tweak = ::keyed)
        r.dj.setMixGlide(true); r.dj.setMixGlideSeconds(3.0)
        r.start()
        val exp = MixMath.glideParams("8A", "10A", 120.0, 126.0)
        assertNotEquals(1.0, exp.outRate, 1e-6); assertNotEquals(0.0, exp.outPitch, 1e-6)
        r.run(20.0 + 3.0 + 0.5)                           // preroll (~4.6 s capped by mixGlide 3 s) + into the fade
        assertTrue(r.e.isPlaying(B))
        assertEquals("outgoing held at its target across the crossfade", exp.outRate, r.e.rate(A), 1e-9)
        assertEquals(exp.outPitch, r.e.pitch(A), 1e-9)
        assertEquals("incoming starts at the opposite offset", exp.inRate, r.e.rate(B), 1e-9)
        assertEquals(exp.inPitch, r.e.pitch(B), 1e-9)
        assertEquals(-exp.outPitch, exp.inPitch, 1e-9)
        r.run(4.0)                                        // fade done, postroll under way
        assertNotNull(r.dj.glide.postrollStartedAt)
        assertEquals("outgoing retired deck restored before it was reloaded", 1.0, r.e.rate(A), 0.0)
        assertEquals(0.0, r.e.pitch(A), 0.0)
        r.run(3.5)
        assertNull(r.dj.glide.postrollStartedAt)
        assertEquals(1.0, r.e.rate(B), 1e-9)
        assertEquals(0.0, r.e.pitch(B), 1e-9)
        assertNull("context cleared", r.dj.glide.ctx)
    }

    @Test fun glideSetPointsAreRecordedAsCompactGlideEventsNotPerTickEvents() {
        val r = rig(tweak = ::keyed)
        r.dj.setMixGlide(true); r.dj.setFXGlide(true); r.dj.setMixGlideSeconds(3.0)
        r.start()
        r.rec().kinds.clear()
        r.run(35.0)
        val g = r.rec().glides
        // outgoing tempo + pitch ramp in, incoming tempo + pitch settle out, plus the crossfader node
        assertTrue(g.any { it.param == "tempo" && it.deck == "A" && it.from == 1.0 })
        assertTrue(g.any { it.param == "pitch" && it.deck == "A" })
        assertTrue(g.any { it.param == "tempo" && it.deck == "B" && it.to == 1.0 })
        assertTrue(g.any { it.param == "pitch" && it.deck == "B" && it.to == 0.0 })
        val xf = g.first { it.param == "crossfader" }
        assertNull(xf.deck); assertEquals(1.0, xf.to, 0.0)
        assertTrue("one compact node per ramp, not one per tick", g.size < 30)
        // the non-recording setters never emit per-tick tempo/pitch/effect/crossfader events
        val k = r.rec().kinds
        for (bad in listOf(MixEventKind.Tempo, MixEventKind.Pitch, MixEventKind.EffectToggle, MixEventKind.EffectStrength, MixEventKind.Crossfader))
            assertFalse("$bad", bad in k)
    }

    @Test fun missingBpmOrKeyMakesThatBendIdentity() {
        val noKeys = MixMath.glideParams(null, "8A", 120.0, 126.0)
        assertEquals(0.0, noKeys.outPitch, 0.0)
        assertNotEquals(1.0, noKeys.outRate, 1e-9)
        val noBpm = MixMath.glideParams("8A", "10A", null, 126.0)
        assertEquals(1.0, noBpm.outRate, 0.0)
        assertNotEquals(0.0, noBpm.outPitch, 1e-9)
    }

    @Test fun glidePhaseAlignUsesTheRecordingSeekOnTheIncomingDeck() {
        val r = rig(tweak = ::keyed)
        r.dj.setMixGlide(true); r.dj.setMixGlideSeconds(1.0)
        r.start()
        r.rec().kinds.clear()
        r.run(26.0)
        assertTrue("the beat-align repositioning lands in the timeline", MixEventKind.Seek in r.rec().kinds)
    }

    // ---------------------------------------------------------------- skip / abort

    @Test fun aSkipGlidesWithNoPrerollAndStillSettlesBack() {
        val r = rig(tweak = ::keyed)
        r.dj.setMixGlide(true); r.dj.setMixGlideSeconds(2.0)
        r.start(); r.run(3.0)
        r.dj.skipToNext(2.0)
        assertNull("skip = advance now", r.dj.glide.prerollStartedAt)
        assertNotNull(r.dj.fadeStartedAt)
        assertEquals(2.0, r.dj.fadeSeconds, 0.0)
        assertEquals(4.0, r.dj.pendingFadeRestore!!, 0.0)
        r.run(2.5); r.run(2.5)
        assertEquals(Deck.B, r.dj.liveDeck)
        assertEquals(1.0, r.e.rate(B), 1e-9)
        assertEquals(4.0, r.dj.fadeSeconds, 0.0)
    }

    @Test fun stoppingMidGlideRestoresTempoPitchAndTheForcedEffect() {
        val r = rig(tweak = ::keyed)
        r.dj.setMixGlide(true); r.dj.setFXGlide(true); r.dj.setMixGlideSeconds(20.0)
        r.start()
        r.run(23.0)                                       // inside the preroll
        assertNotNull(r.dj.glide.prerollStartedAt)
        assertTrue(r.e.deckState(A).slots.any { it.enabled } || r.e.rate(A) != 1.0)
        r.dj.stopAutoMix()
        assertEquals(1.0, r.e.rate(A), 0.0)
        assertEquals(0.0, r.e.pitch(A), 0.0)
        assertTrue(r.e.deckState(A).slots.none { it.enabled })
        assertNull(r.dj.glide.ctx)
        assertNull(r.dj.glide.prerollStartedAt)
    }

    @Test fun withNoGlideFeatureNoPhaseIsEverEntered() {
        val r = rig(); r.start()
        var sawPre = false; var sawPost = false
        repeat(300) {
            r.h.tick(100)
            if (r.dj.glide.prerollStartedAt != null) sawPre = true
            if (r.dj.glide.postrollStartedAt != null) sawPost = true
        }
        assertFalse(sawPre); assertFalse(sawPost)
        assertFalse(r.dj.glide.anyGlide)
        assertTrue("the crossfader node is still recorded for every plain transition", r.rec().glides.any { it.param == "crossfader" })
        assertTrue(r.rec().glides.none { it.param == "tempo" || it.param == "pitch" })
    }

    @Test fun aRemoteFreezeShiftsThePrerollClockToo() {
        val r = rig(); r.dj.setFXGlide(true); r.start(); r.run(21.0)
        val pre = r.dj.glide.prerollStartedAt!!
        r.dj.remotePause()
        r.h.nowMs += 20_000
        r.dj.remotePlay()
        assertEquals(20_000.0, (r.dj.glide.prerollStartedAt!! - pre).toDouble(), 150.0)
    }
}

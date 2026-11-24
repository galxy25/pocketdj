package com.levi.pocketdj.mix.nowplaying

import com.levi.pocketdj.audio.core.OfflineRenderer
import com.levi.pocketdj.audio.core.PcmSource
import com.levi.pocketdj.audio.core.SyntheticPcmSource
import com.levi.pocketdj.audio.core.Voice
import com.levi.pocketdj.mix.engine.MixSourceOpener
import com.levi.pocketdj.mix.engine.VoiceRunner
import com.levi.pocketdj.mix.model.Effect
import com.levi.pocketdj.playback.dj.AutoTransition
import com.levi.pocketdj.playback.dj.DjLeveling
import com.levi.pocketdj.screens.nowplaying.DjChipText
import kotlinx.coroutines.ExperimentalCoroutinesApi
import kotlinx.coroutines.test.StandardTestDispatcher
import kotlinx.coroutines.test.TestScope
import kotlinx.coroutines.test.runCurrent
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNull
import org.junit.Assert.assertSame
import org.junit.Assert.assertTrue
import org.junit.Test
import java.io.File

/** P2-DJ-12: the automation display - pure publishing math + the engine's read-only guarantees. */
@OptIn(ExperimentalCoroutinesApi::class)
class DjDisplayTest {
    private val sr = 44_100

    // ------------------------------------------------------------------ pure

    @Test fun shownValuesFollowTheDisplayOnlyWhileActive() {
        val idle = DjDisplay.IDLE
        assertEquals(1.3, idle.shownRate(1.3), 0.0)
        assertEquals(-2.0, idle.shownPitch(-2.0), 0.0)
        val on = DjDisplay(active = true, rate = 1.12, pitch = 1.5)
        assertEquals(1.12, on.shownRate(1.0), 0.0)
        assertEquals(1.5, on.shownPitch(0.0), 0.0)
    }

    @Test fun shownEffectIsTheHeardStateAndAbsentMeansOff() {
        val d = DjDisplay(active = true, effects = mapOf(Effect.REVERB to DjFxShown(true, 0.7)))
        assertEquals(DjFxShown(true, 0.7), d.shownEffect(Effect.REVERB, false, 0.5))
        // the listener has FILTER on, but the display (what is heard) does not list it: shown off
        assertEquals(DjFxShown(false, 0.4), d.shownEffect(Effect.FILTER, true, 0.4))
        assertEquals(DjFxShown(true, 0.4), DjDisplay.IDLE.shownEffect(Effect.FILTER, true, 0.4))
    }

    @Test fun heardEffectsAddTheSweepOnlyWhereTheListenerHasItOff() {
        val fx = DjDisplayMath.heardEffects(mapOf(Effect.FILTER to 0.3), Effect.REVERB to 0.8)
        assertEquals(mapOf(Effect.FILTER to DjFxShown(true, 0.3), Effect.REVERB to DjFxShown(true, 0.8)), fx)
        // the listener's own effect wins over a sweep on the same effect
        assertEquals(DjFxShown(true, 0.3), DjDisplayMath.heardEffects(mapOf(Effect.FILTER to 0.3), Effect.FILTER to 0.9)[Effect.FILTER])
        assertTrue(DjDisplayMath.heardEffects(emptyMap(), null).isEmpty())
    }

    @Test fun touchesActOnWhatIsShown() {
        assertFalse("tapping a swept (shown-on) effect turns it off", DjDisplayTouch.tapTargetOn(DjFxShown(true, 0.6)))
        assertTrue(DjDisplayTouch.tapTargetOn(DjFxShown(false, 0.6)))
        assertTrue("a strength drag on a swept effect enables the listener's first", DjDisplayTouch.strengthDragNeedsEnable(DjFxShown(true, 0.6), listenerOn = false))
        assertFalse(DjDisplayTouch.strengthDragNeedsEnable(DjFxShown(true, 0.6), listenerOn = true))
        assertFalse(DjDisplayTouch.strengthDragNeedsEnable(DjFxShown(false, 0.6), listenerOn = false))
    }

    @Test fun crossfadeAndPhaseNames() {
        assertEquals(0.0, DjDisplayMath.crossfade(DjPhase.PREROLL, 0.7), 0.0)
        assertEquals(0.4, DjDisplayMath.crossfade(DjPhase.FADING, 0.4), 0.0)
        assertEquals(1.0, DjDisplayMath.crossfade(DjPhase.POSTROLL, 0.0), 0.0)
        assertEquals(1.0, DjDisplayMath.crossfade(DjPhase.IDLE, 0.0), 0.0)
        assertEquals("preRoll", DjDisplayMath.phaseName(DjPhase.PREROLL, false))
        assertEquals("fade", DjDisplayMath.phaseName(DjPhase.FADING, false))
        assertEquals("postRoll", DjDisplayMath.phaseName(DjPhase.POSTROLL, true))
        assertEquals("ease", DjDisplayMath.phaseName(DjPhase.IDLE, true))
        assertEquals("idle", DjDisplayMath.phaseName(DjPhase.IDLE, false))
    }

    @Test fun settleKeepsValuesThatDidNotMoveVisibly() {
        val prev = DjDisplay(active = true, rate = 1.1000, pitch = 1.000, crossfade = 0.5)
        val noise = prev.copy(rate = 1.1003, pitch = 1.003, crossfade = 0.503)
        val s = DjDisplayMath.settle(prev, noise)
        assertEquals(prev, s)
        val moved = DjDisplayMath.settle(prev, prev.copy(rate = 1.11, pitch = 1.2, crossfade = 0.6))
        assertEquals(1.11, moved.rate, 0.0); assertEquals(1.2, moved.pitch, 0.0); assertEquals(0.6, moved.crossfade, 0.0)
        // the end points always land exactly
        assertEquals(1.0, DjDisplayMath.settle(prev.copy(crossfade = 0.998), prev.copy(crossfade = 1.0)).crossfade, 0.0)
    }

    @Test fun levelingTextMatchesTheIosReadout() {
        fun side(s: DjLeveling.Status, db: Double = 0.0) = DjLevelSide(s, db)
        assertEquals("+3.2 dB", DjLevelingText.words(side(DjLeveling.Status.MEASURED, 3.2)))
        assertEquals("−4.5 dB", DjLevelingText.words(side(DjLeveling.Status.MEASURED, -4.5)))
        assertEquals("0.0 dB", DjLevelingText.words(side(DjLeveling.Status.MEASURED, 0.02)))
        assertEquals("≈ +2.0 dB", DjLevelingText.words(side(DjLeveling.Status.ESTIMATED, 2.0)))
        assertEquals("measuring…", DjLevelingText.words(side(DjLeveling.Status.MEASURING)))
        assertEquals("off", DjLevelingText.words(side(DjLeveling.Status.OFF)))
        assertEquals("unavailable", DjLevelingText.words(side(DjLeveling.Status.UNAVAILABLE)))
        val xf = DjLevelingReadout(side(DjLeveling.Status.MEASURED, 3.2), side(DjLeveling.Status.MEASURED, -4.5), 0.6, 0.4)
        assertEquals("−4.5 dB → +3.2 dB", DjLevelingText.line(xf))
        assertEquals("−4.5 dB fading to +3.2 dB", DjLevelingText.a11y(xf))
    }

    @Test fun levelingRowIsHiddenWhenDjIsNotLevelingAndMeterOnlyDrawsMeasuredSides() {
        assertFalse(DjLevelingReadout.NONE.visible)
        assertTrue(DjLevelingReadout(DjLevelSide(DjLeveling.Status.OFF, 0.0)).visible)
        val r = DjLevelingReadout(DjLevelSide(DjLeveling.Status.MEASURING, 0.0), DjLevelSide(DjLeveling.Status.MEASURED, -3.0), 0.7, 0.3)
        assertTrue(r.visible)
        assertEquals(listOf(DjLevelingText.Bar(-3.0, 0.7, false)), DjLevelingText.bars(r))
        val one = DjLevelingReadout(DjLevelSide(DjLeveling.Status.MEASURED, 2.0))
        assertEquals(listOf(DjLevelingText.Bar(2.0, 1.0, true)), DjLevelingText.bars(one))
    }

    @Test fun crossfadeReadoutUsesEqualPowerGainsOnlyWhileFading() {
        val cur = DjLevelSide(DjLeveling.Status.MEASURED, 3.0)
        val out = DjLevelSide(DjLeveling.Status.MEASURED, -4.0)
        val half = DjDisplayMath.levelingReadout(DjPhase.FADING, cur, out, 0.5)
        assertEquals(out, half.outgoing)
        assertEquals(0.7071, half.outGain, 0.001); assertEquals(0.7071, half.inGain, 0.001)
        val start = DjDisplayMath.levelingReadout(DjPhase.FADING, cur, out, 0.0)
        assertEquals(1.0, start.outGain, 1e-6); assertEquals(0.0, start.inGain, 1e-6)
        assertNull(DjDisplayMath.levelingReadout(DjPhase.PREROLL, cur, out, 0.5).outgoing)
        assertNull(DjDisplayMath.levelingReadout(DjPhase.POSTROLL, cur, out, 0.5).outgoing)
    }

    @Test fun hubDedupesAndKeepsLevelingWhenCleared() {
        val hub = DjDisplayHub()
        val lv = DjLevelingReadout(DjLevelSide(DjLeveling.Status.MEASURED, 1.0))
        hub.publishLeveling(lv)
        val first = hub.value
        hub.publishLeveling(DjLevelingReadout(DjLevelSide(DjLeveling.Status.MEASURED, 1.02)))   // below 0.05 dB: no change
        assertSame(first, hub.value)
        hub.publish(DjDisplay(active = true, rate = 1.2, leveling = lv))
        assertTrue(hub.value.active)
        hub.clear()
        assertFalse(hub.value.active)
        assertEquals(lv, hub.value.leveling)
    }

    @Test fun chipFloorFillsFromTheDisplayCrossfade() {
        assertEquals(0.04f, DjChipText.floorFraction(0f), 0f)
        assertEquals(0.5f, DjChipText.floorFraction(0.5f), 0f)
        assertEquals(1f, DjChipText.floorFraction(1f), 0f)
        assertEquals("On, mixing 50 percent", DjChipText.switchValue(true, 0.5f))
    }

    // ------------------------------------------------------------------ engine (read-only guarantees)

    private class Rig(songSeconds: Int = 12) {
        val sr = 44_100
        var now = 0.0
        val scope = TestScope(StandardTestDispatcher())
        val voices = ArrayList<Voice>()
        var sink: OfflineRenderer? = null
        val opener = MixSourceOpener { f ->
            val freq = if (f.name.startsWith("next")) 660.0 else 440.0
            SyntheticPcmSource.tone(freq, sr.toLong() * songSeconds, sr, 0.5f) as PcmSource
        }
        val engine = NowPlayingDspEngine(
            sinkFactory = { OfflineRenderer(sr, 512).also { sink = it } },
            opener = opener,
            runner = VoiceRunner { v -> voices += v; AutoCloseable { voices.remove(v) } },
            stemSource = object : DspStemSource {
                override fun localParts(songId: String): Map<String, File> = emptyMap()
                override fun obtainable(songId: String) = false
                override suspend fun fetch(songId: String, parts: List<String>) = false
            },
            scope = scope, djClock = { now }, djTicker = false,
        )
        init { engine.dj.onFadeStart = { true } }

        fun render(frames: Int) {
            var done = 0
            while (done < frames) {
                var guard = 0
                do { var any = false; for (v in voices.toList()) while (v.pump()) any = true; guard++ } while (any && guard < 100)
                val n = minOf(512, frames - done)
                sink!!.renderFrames(n)
                done += n; now += n.toDouble() / sr
                engine.dj.step(); engine.tick(); scope.testScheduler.runCurrent()
            }
        }
        fun seconds(s: Double) = render(Math.round(s * sr).toInt())
        fun engage() { check(engine.engage(File("song.mp3"), 0, 0, 0.0, play = true)); engine.bindSong("s1"); seconds(1.0) }
        /** The ~16 Hz sampler's tick, by hand (the ticker is off under test). */
        fun sample() = engine.djAutomationChanged()
    }

    private fun spec(plan: AutoTransition.Plan, glide: AutoTransition.GlideTargets, texture: AutoTransition.Texture? = null) =
        DjTransitionSpec(plan, glide, texture, AutoTransition.BeatRef(null), DjIncoming("s2", File("next.mp3")))

    @Test fun displayIsIdleUntilAutomationRunsAndClearsWhenItEnds() {
        val r = Rig(); r.engage()
        assertFalse(r.engine.djDisplay.value.active)
        assertFalse(r.engine.djAutomating)
        assertNull(r.engine.dj.beginTransition(spec(AutoTransition.Plan(true, 2.0, 1.0, 1.0, null), AutoTransition.GlideTargets(1.2, 0.0, 0.8, 0.0))))
        assertTrue(r.engine.djDisplay.value.active)
        assertEquals("preRoll", r.engine.djDisplay.value.phase)
        r.seconds(5.0)
        assertFalse("the display clears when the transition ends", r.engine.djDisplay.value.active)
        assertEquals("idle", r.engine.djDisplay.value.phase)
    }

    @Test fun tempoMovesInTheDisplayWhileTheListenersValueStaysPut() {
        val r = Rig(); r.engage()
        r.engine.setRate(1.05)
        assertNull(r.engine.dj.beginTransition(spec(AutoTransition.Plan(true, 3.0, 1.0, 0.0, null), AutoTransition.GlideTargets(1.2, 2.0, 0.8, 0.0))))
        r.seconds(0.5); r.sample()
        val a = r.engine.djDisplay.value.rate
        r.seconds(1.0); r.sample()
        val b = r.engine.djDisplay.value.rate
        assertTrue("tempo glides toward the outgoing target ($a -> $b)", b > a && a > 1.05)
        assertEquals("the listener's own tempo is untouched", 1.05, r.engine.rate, 0.0)
        assertTrue(r.engine.djDisplay.value.pitch > 0.0)
        assertEquals("the listener's pitch is untouched", 0.0, r.engine.pitch, 0.0)
        assertEquals(0.0, r.engine.djDisplay.value.crossfade, 0.0)
    }

    @Test fun crossfadeFillsZeroToOneAcrossTheFade() {
        val r = Rig(); r.engage()
        assertNull(r.engine.dj.beginTransition(spec(AutoTransition.Plan(false, 0.0, 2.0, 0.0, null), AutoTransition.identityGlide)))
        assertEquals("fade", r.engine.djDisplay.value.phase)
        r.seconds(1.0); r.sample()
        assertEquals(0.5, r.engine.djDisplay.value.crossfade, 0.05)
        r.seconds(1.2)
        assertFalse(r.engine.djDisplay.value.active)
    }

    @Test fun aSweptEffectShowsInTheDisplayButNeverInTheListenersEffects() {
        val r = Rig(); r.engage()
        val tex = AutoTransition.Texture(AutoTransition.TextureEffect.REVERB, 0.8, 3)
        assertNull(r.engine.dj.beginTransition(spec(AutoTransition.Plan(true, 3.0, 1.0, 0.0, null), AutoTransition.GlideTargets(1.1, 0.0, 0.9, 0.0), tex)))
        r.seconds(3.0); r.sample()
        val shown = r.engine.djDisplay.value.effects[Effect.REVERB]
        assertTrue("the sweep is shown on", shown != null && shown.on && shown.strength > 0.0)
        assertFalse("the listener's effect is still off (FX Lock / snapshot read this)", r.engine.isEnabled(Effect.REVERB))
        // tapping the swept effect (shown on) turns it off: the listener sets false, the glide ends, the display follows at once
        r.engine.setEffect(Effect.REVERB, DjDisplayTouch.tapTargetOn(shown!!))
        assertFalse(r.engine.djDisplay.value.effects.containsKey(Effect.REVERB))
    }

    @Test fun aTempoDragEndsTheGlideWithoutAJump() {
        val r = Rig(); r.engage()
        assertNull(r.engine.dj.beginTransition(spec(AutoTransition.Plan(true, 4.0, 1.0, 0.0, null), AutoTransition.GlideTargets(1.2, 0.0, 0.8, 0.0))))
        r.seconds(2.0); r.sample()
        val shown = r.engine.djDisplay.value.rate
        assertTrue(shown > 1.05)
        r.engine.setRate(shown)                 // the panel's drag: the listener's value becomes the shown one
        assertTrue(r.engine.dj.glideDropped)
        assertEquals(shown, r.engine.rate, 1e-9)
        assertEquals("what is heard equals what was shown: no jump", shown, r.engine.djParams(r.engine.liveDeck).speed.toDouble(), 1e-4)
        assertEquals("the display shows the dragged value at once", shown, r.engine.djDisplay.value.rate, 0.001)
        r.seconds(1.0); r.sample()
        assertEquals("the glide no longer moves it", shown, r.engine.djDisplay.value.rate, 0.001)
    }

    @Test fun levelingStatusReachesTheReadoutAndTheIncomingTrimIsShownDuringTheFade() {
        val r = Rig(); r.engage()
        assertFalse(r.engine.djDisplay.value.leveling.visible)
        r.engine.setLevelingStatus(DjLeveling.Status.MEASURING)
        assertEquals("measuring…", DjLevelingText.line(r.engine.djDisplay.value.leveling))
        r.engine.setLevelDb(3.2)
        r.seconds(0.1)
        r.engine.setLevelingStatus(DjLeveling.Status.MEASURED)
        assertEquals("+3.2 dB", DjLevelingText.line(r.engine.djDisplay.value.leveling))
        assertNull(r.engine.dj.beginTransition(spec(AutoTransition.Plan(false, 0.0, 2.0, 0.0, null), AutoTransition.identityGlide)
            .let { it.copy(incoming = it.incoming.copy(levelDb = -4.5)) }))
        // the host's advance re-sets the status for the incoming
        r.engine.setLevelingStatus(DjLeveling.Status.MEASURED)
        r.seconds(1.0); r.sample()
        val lv = r.engine.djDisplay.value.leveling
        assertTrue("the outgoing side shows while crossfading", lv.outgoing != null)
        assertEquals(3.2, lv.outgoing!!.trimDb, 0.1)
        assertTrue(DjLevelingText.line(lv).contains("→"))
        r.seconds(1.5)
        assertNull("after the fade only the playing song shows", r.engine.djDisplay.value.leveling.outgoing)
    }

    @Test fun displayDoesNotPerturbTheListenersSnapshotOfControls() {
        val r = Rig(); r.engage()
        r.engine.setRate(0.97); r.engine.setPitch(1.0); r.engine.setEffect(Effect.FILTER, true); r.engine.setEffectStrength(Effect.FILTER, 0.35)
        assertNull(r.engine.dj.beginTransition(spec(AutoTransition.Plan(true, 3.0, 1.0, 0.0, null), AutoTransition.GlideTargets(1.2, 2.0, 0.8, 0.0))))
        // touching nothing: the automated overlay is on the audio, not on the listener controls
        r.seconds(1.5); r.sample()
        assertEquals(0.97, r.engine.rate, 0.0)
        assertEquals(1.0, r.engine.pitch, 0.0)
        assertTrue(r.engine.isEnabled(Effect.FILTER)); assertEquals(0.35, r.engine.strength(Effect.FILTER), 0.0)
        // the display reports the listener's own effect at the listener's strength
        assertEquals(DjFxShown(true, 0.35), r.engine.djDisplay.value.effects[Effect.FILTER])
    }
}

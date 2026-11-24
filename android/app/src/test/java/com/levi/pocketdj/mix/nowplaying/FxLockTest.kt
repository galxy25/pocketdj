package com.levi.pocketdj.mix.nowplaying

import com.levi.pocketdj.audio.core.OfflineRenderer
import com.levi.pocketdj.audio.core.SyntheticPcmSource
import com.levi.pocketdj.audio.core.Voice
import com.levi.pocketdj.mix.engine.MixSourceOpener
import com.levi.pocketdj.mix.engine.ResolvedTrack
import com.levi.pocketdj.mix.engine.VoiceRunner
import com.levi.pocketdj.mix.model.Effect
import com.levi.pocketdj.mix.nowplaying.NowPlayingPrefetcher.Track
import com.levi.pocketdj.playback.durable.SessionFxLock
import com.levi.pocketdj.playback.durable.SessionFxSetting
import com.levi.pocketdj.playback.durable.SessionSnapshot
import com.levi.pocketdj.data.PdjJson
import kotlinx.coroutines.ExperimentalCoroutinesApi
import kotlinx.coroutines.runBlocking
import kotlinx.coroutines.test.StandardTestDispatcher
import kotlinx.coroutines.test.TestScope
import kotlinx.coroutines.test.advanceTimeBy
import kotlinx.coroutines.test.runCurrent
import kotlinx.serialization.json.JsonObject
import kotlinx.serialization.json.jsonObject
import kotlinx.serialization.json.jsonPrimitive
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNotNull
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test
import java.io.File

@OptIn(ExperimentalCoroutinesApi::class)
class FxLockTest {
    private fun on(s: Double = 0.5) = SessionFxSetting(true, s)
    private fun off(s: Double = 0.5) = SessionFxSetting(false, s)

    // ---------------------------------------------------------------- pure state

    @Test fun wantsFxNeedsTheLockAndAKnownEffectOn() {
        assertFalse(FxLockState(enabled = false, effects = mapOf("reverb" to on())).wantsFX)
        assertFalse(FxLockState(enabled = true).wantsFX)
        assertFalse("strength set but off", FxLockState(true, mapOf("reverb" to off(0.9))).wantsFX)
        assertTrue(FxLockState(true, mapOf("reverb" to off(), "filter" to on())).wantsFX)
        assertFalse("an effect only a newer build knows cannot be applied", FxLockState(true, mapOf("echoPlus" to on())).wantsFX)
    }

    @Test fun knownEffectsDropsUnknownKeysSoEngageComparisonCanMatch() {
        val st = FxLockState(true, mapOf("reverb" to on(0.7), "echoPlus" to on()))
        assertEquals(mapOf("reverb" to on(0.7)), st.knownEffects)
        assertEquals(setOf("reverb"), st.knownEffects.keys)
    }

    @Test fun logSummaryListsOnEffectsSorted() {
        assertEquals("fx=none", FxLockState(true, mapOf("reverb" to off())).logSummary)
        assertEquals("fx=filter:0.30,reverb:0.70", FxLockState(true, mapOf("reverb" to on(0.7), "filter" to on(0.3), "flanger" to off())).logSummary)
    }

    @Test fun captureFollowsUserChangesOnlyWhileLockedAndNotApplying() {
        val s = FxLockSession()
        assertFalse("lock off: nothing captured", s.onUserEffectChange(mapOf("reverb" to on())))
        s.setLock(true, emptyMap())
        s.applying = true
        assertFalse("the lock's own writes are not user changes", s.onUserEffectChange(mapOf("reverb" to on())))
        s.applying = false
        assertTrue(s.onUserEffectChange(mapOf("reverb" to on(0.8))))
        assertEquals(mapOf("reverb" to on(0.8)), s.current.effects)
        assertFalse("unchanged snapshot is not a change", s.onUserEffectChange(mapOf("reverb" to on(0.8))))
        assertTrue(s.onUserEffectChange(mapOf("reverb" to off(0.8))))
        assertFalse(s.current.wantsFX)
    }

    @Test fun unknownEffectKeysAreKeptThroughCapture() {
        val future = SessionFxSetting(true, 0.4)
        val s = FxLockSession()
        s.restoreHeld(SessionFxLock(true, mapOf("futureEffect" to future)))
        assertTrue(s.onUserEffectChange(mapOf("reverb" to on())))
        assertEquals(future, s.current.effects["futureEffect"])
        assertEquals(on(), s.current.effects["reverb"])
        // the snapshot of a build that knows the key can never overwrite it with a foreign value
        assertTrue(s.onUserEffectChange(mapOf("reverb" to on(0.2), "futureEffect" to off())))
        assertEquals(future, s.current.effects["futureEffect"])
    }

    @Test fun sessionScopeNewSessionClearsAndWriteStaysAbsentUntilUsed() {
        val s = FxLockSession()
        assertNull("never used: the key is not invented", s.write())
        s.setLock(true, mapOf("reverb" to on()))
        assertEquals(true, s.write()!!.enabled)
        s.setLock(false, emptyMap())
        val offDto = s.write()!!
        assertFalse("an off state is written so it overwrites a stored ON", offDto.enabled)
        assertTrue(offDto.effects.isEmpty())
        s.setLock(true, mapOf("reverb" to on()))
        s.reset()
        assertFalse(s.current.enabled)
        assertNull("a new session starts with nothing stored", s.write())
    }

    @Test fun onChangedSaysWhetherTheWriteIsDebounced() {
        val seen = ArrayList<Boolean>()
        val s = FxLockSession { seen += it }
        s.setLock(true, emptyMap())
        s.onUserEffectChange(mapOf("filter" to on()))
        s.onUserEffectChange(mapOf("filter" to on()))   // no change: no write
        s.setLock(false, emptyMap())
        assertEquals(listOf(false, true, false), seen)
    }

    @Test fun indicatorRule() {
        val st = FxLockState(true, mapOf("reverb" to on()))
        fun ind(state: FxLockState = st, song: String? = "a", held: Boolean = false, engaged: Boolean = false, mix: Boolean = false) =
            FxLockSession.indicator(state, song, held, engaged, mix)
        assertEquals(FxLock.Indicator.OFF, ind(FxLockState()))
        assertEquals(FxLock.Indicator.IDLE, ind(FxLockState(true, mapOf("reverb" to off()))))
        assertEquals(FxLock.Indicator.IDLE, ind(song = null))
        assertEquals(FxLock.Indicator.IDLE, ind(held = true))
        assertEquals(FxLock.Indicator.APPLIED, ind(engaged = true))
        assertEquals(FxLock.Indicator.DORMANT, ind(mix = true))
        assertEquals(FxLock.Indicator.WAITING, ind())
    }

    @Test fun rampScaleRisesLinearlyAndLandsOnOne() {
        val xs = (1..FxLock.RAMP_STEPS).map { FxLockSession.rampScale(it) }
        assertEquals(1.0, xs.last(), 0.0)
        assertTrue(xs.zipWithNext().all { (a, b) -> b > a })
        assertTrue(xs.first() > 0.0 && xs.first() < 0.2)
    }

    // ---------------------------------------------------------------- iOS JSON

    private val fixture: String =
        javaClass.classLoader!!.getResourceAsStream("parity2/ios-playback-session-1.0.6.json")!!.readBytes().toString(Charsets.UTF_8)

    @Test fun iosJsonRoundTripKeepsTheUnknownEffectAndItsFields() {
        val snap = SessionSnapshot.decode(fixture)!!
        val s = FxLockSession()
        s.restoreHeld(snap.fxLock!!)
        assertTrue(s.current.enabled)
        assertTrue("fixture carries reverb", s.current.effects.getValue("reverb").on)
        // a user change keeps the unknown effect untouched, and the whole thing re-encodes through the real codec
        assertTrue(s.onUserEffectChange(mapOf("reverb" to on(0.33))))
        val out = PdjJson.lenient.parseToJsonElement(SessionSnapshot.encode(snap.copy(fxLock = s.write()))).jsonObject["fxLock"]!!.jsonObject
        val effects = out["effects"]!!.jsonObject
        assertEquals("log", effects["futureEffect"]!!.jsonObject["curve"]!!.jsonPrimitive.content)
        assertEquals(0.33, effects["reverb"]!!.jsonObject["strength"]!!.jsonPrimitive.content.toDouble(), 0.0)
        assertEquals(setOf("on", "strength"), effects["reverb"]!!.jsonObject.keys.filter { it in setOf("on", "strength") }.toSet())
    }

    @Test fun anIosFileWithoutTheKeyStaysWithoutIt() {
        val bare = SessionSnapshot.decode(fixture)!!.copy(fxLock = null)
        val s = FxLockSession()
        assertNull(s.write())
        val out = PdjJson.lenient.parseToJsonElement(SessionSnapshot.encode(bare.copy(fxLock = s.write() ?: bare.fxLock))).jsonObject
        assertFalse("fxLock" in out)
    }

    @Test fun restoredStrengthIsClamped() {
        val st = FxLockState.fromSession(SessionFxLock(true, mapOf("filter" to SessionFxSetting(true, 7.0))))
        assertEquals(1.0, st.effects.getValue("filter").strength, 0.0)
    }

    // ---------------------------------------------------------------- engine + host

    private class Ports : DspHostPorts {
        var song: String? = null
        override val currentSongId get() = song
        override val currentTitle: String? = null
        override val currentArtist: String? = null
        override val currentArtworkUri: String? = null
        override var heldForResume = false
        override var mixSessionActive = false
        override var appleMusicActive = false
        val local = HashSet<String>()
        override fun resolve(songId: String) = if (songId in local) ResolvedTrack(File("$songId.mp3"), isCut = true) else null
        override fun windowLengthMs(songId: String) = 0L
        override suspend fun positionMs(): Long = 0L
        override var exoPlaying = true
        override fun advanceAfterEnd(songId: String) {}
    }

    private class Rig(val refuse: Set<String> = emptySet()) {
        val sr = 44_100
        val scope = TestScope(StandardTestDispatcher())
        val voices = ArrayList<Voice>()
        var sink: OfflineRenderer? = null
        val ports = Ports()
        val lock = StemLockSession()
        val fx = FxLockSession()
        var replans = 0
        val engine = NowPlayingDspEngine(
            sinkFactory = { OfflineRenderer(sr, 512).also { sink = it } },
            opener = MixSourceOpener { f -> if (f.name.removeSuffix(".mp3") in refuse) null else SyntheticPcmSource.tone(440.0, sr * 10L, sr, 0.5f) },
            runner = VoiceRunner { v -> voices += v; AutoCloseable { voices.remove(v) } },
            stemSource = object : DspStemSource {
                override fun localParts(songId: String) = emptyMap<String, File>()
                override fun obtainable(songId: String) = false
                override suspend fun fetch(songId: String, parts: List<String>) = false
            },
            scope = scope,
        )
        val host = NowPlayingDspHost(engine, lock, ports, replan = { replans++ }, fxLock = fx)
        fun give(song: String) { ports.local += song }
        fun start(song: String) { ports.song = song; runBlocking { host.onTrackStarted(song) } }
        fun advanceMs(ms: Long) { scope.testScheduler.advanceTimeBy(ms); scope.testScheduler.runCurrent() }
    }

    /** The user turns reverb on at 0.8 on track [a], then the lock is switched on. */
    private fun lockedOnReverb(r: Rig, a: String = "a") {
        r.give(a); r.start(a)
        runBlocking { r.host.withEngaged { it.setEffect(Effect.REVERB, true); it.setEffectStrength(Effect.REVERB, 0.8) } }
        r.host.setFxLock(true)
    }

    @Test fun lockOnCapturesTheCurrentEffectsAndOffForgetsThem() {
        val r = Rig(); lockedOnReverb(r)
        assertEquals(mapOf("reverb" to on(0.8)), r.fx.current.effects)
        assertTrue(r.host.ui.value.fxLock.wantsFX)
        r.host.setFxLock(false)
        assertFalse(r.fx.current.enabled)
        assertTrue(r.fx.current.effects.isEmpty())
    }

    @Test fun effectsCarryToTheNextTrackAndRampInFromTransparent() {
        val r = Rig(); lockedOnReverb(r); r.give("b")
        r.start("b")
        runBlocking { r.host.carryIfReady() }
        assertEquals("the lock engages the DSP at the next track's start", "b", r.engine.engagedSongId)
        assertTrue(r.engine.isEnabled(Effect.REVERB))
        assertEquals(0.8, r.engine.strength(Effect.REVERB), 0.0)
        assertEquals("starts transparent", 0.0, r.engine.renderedStrength(Effect.REVERB), 0.0)
        assertTrue(r.engine.effectRampInFlight)
        r.advanceMs(125)
        val mid = r.engine.renderedStrength(Effect.REVERB)
        assertTrue("mid ramp $mid", mid > 0.05 && mid < 0.75)
        r.advanceMs(200)
        assertEquals("lands on the set strength", 0.8, r.engine.renderedStrength(Effect.REVERB), 1e-9)
        assertFalse(r.engine.effectRampInFlight)
        assertEquals(FxLock.Indicator.APPLIED, r.host.fxIndicator())
    }

    @Test fun carryingIsNotACaptureAndTempoPitchGainNeverCarry() {
        val r = Rig(); lockedOnReverb(r); r.give("b")
        runBlocking { r.host.withEngaged { it.setRate(1.2); it.setPitch(2.0); it.setVolume(0.5) } }
        val before = r.fx.current
        r.start("b"); runBlocking { r.host.carryIfReady() }
        assertEquals("applying the carry did not rewrite it", before, r.fx.current)
        assertEquals(1.0, r.engine.rate, 0.0)
        assertEquals(0.0, r.engine.pitch, 0.0)
        assertEquals(1.0, r.engine.volume, 0.0)
    }

    @Test fun aUserTouchBeatsTheRampAndIsWhatCarriesNext() {
        val r = Rig(); lockedOnReverb(r); r.give("b"); r.give("c")
        r.start("b"); runBlocking { r.host.carryIfReady() }
        r.advanceMs(40)
        r.engine.setEffectStrength(Effect.REVERB, 0.3)   // the user grabs the knob mid-ramp
        assertEquals("the ramp no longer scales it", 0.3, r.engine.renderedStrength(Effect.REVERB), 1e-9)
        r.advanceMs(400)
        assertEquals(0.3, r.engine.renderedStrength(Effect.REVERB), 1e-9)
        assertEquals(0.3, r.fx.current.effects.getValue("reverb").strength, 0.0)
        r.start("c"); runBlocking { r.host.carryIfReady() }
        assertEquals(0.3, r.engine.strength(Effect.REVERB), 0.0)
    }

    @Test fun turningTheLastEffectOffReplansAndStopsEngagingAtStart() {
        val r = Rig(); lockedOnReverb(r); r.give("b")
        val replansBefore = r.replans
        r.engine.setEffect(Effect.REVERB, false)
        assertFalse(r.fx.current.wantsFX)
        assertTrue("lane re-planned when the lock stops carrying anything", r.replans > replansBefore)
        r.start("b"); runBlocking { r.host.carryIfReady() }
        assertNull("nothing to carry: ExoPlayer keeps the track", r.engine.engagedSongId)
        assertEquals(FxLock.Indicator.IDLE, r.host.fxIndicator())
    }

    @Test fun nonMixableRowPlaysDryAndWaits() {
        val r = Rig(); lockedOnReverb(r)
        r.start("stream-only"); runBlocking { r.host.carryIfReady() }
        assertNull(r.engine.engagedSongId)
        assertEquals(FxLock.Indicator.WAITING, r.host.fxIndicator())
        assertTrue("lock kept", r.fx.current.wantsFX)
        r.ports.appleMusicActive = true; r.give("am")
        r.start("am"); runBlocking { r.host.carryIfReady() }
        assertNull("Apple Music only moves on a control touch", r.engine.engagedSongId)
        assertEquals(FxLock.Indicator.WAITING, r.host.fxIndicator())
    }

    @Test fun mixTabLiveLeavesTheLockDormant() {
        val r = Rig(); lockedOnReverb(r); r.give("b")
        r.ports.mixSessionActive = true
        r.start("b"); runBlocking { r.host.carryIfReady() }
        assertNull(r.engine.engagedSongId)
        assertEquals(FxLock.Indicator.DORMANT, r.host.fxIndicator())
    }

    @Test fun anUnopenableFileStaysOnExoPlayerAndTheLockWaits() {
        val r = Rig(refuse = setOf("bad")); lockedOnReverb(r); r.give("bad")
        r.start("bad"); runBlocking { r.host.carryIfReady() }
        assertFalse("never playing over dead air: the DSP did not take it", r.engine.isEngaged)
        assertNull(r.engine.engagedSongId)
        assertEquals(FxLock.Indicator.WAITING, r.host.fxIndicator())
        assertTrue(r.fx.current.wantsFX)
    }

    @Test fun aLockEngageOfAPlayingFileTakesItOnceAtItsStart() {
        val r = Rig(); lockedOnReverb(r); r.give("b")
        var engaged = 0
        r.engine.onEngaged = { engaged++ }
        r.start("b")
        runBlocking { r.host.carryIfReady(); r.host.carryIfReady() }   // the heartbeat re-checks: no second takeover
        assertEquals(1, engaged)
    }

    @Test fun swapOnLandUnderAnFxLockEngagesWithoutStemLock() {
        val r = Rig(); lockedOnReverb(r)
        r.give("b"); r.ports.song = "b"
        assertTrue(runBlocking { r.host.engageForHandOff("b", 3_000) })
        assertEquals("b", r.engine.engagedSongId)
        assertEquals("ramped in", 0.0, r.engine.renderedStrength(Effect.REVERB), 0.0)
        assertFalse("without a lock nothing hands off", runBlocking { Rig().also { it.give("x"); it.ports.song = "x" }.host.engageForHandOff("x", 0) })
    }

    @Test fun sessionEndClearsTheLockAndTheStampedCarry() {
        val r = Rig(); lockedOnReverb(r)
        r.engine.disengage()
        r.host.sessionEnded()
        assertFalse(r.fx.current.enabled)
        assertFalse("an idle DSP drops the stamped carry", r.engine.isEnabled(Effect.REVERB))
        assertNull(r.fx.write())
    }

    @Test fun idleDspShowsTheCarryBeforeTheNextEngage() {
        val r = Rig(); r.fx.restoreHeld(SessionFxLock(true, mapOf("filter" to SessionFxSetting(true, 0.6))))
        r.host.restoreFxStamp()
        assertTrue(r.engine.isEnabled(Effect.FILTER))
        assertEquals(setOf(Effect.FILTER), r.host.ui.value.effectsOn)
        assertFalse("nothing is armed by a held restore", r.engine.isEngaged)
    }

    @Test fun effectSettingsListsOnEffectsAndTouchedStrengths() {
        val r = Rig(); r.give("a"); r.start("a")
        assertTrue(r.engine.effectSettings().isEmpty())
        runBlocking { r.host.withEngaged { it.setEffectStrength(Effect.FILTER, 0.2); it.setEffect(Effect.COMPRESSOR, true) } }
        assertEquals(mapOf("filter" to off(0.2), "compressor" to on(0.5)), r.engine.effectSettings())
    }

    // ---------------------------------------------------------------- lane

    @Test fun theLaneFetchesNextSongsWithoutStemsWhileTheLockCarriesEffects() {
        fun t(id: String, local: Boolean) = Track(id, id, id, "a", local, true, emptySet(), false, Track.Source.RIPPED)
        val plan = NowPlayingPrefetcher.plan(
            NowPlayingPrefetcher.Input(
                current = null, upcoming = listOf(t("n1", false), t("n2", true), t("n3", false)),
                stemLock = StemLockState(), fxLockSongs = true, network = NetworkClass.UNMETERED,
            ),
        )
        assertEquals(listOf("n1", "n3"), plan.steps.map { (it as NowPlayingPrefetcher.Step.Song).id })
        assertTrue(plan.stemify.isEmpty())
        val off = NowPlayingPrefetcher.plan(NowPlayingPrefetcher.Input(null, listOf(t("n1", false)), StemLockState()))
        assertTrue("lock off: unchanged (nothing planned)", off.steps.isEmpty())
    }
}

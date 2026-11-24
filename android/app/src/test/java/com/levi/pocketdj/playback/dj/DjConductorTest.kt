package com.levi.pocketdj.playback.dj

import com.levi.pocketdj.mix.nowplaying.DjPhase
import com.levi.pocketdj.mix.nowplaying.DjTransitionSpec
import com.levi.pocketdj.playback.PlayEventBus
import com.levi.pocketdj.playback.health.DeadAirMeter
import com.levi.pocketdj.playback.sequencer.AdvanceCause
import com.levi.pocketdj.playback.sequencer.DjAdoptedSource
import com.levi.pocketdj.playback.sequencer.FakePlayerPort
import com.levi.pocketdj.playback.sequencer.MapResolver
import com.levi.pocketdj.playback.sequencer.PlayRequest
import com.levi.pocketdj.playback.sequencer.PlayerPort
import com.levi.pocketdj.playback.sequencer.QueueItem
import com.levi.pocketdj.playback.sequencer.RepeatMode
import com.levi.pocketdj.playback.sequencer.Rung
import com.levi.pocketdj.playback.sequencer.RowResolverRegistry
import com.levi.pocketdj.playback.sequencer.SequencerListener
import com.levi.pocketdj.playback.sequencer.SetlistSequencer
import com.levi.pocketdj.playback.sequencer.StartPath
import com.levi.pocketdj.playback.sequencer.TrackStart
import com.levi.pocketdj.playback.sequencer.TransitionCause
import com.levi.pocketdj.playback.sequencer.rows
import com.levi.pocketdj.playback.sequencer.stream
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.ExperimentalCoroutinesApi
import kotlinx.coroutines.launch
import kotlinx.coroutines.test.TestScope
import kotlinx.coroutines.test.UnconfinedTestDispatcher
import kotlinx.coroutines.test.runCurrent
import kotlinx.coroutines.test.runTest
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNotNull
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test
import java.io.File
import kotlin.random.Random

@OptIn(ExperimentalCoroutinesApi::class)
class DjConductorTest {

    // ================================================================ the conductor over a fake environment

    private class FakeEnv : DjConductor.Env {
        var active = true
        override val djActive get() = active
        override var running = true
        override var held = false
        var cur: QueueItem? = QueueItem("a", lengthMs = 200_000)
        var next: QueueItem? = QueueItem("b", lengthMs = 200_000)
        override fun currentItem() = cur
        override fun nextItem() = next
        override var queueCount = 3
        override var repeatOne = false
        override var repeatAll = false
        override var playsRemaining = 1
        override var halted = false
        var cfg = DJModeSettings()
        override fun settings() = cfg
        var timings = DjMode.Timings()
        override fun timings() = timings
        var albumRun = false
        var nextAlbum = false
        override fun currentInAlbumRun() = albumRun
        override fun nextStartsAlbumRun() = nextAlbum
        val sources = mutableMapOf<String, DjConductor.LocalSource>(
            "a" to DjConductor.LocalSource(File("a.mp3")),
            "b" to DjConductor.LocalSource(File("b.mp3"), startMs = 5_000, lengthMs = 180_000),
        )
        override fun localSource(item: QueueItem) = sources[item.id]
        val facts = mutableMapOf<String, DjConductor.Facts>()
        override fun facts(songId: String) = facts[songId]
        var level = 0.0
        override fun levelDb(songId: String, src: DjConductor.LocalSource) = level
        override var dspEngaged = true
        override var dspEngagedSongId: String? = "a"
        override var dspRate = 1.0
        override var dspSecondsLeft = 20.0
        override var dspPhase = DjPhase.IDLE
        var mixable = true
        var ready = true
        var engageResult = true
        var engageCalls = 0
        override fun currentMixable() = mixable
        override fun currentReadyToEngage() = ready
        override suspend fun engageCurrent(liveClock: Boolean): Boolean {
            engageCalls++
            if (engageResult) { dspEngaged = true; dspEngagedSongId = cur?.id }
            return engageResult
        }
        var armLead: Double? = null
        var armBuild: (() -> DjTransitionSpec?)? = null
        var armCalls = 0
        var disarmCalls = 0
        override fun arm(lead: Double, build: () -> DjTransitionSpec?) { armLead = lead; armBuild = build; armCalls++ }
        override fun disarm() { disarmCalls++ }
        var advanceResult = true
        val advances = mutableListOf<String>()
        override fun advanceAtFadeStart(songId: String): Boolean { advances += songId; return advanceResult }
        val plain = mutableListOf<QueueItem>()
        override fun playPlain(item: QueueItem) { plain += item }
        val replans = mutableListOf<String>()
        override fun replan(reason: String) { replans += reason }
        val logs = mutableListOf<String>()
        override fun log(line: String) { logs += line }
    }

    private fun TestScope.conductor(env: FakeEnv = FakeEnv()) = DjConductor(env, backgroundScope) to env

    @Test fun aMiddleRowBuildsATransitionWithTheIosWords() = runTest {
        val (c, env) = conductor()
        val spec = c.buildTransition()
        assertNotNull(spec)
        assertEquals("b", spec!!.incoming.songId)
        assertEquals(File("b.mp3"), spec.incoming.file)
        assertEquals(5_000L, spec.incoming.startMs)
        assertEquals(180_000L, spec.incoming.lengthMs)
        assertTrue(env.logs.single().startsWith("transition from=a to=b plan=pre="))
    }

    @Test fun everyDeclineIsLoggedOncePerSongAndReason() = runTest {
        val (c, env) = conductor()
        env.cfg = DJModeSettings(transitions = false)
        assertNull(c.buildTransition()); assertNull(c.buildTransition()); assertNull(c.buildTransition())
        assertEquals(listOf("declined reason=transitions off song=a -> normal advance"), env.logs)
        env.cfg = DJModeSettings()
        env.repeatOne = true
        assertNull(c.buildTransition())
        assertEquals("a new reason is a new line", 2, env.logs.size)
        assertTrue(env.logs.last().startsWith("declined reason=repeat "))
    }

    @Test fun theNextRowNotBeingLocalDeclinesAfterTheSequencerReasons() = runTest {
        val (c, env) = conductor()
        env.sources.remove("b")
        assertNull(c.buildTransition())
        assertEquals("declined reason=next not local song=a -> normal advance", env.logs.single())
        assertEquals(DjMode.Indicator.BufferingNext(null), c.indicator())
    }

    @Test fun theSequencerSideDeclinesAllGoThroughTheOneList() = runTest {
        val cases = listOf<Pair<(FakeEnv) -> Unit, String>>(
            { e: FakeEnv -> e.cfg = DJModeSettings(transitions = false) } to "transitions off",
            { e: FakeEnv -> e.playsRemaining = 2 } to "repeat",
            { e: FakeEnv -> e.halted = true } to "halted",
            { e: FakeEnv -> e.next = null } to "last song",
            { e: FakeEnv -> e.next = null; e.repeatAll = true } to "set repeats",
            { e: FakeEnv -> e.albumRun = true } to "album run",
            { e: FakeEnv -> e.nextAlbum = true } to "next starts an album side",
        )
        for ((arrange, words) in cases) {
            val (c, env) = conductor()
            arrange(env)
            // a missing next row has nothing to build: the shared decision still names the reason
            if (env.next != null) assertNull(c.buildTransition()) else assertNull(c.buildTransition())
            assertEquals(words, c.decide(forSkip = false, withLocal = false)?.raw)
        }
    }

    @Test fun theChipUsesTheSameListAsTheDecision() = runTest {
        val (c, env) = conductor()
        assertEquals(DjMode.Indicator.NextReady, c.indicator())
        env.halted = true
        assertEquals(DjMode.Indicator.NoMix("paused"), c.indicator())
        env.halted = false; env.next = null
        assertEquals(DjMode.Indicator.LastTrack, c.indicator())
        env.next = QueueItem("b"); env.dspPhase = DjPhase.FADING
        assertEquals(DjMode.Indicator.Mixing, c.indicator())
    }

    @Test fun anEngineDeclineBecomesTheChipForThatSongOnly() = runTest {
        val (c, env) = conductor()
        c.onEngineDeclined("stems-muted")
        assertEquals(DjMode.Indicator.NoMix("stems muted"), c.indicator())
        assertTrue(env.logs.single().startsWith("declined reason=stems-muted song=a"))
        env.cur = QueueItem("b")
        assertEquals("another song starts clean", DjMode.Indicator.NextReady, c.indicator())
    }

    // ---- the plan ----

    private fun planOf(env: FakeEnv, left: Double): AutoTransition.Plan {
        env.dspSecondsLeft = left
        return DjConductor(env, kotlinx.coroutines.CoroutineScope(kotlinx.coroutines.Dispatchers.Unconfined)).buildTransition()!!.plan
    }

    @Test fun planIsAdvancePlanOnTheRunwayWithGlideTempoOrKey() = runTest {
        val env = FakeEnv()
        val plan = planOf(env, left = 14.0)
        assertEquals(AutoTransition.advancePlan(14.0, 3.0, 10.0, fxGlide = true, mixGlide = true), plan)
        assertTrue(plan.isGlide)
        // 14 / 1.12 - 3 - 0.3 = 9.2: the pre-roll fits the runway, not the 10 s ceiling
        assertEquals(9.2, plan.preRollSeconds, 0.01)
    }

    @Test fun theRunwayShrinksByTheTempoMeetBeyondTheHeadroom() = runTest {
        val env = FakeEnv()
        env.facts["a"] = DjConductor.Facts(bpm = 100.0)
        env.facts["b"] = DjConductor.Facts(bpm = 150.0)
        val c = DjConductor(env, backgroundScope)
        env.dspSecondsLeft = 14.0
        val spec = c.buildTransition()!!
        val g = AutoTransition.glideParams(null, null, 100.0, 150.0)
        assertTrue("the outgoing meets the incoming in the middle", g.outRate > 1.12)
        assertEquals(g, spec.glide.copy(outPitch = 0.0, inPitch = 0.0).let { AutoTransition.GlideTargets(it.outRate, 0.0, it.inRate, 0.0) })
        val expected = AutoTransition.advancePlan(14.0 * minOf(1.0, 1.12 / g.outRate), 3.0, 10.0, true, true)
        assertEquals(expected, spec.plan)
        assertTrue(spec.plan.preRollSeconds < AutoTransition.advancePlan(14.0, 3.0, 10.0, true, true).preRollSeconds)
    }

    @Test fun theOutgoingsEffectiveTempoMeetsTheIncomings() = runTest {
        val env = FakeEnv()
        env.facts["a"] = DjConductor.Facts(bpm = 100.0)
        env.facts["b"] = DjConductor.Facts(bpm = 120.0)
        val c = DjConductor(env, backgroundScope)
        val slow = c.buildTransition()!!.glide
        env.dspRate = 1.2   // the listener sped the outgoing up to 120: nothing left to meet
        val matched = c.buildTransition()!!.glide
        assertEquals(AutoTransition.glideParams(null, null, 100.0, 120.0).outRate, slow.outRate, 1e-9)
        assertEquals(1.0, matched.outRate, 1e-9)
        assertEquals(1.0, matched.inRate, 1e-9)
    }

    @Test fun keyMatchOnlyGlidesPitchNotTempo() = runTest {
        val env = FakeEnv()
        env.cfg = DJModeSettings(tempoMatch = false, keyMatch = true, effectSweeps = false)
        env.facts["a"] = DjConductor.Facts(bpm = 100.0, camelot = "8A")
        env.facts["b"] = DjConductor.Facts(bpm = 140.0, camelot = "9A")
        val spec = DjConductor(env, backgroundScope).buildTransition()!!
        assertTrue(spec.plan.isGlide)
        assertEquals(1.0, spec.glide.outRate, 0.0)
        assertEquals(1.0, spec.glide.inRate, 0.0)
        assertTrue("one Camelot step bends the pitch", spec.glide.outPitch != 0.0)
        assertNull("no texture without Effect sweeps", spec.texture)
    }

    @Test fun tempoMatchOnlyGlidesTempoNotPitch() = runTest {
        val env = FakeEnv()
        env.cfg = DJModeSettings(tempoMatch = true, keyMatch = false, effectSweeps = false)
        env.facts["a"] = DjConductor.Facts(bpm = 100.0, camelot = "8A")
        env.facts["b"] = DjConductor.Facts(bpm = 120.0, camelot = "3B")
        val spec = DjConductor(env, backgroundScope).buildTransition()!!
        assertEquals(0.0, spec.glide.outPitch, 0.0)
        assertEquals(0.0, spec.glide.inPitch, 0.0)
        assertTrue(spec.glide.outRate > 1.0)
    }

    @Test fun withNeitherMatchNorSweepsThePlanIsAPlainCrossfade() = runTest {
        val env = FakeEnv()
        env.cfg = DJModeSettings(tempoMatch = false, keyMatch = false, effectSweeps = false)
        val spec = DjConductor(env, backgroundScope).buildTransition()!!
        assertFalse(spec.plan.isGlide)
        assertEquals(0.0, spec.plan.preRollSeconds, 0.0)
        assertEquals(0.0, spec.plan.postRollSeconds, 0.0)
        assertEquals(AutoTransition.identityGlide, spec.glide)
        assertNull(spec.texture)
        assertEquals(3.0, spec.plan.fadeSeconds, 0.0)
    }

    @Test fun effectSweepsAloneGlideWithTextureButNoTempoOrKeyBend() = runTest {
        val env = FakeEnv()
        env.cfg = DJModeSettings(tempoMatch = false, keyMatch = false, effectSweeps = true)
        val spec = DjConductor(env, backgroundScope).buildTransition()!!
        assertTrue(spec.plan.isGlide)
        assertNotNull(spec.texture)
        assertEquals(AutoTransition.identityGlide, spec.glide)
    }

    @Test fun incomingGainOnlyWithVolumeLeveling() = runTest {
        val env = FakeEnv()
        env.level = -3.5
        assertEquals(-3.5, DjConductor(env, backgroundScope).buildTransition()!!.incoming.levelDb, 0.0)
        env.cfg = DJModeSettings(volumeLeveling = false)
        assertEquals(0.0, DjConductor(env, backgroundScope).buildTransition()!!.incoming.levelDb, 0.0)
    }

    @Test fun aShortRunwayCapsTheFadeToWhatIsLeft() = runTest {
        val env = FakeEnv()
        val plan = planOf(env, left = 2.0)
        assertEquals(2.0, plan.fadeSeconds, 1e-9)
        assertEquals("the configured fade is restored afterwards", 3.0, plan.fadeRestore!!, 0.0)
    }

    @Test fun theTextureIsHeldForItsRunThenRerolledDeterministically() = runTest {
        val env = FakeEnv()
        val c = DjConductor(env, backgroundScope)
        c.plannerSeeded(1234uL)
        val rng = AutoTransition.Rng(1234uL)
        val first = AutoTransition.rollTexture(rng)
        val seen = (1..first.run).map { c.buildTransition()!!.texture }
        assertTrue("held for its run", seen.all { it == first })
        val next = AutoTransition.rollTexture(rng)
        assertEquals("then re-rolled from the same seeded stream", next, c.buildTransition()!!.texture)
    }

    @Test fun aSuspendedOrHeldDeckBuildsNothing() = runTest {
        val env = FakeEnv()
        val c = DjConductor(env, backgroundScope)
        env.active = false; assertNull(c.buildTransition())
        env.active = true; env.held = true; assertNull(c.buildTransition())
        env.held = false; env.dspEngaged = false; assertNull(c.buildTransition())
        assertTrue("silent: not a decline, DJ simply is not acting", env.logs.isEmpty())
    }

    // ---- track start ----

    @Test fun trackStartEngagesTheLocalRowAndArmsTheLeadWindow() = runTest {
        val env = FakeEnv().apply { dspEngaged = false; dspEngagedSongId = null; timings = DjMode.Timings(lead = 12.0) }
        val c = DjConductor(env, backgroundScope)
        c.onTrackStarted("a"); runCurrent()
        assertEquals(1, env.engageCalls)
        assertEquals(12.0, env.armLead!!, 0.0)
        assertEquals(listOf("track"), env.replans)
        assertNotNull("the armed callback decides at the lead window", env.armBuild!!.invoke())
    }

    @Test fun aRowThatIsNotSoundingYetWaitsForTheHeartbeat() = runTest {
        val env = FakeEnv().apply { dspEngaged = false; dspEngagedSongId = null; ready = false }
        val c = DjConductor(env, backgroundScope)
        c.onTrackStarted("a"); runCurrent()
        assertEquals(0, env.engageCalls)
        assertNull(env.armLead)
        env.ready = true
        c.poll(); runCurrent()
        assertEquals(1, env.engageCalls)
        assertNotNull(env.armLead)
        c.poll(); runCurrent()
        assertEquals("nothing pending any more", 1, env.engageCalls)
    }

    @Test fun aRowTheDspCannotOwnIsPlainAndNeverArms() = runTest {
        val env = FakeEnv().apply { dspEngaged = false; dspEngagedSongId = null; mixable = false }
        val c = DjConductor(env, backgroundScope)
        c.onTrackStarted("a"); runCurrent()
        assertEquals(0, env.engageCalls)
        assertNull(env.armLead)
        assertTrue(env.logs.single().contains("plain"))
    }

    @Test fun aRefusedEngageIsPlainToo() = runTest {
        val env = FakeEnv().apply { dspEngaged = false; dspEngagedSongId = null; engageResult = false }
        DjConductor(env, backgroundScope).also { it.onTrackStarted("a"); runCurrent() }
        assertNull(env.armLead)
        assertTrue(env.logs.single().contains("DSP refused"))
    }

    @Test fun anAlbumRunPlaysThroughOnTheRecordUnarmed() = runTest {
        val env = FakeEnv().apply { dspEngaged = false; dspEngagedSongId = null; albumRun = true }
        DjConductor(env, backgroundScope).also { it.onTrackStarted("a"); runCurrent() }
        assertEquals(0, env.engageCalls)
        assertTrue(env.logs.single().contains("album run"))
    }

    @Test fun aRowAlreadyOnTheDspJustArms() = runTest {
        val env = FakeEnv()
        DjConductor(env, backgroundScope).also { it.onTrackStarted("a"); runCurrent() }
        assertEquals(0, env.engageCalls)
        assertEquals(1, env.armCalls)
    }

    @Test fun aSuspendedDeckArmsNothingUntilResumed() = runTest {
        val env = FakeEnv().apply { active = false; dspEngaged = false; dspEngagedSongId = null }
        val c = DjConductor(env, backgroundScope)
        c.onTrackStarted("a"); runCurrent()
        assertEquals(0, env.engageCalls)
        env.active = true
        c.applyOnTrackStart(liveClock = true); runCurrent()
        assertEquals(1, env.engageCalls)
        assertEquals(1, env.armCalls)
    }

    @Test fun theRowMovingOnWhileEngagingLeavesItsOwnStartToArm() = runTest {
        val env = FakeEnv().apply { dspEngaged = false; dspEngagedSongId = null }
        val c = DjConductor(env, backgroundScope)
        val gate = kotlinx.coroutines.CompletableDeferred<Unit>()
        val slow = object : DjConductor.Env by env {
            override suspend fun engageCurrent(liveClock: Boolean): Boolean { gate.await(); return true }
        }
        val c2 = DjConductor(slow, backgroundScope)
        c2.onTrackStarted("a"); runCurrent()
        env.cur = QueueItem("b")
        gate.complete(Unit); runCurrent()
        assertEquals("a stale engage must not arm the new row", 0, env.armCalls)
        assertNotNull(c)
    }

    // ---- the fade start ----

    @Test fun fadeStartAdvancesRearmsAndReplans() = runTest {
        val (c, env) = conductor()
        assertTrue(c.onFadeStart("b"))
        assertEquals(listOf("b"), env.advances)
        assertEquals("re-armed for the incoming", 1, env.armCalls)
        assertEquals(listOf("track"), env.replans)
        assertEquals(1, c.transitionCount)
        assertTrue(env.logs.single().startsWith("advance at fade start from=a to=b"))
    }

    @Test fun aQueueThatMovedRefusesTheFadeStart() = runTest {
        val (c, env) = conductor()
        assertFalse(c.onFadeStart("c"))
        env.next = null
        assertFalse(c.onFadeStart("b"))
        assertTrue("nothing advanced", env.advances.isEmpty())
        assertEquals(0, env.armCalls)
        assertTrue(env.logs.all { it.contains("refused (the queue moved") })
    }

    @Test fun everyDeclineStartedDuringThePreRollRefusesTheFadeStart() = runTest {
        val cases = listOf<Pair<(FakeEnv) -> Unit, String>>(
            { e: FakeEnv -> e.cfg = DJModeSettings(transitions = false) } to "transitions off",
            { e: FakeEnv -> e.repeatOne = true } to "repeat",
            { e: FakeEnv -> e.playsRemaining = 3 } to "repeat",
            { e: FakeEnv -> e.halted = true } to "halted",
            { e: FakeEnv -> e.nextAlbum = true } to "next starts an album side",
        )
        for ((arrange, words) in cases) {
            val (c, env) = conductor()
            arrange(env)
            assertFalse(c.onFadeStart("b"))
            assertTrue(env.logs.single(), env.logs.single().contains("refused ($words since the transition began)"))
            assertTrue(env.advances.isEmpty())
        }
    }

    @Test fun suspendingDjDuringThePreRollRefusesTheFadeStart() = runTest {
        val (c, env) = conductor()
        env.active = false
        assertFalse(c.onFadeStart("b"))
        assertTrue(env.advances.isEmpty())
    }

    @Test fun aSequencerThatWillNotAdvanceRefusesTheFadeStart() = runTest {
        val (c, env) = conductor()
        env.advanceResult = false
        assertFalse(c.onFadeStart("b"))
        assertEquals(listOf("b"), env.advances)
        assertEquals("nothing re-armed or re-planned", 0, env.armCalls + env.replans.size)
        assertEquals(0, c.transitionCount)
    }

    // ---- failure and hand-back ----

    @Test fun anIncomingTheEngineCannotKeepPlaysThePlainWay() = runTest {
        val (c, env) = conductor()
        env.cur = QueueItem("b")
        c.onIncomingFailed("b")
        assertEquals(listOf("b"), env.plain.map { it.id })
        c.onIncomingFailed("zzz")
        assertEquals("only the current row", 1, env.plain.size)
    }

    @Test fun aHandBackLogsAndTheSongPlaysOn() = runTest {
        val (c, env) = conductor()
        c.onHandBack(41.25)
        c.onTransitionEnded(null, "seek")
        assertEquals("hand back at 41.3s (the song plays on)", env.logs[0].let { it.replace("41.2s", "41.3s") })
        assertTrue(env.logs[1].contains("how=seek"))
        assertTrue(env.advances.isEmpty() && env.plain.isEmpty())
    }

    @Test fun disarmAndLevelReachTheEngine() = runTest {
        val (c, env) = conductor()
        c.disarm()
        assertEquals(1, env.disarmCalls)
    }

    // ================================================================ the sequencer side of the advance (real SetlistSequencer)

    private class AdoptingPort(private val fake: FakePlayerPort, val adopt: MutableList<PlayRequest>, var adoptOk: Boolean = true) : PlayerPort by fake {
        override suspend fun adoptDsp(request: PlayRequest): Boolean { adopt += request; return adoptOk }
    }

    private class Rig(val ts: TestScope, scope: CoroutineScope, ids: Set<String>, adoptOk: Boolean = true) {
        val fake = FakePlayerPort()
        val adopted = mutableListOf<PlayRequest>()
        val logs = mutableListOf<String>()
        val meterLogs = mutableListOf<String>()
        val seq = SetlistSequencer(
            scope = scope,
            port = AdoptingPort(fake, adopted, adoptOk),
            registry = RowResolverRegistry(listOf(MapResolver("map", Rung.MANIFEST, ids.associateWith { stream(it) }))),
            modeProvider = { com.levi.pocketdj.playback.PlaybackMode.CLOUD },
            random = Random(7),
            log = { logs += it },
        )
        val meter = DeadAirMeter(file = null, log = { meterLogs += it }).also { seq.meter = it }
        val starts = mutableListOf<TrackStart>()
        init { seq.hooks.add(object : SequencerListener { override fun onTrackStarted(start: TrackStart) { starts += start } }) }
        fun settle() = ts.runCurrent()
    }

    private fun TestScope.rig(vararg ids: String, adoptOk: Boolean = true) = Rig(this, backgroundScope, ids.toSet(), adoptOk)

    @Test fun theFadeStartAdvanceMovesTheCursorWithoutALoadAndAdoptsTheDsp() = runTest {
        val r = rig("a", "b", "c")
        r.seq.play(rows("a", "b", "c")); r.settle()
        r.seq.onFirstAudio("a")
        assertEquals(listOf("a"), r.fake.loadedIds)
        assertTrue(r.seq.advanceAtDjFadeStart()); r.settle()
        assertEquals("b", r.seq.currentSongId)
        assertEquals("no ExoPlayer load for the incoming", listOf("a"), r.fake.loadedIds)
        val adopt = r.adopted.single()
        assertEquals("b", adopt.item.id)
        assertEquals(DjAdoptedSource, adopt.source)
        assertEquals(1, adopt.index)
        assertEquals(r.seq.state.value.playGeneration, adopt.generation)
        val start = r.starts.last()
        assertEquals(StartPath.DJ, start.path)
        assertTrue(r.logs.any { it.startsWith("[playback] track start song=b index=2/3 backend=dj noLoad=true") })
    }

    @Test fun theAdvanceIsANaturalEndNeverAnAutoSkip() = runTest {
        val r = rig("a", "b")
        val verdicts = mutableListOf<Pair<String, Boolean>>()
        r.seq.outcomes = com.levi.pocketdj.playback.outcome.PlayOutcomeRegistry {
            listOf(com.levi.pocketdj.shell.PlayOutcomeListener { id, skipped, _ -> verdicts += id to skipped })
        }
        r.seq.play(rows("a", "b")); r.settle()
        assertTrue(r.seq.advanceAtDjFadeStart()); r.settle()
        assertEquals(TransitionCause.NATURAL_END, r.seq.lastTransitionCause)
        assertEquals("the outgoing played through: not a skip", listOf("a" to false), verdicts)
        assertTrue(r.logs.any { it.contains("cause=${AdvanceCause.NATURAL_END}") })
        assertTrue(r.logs.none { it.contains("AUTO_SKIP") })
    }

    @Test fun oneHistoryPlayForTheIncoming() = runTest {
        val r = rig("a", "b", "c")
        val seen = mutableListOf<String>()
        backgroundScope.launch(UnconfinedTestDispatcher(testScheduler)) { PlayEventBus.events.collect { if (it.songId != "x") seen += it.songId } }
        r.seq.play(rows("a", "b", "c")); r.settle()
        seen.clear()
        assertTrue(r.seq.advanceAtDjFadeStart()); r.settle()
        assertEquals(listOf("b"), seen)
    }

    @Test fun theDeadAirMeterGetsCauseDjWithFirstAudioAtOnce() = runTest {
        val r = rig("a", "b")
        r.seq.play(rows("a", "b")); r.settle()
        r.seq.onFirstAudio("a")
        r.meterLogs.clear()
        assertTrue(r.seq.advanceAtDjFadeStart()); r.settle()
        val line = r.meterLogs.single()
        assertTrue(line, line.contains("cause=${DeadAirMeter.CAUSE_DJ}"))
        val gap = Regex("gap=([0-9.]+)s").find(line)!!.groupValues[1].toDouble()
        assertTrue("first audio at once: gap $gap", gap < 1.0)
        assertFalse("the start window closed at once (the incoming already sounds)", r.seq.isStartPending)
    }

    @Test fun theRepeatCounterOfTheIncomingStartsFresh() = runTest {
        val r = rig("a", "b")
        r.seq.play(listOf(QueueItem("a", title = "a"), QueueItem("b", title = "b", repeatCount = 2))); r.settle()
        assertEquals(1, r.seq.currentPlaysRemaining)
        assertTrue(r.seq.advanceAtDjFadeStart()); r.settle()
        assertEquals(2, r.seq.currentPlaysRemaining)
    }

    @Test fun aHaltedGateRefusesSoTheEngineCanPutTheOutgoingBack() = runTest {
        val r = rig("a", "b")
        r.seq.play(rows("a", "b")); r.settle()
        r.seq.autoAdvanceGate = { false }
        assertFalse(r.seq.advanceAtDjFadeStart()); r.settle()
        assertEquals("a", r.seq.currentSongId)
        assertTrue(r.adopted.isEmpty())
    }

    @Test fun nothingAdvancesWhenNotRunning() = runTest {
        val r = rig("a", "b")
        assertFalse(r.seq.advanceAtDjFadeStart())
        assertTrue(r.adopted.isEmpty())
    }

    @Test fun theLastRowFinishesTheRunLikeANormalAdvance() = runTest {
        val r = rig("a")
        r.seq.play(rows("a")); r.settle()
        r.seq.advanceAtDjFadeStart(); r.settle()
        assertFalse("past the end the run is over", r.seq.isRunning)
        assertTrue(r.adopted.isEmpty())
    }

    @Test fun aRepeatAllWrapAdvancesOntoTheFirstRow() = runTest {
        val r = rig("a", "b")
        r.seq.setRepeatMode(RepeatMode.ALL)
        r.seq.play(rows("a", "b")); r.settle()
        assertTrue(r.seq.advanceAtDjFadeStart()); r.settle()   // a -> b
        assertTrue(r.seq.advanceAtDjFadeStart()); r.settle()   // b -> a (wrap)
        assertEquals("a", r.seq.currentSongId)
        assertEquals(listOf("b", "a"), r.adopted.map { it.item.id })
    }

    @Test fun anAdoptThatFailsIsReportedForThePlainStart() = runTest {
        val r = rig("a", "b", adoptOk = false)
        val failed = mutableListOf<String>()
        r.seq.onDjAdoptFailed = { failed += it }
        r.seq.play(rows("a", "b")); r.settle()
        assertTrue(r.seq.advanceAtDjFadeStart()); r.settle()
        assertEquals(listOf(r.seq.state.value.current!!.uid), failed)
    }

    @Test fun anAdoptFailureForARowThatMovedOnIsIgnored() = runTest {
        val r = rig("a", "b", "c", adoptOk = false)
        val failed = mutableListOf<String>()
        r.seq.onDjAdoptFailed = { failed += it }
        r.seq.play(rows("a", "b", "c")); r.settle()
        assertTrue(r.seq.advanceAtDjFadeStart())
        r.seq.skipNext()          // the listener moves on before the adopt result lands
        r.settle()
        assertTrue(failed.isEmpty())
    }

    @Test fun theDspEndOfTheIncomingAdvancesTaggedNaturalEnd() = runTest {
        val r = rig("a", "b", "c")
        r.seq.play(rows("a", "b", "c")); r.settle()
        r.seq.advanceAtDjFadeStart(); r.settle()
        // the engine ends b on the DSP (host.advanceAfterEnd -> handleEnded)
        r.seq.handleEnded("b"); r.settle()
        assertEquals("c", r.seq.currentSongId)
        assertEquals(TransitionCause.NATURAL_END, r.seq.lastTransitionCause)
        assertEquals("c is a normal load", listOf("a", "c"), r.fake.loadedIds)
    }
}

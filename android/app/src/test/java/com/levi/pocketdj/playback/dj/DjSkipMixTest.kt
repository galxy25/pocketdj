package com.levi.pocketdj.playback.dj

import com.levi.pocketdj.mix.nowplaying.DjIncoming
import com.levi.pocketdj.mix.nowplaying.DjPhase
import com.levi.pocketdj.mix.nowplaying.DjTransitionSpec
import com.levi.pocketdj.playback.health.DeadAirMeter
import com.levi.pocketdj.playback.sequencer.AdvanceCause
import com.levi.pocketdj.playback.sequencer.FakePlayerPort
import com.levi.pocketdj.playback.sequencer.MapResolver
import com.levi.pocketdj.playback.sequencer.QueueItem
import com.levi.pocketdj.playback.sequencer.RepeatMode
import com.levi.pocketdj.playback.sequencer.Rung
import com.levi.pocketdj.playback.sequencer.RowResolverRegistry
import com.levi.pocketdj.playback.sequencer.SetlistSequencer
import com.levi.pocketdj.playback.sequencer.TransitionCause
import com.levi.pocketdj.playback.sequencer.rows
import com.levi.pocketdj.playback.sequencer.stream
import kotlinx.coroutines.ExperimentalCoroutinesApi
import kotlinx.coroutines.test.TestScope
import kotlinx.coroutines.test.runCurrent
import kotlinx.coroutines.test.runTest
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test
import java.io.File
import kotlin.random.Random

@OptIn(ExperimentalCoroutinesApi::class)
class DjSkipMixTest {

    // ================================================================ the pure skip rules (fake Port)

    private class FakePort : DjSkipMix.Port {
        var mix = true
        override val canMix get() = mix
        override var currentId: String? = "a"
        override var phase = DjPhase.IDLE
        override var isPlaying = true
        override var incomingSongId: String? = null
        override var secondsLeft = 100.0
        override var outRate: Double? = null
        override var skipFadeSeconds = 15.0
        var spec: DjTransitionSpec? = spec("b", fade = 15.0)
        val asked = mutableListOf<Double>()
        override fun makeTransition(skipFade: Double): DjTransitionSpec? { asked += skipFade; return spec?.let { it.copy(plan = it.plan.copy(fadeSeconds = skipFade)) } }
        var beginReason: String? = null
        val begun = mutableListOf<DjTransitionSpec>()
        var onBegin: () -> Unit = {}
        override fun beginTransition(spec: DjTransitionSpec): String? { begun += spec; onBegin(); return beginReason }
        val preRollFades = mutableListOf<Double>()
        override fun skipDuringPreRoll(fadeSeconds: Double) { preRollFades += fadeSeconds }
        var abandons = 0
        override fun abandonForSkip() { abandons++ }
        var postRollEnds = 0
        override fun endPostRollForSkip() { postRollEnds++ }
        val shortened = mutableListOf<Double>()
        var canShorten = true
        override fun shortenFade(fadeSeconds: Double): Boolean { shortened += fadeSeconds; return canShorten }
        var aways = 0
        override fun noteAdvanceAway() { aways++ }
        val declines = mutableListOf<Pair<String, String>>()
        override fun declined(from: String, reason: String) { declines += from to reason }
        val logs = mutableListOf<String>()
        override fun log(line: String) { logs += line }

        companion object {
            fun spec(incoming: String, fade: Double) = DjTransitionSpec(
                plan = AutoTransition.immediatePlan(fade, 3.0, 10.0, fxGlide = false, mixGlide = false),
                incoming = DjIncoming(incoming, File("$incoming.mp3")),
            )
        }
    }

    private fun skipMix(p: FakePort = FakePort()) = DjSkipMix(p) to p

    @Test fun idleMixesOverTheSkipFadeAndReportsThePressBeforeTheAdvance() {
        val (m, p) = skipMix()
        var awaysAtBegin = -1
        p.onBegin = { awaysAtBegin = p.aways }
        assertEquals(DjSkipResult.HANDLED, m.skip(fast = false))
        assertEquals(listOf(15.0), p.asked)
        assertEquals("the listen ends at the press, before the synchronous fade-start advance", 1, awaysAtBegin)
        assertEquals("b", m.pending)
        assertTrue(p.logs.single().startsWith("skip song=a -> b mix fade=15.0s"))
        assertFalse(p.logs.single().contains("(fast)"))
    }

    @Test fun fastUsesTheFiveSecondSweep() {
        val (m, p) = skipMix()
        m.skip(fast = true)
        assertEquals(listOf(5.0), p.asked)
        assertTrue(p.logs.single().endsWith("(fast)"))
    }

    @Test fun theSkipFadeSettingIsWhatATapMixesOver() {
        val (m, p) = skipMix(FakePort().also { it.skipFadeSeconds = 8.0 })
        m.skip(fast = false)
        assertEquals(listOf(8.0), p.asked)
    }

    @Test fun notMixableFallsBackToTheImmediateAdvanceWithoutReportingThePress() {
        val (m, p) = skipMix(FakePort().also { it.mix = false })
        assertEquals(DjSkipResult.FALLBACK, m.skip(false))
        assertEquals(0, p.aways)
        assertTrue(p.begun.isEmpty())
    }

    @Test fun noTransitionFromTheDecisionIsAFallbackTheCallerReports() {
        val (m, p) = skipMix(FakePort().also { it.spec = null })
        assertEquals(DjSkipResult.FALLBACK, m.skip(false))
        assertEquals("the caller's immediate advance reports the press", 0, p.aways)
        assertNull(m.pending)
    }

    @Test fun anEngineDeclineFallsBackWithThePressAlreadyReportedAndNothingPending() {
        val (m, p) = skipMix(FakePort().also { it.beginReason = "stems-muted" })
        assertEquals(DjSkipResult.FALLBACK_AWAY_NOTED, m.skip(false))
        assertEquals(1, p.aways)
        assertNull(m.pending)
        assertEquals(listOf("a" to "skip: stems-muted"), p.declines)
    }

    @Test fun midFadeIsIgnored() {
        val (m, p) = skipMix(FakePort().also { it.phase = DjPhase.FADING })
        assertEquals(DjSkipResult.HANDLED, m.skip(false))
        assertEquals(DjSkipResult.HANDLED, m.skip(true))   // a fast press on a NON-skip fade is ignored too
        assertTrue(p.shortened.isEmpty() && p.begun.isEmpty() && p.aways == 0)
        assertTrue(p.logs.all { it == "skip ignored - fade in flight song=a" })
    }

    @Test fun preRollDropsThePreRollAndFadesNowOverTheSkipLength() {
        val p = FakePort().also { it.phase = DjPhase.PREROLL; it.incomingSongId = "b" }
        val (m, _) = skipMix(p)
        assertEquals(DjSkipResult.HANDLED, m.skip(false))
        assertEquals(1, p.aways)
        assertEquals("keyed on the run's incoming", "b", m.pending)
        assertEquals(listOf(15.0), p.preRollFades)
        assertTrue(p.begun.isEmpty())
    }

    @Test fun preRollFadeIsCutToTheRunway() {
        // 8 s left at 1.0x: min(15, max(1, 8 - 0.5)) = 7.5
        val p = FakePort().also { it.phase = DjPhase.PREROLL; it.incomingSongId = "b"; it.secondsLeft = 8.0 }
        skipMix(p).first.skip(false)
        assertEquals(7.5, p.preRollFades.single(), 1e-9)
        // the pinned glide tempo shortens the real runway: 8 / 1.25 = 6.4 -> 5.9
        val q = FakePort().also { it.phase = DjPhase.PREROLL; it.incomingSongId = "b"; it.secondsLeft = 8.0; it.outRate = 1.25 }
        skipMix(q).first.skip(false)
        assertEquals(5.9, q.preRollFades.single(), 1e-9)
        // never below 1 s, whatever is left
        val r = FakePort().also { it.phase = DjPhase.PREROLL; it.incomingSongId = "b"; it.secondsLeft = 0.9 }
        skipMix(r).first.skip(false)
        assertEquals(1.0, r.preRollFades.single(), 1e-9)
    }

    @Test fun aSecondPressInThePreRollIsTheSameSkip() {
        val p = FakePort().also { it.phase = DjPhase.PREROLL; it.incomingSongId = "b" }
        val (m, _) = skipMix(p)
        m.skip(false)
        assertEquals(DjSkipResult.HANDLED, m.skip(true))
        assertEquals(1, p.aways)
        assertEquals(1, p.preRollFades.size)
        assertTrue(p.logs.last().startsWith("skip ignored - a skip mix is starting"))
    }

    @Test fun pausedInThePreRollAbandonsTheMixAndTheImmediateAdvanceSkips() {
        val p = FakePort().also { it.phase = DjPhase.PREROLL; it.incomingSongId = "b"; it.isPlaying = false }
        val (m, _) = skipMix(p)
        assertEquals(DjSkipResult.FALLBACK, m.skip(false))
        assertEquals(1, p.abandons)
        assertEquals("the caller reports the press", 0, p.aways)
        assertNull(m.pending)
    }

    @Test fun postRollEndsTheGlideThenMixesOutOfTheNewSong() {
        val p = FakePort().also { it.phase = DjPhase.POSTROLL }
        val (m, _) = skipMix(p)
        assertEquals(DjSkipResult.HANDLED, m.skip(false))
        assertEquals(1, p.postRollEnds)
        assertEquals(1, p.begun.size)
        assertEquals("b", m.pending)
    }

    @Test fun aSecondFastPressInsideTheSkipsOwnCrossfadeUpgradesIt() {
        val (m, p) = skipMix()
        m.skip(false)
        assertEquals("b", m.consumeAtFadeStart("b").let { "b" })   // the fade start lands
        assertTrue(m.mixing)
        p.phase = DjPhase.FADING
        assertEquals(DjSkipResult.HANDLED, m.skip(true))
        assertEquals(listOf(5.0), p.shortened)
        assertTrue(p.logs.last().startsWith("skip upgraded to fast"))
        assertEquals("still one skip: no second press reported", 1, p.aways)
    }

    @Test fun aFadeAlreadyAtFastOrShorterIsLeftAlone() {
        val (m, p) = skipMix(FakePort().also { it.canShorten = false })
        m.skip(true); m.consumeAtFadeStart("b")
        p.phase = DjPhase.FADING
        m.skip(true)
        assertTrue(p.logs.last().startsWith("skip ignored - fade in flight"))
    }

    @Test fun aSecondInAppTapInsideTheSkipsCrossfadeUpgradesToo() {
        val (m, p) = skipMix()
        m.skip(false); m.consumeAtFadeStart("b")
        p.phase = DjPhase.FADING
        assertEquals(DjSkipResult.HANDLED, m.skip(false))
        assertEquals(listOf(5.0), p.shortened)
        assertEquals(1, p.aways)
    }

    @Test fun aPressOnANaturalFadeIsNeverAnUpgrade() {
        val (m, p) = skipMix(FakePort().also { it.phase = DjPhase.FADING })
        m.skip(false)
        assertTrue(p.shortened.isEmpty())
    }

    @Test fun theFadeStartTakesThePendingSkipAndKeysItOnTheIncoming() {
        val (m, _) = skipMix()
        m.skip(false)
        assertEquals(DjSkipMix.Taken(skipPending = true, isSkip = true), m.consumeAtFadeStart("b"))
        assertNull(m.pending)
        assertEquals(DjSkipMix.Taken.None, m.consumeAtFadeStart("b"))
    }

    @Test fun aPendingSkipForAnotherRowIsStillPendingButNotThisSkip() {
        val (m, _) = skipMix()
        m.skip(false)
        val t = m.consumeAtFadeStart("zzz")
        assertTrue(t.skipPending && !t.isSkip)
        assertFalse("a refused skip leaves no crossfade running", m.mixing)
    }

    @Test fun everyStartAdvanceAndRunEndClearsThePending() {
        val (m, _) = skipMix()
        m.skip(false)
        m.clearPending()
        assertNull(m.pending)
        m.skip(false)
        m.transitionEnded()
        assertNull(m.pending)
        assertFalse(m.mixing)
        assertFalse(m.inFlight)
    }

    // ================================================================ the conductor: the fade start of a skip

    private open class Env : DjConductor.Env {
        override val djActive = true
        override val running = true
        override val held = false
        var cur = QueueItem("a", lengthMs = 200_000)
        var next: QueueItem? = QueueItem("b", lengthMs = 200_000)
        override fun currentItem() = cur
        override fun nextItem() = next
        override val queueCount = 3
        override var repeatOne = false
        override val repeatAll = false
        override var playsRemaining = 1
        override var halted = false
        override fun settings() = DJModeSettings()
        override fun timings() = DjMode.Timings()
        override fun currentInAlbumRun() = false
        override fun nextStartsAlbumRun() = false
        override fun localSource(item: QueueItem): DjConductor.LocalSource? = DjConductor.LocalSource(File("${item.id}.mp3"))
        override fun facts(songId: String): DjConductor.Facts? = null
        override val dspEngaged = true
        override val dspEngagedSongId: String? = "a"
        override val dspRate = 1.0
        override var dspSecondsLeft = 60.0
        override var dspPhase = DjPhase.IDLE
        override fun currentMixable() = true
        override suspend fun engageCurrent(liveClock: Boolean) = true
        override fun arm(lead: Double, build: () -> DjTransitionSpec?) {}
        override fun disarm() {}
        val plainAdvances = mutableListOf<String>()
        val skipAdvances = mutableListOf<String>()
        var advanceOk = true
        override fun advanceAtFadeStart(songId: String): Boolean { plainAdvances += songId; return advanceOk }
        override fun advanceAtFadeStartForSkip(songId: String): Boolean { skipAdvances += songId; return advanceOk }
        override fun playPlain(item: QueueItem) {}
        var refusedMixes = 0
        override fun skipAfterRefusedMix() { refusedMixes++ }
        var aways = 0
        override fun noteAdvanceAway() { aways++ }
        var beginSpec: DjTransitionSpec? = null
        var beginReason: String? = null
        override fun beginTransition(spec: DjTransitionSpec): String? { beginSpec = spec; return beginReason }
        val logs = mutableListOf<String>()
        override fun log(line: String) { logs += line }
    }

    private fun TestScope.conductor(e: Env = Env()) = DjConductor(e, backgroundScope) to e

    @Test fun aSkipMixIsBuiltOverTheSkipFadeWithThePlainImmediatePlan() = runTest {
        val (c, e) = conductor()
        assertEquals(DjSkipResult.HANDLED, c.skip(fast = false))
        val plan = e.beginSpec!!.plan
        assertEquals(0.0, plan.preRollSeconds, 0.0)
        assertEquals(15.0, plan.fadeSeconds, 0.0)
        assertEquals(1, e.aways)
        assertEquals("b", c.skipMix.pending)
    }

    @Test fun theSkipFadeIsCutToTheRunwayWithHalfASecondSpare() = runTest {
        val (c, e) = conductor()
        e.dspSecondsLeft = 8.0
        c.skip(false)
        assertEquals(7.5, e.beginSpec!!.plan.fadeSeconds, 1e-9)
        val (c2, e2) = conductor(Env().also { it.dspSecondsLeft = 1.2 })
        c2.skip(false)
        assertEquals("never under 1 s", 1.0, e2.beginSpec!!.plan.fadeSeconds, 1e-9)
    }

    @Test fun aSkipOverridesRepeatOneAndACountAndALiftedHaltButARealDeclineStillFallsBack() = runTest {
        val (c, e) = conductor(Env().also { it.repeatOne = true; it.playsRemaining = 3; it.halted = true })
        assertEquals(DjSkipResult.HANDLED, c.skip(false))
        assertEquals(1, e.aways)
        val (c2, e2) = conductor(Env().also { it.next = null })
        assertEquals("the last row has nothing to mix into", DjSkipResult.FALLBACK, c2.skip(false))
        assertEquals(0, e2.aways)
    }

    @Test fun anIncomingThatIsNotLocalFallsBackToTheImmediateAdvance() = runTest {
        val e = object : Env() { override fun localSource(item: QueueItem): DjConductor.LocalSource? = if (item.id == "b") null else super.localSource(item) }
        val (c, _) = conductor(e)
        assertEquals(DjSkipResult.FALLBACK, c.skip(false))
        assertEquals(0, e.aways)
        assertTrue(e.logs.any { it == "declined reason=skip: next not local song=a -> normal advance" })
    }

    @Test fun theFadeStartOfASkipAdvancesAsAUserSkipAndEndsTheSkipKeyedState() = runTest {
        val (c, e) = conductor()
        c.skip(false)
        assertTrue(c.onFadeStart("b"))
        assertEquals(listOf("b"), e.skipAdvances)
        assertTrue(e.plainAdvances.isEmpty())
        assertTrue(e.logs.any { it.contains("(skip)") })
        assertTrue("the skip crossfade is running", c.skipMix.mixing)
        c.onTransitionEnded("b", "complete")
        assertFalse(c.skipMix.mixing)
    }

    @Test fun aNaturalFadeStartIsNotASkip() = runTest {
        val (c, e) = conductor()
        assertTrue(c.onFadeStart("b"))
        assertEquals(listOf("b"), e.plainAdvances)
        assertTrue(e.skipAdvances.isEmpty())
    }

    @Test fun aSkipFadeStartIgnoresRepeatOneButANaturalOneRefuses() = runTest {
        val (c, e) = conductor(Env().also { it.repeatOne = true })
        // a natural fade start refuses a repeating row ...
        assertFalse(c.onFadeStart("b"))
        assertEquals(0, e.refusedMixes)
        // ... a skip's does not: ⏭ overrides repeat-one
        c.skip(false)
        assertTrue(c.onFadeStart("b"))
        assertEquals(listOf("b"), e.skipAdvances)
    }

    @Test fun aRefusedSkipFadeStillSkipsViaTheImmediateAdvance() = runTest {
        val (c, e) = conductor()
        c.skip(false)
        e.next = QueueItem("zzz")          // the queue moved under the transition
        assertFalse(c.onFadeStart("b"))
        assertEquals(1, e.refusedMixes)
        assertNull(c.skipMix.pending)
    }

    @Test fun aSkipPendingForAnotherRowRefusesAndStillSkips() = runTest {
        val (c, e) = conductor()
        c.skip(false)
        assertFalse(c.onFadeStart("someone-else"))
        assertEquals(1, e.refusedMixes)
        assertTrue(e.logs.any { it.contains("a skip was pending for another row") })
    }

    @Test fun theSequencerRefusingTheSkipAdvanceStillFallsBackToTheImmediateAdvance() = runTest {
        val (c, e) = conductor(Env().also { it.advanceOk = false })
        c.skip(false)
        assertFalse(c.onFadeStart("b"))
        assertEquals(1, e.refusedMixes)
    }

    @Test fun aCutBeforeTheAdvanceClearsThePendingSoALaterNaturalMixIsNotASkip() = runTest {
        val (c, e) = conductor()
        c.skip(false)
        c.onTransitionEnded(null, "seek")
        assertNull(c.skipMix.pending)
        assertTrue(c.onFadeStart("b"))
        assertEquals(listOf("b"), e.plainAdvances)
    }

    @Test fun disarmClearsThePending() = runTest {
        val (c, _) = conductor()
        c.skip(false)
        c.disarm()
        assertNull(c.skipMix.pending)
    }

    // ================================================================ the sequencer side: a skip's advance is a USER transport

    private class Rig(val ts: TestScope, ids: Set<String>) {
        val fake = FakePlayerPort()
        val logs = mutableListOf<String>()
        val meterLogs = mutableListOf<String>()
        val seq = SetlistSequencer(
            scope = ts.backgroundScope,
            port = fake,
            registry = RowResolverRegistry(listOf(MapResolver("map", Rung.MANIFEST, ids.associateWith { stream(it) }))),
            modeProvider = { com.levi.pocketdj.playback.PlaybackMode.CLOUD },
            random = Random(7),
            log = { logs += it },
        )
        init { seq.meter = DeadAirMeter(file = null, log = { meterLogs += it }) }
        fun settle() = ts.runCurrent()
    }

    private class Hooks(var result: DjSkipResult) : DjSkipHooks {
        val fast = mutableListOf<Boolean>()
        var cleared = 0
        override fun skip(fast: Boolean): DjSkipResult { this.fast += fast; return result }
        override fun clearPending() { cleared++ }
    }

    @Test fun theSkipAdvanceIsAUserTransportWithMeterCauseSkipAndOneVerdict() = runTest {
        val r = Rig(this, setOf("a", "b", "c"))
        val verdicts = mutableListOf<Pair<String, Boolean>>()
        r.seq.outcomes = com.levi.pocketdj.playback.outcome.PlayOutcomeRegistry {
            listOf(com.levi.pocketdj.shell.PlayOutcomeListener { id, skipped, _ -> verdicts += id to skipped })
        }
        r.seq.play(rows("a", "b", "c")); r.settle()
        r.seq.onFirstAudio("a")
        r.meterLogs.clear()
        assertTrue(r.seq.advanceAtDjFadeStart(skip = true)); r.settle()
        assertEquals("b", r.seq.currentSongId)
        assertEquals(TransitionCause.USER, r.seq.lastTransitionCause)
        assertTrue(r.logs.any { it.contains("cause=${AdvanceCause.USER}") })
        assertTrue(r.meterLogs.single().contains("cause=skip"))
        // the listen ends at the PRESS (noteDjSkipPress); the advance itself must not report it a second time
        assertTrue("no second away verdict from the advance: $verdicts", verdicts.size <= 1)
    }

    @Test fun aSkipAdvanceOverridesRepeatOneAndLiftsTheCascadeHalt() = runTest {
        val r = Rig(this, setOf("a", "b"))
        r.seq.setRepeatMode(RepeatMode.ONE)
        r.seq.play(rows("a", "b")); r.settle()
        assertTrue(r.seq.advanceAtDjFadeStart(skip = true)); r.settle()
        assertEquals("repeat-one never holds a skip", "b", r.seq.currentSongId)
        // while a NATURAL fade start with the gate shut still refuses
        val r2 = Rig(this, setOf("a", "b"))
        r2.seq.play(rows("a", "b")); r2.settle()
        r2.seq.autoAdvanceGate = { false }
        assertFalse(r2.seq.advanceAtDjFadeStart(skip = false))
        assertTrue("a skip lifts the halt", r2.seq.advanceAtDjFadeStart(skip = true))
    }

    @Test fun skipNextRoutesThroughTheDjHooksAndFastIsPassedOn() = runTest {
        val r = Rig(this, setOf("a", "b", "c"))
        val hooks = Hooks(DjSkipResult.HANDLED)
        r.seq.djSkip = hooks
        r.seq.play(rows("a", "b", "c")); r.settle()
        r.seq.skipNext(); r.seq.skipNext(fast = true)
        assertEquals(listOf(false, true), hooks.fast)
        assertEquals("handled by the mix: the row did not move", "a", r.seq.currentSongId)
    }

    @Test fun aFallbackIsTheImmediateAdvanceAndANonMixableDjIsToday() = runTest {
        val r = Rig(this, setOf("a", "b", "c"))
        r.seq.djSkip = Hooks(DjSkipResult.FALLBACK)
        r.seq.play(rows("a", "b", "c")); r.settle()
        r.seq.skipNext(); r.settle()
        assertEquals("b", r.seq.currentSongId)
        r.seq.djSkip = null
        r.seq.skipNext(fast = true); r.settle()
        assertEquals("c", r.seq.currentSongId)
    }

    @Test fun aRefusedSkipMixAdvancesImmediatelyAndIsAUserTransport() = runTest {
        val r = Rig(this, setOf("a", "b", "c"))
        r.seq.play(rows("a", "b", "c")); r.settle()
        r.seq.skipAfterRefusedDjMix(); r.settle()
        assertEquals("b", r.seq.currentSongId)
        assertEquals(TransitionCause.USER, r.seq.lastTransitionCause)
    }

    @Test fun everyStartAdvancePreviousAndRunEndClearsAPendingSkip() = runTest {
        val r = Rig(this, setOf("a", "b", "c"))
        val hooks = Hooks(DjSkipResult.FALLBACK)
        r.seq.djSkip = hooks
        r.seq.play(rows("a", "b", "c")); r.settle()
        var seen = hooks.cleared
        assertTrue("a start clears", seen > 0)
        r.seq.skipNext(); r.settle()
        assertTrue("an advance clears", hooks.cleared > seen); seen = hooks.cleared
        r.seq.skipPrevious(); r.settle()
        assertTrue("previous clears", hooks.cleared > seen); seen = hooks.cleared
        r.seq.stop(); r.settle()
        assertTrue("a run end clears", hooks.cleared > seen)
    }
}

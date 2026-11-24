package com.levi.pocketdj.playback.dj

import com.levi.pocketdj.audio.core.PcmBuffer
import com.levi.pocketdj.audio.dsp.LoudnessLeveling
import com.levi.pocketdj.audio.dsp.LoudnessSegment
import com.levi.pocketdj.playback.sequencer.QueueItem
import java.io.File
import java.util.concurrent.CountDownLatch
import java.util.concurrent.TimeUnit
import java.util.concurrent.atomic.AtomicBoolean
import java.util.concurrent.atomic.AtomicInteger
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.ExperimentalCoroutinesApi
import kotlinx.coroutines.SupervisorJob
import kotlinx.coroutines.test.StandardTestDispatcher
import kotlinx.coroutines.test.TestScope
import kotlinx.coroutines.test.advanceTimeBy
import kotlinx.coroutines.test.advanceUntilIdle
import kotlinx.coroutines.test.runCurrent
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNotEquals
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test
import kotlin.math.abs

/** P2-DJ-11: DJ volume leveling (ramps, stored-only, slices, cancel) and the analysis driver (priority, fact-gated re-plans). */
@OptIn(ExperimentalCoroutinesApi::class)
class DjLevelingTest {

    // ---------------------------------------------------------------- the ramp

    @Test fun rampValuesAreLinearEndExactlyOnTargetAndNeverStep() {
        val v = LevelRamper.rampValues(0.0, 6.0, 2.0)
        assertEquals("2 s in 20 ms steps", 100, v.size)
        assertEquals(6.0, v.last(), 0.0)
        var prev = 0.0
        for (x in v) { assertTrue("monotone", x >= prev); assertTrue("step <= 0.06 dB", x - prev <= 0.0601); prev = x }
        // downward, the full -12..+6 swing is 18 dB: each step still only 0.18 dB
        val d = LevelRamper.rampValues(6.0, -12.0, 2.0)
        var p = 6.0
        for (x in d) { assertTrue(p - x <= 0.1801); p = x }
        assertEquals(-12.0, d.last(), 0.0)
        assertEquals("the fade-start landing is 150 ms", 8, LevelRamper.rampValues(0.0, -3.5, LevelRamper.FADE_START_SECONDS).size)
    }

    @Test fun rampedSetWalksTheTwoSecondsInTwentyMsStepsAndLandsOnTarget() {
        val test = TestScope()
        val applied = ArrayList<Double>()
        val r = LevelRamper(CoroutineScope(SupervisorJob() + StandardTestDispatcher(test.testScheduler)), 0.0) { applied += it }
        r.set(5.0, ramp = true)
        test.testScheduler.runCurrent()
        assertTrue("nothing lands at once: never a step", applied.isEmpty())
        assertEquals(5.0, r.target, 0.0)
        assertTrue(r.inFlight)
        test.testScheduler.advanceTimeBy(20); test.testScheduler.runCurrent()
        assertEquals(1, applied.size); assertEquals(0.05, applied[0], 1e-9)
        test.testScheduler.advanceTimeBy(990); test.testScheduler.runCurrent()
        assertTrue("about halfway at 1 s", abs(r.applied - 2.5) < 0.11)
        test.testScheduler.advanceTimeBy(2000); test.testScheduler.advanceUntilIdle()
        assertEquals(100, applied.size)
        assertEquals(5.0, r.applied, 0.0)
        assertFalse(r.inFlight)
        var prev = 0.0
        for (x in applied) { assertTrue(x - prev <= 0.0501); prev = x }
    }

    @Test fun nonRampedSetLandsAtOnceAndClampsToMinus12Plus6() {
        val test = TestScope()
        val applied = ArrayList<Double>()
        val r = LevelRamper(CoroutineScope(SupervisorJob() + StandardTestDispatcher(test.testScheduler)), 0.0) { applied += it }
        r.set(9.0, ramp = false)
        assertEquals(listOf(6.0), applied)
        r.set(-30.0, ramp = false)
        assertEquals(-12.0, r.applied, 0.0)
        assertEquals(-12.0, r.target, 0.0)
    }

    @Test fun aNewTargetMidRampRestartsFromWhereTheTrimIsNow() {
        val test = TestScope()
        val applied = ArrayList<Double>()
        val r = LevelRamper(CoroutineScope(SupervisorJob() + StandardTestDispatcher(test.testScheduler)), 0.0) { applied += it }
        r.set(4.0, ramp = true)
        test.testScheduler.advanceTimeBy(1000); test.testScheduler.runCurrent()
        val mid = r.applied
        assertTrue(mid in 1.5..2.5)
        r.set(-2.0, ramp = true)
        test.testScheduler.advanceTimeBy(20); test.testScheduler.runCurrent()
        assertTrue("continues from the mid value, no jump", abs(applied.last() - mid) < 0.15)
        test.testScheduler.advanceUntilIdle()
        assertEquals(-2.0, r.applied, 0.0)
    }

    @Test fun aSubFractionOfADbChangeSnapsInsteadOfRamping() {
        val test = TestScope()
        val applied = ArrayList<Double>()
        val r = LevelRamper(CoroutineScope(SupervisorJob() + StandardTestDispatcher(test.testScheduler)), 1.0) { applied += it }
        r.set(1.005, ramp = true)
        assertEquals(listOf(1.005), applied)
        assertFalse(r.inFlight)
    }

    @Test fun fadeStartLandsInEightStepsOver150ms() {
        val test = TestScope()
        val applied = ArrayList<Double>()
        val r = LevelRamper(CoroutineScope(SupervisorJob() + StandardTestDispatcher(test.testScheduler)), 0.0) { applied += it }
        r.set(-3.5, ramp = true, seconds = LevelRamper.FADE_START_SECONDS)
        test.testScheduler.advanceTimeBy(160); test.testScheduler.advanceUntilIdle()
        assertEquals(8, applied.size)
        assertEquals(-3.5, applied.last(), 0.0)
        assertTrue("each step under a dB", applied.zipWithNext().all { (a, b) -> abs(b - a) < 1.0 })
    }

    // ---------------------------------------------------------------- leveling

    private val scope = CoroutineScope(SupervisorJob() + Dispatchers.Default)

    private fun media(size: Int): File = File.createTempFile("song", ".m4a").also { it.writeBytes(ByteArray(size)); it.deleteOnExit() }

    private class Fake(val file: File) : DjLeveling.Host {
        var dj = true
        var level = true
        var runningNow = true
        var engaged = true
        var streaming = false
        var target = 0.0
        var cur: QueueItem? = QueueItem("a")
        var startMs = 0L
        var lengthMs = 0L
        val sets = ArrayList<Pair<Double, Boolean>>()
        val logs = ArrayList<String>()
        override val djActive get() = dj
        override val volumeLeveling get() = level
        override val running get() = runningNow
        override val dspEngaged get() = engaged
        override val dspStreaming get() = streaming
        override val levelTargetDb get() = target
        override fun currentItem() = cur
        override fun localSource(item: QueueItem) = DjConductor.LocalSource(file, startMs, lengthMs)
        override fun setLevel(db: Double, ramp: Boolean) { sets += db to ramp; target = db }
        override fun log(line: String) { logs += line }
    }

    private class Rig(val file: File, measure: (String, LoudnessSegment?, com.levi.pocketdj.audio.dsp.LoudnessCancelFlag) -> Double? = { _, _, _ -> -20.0 }) {
        val calls = AtomicInteger()
        val host = Fake(file)
        val loud = LoudnessCache(
            null, CoroutineScope(SupervisorJob() + Dispatchers.Default), Dispatchers.Default, 10,
            { p, s, c -> calls.incrementAndGet(); measure(p, s, c) },
        )
        val analysis = AudioAnalysisCache(null)
        val leveling = DjLeveling(host, loud, analysis, CoroutineScope(SupervisorJob() + Dispatchers.Default))
        val src get() = DjConductor.LocalSource(file, host.startMs, host.lengthMs)
        fun key(id: String = "a") = leveling.keyFor(id, src)!!
    }

    private fun waitUntil(what: String, cond: () -> Boolean) {
        val end = System.nanoTime() + TimeUnit.SECONDS.toNanos(5)
        while (!cond()) { check(System.nanoTime() < end) { "timed out: $what" }; Thread.sleep(5) }
    }

    @Test fun unknownLoudnessIsZeroDbAndTheAnalysisIsKickedOnce() {
        val gate = CountDownLatch(1)
        val r = Rig(media(5)) { _, _, _ -> gate.await(5, TimeUnit.SECONDS); -20.0 }
        repeat(5) { assertEquals(0.0, r.leveling.levelDb("a", r.src), 0.0) }
        assertEquals("running for the key: never kicked twice", 1, r.loud.let { waitUntil("started") { r.calls.get() == 1 }; r.calls.get() })
        assertEquals(DjLeveling.Status.MEASURING, r.leveling.statusFor(r.key()))
        gate.countDown()
        waitUntil("stored") { r.loud.contains(r.key()) }
        assertEquals(6.0, r.leveling.levelDb("a", r.src), 1e-9)   // -14 - -20
        assertEquals(1, r.calls.get())
    }

    @Test fun aFailedAnalysisIsNeverKickedAgain() {
        val r = Rig(media(5)) { _, _, _ -> throw java.io.IOException("bad file") }
        assertEquals(0.0, r.leveling.levelDb("a", r.src), 0.0)
        waitUntil("failed") { r.loud.hasFailed(r.key()) }
        repeat(3) { assertEquals(0.0, r.leveling.levelDb("a", r.src), 0.0) }
        assertEquals(1, r.calls.get())
        assertEquals(DjLeveling.Status.UNAVAILABLE, r.leveling.statusFor(r.key()))
    }

    @Test fun onlyAStoredResultReappliesGainAndItRampsNeverSteps() {
        val r = Rig(media(5))
        val key = r.key()
        r.loud.store(-20.0, key)
        // cached / failed / cancelled / not-ready outcomes never re-apply (the old busy loop)
        for (o in listOf(LoudnessCache.Outcome.Cached(-20.0), LoudnessCache.Outcome.Failed, LoudnessCache.Outcome.Cancelled, LoudnessCache.Outcome.NotReady)) {
            r.leveling.onOutcome(key, o)
        }
        assertTrue("no gain moved", r.host.sets.isEmpty())
        r.leveling.onOutcome(key, LoudnessCache.Outcome.Measured(-20.0))
        assertEquals(listOf(6.0 to true), r.host.sets)          // landing mid-play: a ramp, not a step
        assertEquals(DjLeveling.Status.MEASURED, r.leveling.status.value)
        assertEquals("leveling song=a lufs=-20.0 gain=+6.0 dB (ramped)", r.host.logs.single())
    }

    @Test fun aTrackStartLandsTheStoredGainAtOnce() {
        val r = Rig(media(5))
        r.loud.store(-17.5, r.key())
        r.leveling.applyCurrent(ramp = false)
        assertEquals(listOf(3.5 to false), r.host.sets)
        r.leveling.applyCurrent(ramp = false)
        assertEquals("already there: nothing to move", 1, r.host.sets.size)
    }

    @Test fun anOutcomeForAnotherSongDoesNotMoveThePlayingTrim() {
        val r = Rig(media(5))
        val other = r.leveling.keyFor("zzz", r.src)!!
        r.loud.store(-20.0, other)
        r.leveling.onOutcome(other, LoudnessCache.Outcome.Measured(-20.0))
        assertTrue(r.host.sets.isEmpty())
    }

    @Test fun aFailedOutcomeOnlyUpdatesTheStatus() {
        val r = Rig(media(5))
        r.leveling.onOutcome(r.key(), LoudnessCache.Outcome.Failed)
        assertEquals(DjLeveling.Status.UNAVAILABLE, r.leveling.status.value)
        assertTrue(r.host.sets.isEmpty())
    }

    @Test fun theQuickHintStandsInClampedToFourDbUntilTheFinalLands() {
        val r = Rig(media(5)) { _, _, c -> while (!c.isCancelled) Thread.sleep(2); null }
        // hint says -30 LUFS: the full gain would be +6 (clamped from +16), the hint is capped at +4
        r.analysis.store(AudioAnalysis.Result(kind = AudioAnalysis.Kind.quick, lufs = -30.0), r.key())
        assertEquals(4.0, r.leveling.levelDb("a", r.src), 1e-9)
        assertEquals(DjLeveling.Status.ESTIMATED, r.leveling.statusFor(r.key()))
        r.analysis.store(AudioAnalysis.Result(kind = AudioAnalysis.Kind.quick, lufs = -2.0), r.key())
        assertEquals("-12 clamp then the hint's own -4 cap", -4.0, r.leveling.levelDb("a", r.src), 1e-9)
        r.loud.cancelAll()
    }

    @Test fun aGrowingFileUsesTheHintOrReportsMeasuringAndNeverKicksAMeasurement() {
        val r = Rig(media(5))
        r.host.streaming = true
        r.leveling.applyCurrent(ramp = true)
        assertEquals(DjLeveling.Status.MEASURING, r.leveling.status.value)
        assertTrue(r.host.sets.isEmpty())
        r.analysis.store(AudioAnalysis.Result(kind = AudioAnalysis.Kind.quick, headOnly = true, lufs = -16.0), r.key())
        r.analysis.store(AudioAnalysis.Result(kind = AudioAnalysis.Kind.quick, headOnly = true, lufs = -16.0), r.leveling.keyFor("a", r.src)!!)
        r.leveling.applyCurrent(ramp = true)
        assertEquals(DjLeveling.Status.ESTIMATED, r.leveling.status.value)
        assertEquals(listOf(2.0 to true), r.host.sets)
        assertEquals("a growing file is not measured", 0, r.calls.get())
    }

    @Test fun volumeOffLevelsTheTrimToZeroWithTheOffStatus() {
        val r = Rig(media(5))
        r.loud.store(-20.0, r.key())
        r.host.target = 6.0
        r.host.level = false
        r.leveling.applyCurrent(ramp = true)
        assertEquals(DjLeveling.Status.OFF, r.leveling.status.value)
        assertEquals(listOf(0.0 to true), r.host.sets)
        assertEquals("leveling off gain=0", r.host.logs.last())
    }

    @Test fun djOffIsInactiveAndLevelToZeroCancelsRunningAnalysesAndLandsAtOnce() {
        val started = CountDownLatch(1)
        val cancelled = AtomicBoolean(false)
        val r = Rig(media(5)) { _, _, c ->
            started.countDown()
            while (!c.isCancelled) Thread.sleep(2)
            cancelled.set(true)
            throw kotlin.coroutines.cancellation.CancellationException("x")
        }
        r.leveling.levelDb("a", r.src)
        assertTrue(started.await(5, TimeUnit.SECONDS))
        r.host.target = 3.0
        r.host.dj = false
        r.leveling.levelToZero()
        waitUntil("cancelled") { cancelled.get() }
        assertEquals(listOf(0.0 to false), r.host.sets)            // DJ off lands at once at 0 dB (no ramp)
        assertEquals(DjLeveling.Status.INACTIVE, r.leveling.status.value)
        assertEquals("leveling off gain=0", r.host.logs.last())
        waitUntil("not remembered") { !r.loud.isAnalyzing(r.key()) }
        assertFalse("a cancelled analysis is not a result", r.loud.contains(r.key()))
        assertFalse("nor a failure: the next DJ-on may measure it", r.loud.hasFailed(r.key()))
    }

    @Test fun nothingMovesWhenDspIsNotEngagedOrTheSessionIsOver() {
        val r = Rig(media(5))
        r.loud.store(-20.0, r.key())
        r.host.engaged = false
        r.leveling.applyCurrent(ramp = false)
        r.host.engaged = true; r.host.runningNow = false
        r.leveling.applyCurrent(ramp = false)
        assertTrue(r.host.sets.isEmpty())
    }

    @Test fun sharedAlbumSideIsMeasuredPerSongSliceNotWholeSide() {
        val side = media(50)
        val r = Rig(side)
        fun key(start: Long, len: Long) = r.leveling.keyFor("s", DjConductor.LocalSource(side, start, len))!!
        val k1 = key(0, 180_000); val k2 = key(180_000, 200_000); val k3 = key(180_000, 210_000)
        assertEquals(LoudnessSegment(180_000, 200_000), k2.segment)
        assertNotEquals(k1, k2)
        assertNotEquals(k2, k3)
        // two songs of one side never share a measurement
        r.loud.store(-20.0, k1); r.loud.store(-10.0, k2)
        assertEquals(6.0, r.loud.gainDb(k1)!!, 1e-9)
        assertEquals(-4.0, r.loud.gainDb(k2)!!, 1e-9)
        // an unknown length keys the slice to the end of the side
        assertNull(key(180_000, 0).segment!!.lengthMs)
        // a different file size is a different key (stale copies never answer)
        assertNotEquals(k2, r.leveling.keyFor("s", DjConductor.LocalSource(media(51), 180_000, 200_000)))
    }

    @Test fun theGainIsAlwaysWithinTheClampAndZeroWhenUnmeasurable() {
        val r = Rig(media(5))
        r.loud.store(-40.0, r.key("a"))
        assertEquals(LoudnessLeveling.MAX_GAIN_DB, r.leveling.levelDb("a", r.src), 0.0)
        r.loud.store(0.0, r.key("b"))
        assertEquals(LoudnessLeveling.MIN_GAIN_DB, r.leveling.levelDb("b", r.src), 0.0)
        r.loud.store(null, r.key("c"))         // analysed, nothing measurable: silence
        assertEquals(0.0, r.leveling.levelDb("c", r.src), 0.0)
        assertEquals(DjLeveling.Status.UNAVAILABLE, r.leveling.statusFor(r.key("c")))
    }

    // ---------------------------------------------------------------- the analysis driver

    private class Src : AudioAnalysis.PassSource {
        override fun decode(path: String, startSeconds: Double, lengthSeconds: Double) =
            PcmBuffer(8000, 1, FloatArray((8000 * lengthSeconds.coerceAtMost(2.0)).toInt()) { 0.01f })
        override fun availableSeconds(path: String, complete: Boolean) = 100.0
    }

    private class DriverRig(val file: File, val rows: List<QueueItem>, var index: Int = 0) {
        val test = TestScope()
        val gate = AtomicBoolean(false)       // hold the scheduler so ORDER is observable
        val cache = AudioAnalysisCache(null)
        val sched = AudioAnalysisScheduler(
            cache, CoroutineScope(SupervisorJob() + StandardTestDispatcher(test.testScheduler)), Src(), { gate.get() },
        )
        val fake = Fake(file).also { it.cur = rows.getOrNull(index) }
        val loud = LoudnessCache(null, CoroutineScope(SupervisorJob() + Dispatchers.Default), Dispatchers.Default, 10, { _, _, _ -> -20.0 })
        val leveling = DjLeveling(fake, loud, cache, CoroutineScope(SupervisorJob() + Dispatchers.Default))
        val landed = ArrayList<String>()
        var active = true
        var levelingOn = true
        var streaming = false
        val driver = DjAnalysisDriver(object : DjAnalysisDriver.Host {
            override val djActive get() = active
            override val volumeLeveling get() = levelingOn
            override val running = true
            override val index get() = this@DriverRig.index
            override val queue get() = rows
            override val currentStreaming get() = streaming
            // each row is its own file slice so every key is distinct
            override fun localSource(item: QueueItem) = DjConductor.LocalSource(file, rows.indexOf(item) * 1000L + 1, 900)
            override fun analysisLanded(songId: String) { landed += songId }
            override fun log(line: String) {}
        }, leveling, sched)
        init {
            fake.dj = true
        }
        fun settle() = test.testScheduler.advanceUntilIdle()
    }

    private fun rows(n: Int, userNextAt: Int? = null) =
        List(n) { QueueItem("s$it", lengthMs = 200_000, djUserNext = it == userNextAt) }

    @Test fun analysesAreRequestedCurrentThenUserPickThenNextThenWindow() {
        val r = DriverRig(media(9), rows(6, userNextAt = 1))
        r.driver.scheduleAnalysis()
        assertEquals(listOf("s0", "s1", "s2", "s3", "s4", "s5"), r.sched.pendingSongIds)
        // a planned next (not the listener's pick) is still ahead of the rest of the window
        val r2 = DriverRig(media(9), rows(5))
        r2.driver.scheduleAnalysis()
        assertEquals("s0", r2.sched.pendingSongIds.first())
        assertEquals("s1", r2.sched.pendingSongIds[1])
    }

    @Test fun theWindowIsFortyRowsPastTheCurrentOne() {
        val r = DriverRig(media(9), rows(60), index = 3)
        r.driver.scheduleAnalysis()
        assertEquals(1 + DjCandidates.PLAN_WINDOW, r.sched.pendingSongIds.size)
        assertEquals("s3", r.sched.pendingSongIds.first())
        assertEquals("s43", r.sched.pendingSongIds.last())
    }

    @Test fun nothingIsQueuedWhileDjIsOffAndCancelAllDropsTheQueue() {
        val r = DriverRig(media(9), rows(4))
        r.active = false
        r.driver.scheduleAnalysis()
        assertTrue(r.sched.pendingSongIds.isEmpty())
        r.active = true
        r.driver.scheduleAnalysis()
        assertEquals(4, r.sched.pendingSongIds.size)
        r.driver.cancelAll()
        assertTrue("DJ off drops the queue", r.sched.pendingSongIds.isEmpty())
    }

    @Test fun aResultReplansOnlyWhenAUsableFactChanged() {
        val r = DriverRig(media(9), rows(3))
        r.driver.onResult(LoudnessCache.Key("s1", 9), usableChanged = false)
        assertTrue("a loudness-only result / one that confirms the plan never re-plans", r.landed.isEmpty())
        r.driver.onResult(LoudnessCache.Key("s1", 9), usableChanged = true)
        assertEquals(listOf("s1"), r.landed)
        assertEquals(1, r.driver.replanRequests)
    }

    @Test fun aResultForTheCurrentSongRelevelsItRampedAndAnotherSongsDoesNot() {
        val r = DriverRig(media(9), rows(3))
        r.fake.startMs = 1; r.fake.lengthMs = 900   // the playing row's slice, as the driver host reports it
        val key = r.leveling.keyFor("s0", DjConductor.LocalSource(r.file, 1, 900))!!
        r.cache.store(AudioAnalysis.Result(kind = AudioAnalysis.Kind.quick, lufs = -16.0), key)
        r.driver.onResult(LoudnessCache.Key("s2", 9), usableChanged = false)
        assertTrue(r.fake.sets.isEmpty())
        r.driver.onResult(key, usableChanged = false)
        assertEquals(listOf(2.0 to true), r.fake.sets)
    }

    @Test fun nothingHappensForAResultOnceDjIsOff() {
        val r = DriverRig(media(9), rows(3))
        r.active = false; r.fake.dj = false
        r.driver.onResult(LoudnessCache.Key("s0", 9), usableChanged = true)
        assertTrue(r.landed.isEmpty() && r.fake.sets.isEmpty())
    }

    @Test fun theSchedulersLandedResultReachesTheDriverWithTheUsableFlag() {
        val r = DriverRig(media(9), rows(2))
        r.gate.set(true)
        r.driver.scheduleAnalysis()
        r.settle()
        // the fake PCM carries no beat or key: nothing usable changed, so the planner is never bothered
        assertTrue(r.landed.isEmpty())
        assertEquals(listOf("s0", "s1"), r.sched.startedOrder)
    }

    @Test fun upcomingRowsAreMeasuredOnlyWhileVolumeLevelingIsOnAndOnceEach() {
        val calls = AtomicInteger()
        val src = media(9)
        val rows = rows(5)
        val rig = DriverRig(src, rows)
        val counting = LoudnessCache(null, CoroutineScope(SupervisorJob() + Dispatchers.Default), Dispatchers.Default, 10, { _, _, _ -> calls.incrementAndGet(); -20.0 })
        val lv = DjLeveling(rig.fake, counting, rig.cache, CoroutineScope(SupervisorJob() + Dispatchers.Default))
        val d = DjAnalysisDriver(object : DjAnalysisDriver.Host {
            override val djActive = true
            override val volumeLeveling get() = rig.levelingOn
            override val running = true
            override val index = 0
            override val queue = rows
            override val currentStreaming = false
            override fun localSource(item: QueueItem) = DjConductor.LocalSource(src, rows.indexOf(item) * 1000L + 1, 900)
            override fun analysisLanded(songId: String) {}
            override fun log(line: String) {}
        }, lv, AudioAnalysisScheduler(rig.cache, CoroutineScope(SupervisorJob() + StandardTestDispatcher(rig.test.testScheduler)), Src(), { false }))
        rig.levelingOn = false
        d.analyzeUpcoming()
        Thread.sleep(50)
        assertEquals("Volume off: no loudness measurement", 0, calls.get())
        rig.levelingOn = true
        d.analyzeUpcoming(); d.analyzeUpcoming()
        waitUntil("two rows measured") { calls.get() == DjAnalysisDriver.UPCOMING_LEVELED }
        Thread.sleep(50)
        assertEquals(DjAnalysisDriver.UPCOMING_LEVELED, calls.get())
    }

    @Test fun factsFillFromAnalysisButNeverOverrideAMeasuredValue() {
        val full = AudioAnalysis.Result(kind = AudioAnalysis.Kind.full, bpm = 128.0, bpmConfidence = 0.9, camelot = "8A", keyConfidence = 0.9)
        val hint = AudioAnalysis.Result(kind = AudioAnalysis.Kind.quick, bpm = 90.0, bpmConfidence = 0.5, camelot = "3B", keyConfidence = 0.8)
        val weak = AudioAnalysis.Result(kind = AudioAnalysis.Kind.quick, bpm = 90.0, bpmConfidence = 0.1, camelot = "3B", keyConfidence = 0.2)
        assertEquals(120.0 to "5A", DjAnalysisDriver.factsWithAnalysis(120.0, "5A", full, hint))
        assertEquals(120.0 to "8A", DjAnalysisDriver.factsWithAnalysis(120.0, null, full, null))
        assertEquals("full beats a hint", 128.0 to "8A", DjAnalysisDriver.factsWithAnalysis(null, null, full, hint))
        assertEquals("a confident hint fills when nothing else", 90.0 to "3B", DjAnalysisDriver.factsWithAnalysis(0.0, null, null, hint))
        assertEquals("a low-confidence hint is missing", null to null, DjAnalysisDriver.factsWithAnalysis(null, null, null, weak))
    }
}

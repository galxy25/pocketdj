package com.levi.pocketdj.playback.npmix

import com.levi.pocketdj.playback.npmix.GrowingRules.RowFacts
import com.levi.pocketdj.playback.npmix.GrowingRules.TouchFacts
import com.levi.pocketdj.playback.npmix.GrowingRules.TouchVerdict
import com.levi.pocketdj.playback.npmix.GrowingRules.Verdict
import com.levi.pocketdj.playback.sequencer.QueueItem
import com.levi.pocketdj.playback.sequencer.StartAttempt
import kotlinx.coroutines.ExperimentalCoroutinesApi
import kotlinx.coroutines.test.advanceTimeBy
import kotlinx.coroutines.test.runCurrent
import kotlinx.coroutines.test.runTest
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test
import java.io.File

private fun plain(f: RowFacts) = (GrowingRules.eligible(f) as Verdict.Plain).reason

private fun stream(
    bytes: Long = 1_000_000, expected: Long? = 10_000_000, complete: Boolean = false, failed: Boolean = false,
    cut: Boolean = false, start: Long? = null, resolved: Boolean = true,
) = StreamInfo("a", File("/tmp/a.mp3"), null, bytes, expected, complete, failed, resolved, cut, start)

class GrowingEligibilityTest {
    @Test fun aRippedCloudRowWithMixModeBufferingIsEligible() {
        assertEquals(Verdict.Growing, GrowingRules.eligible(RowFacts()))
    }

    @Test fun eachRuleRefusesWithItsOwnReason() {
        assertEquals("mix-off", plain(RowFacts(buffering = false)))
        assertEquals("mix-tab", plain(RowFacts(mixTabActive = true)))
        assertEquals("device-mode", plain(RowFacts(deviceMode = true)))
        assertEquals("no-dsp", plain(RowFacts(dspAvailable = false)))
        assertEquals("refused", plain(RowFacts(refused = true)))
        assertEquals("local", plain(RowFacts(local = true)))
        assertEquals("studio-or-profile", plain(RowFacts(studioOrProfile = true)))
        assertEquals("catalog-only", plain(RowFacts(catalogOnly = true)))
        assertEquals("not-ripped", plain(RowFacts(ripped = false)))
        assertEquals("apple-music-first", plain(RowFacts(appleMusicFirst = true)))
        assertEquals("network-policy", plain(RowFacts(networkAllows = false)))
    }

    @Test fun anAnalogSongWithoutACutMinutesIntoTheSideIsPlain() {
        assertEquals("analog-side", plain(RowFacts(analogSide = true, analogStartMs = 95_000)))
    }

    @Test fun anAnalogSongAtTheTopOfItsSideOrWithACutStillGrows() {
        assertEquals(Verdict.Growing, GrowingRules.eligible(RowFacts(analogSide = true, analogStartMs = 0)))
        // a cut means analogSide=false (the stream is the per-song cut): the start offset is irrelevant
        assertEquals(Verdict.Growing, GrowingRules.eligible(RowFacts(analogSide = false, analogStartMs = 95_000)))
    }

    @Test fun refusedThisPlayBeatsEveryOtherFavourableFact() {
        assertEquals("refused", plain(RowFacts(refused = true, ripped = true)))
    }

    @Test fun aRestoreResumeUpTo15sDeepAlwaysStartsGrowing() {
        assertTrue(GrowingRules.resumeOk(null, null))
        assertTrue(GrowingRules.resumeOk(0, null))
        assertTrue(GrowingRules.resumeOk(15_000, null))
    }

    @Test fun aDeeperResumeNeedsTheBufferToCoverItPlusTheStartRunway() {
        assertFalse(GrowingRules.resumeOk(15_001, null))
        assertFalse(GrowingRules.resumeOk(60_000, 61.9))
        assertTrue(GrowingRules.resumeOk(60_000, 62.0))
    }

    @Test fun coveredIsTheByteFractionOfTheFileMinusTheFrontierMargin() {
        // 25 % of a 200 s file minus the margin
        val c = GrowingRules.covered(stream(bytes = 2_500_000), 200.0)!!
        assertEquals(50.0 - com.levi.pocketdj.mix.stream.GrowingFileSchedule.FRONTIER_MARGIN, c, 1e-9)
        assertEquals(200.0, GrowingRules.covered(stream(complete = true), 200.0)!!, 0.0)
        assertNull(GrowingRules.covered(stream(expected = null), 200.0))
        assertNull(GrowingRules.covered(stream(), null))
    }
}

class GrowingTouchTest {
    private fun facts(s: StreamInfo? = stream(bytes = 5_000_000), rel: Double = 30.0, dur: Double? = 200.0) =
        TouchFacts(
            buffering = true, refused = false, onPlainStream = true, dspEngaged = false, interruptionOpen = false,
            startPending = false, stream = s, songRelSeconds = rel, fileDurationSeconds = dur,
        )

    @Test fun theBufferMustCoverThePlayheadPlusTheResumeRunway() {
        // 50 % of 200 s = ~99.9 s covered
        assertTrue(GrowingRules.touchCovers(stream(bytes = 5_000_000), 90.0, 200.0))
        assertFalse(GrowingRules.touchCovers(stream(bytes = 5_000_000), 96.5, 200.0))
    }

    @Test fun aSideStreamNeedsTheSideOffsetOnTopOfTheSongPosition() {
        val side = stream(bytes = 5_000_000, start = 60_000)
        assertTrue(GrowingRules.touchCovers(side, 30.0, 200.0))   // needs 60 + 30 + 4 = 94 <= 99.9
        assertFalse(GrowingRules.touchCovers(side, 40.0, 200.0))  // needs 104
        // the SAME stream as a cut ignores the offset
        assertTrue(GrowingRules.touchCovers(stream(bytes = 5_000_000, cut = true, start = 60_000), 40.0, 200.0))
    }

    @Test fun anUnresolvedFailedOrDurationlessStreamNeverCovers() {
        assertFalse(GrowingRules.touchCovers(stream(resolved = false), 1.0, 200.0))
        assertFalse(GrowingRules.touchCovers(stream(failed = true, complete = true), 1.0, 200.0))
        assertFalse(GrowingRules.touchCovers(stream(), 1.0, null))
        assertFalse(GrowingRules.touchCovers(null, 1.0, 200.0))
    }

    @Test fun theTouchDecisionOrder() {
        assertEquals(TouchVerdict.Go, GrowingRules.touch(facts()))
        fun refuse(f: TouchFacts) = (GrowingRules.touch(f) as TouchVerdict.Refuse).reason
        assertEquals("mix-off", refuse(facts().copy(buffering = false)))
        assertEquals("engaged", refuse(facts().copy(dspEngaged = true)))
        assertEquals("refused", refuse(facts().copy(refused = true)))
        assertEquals("not-on-stream", refuse(facts().copy(onPlainStream = false)))
        assertEquals("interruption", refuse(facts().copy(interruptionOpen = true)))
        assertEquals("start-pending", refuse(facts().copy(startPending = true)))
        assertEquals("no-stream", refuse(facts(s = null)))
        assertEquals("no-stream", refuse(facts(s = stream(failed = true))))
        assertEquals("not-covered", refuse(facts(rel = 150.0)))
    }
}

class HoldWatchTest {
    @Test fun aMidSongHoldFallsBackAtExactlyFiveSeconds() {
        val w = HoldWatch()
        assertNull(w.sample(0, holding = true, awaitingFirstAudio = false, interruptionOpen = false))
        assertNull(w.sample(4_999, true, false, false))
        assertEquals("hold>5s", w.sample(5_000, true, false, false))
    }

    @Test fun aHoldThatClearsStartsOverNextTime() {
        val w = HoldWatch()
        w.sample(0, true, false, false)
        assertNull(w.sample(3_000, false, false, false))
        assertNull(w.sample(4_000, true, false, false))
        assertNull(w.sample(8_999, true, false, false))
        assertEquals("hold>5s", w.sample(9_000, true, false, false))
    }

    @Test fun aHoldBeforeFirstAudioGetsTheStartBudget() {
        val w = HoldWatch()
        w.sample(0, true, true, false)
        assertNull(w.sample(21_999, true, true, false))
        assertEquals("hold>22s", w.sample(22_000, true, true, false))
    }

    @Test fun anOpenInterruptionNeverFallsBackAndRestartsTheBudget() {
        val w = HoldWatch()
        w.sample(0, true, false, false)
        assertNull(w.sample(6_000, true, false, true))
        assertNull(w.sample(10_999, true, false, false))
        assertEquals("hold>5s", w.sample(11_000, true, false, false))
    }
}

@OptIn(ExperimentalCoroutinesApi::class)
class GrowingStartTest {
    private val row = QueueItem(id = "a", title = "A", artist = "X", lengthMs = 200_000, uid = "u1")

    private class FakeDsp : GrowingDsp {
        override var engagedSongId: String? = null
        override var isBuffering = false
        override var awaitingFirstAudio = false
        override var currentTimeSec = 0.0
    }

    private class FakeEnv(var current: QueueItem?) : GrowingEnv {
        override val dsp = FakeDsp()
        override var buffering = true
        override var generation = 7L
        override fun currentRow() = current
        override var interruptionOpen = false
        override var startPending = false
        var facts = RowFacts()
        var stream: StreamInfo? = stream()
        var duration: Double? = 200.0
        var touch: TouchFacts? = null
        var engageOk = true
        var completeOk = true
        var leftOk = true
        var restartOk = true
        val calls = mutableListOf<String>()
        val feeds = mutableListOf<StreamInfo>()
        val meter = mutableListOf<String>()
        var engagedAt = -1.0
        var rowFactsCalls = 0
        var replans = 0
        var firstAudio = mutableListOf<Pair<String, String>>()

        override suspend fun rowFacts(item: QueueItem): RowFacts { rowFactsCalls++; return facts }
        override fun openStream(item: QueueItem): StreamInfo? { calls += "open"; return stream }
        override fun stream(audioId: String): StreamInfo? = stream
        override fun fileDurationSeconds(item: QueueItem, s: StreamInfo) = duration
        override suspend fun touchFacts(item: QueueItem) = touch
        override suspend fun quietOutgoing() { calls += "quiet" }
        override fun engage(item: QueueItem, s: StreamInfo, atSeconds: Double): Boolean {
            calls += "engage"
            if (!engageOk) return false
            dsp.engagedSongId = item.id; engagedAt = atSeconds
            return true
        }
        override fun resume() { calls += "resume" }
        override fun disengage(): Double? { calls += "disengage"; dsp.engagedSongId = null; return dsp.currentTimeSec }
        override fun feed(s: StreamInfo) { feeds += s }
        override fun completeClaimedStart(gen: Long): Boolean { calls += "complete($gen)"; return completeOk }
        override fun noteFirstAudio(songId: String, source: String) { firstAudio += songId to source }
        override fun restartPlain(uid: String, atMs: Long): Boolean { calls += "restart($uid,$atMs)"; return restartOk }
        override suspend fun resumeLeftStream(songId: String, atMs: Long): Boolean { calls += "left($songId,$atMs)"; return leftOk }
        override fun meterBegan(cause: String) { meter += "began:$cause" }
        override fun meterTrackStarting(backend: String) { meter += "starting:$backend" }
        override fun meterFirstAudio(backend: String) { meter += "first:$backend" }
        override fun replan() { replans++ }
        override fun log(line: String) {}
    }

    private fun attempt(item: QueueItem, gen: Long = 7, resumeAtMs: Long? = null) =
        StartAttempt(item, 0, 3, gen, fresh = true, resumeAtMs = resumeAtMs, inPlace = false, reResolve = false)

    @Test fun anEligibleRowIsClaimedInTheRightOrder() = runTest {
        val env = FakeEnv(row)
        val g = GrowingStart(env, backgroundScope, { testScheduler.currentTime })
        assertTrue(g.tryClaim(attempt(row, resumeAtMs = 4_000)))
        assertEquals(listOf("open", "quiet", "engage", "complete(7)", "resume"), env.calls)
        assertEquals(4.0, env.engagedAt, 0.0)
        assertEquals("u1", g.growingUid)
        assertTrue(g.ownsAudio)
        assertEquals(1, g.startCount)
    }

    @Test fun mixModeOffNeverTouchesTheLoaderOrFacts() = runTest {
        val env = FakeEnv(row).apply { buffering = false }
        val g = GrowingStart(env, backgroundScope, { testScheduler.currentTime })
        assertFalse(g.tryClaim(attempt(row)))
        assertEquals(0, env.rowFactsCalls)
        assertTrue(env.calls.isEmpty())
    }

    @Test fun anIneligibleRowFallsThroughWithoutOpeningAStream() = runTest {
        val env = FakeEnv(row).apply { facts = RowFacts(local = true) }
        val g = GrowingStart(env, backgroundScope, { testScheduler.currentTime })
        assertFalse(g.tryClaim(attempt(row)))
        assertTrue(env.calls.isEmpty())
        assertFalse(g.ownsAudio)
    }

    @Test fun noStreamOrAFailedStreamIsPlain() = runTest {
        val env = FakeEnv(row).apply { stream = null }
        val g = GrowingStart(env, backgroundScope, { testScheduler.currentTime })
        assertFalse(g.tryClaim(attempt(row)))
        env.stream = stream(failed = true)
        assertFalse(g.tryClaim(attempt(row)))
        assertFalse(env.calls.contains("engage"))
    }

    @Test fun aDeepResumeTheBufferDoesNotCoverStartsPlainButACoveredOneGrows() = runTest {
        val env = FakeEnv(row)
        val g = GrowingStart(env, backgroundScope, { testScheduler.currentTime })
        // 10 % of 200 s buffered (~19 s): 40 s deep is not covered
        env.stream = stream(bytes = 1_000_000)
        assertFalse(g.tryClaim(attempt(row, resumeAtMs = 40_000)))
        assertFalse(env.calls.contains("quiet"))
        env.stream = stream(bytes = 5_000_000) // ~99.9 s
        assertTrue(g.tryClaim(attempt(row, resumeAtMs = 40_000)))
    }

    @Test fun aDspThatRefusesTheFileLeavesTheRowPlain() = runTest {
        val env = FakeEnv(row).apply { engageOk = false }
        val g = GrowingStart(env, backgroundScope, { testScheduler.currentTime })
        assertFalse(g.tryClaim(attempt(row)))
        assertFalse(g.ownsAudio)
        assertFalse(env.calls.contains("resume"))
    }

    @Test fun aStartSupersededWhileTheOutgoingSourceWentQuietIsDroppedBeforeTheDspEngages() = runTest {
        val env = FakeEnv(row)
        val g = GrowingStart(env, backgroundScope, { testScheduler.currentTime })
        env.generation = 8 // a skip bumped the generation while quiet ran
        assertTrue(g.tryClaim(attempt(row, gen = 7))) // claimed = "do nothing more": the newer start owns the audio
        assertFalse(env.calls.contains("engage"))
        assertFalse(g.ownsAudio)
    }

    @Test fun aStartSupersededBetweenEngageAndAnnouncementDisengagesAgain() = runTest {
        val env = FakeEnv(row).apply { completeOk = false }
        val g = GrowingStart(env, backgroundScope, { testScheduler.currentTime })
        assertTrue(g.tryClaim(attempt(row)))
        assertTrue(env.calls.contains("disengage"))
        assertFalse(env.calls.contains("resume"))
        assertFalse(g.ownsAudio)
    }

    @Test fun aHoldOfFiveSecondsLeavesTheDspAndRestartsPlainAtTheSamePosition() = runTest {
        val env = FakeEnv(row)
        val g = GrowingStart(env, backgroundScope, { testScheduler.currentTime }, pollMs = 250)
        g.tryClaim(attempt(row))
        env.dsp.currentTimeSec = 73.4
        env.dsp.isBuffering = true
        advanceTimeBy(4_900); runCurrent()
        assertTrue(g.ownsAudio)
        advanceTimeBy(500); runCurrent()
        assertFalse(g.ownsAudio)
        assertEquals(listOf("disengage", "restart(u1,73400)"), env.calls.takeLast(2))
        assertEquals(listOf("began:npmix-fallback"), env.meter)
        assertEquals("u1", g.refusedUid)
        assertEquals(1, g.fallbackCount)
        // the plain restart goes back through the funnel: the growing path refuses it this play
        assertFalse(g.tryClaim(attempt(row, gen = 9)))
    }

    @Test fun aHoldThatEndsInTimeDoesNotFallBack() = runTest {
        val env = FakeEnv(row)
        val g = GrowingStart(env, backgroundScope, { testScheduler.currentTime }, pollMs = 250)
        g.tryClaim(attempt(row))
        env.dsp.isBuffering = true
        advanceTimeBy(3_000); runCurrent()
        env.dsp.isBuffering = false
        advanceTimeBy(10_000); runCurrent()
        assertTrue(g.ownsAudio)
        assertEquals(0, g.fallbackCount)
    }

    @Test fun aStartHoldGetsTheLongerBudget() = runTest {
        val env = FakeEnv(row)
        val g = GrowingStart(env, backgroundScope, { testScheduler.currentTime }, pollMs = 250)
        g.tryClaim(attempt(row))
        env.dsp.isBuffering = true
        env.dsp.awaitingFirstAudio = true
        advanceTimeBy(20_000); runCurrent()
        assertTrue(g.ownsAudio)
        advanceTimeBy(2_500); runCurrent()
        assertFalse(g.ownsAudio)
    }

    @Test fun anInterruptionKeepsTheDspHolding() = runTest {
        val env = FakeEnv(row)
        val g = GrowingStart(env, backgroundScope, { testScheduler.currentTime }, pollMs = 250)
        g.tryClaim(attempt(row))
        env.dsp.isBuffering = true
        env.interruptionOpen = true
        advanceTimeBy(30_000); runCurrent()
        assertTrue(g.ownsAudio)
    }

    @Test fun aNewerGenerationFencesOutAStaleFallback() = runTest {
        val env = FakeEnv(row)
        val g = GrowingStart(env, backgroundScope, { testScheduler.currentTime }, pollMs = 250)
        g.tryClaim(attempt(row))
        env.dsp.isBuffering = true
        env.generation = 8 // a newer start owns the row: nothing of the old engagement may act
        advanceTimeBy(6_000); runCurrent()
        assertEquals(0, g.fallbackCount)
        assertFalse(env.calls.any { it.startsWith("restart") })
        assertFalse(g.ownsAudio) // the monitor retired itself
    }

    @Test fun aFallbackForAnotherRowIsIgnored() = runTest {
        val env = FakeEnv(row)
        val g = GrowingStart(env, backgroundScope, { testScheduler.currentTime }, pollMs = 250)
        g.tryClaim(attempt(row))
        env.current = QueueItem(id = "b", uid = "u2")
        g.onStreamFailed(12.0)
        assertEquals(0, g.fallbackCount)
        assertFalse(env.calls.any { it.startsWith("restart") })
    }

    @Test fun aStreamThatDiesBeforeAnyAudioFallsBackWithoutAnotherDisengage() = runTest {
        val env = FakeEnv(row)
        val g = GrowingStart(env, backgroundScope, { testScheduler.currentTime })
        g.tryClaim(attempt(row))
        val before = env.calls.count { it == "disengage" }
        g.onStreamFailed(2.0) // the engine already released itself
        assertEquals(before, env.calls.count { it == "disengage" })
        assertEquals("restart(u1,2000)", env.calls.last())
        assertEquals("u1", g.refusedUid)
    }

    @Test fun aTouchHandOffFallsBackOntoTheStreamItLeft() = runTest {
        val env = FakeEnv(row).apply {
            touch = TouchFacts(true, false, true, false, false, false, stream(bytes = 5_000_000), 30.0, 200.0)
        }
        val g = GrowingStart(env, backgroundScope, { testScheduler.currentTime }, pollMs = 250)
        assertTrue(g.engageFromStream(play = true))
        assertEquals(1, g.handOffCount)
        assertEquals(30.0, env.engagedAt, 0.0)
        assertEquals(listOf("began:npmix-growing-handoff", "starting:handoff"), env.meter)
        assertTrue(env.calls.last() == "resume")
        env.dsp.currentTimeSec = 41.0
        env.dsp.isBuffering = true
        advanceTimeBy(5_500); runCurrent()
        runCurrent()
        assertEquals("left(a,41000)", env.calls.last())
        assertFalse(env.calls.any { it.startsWith("restart") })
    }

    @Test fun ifTheLeftStreamCannotBeResumedTheRowRestartsPlain() = runTest {
        val env = FakeEnv(row).apply {
            leftOk = false
            touch = TouchFacts(true, false, true, false, false, false, stream(bytes = 5_000_000), 30.0, 200.0)
        }
        val g = GrowingStart(env, backgroundScope, { testScheduler.currentTime }, pollMs = 250)
        g.engageFromStream(play = true)
        env.dsp.currentTimeSec = 41.0
        env.dsp.isBuffering = true
        advanceTimeBy(5_500); runCurrent(); runCurrent()
        assertEquals(listOf("left(a,41000)", "restart(u1,41000)"), env.calls.takeLast(2))
    }

    @Test fun aPausedTouchHandOffStaysPausedAndOpensNoDeadAirTransition() = runTest {
        val env = FakeEnv(row).apply {
            touch = TouchFacts(true, false, true, false, false, false, stream(bytes = 5_000_000), 30.0, 200.0)
        }
        val g = GrowingStart(env, backgroundScope, { testScheduler.currentTime })
        assertTrue(g.engageFromStream(play = false))
        assertFalse(env.calls.contains("resume"))
        assertTrue(env.meter.isEmpty())
    }

    @Test fun aRefusedTouchHandOffTouchesNothing() = runTest {
        val env = FakeEnv(row).apply {
            touch = TouchFacts(true, false, true, false, true, false, stream(bytes = 5_000_000), 30.0, 200.0) // interruption
        }
        val g = GrowingStart(env, backgroundScope, { testScheduler.currentTime })
        assertFalse(g.engageFromStream(play = true))
        assertFalse(env.calls.contains("engage"))
        assertFalse(g.ownsAudio)
    }

    @Test fun aTouchHandOffIsRefusedForARowThatFellBackThisPlay() = runTest {
        val env = FakeEnv(row).apply {
            touch = TouchFacts(true, false, true, false, false, false, stream(bytes = 5_000_000), 30.0, 200.0)
        }
        val g = GrowingStart(env, backgroundScope, { testScheduler.currentTime })
        g.tryClaim(attempt(row))
        g.onStreamFailed(1.0)
        env.calls.clear()
        assertFalse(g.engageFromStream(play = true))
        assertFalse(env.calls.contains("engage"))
    }

    @Test fun firstAudioIsReportedToTheSequencerUnderTheRightSource() = runTest {
        val env = FakeEnv(row)
        val g = GrowingStart(env, backgroundScope, { testScheduler.currentTime })
        g.tryClaim(attempt(row))
        g.onDspAudioStarted()
        assertEquals(listOf("a" to "dsp-stream"), env.firstAudio)
    }

    @Test fun aHandOffFirstAudioClosesItsDeadAirTransition() = runTest {
        val env = FakeEnv(row).apply {
            touch = TouchFacts(true, false, true, false, false, false, stream(bytes = 5_000_000), 30.0, 200.0)
        }
        val g = GrowingStart(env, backgroundScope, { testScheduler.currentTime })
        g.engageFromStream(play = true)
        g.onDspAudioStarted()
        assertEquals(listOf("a" to "dsp-stream-handoff"), env.firstAudio)
        assertEquals("first:handoff", env.meter.last())
    }

    @Test fun progressForTheGrowingRowFeedsTheEngineAndCompletionReplansOnce() = runTest {
        val env = FakeEnv(row)
        val g = GrowingStart(env, backgroundScope, { testScheduler.currentTime })
        g.tryClaim(attempt(row))
        g.onStreamProgress("a")
        assertEquals(1, env.feeds.size)
        env.stream = stream(complete = true, bytes = 10_000_000)
        g.onStreamProgress("a"); g.onStreamProgress("a")
        assertEquals(3, env.feeds.size)
        assertEquals(1, env.replans)
        g.onStreamProgress("other")
        assertEquals(3, env.feeds.size)
    }

    @Test fun rowChangeAndSessionEndClearTheLedger() = runTest {
        val env = FakeEnv(row)
        val g = GrowingStart(env, backgroundScope, { testScheduler.currentTime })
        g.tryClaim(attempt(row))
        g.rowChanged("u1")
        assertTrue(g.ownsAudio) // the claimed row's own announcement must not clear it
        g.rowChanged("u2")
        assertFalse(g.ownsAudio)
        g.tryClaim(attempt(row, gen = 7))
        g.onStreamFailed(1.0)
        assertEquals("u1", g.refusedUid)
        g.rowChanged("u2")
        assertNull(g.refusedUid) // a different row clears the refusal
        g.sessionEnded()
        assertFalse(g.ownsAudio)
    }

    @Test fun theInterceptorRunsBetweenTheGlideAndTheDefaultLoad() {
        assertEquals(50, GrowingRules.PRIORITY)
        assertEquals("growing", GrowingRules.BACKEND)
    }
}

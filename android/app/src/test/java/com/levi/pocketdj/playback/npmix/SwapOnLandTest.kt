package com.levi.pocketdj.playback.npmix

import com.levi.pocketdj.playback.health.PlaybackRunway
import com.levi.pocketdj.playback.health.RunwayLock
import com.levi.pocketdj.playback.npmix.SwapOnLand.Decision
import com.levi.pocketdj.playback.npmix.SwapOnLand.FailVerdict
import com.levi.pocketdj.playback.npmix.SwapOnLand.Facts
import com.levi.pocketdj.playback.npmix.SwapOnLand.Playing
import com.levi.pocketdj.playback.npmix.SwapOnLand.StreamRef
import com.levi.pocketdj.playback.npmix.SwapOnLand.Target
import kotlinx.coroutines.CompletableDeferred
import kotlinx.coroutines.ExperimentalCoroutinesApi
import kotlinx.coroutines.test.advanceTimeBy
import kotlinx.coroutines.test.runCurrent
import kotlinx.coroutines.test.runTest
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNotNull
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test

private val STREAM = "https://rips.example/presigned/a.mp3?sig=1"
private val LOCAL = "file:///data/burns/a.mp3"

private fun playing(
    songId: String = "a", url: String = STREAM, pos: Long = 42_000, dur: Long? = 200_000,
    clipStart: Long? = null, clipEnd: Long? = null, rel: Boolean = true,
    isFile: Boolean = false, live: Boolean = false, loaded: Boolean = true, ended: Boolean = false,
) = Playing(songId, url, clipStart, clipEnd, pos, dur, isFile, live, loaded, ended, rel)

private fun mkFacts(
    playing: Playing? = playing(),
    target: Target? = Target(LOCAL, null, null, "a"),
    mix: Boolean = true, running: Boolean = true, held: Boolean = false, dsp: Boolean = false, mixTab: Boolean = false,
    cascade: Boolean = false, am: Boolean = false, startPending: Boolean = false, interruption: Boolean = false,
    paused: Boolean = false, intent: Boolean = true, pwr: Boolean = true, len: Long? = 200_000, gen: Long = 1,
    uid: String = "u1", resolveId: String = "a",
) = Facts(
    mixEnabled = mix, running = running, held = held, dspEngaged = dsp, mixTabActive = mixTab, pausedByCascade = cascade,
    appleMusicActive = am, startPending = startPending, rowUid = uid, rowId = "a", rowResolveId = resolveId, rowLengthMs = len,
    generation = gen, playing = playing, target = target, interruptionOpen = interruption, listenerPaused = paused,
    intentPlaying = intent, enginePlayWhenReady = pwr,
)

private fun refusal(f: Facts) = decide(f) as Decision.Refuse
private fun decide(f: Facts) = SwapOnLand.decide(f)

class SwapOnLandDecisionTest {
    @Test fun goesWhenPlayingTheStreamAndTheFileLanded() {
        val d = decide(mkFacts()) as Decision.Go
        assertEquals(42_000L, d.atMs)
        assertEquals(42_000L, d.localSeekMs)
        assertEquals(LOCAL, d.target.url)
        assertEquals(StreamRef(STREAM, null, null), d.stream)
    }

    @Test fun pausedByTheListenerIsRefusedAndOwed() {
        val r = refusal(mkFacts(paused = true))
        assertEquals("paused", r.reason)
        assertTrue("a paused refusal is retried on the next play", r.owe)
    }

    @Test fun anEngineThatNoLongerIntendsToPlayIsRefused() {
        assertEquals("paused", refusal(mkFacts(intent = false)).reason)
        assertEquals("paused", refusal(mkFacts(pwr = false)).reason)
    }

    @Test fun focusLostOrTransientIsRefusedAndOwed() {
        val r = refusal(mkFacts(interruption = true))
        assertEquals("focus", r.reason)
        assertTrue(r.owe)
    }

    @Test fun startWindowStillOpenIsDeferredNotDropped() {
        val r = refusal(mkFacts(startPending = true))
        assertEquals("start-pending", r.reason)
        assertTrue(r.owe)
    }

    @Test fun mixTabLiveSuspendsAndIsOwed() {
        val r = refusal(mkFacts(mixTab = true))
        assertEquals("mix-tab", r.reason)
        assertTrue(r.owe)
    }

    @Test fun sessionWideGuards() {
        assertEquals("mix-off", refusal(mkFacts(mix = false)).reason)
        assertEquals("not-running", refusal(mkFacts(running = false)).reason)
        assertEquals("held", refusal(mkFacts(held = true)).reason)
        assertEquals("engaged", refusal(mkFacts(dsp = true)).reason)
        assertEquals("cascade", refusal(mkFacts(cascade = true)).reason)
        assertEquals("apple-music", refusal(mkFacts(am = true)).reason)
    }

    @Test fun onlyAPresignedStreamOfTheSameRowHandsOff() {
        assertEquals("no-engine-item", refusal(mkFacts(playing = null)).reason)
        assertEquals("live", refusal(mkFacts(playing = playing(live = true))).reason)
        assertEquals("not-current", refusal(mkFacts(playing = playing(songId = "zzz"))).reason)
        assertEquals("already-local", refusal(mkFacts(playing = playing(url = LOCAL, isFile = true))).reason)
        assertEquals("not-loaded", refusal(mkFacts(playing = playing(loaded = false))).reason)
        assertEquals("track-ended", refusal(mkFacts(playing = playing(ended = true))).reason)
    }

    @Test fun theEditionSubstituteRowIsMatchedByItsResolveIdToo() {
        val f = mkFacts(playing = playing(songId = "a_clean"), target = Target(LOCAL, null, null, "a_clean"), resolveId = "a_clean")
        assertTrue(decide(f) is Decision.Go)
    }

    @Test fun sameBytesOnly() {
        assertEquals("no-local-file", refusal(mkFacts(target = null)).reason)
        assertEquals("other-edition", refusal(mkFacts(target = Target(LOCAL, null, null, "a_explicit"))).reason)
    }

    @Test fun neverCutsIntoTheLastMoments() {
        assertEquals("near-end", refusal(mkFacts(playing = playing(pos = 198_000))).reason)
        assertTrue(decide(mkFacts(playing = playing(pos = 190_000))) is Decision.Go)
        // The row's length is the queue's clipped length; the engine duration is the fallback.
        assertEquals("near-end", refusal(mkFacts(len = null, playing = playing(pos = 198_000, dur = 200_000))).reason)
    }

    @Test fun nearEndUsesTheSongLengthNotTheFileWhenTheEngineIsFileAbsolute() {
        // A side file: the song window is 60 s..120 s; the engine's duration is the whole side (300 s).
        val p = playing(pos = 118_000, dur = 300_000, clipStart = 60_000, clipEnd = 120_000, rel = false)
        assertEquals("near-end", refusal(mkFacts(len = null, playing = p)).reason)
    }
}

class SwapOnLandPositionTest {
    @Test fun clipRelativeEnginesPassThrough() {
        val p = playing(pos = 5_000, clipStart = 60_000, rel = true)
        assertEquals(5_000L, SwapOnLand.songRelMs(p))
        assertEquals(5_000L, SwapOnLand.localSeekMs(5_000, Target(LOCAL, 120_000, 180_000, "a"), positionIsClipRelative = true))
    }

    @Test fun sideToCutRebasesOnStartMs() {
        // File-absolute engine on a shared side starting at 60 s, 5 s into the song; the landed file is a per-song cut.
        val p = playing(pos = 65_000, clipStart = 60_000, rel = false)
        assertEquals(5_000L, SwapOnLand.songRelMs(p))
        assertEquals(5_000L, SwapOnLand.localSeekMs(5_000, Target(LOCAL, null, null, "a"), positionIsClipRelative = false))
    }

    @Test fun sideToSideRebasesOntoTheNewWindow() {
        val p = playing(pos = 65_000, clipStart = 60_000, rel = false)
        val seek = SwapOnLand.localSeekMs(SwapOnLand.songRelMs(p), Target(LOCAL, 120_000, 180_000, "a"), positionIsClipRelative = false)
        assertEquals(125_000L, seek)
    }

    @Test fun cutToSideAndNegativeClocksClamp() {
        assertEquals(0L, SwapOnLand.songRelMs(playing(pos = 59_000, clipStart = 60_000, rel = false)))
        assertEquals(0L, SwapOnLand.songRelMs(playing(pos = -5, rel = true)))
        assertEquals(30_000L + 90_000L, SwapOnLand.localSeekMs(30_000, Target(LOCAL, 90_000, null, "a"), false))
    }

    @Test fun decisionCarriesTheRebasedSeek() {
        val p = playing(pos = 65_000, clipStart = 60_000, rel = false)
        val d = decide(mkFacts(playing = p, target = Target(LOCAL, 120_000, 180_000, "a"))) as Decision.Go
        assertEquals(5_000L, d.atMs)
        assertEquals(125_000L, d.localSeekMs)
        assertEquals(60_000L, d.stream.clipStartMs)
    }
}

class HandOffLedgerTest {
    private val stream = StreamRef(STREAM, 0L, null)
    private val local = Target(LOCAL, null, null, "a")

    @Test fun aFailedLocalFileRevertsOnceThenAdvances() {
        val l = SwapOnLand.HandOffLedger()
        l.recordHandOff("u1", "a", local, stream, atMs = 42_000)
        val first = l.onFailed("u1", "a", LOCAL, liveSongRelMs = 43_500)
        assertEquals(FailVerdict.Revert(stream, 43_500), first)
        assertNull(l.fallback)
        // The stream is the stamp now; ANOTHER failure (the stream or the file) is the sequencer's: advance.
        assertEquals(FailVerdict.Advance, l.onFailed("u1", "a", STREAM, 44_000))
        assertEquals(FailVerdict.Advance, l.onFailed("u1", "a", LOCAL, 44_000))
        assertEquals(1, l.revertCount)
    }

    @Test fun aFileThatDiedBeforeItEverLoadedRevertsToTheHandOffPosition() {
        val l = SwapOnLand.HandOffLedger()
        l.recordHandOff("u1", "a", local, stream, atMs = 42_000)
        assertEquals(FailVerdict.Revert(stream, 42_000), l.onFailed("u1", "a", LOCAL, liveSongRelMs = 0))
    }

    @Test fun ownStampNeedsUrlAndSong() {
        val l = SwapOnLand.HandOffLedger()
        l.recordHandOff("u1", "a", local, stream, 1)
        assertTrue(l.isOwnStamp(LOCAL, "a"))
        // Two songs on one analog side share one file: the URL alone is not ours.
        assertFalse(l.isOwnStamp(LOCAL, "b"))
        assertFalse(l.isOwnStamp("file:///other.mp3", "a"))
        assertEquals(FailVerdict.Advance, l.onFailed("u1", "b", LOCAL, 10))
    }

    @Test fun anotherRowsFailureNeverReverts() {
        val l = SwapOnLand.HandOffLedger()
        l.recordHandOff("u1", "a", local, stream, 1)
        assertEquals(FailVerdict.Advance, l.onFailed("u2", "a", LOCAL, 10))
    }

    @Test fun aRowChangeVoidsFallbackStampAndOwed() {
        val l = SwapOnLand.HandOffLedger()
        l.recordHandOff("u1", "a", local, stream, 1)
        l.owe("u1")
        l.rowChanged("u2")
        assertNull(l.fallback)
        assertNull(l.ownStamp)
        assertNull(l.takeOwed("u1"))
    }

    @Test fun owedIsConsumedOnlyForTheSameRow() {
        val l = SwapOnLand.HandOffLedger()
        l.owe("u1")
        assertNull(l.takeOwed("u2"))
        assertNull("taking clears it", l.takeOwed("u1"))
        l.owe("u1")
        assertEquals("u1", l.takeOwed("u1"))
    }
}

@OptIn(ExperimentalCoroutinesApi::class)
class SwapOnLandRunnerTest {
    private class FakeEngine : SwapOnLand.Engine {
        val reloads = mutableListOf<List<Any?>>()
        var accept = true
        var audio = CompletableDeferred<Boolean>()
        override suspend fun reload(songId: String, url: String, clipStartMs: Long?, clipEndMs: Long?, atMs: Long): Boolean {
            if (!accept) return false
            reloads += listOf(songId, url, clipStartMs, clipEndMs, atMs)
            audio = CompletableDeferred()
            return true
        }
        override suspend fun awaitAudio(timeoutMs: Long): Boolean = kotlinx.coroutines.withTimeoutOrNull(timeoutMs) { audio.await() } ?: false
    }

    private class FakeEnv : SwapOnLand.Env {
        var next: Facts? = mkFacts()
        var sequence: ArrayDeque<Facts?>? = null
        override var lockCarriesStems = false
        var dspResult = true
        val dspCalls = mutableListOf<Pair<String, Long>>()
        var replans = 0
        val lines = mutableListOf<String>()
        override suspend fun facts(): Facts? { val q = sequence; return if (q != null) (if (q.size > 1) q.removeFirst() else q.first()) else next }
        override suspend fun engageDsp(songId: String, atMs: Long): Boolean { dspCalls += songId to atMs; return dspResult }
        override fun replan() { replans++ }
        override val runwayLock: RunwayLock? = null
        override fun log(line: String) { lines += line }
    }

    private val runwayLines = mutableListOf<String>()
    private fun newRunway(n: String, l: RunwayLock?, cap: Long) = PlaybackRunway(n, l, log = { runwayLines += it }, capMs = cap)

    @Test fun handOffReloadsOnTheLocalFileAtTheSamePositionAndHoldsARunwayUntilFirstAudio() = runTest {
        val env = FakeEnv(); val eng = FakeEngine()
        val r = SwapOnLand.Runner(env, eng, backgroundScope, newRunway = ::newRunway)
        assertTrue(r.attempt("landed"))
        assertEquals(listOf<Any?>("a", LOCAL, null, null, 42_000L), eng.reloads.single())
        assertEquals(1, r.ledger.handOffCount)
        assertEquals(1, env.replans)
        assertTrue(env.lines.any { it.startsWith("hand-off row=a pos=42000") })
        runCurrent()
        assertTrue("runway held across the reload", r.runwayHeld)
        eng.audio.complete(true)
        runCurrent()
        assertFalse(r.runwayHeld)
        assertTrue(runwayLines.any { it.contains("reason=firstAudio") })
    }

    @Test fun theRunwayIsCappedAtTenSecondsWhenNoAudioEverComes() = runTest {
        val env = FakeEnv(); val eng = FakeEngine()
        val r = SwapOnLand.Runner(env, eng, backgroundScope, newRunway = ::newRunway)
        r.attempt("landed")
        runCurrent()
        assertTrue(r.runwayHeld)
        advanceTimeBy(SwapOnLand.RUNWAY_CAP_MS + 1)
        runCurrent()
        assertFalse(r.runwayHeld)
        assertTrue(runwayLines.any { it.contains("reason=cap") })
    }

    @Test fun neverStartsAudioWhilePausedAndRetriesWhenTheListenerPlaysAgain() = runTest {
        val env = FakeEnv(); val eng = FakeEngine()
        env.next = mkFacts(paused = true)
        val r = SwapOnLand.Runner(env, eng, backgroundScope, newRunway = ::newRunway)
        assertFalse(r.attempt("landed"))
        assertTrue(eng.reloads.isEmpty())
        assertTrue(env.lines.any { it.startsWith("hand-off refused reason=paused") })
        assertEquals("u1", r.ledger.owedUid)
        // Still paused at the retry: refused again, still owed.
        r.retryOwed("user-play", "u1")
        assertTrue(eng.reloads.isEmpty())
        // The listener resumed: the retry hands off.
        env.next = mkFacts(paused = false)
        r.retryOwed("user-play", "u1")
        assertEquals(1, eng.reloads.size)
        assertNull(r.ledger.owedUid)
    }

    @Test fun anOwedHandOffForAnotherRowIsDropped() = runTest {
        val env = FakeEnv(); val eng = FakeEngine()
        env.next = mkFacts(startPending = true)
        val r = SwapOnLand.Runner(env, eng, backgroundScope, newRunway = ::newRunway)
        r.attempt("landed")
        assertEquals("u1", r.ledger.owedUid)
        env.next = mkFacts(uid = "u2")
        r.retryOwed("after-start", "u2")
        assertTrue(eng.reloads.isEmpty())
    }

    @Test fun aSkipRacingTheFactsReadSupersedesTheHandOff() = runTest {
        val env = FakeEnv(); val eng = FakeEngine()
        env.sequence = ArrayDeque(listOf(mkFacts(uid = "u1", gen = 1), mkFacts(uid = "u2", gen = 2)))
        val r = SwapOnLand.Runner(env, eng, backgroundScope, newRunway = ::newRunway)
        assertFalse(r.attempt("landed"))
        assertTrue(eng.reloads.isEmpty())
        assertTrue(env.lines.any { it.contains("reason=superseded") })
    }

    @Test fun aPauseBetweenTheTwoReadsIsHonoured() = runTest {
        val env = FakeEnv(); val eng = FakeEngine()
        env.sequence = ArrayDeque(listOf(mkFacts(), mkFacts(paused = true)))
        val r = SwapOnLand.Runner(env, eng, backgroundScope, newRunway = ::newRunway)
        assertFalse(r.attempt("landed"))
        assertTrue(eng.reloads.isEmpty())
        assertEquals("u1", r.ledger.owedUid)
    }

    @Test fun anEngineThatRefusesLeavesNoFallbackAndNoRunway() = runTest {
        val env = FakeEnv(); val eng = FakeEngine().apply { accept = false }
        val r = SwapOnLand.Runner(env, eng, backgroundScope, newRunway = ::newRunway)
        assertFalse(r.attempt("landed"))
        assertNull(r.ledger.fallback)
        assertFalse(r.runwayHeld)
        assertEquals(0, r.ledger.handOffCount)
    }

    @Test fun underAStemLockWithStemsTheDspEngagesDirectlyWithoutAnExoReload() = runTest {
        val env = FakeEnv().apply { lockCarriesStems = true }; val eng = FakeEngine()
        val r = SwapOnLand.Runner(env, eng, backgroundScope, newRunway = ::newRunway)
        assertTrue(r.attempt("landed"))
        assertEquals(listOf("a" to 42_000L), env.dspCalls)
        assertTrue(eng.reloads.isEmpty())
    }

    @Test fun aRefusedDspEngageFallsBackToThePlainReload() = runTest {
        val env = FakeEnv().apply { lockCarriesStems = true; dspResult = false }; val eng = FakeEngine()
        val r = SwapOnLand.Runner(env, eng, backgroundScope, newRunway = ::newRunway)
        assertTrue(r.attempt("landed"))
        assertEquals(1, env.dspCalls.size)
        assertEquals(1, eng.reloads.size)
    }

    @Test fun aFailedLocalFileRevertsOnceToTheStreamAtTheSamePosition() = runTest {
        val env = FakeEnv(); val eng = FakeEngine()
        val r = SwapOnLand.Runner(env, eng, backgroundScope, newRunway = ::newRunway)
        r.attempt("landed")
        eng.reloads.clear()
        assertTrue("first failure is handled by the revert", r.onFailed("u1", "a", LOCAL, 44_000))
        runCurrent()
        assertEquals(listOf<Any?>("a", STREAM, null, null, 44_000L), eng.reloads.single())
        // A second failure is the sequencer's to advance.
        assertFalse(r.onFailed("u1", "a", STREAM, 45_000))
        assertFalse(r.onFailed("u1", "a", LOCAL, 45_000))
        assertNotNull(r.ledger.ownStamp)
        assertEquals(1, eng.reloads.size)
    }

    @Test fun aRowChangeEndsTheRunwayAndForgetsTheFallback() = runTest {
        val env = FakeEnv(); val eng = FakeEngine()
        val r = SwapOnLand.Runner(env, eng, backgroundScope, newRunway = ::newRunway)
        r.attempt("landed")
        runCurrent()
        assertTrue(r.runwayHeld)
        r.rowChanged("u2")
        assertFalse(r.runwayHeld)
        assertNull(r.ledger.fallback)
        assertFalse(r.onFailed("u2", "a", LOCAL, 1))
    }
}

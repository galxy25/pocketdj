package com.levi.pocketdj.playback.npmix

import com.levi.pocketdj.playback.npmix.AppleMusicHandOffRules.Facts
import com.levi.pocketdj.playback.npmix.AppleMusicHandOffRules.Verdict
import kotlinx.coroutines.test.runTest
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

private fun facts(f: Facts.() -> Facts = { this }) = Facts(
    buffering = true, appleMusicActive = true, dspEngaged = false, mixTabActive = false, localCopyComplete = true, appleMusicPlaying = true,
    lengthMs = 200_000, positionMs = 60_000,
).f()

private fun reason(f: Facts) = (AppleMusicHandOffRules.verdict(f) as Verdict.Refuse).reason

class AppleMusicHandOffRulesTest {
    @Test fun aCompleteLocalCopyMidSongIsEligible() {
        assertEquals(Verdict.Go, AppleMusicHandOffRules.verdict(facts()))
    }

    @Test fun eachRuleRefusesWithItsOwnReason() {
        assertEquals("mix-off", reason(facts { copy(buffering = false) }))
        assertEquals("not-on-apple-music", reason(facts { copy(appleMusicActive = false) }))
        assertEquals("engaged", reason(facts { copy(dspEngaged = true) }))
        assertEquals("mix-tab", reason(facts { copy(mixTabActive = true) }))
        assertEquals("refused", reason(facts { copy(refused = true) }))
        assertEquals("no-local-copy", reason(facts { copy(localCopyComplete = false) }))
        assertEquals("interruption", reason(facts { copy(interruptionOpen = true, appleMusicPlaying = false) }))
        assertEquals("start-pending", reason(facts { copy(startPending = true) }))
    }

    @Test fun aMusicKitOwnedInterruptionFlagDoesNotHoldWhileAppleMusicSoundsOrThePauseIsIntentional() {
        assertEquals(Verdict.Go, AppleMusicHandOffRules.verdict(facts { copy(interruptionOpen = true, appleMusicPlaying = true) }))
        assertEquals(Verdict.Go, AppleMusicHandOffRules.verdict(facts { copy(interruptionOpen = true, appleMusicPlaying = false, pauseIntentional = true) }))
    }

    @Test fun tailGuardIs3sOfTheEnd() {
        assertEquals(3_000L, AppleMusicHandOffRules.TAIL_GUARD_MS)
        assertEquals("tail-guard", reason(facts { copy(positionMs = 197_001) }))
        assertEquals(Verdict.Go, AppleMusicHandOffRules.verdict(facts { copy(positionMs = 197_000) }))
    }

    @Test fun unknownLengthOrPositionCannotTripTheTailGuard() {
        assertFalse(AppleMusicHandOffRules.inTail(null, 200_000))
        assertFalse(AppleMusicHandOffRules.inTail(199_000, null))
        assertFalse(AppleMusicHandOffRules.inTail(199_000, 0))
    }

    @Test fun targetIsThePositionPlusLeadKeptInsideTheSong() {
        assertEquals(60_000L, AppleMusicHandOffRules.targetMs(60_000, 200_000))
        assertEquals(60_250L, AppleMusicHandOffRules.targetMs(60_000, 200_000, 250))
        assertEquals(199_999L, AppleMusicHandOffRules.targetMs(250_000, 200_000))
        assertEquals(0L, AppleMusicHandOffRules.targetMs(-5, null))
        assertEquals(0L, AppleMusicHandOffRules.LEAD_MS_DEFAULT)
    }

    @Test fun causeLabelMatchesTheDeadAirContract() {
        assertEquals("npmix-am-handoff", AppleMusicHandOffRules.CAUSE)
    }
}

class AppleMusicHandOffTest {
    private class FakeEnv : AppleMusicHandOffEnv {
        override var buffering = true
        override var generation = 1L
        var uid: String? = "u1"
        var facts: Facts? = facts { copy(positionMs = null) }
        var position: Long? = 60_000
        var engageOk = true
        val calls = mutableListOf<String>()
        val meter = mutableListOf<String>()
        var readyChanges = 0
        override fun currentRowUid() = uid
        override fun currentRowId() = "sng_1"
        override suspend fun facts() = facts
        override suspend fun appleMusicPositionMs() = position
        override suspend fun engagePaused(atSeconds: Double): Boolean { calls += "engagePaused($atSeconds)"; return engageOk }
        override suspend fun stopAppleMusic() { calls += "stopAm" }
        override fun resume() { calls += "resume" }
        override fun disengage() { calls += "disengage" }
        override fun readyChanged() { readyChanges++ }
        override fun meterBegan(cause: String) { meter += "began:$cause" }
        override fun meterTrackStarting(backend: String) { meter += "starting:$backend" }
        override fun meterFirstAudio(backend: String) { meter += "first:$backend" }
        override fun log(line: String) {}
    }

    @Test fun theSwapIsEngagePausedThenStopAppleMusicThenPlay_atTheAppleMusicPosition() = runTest {
        val env = FakeEnv()
        val h = AppleMusicHandOff(env)
        assertTrue(h.handOff(play = true))
        assertEquals(listOf("engagePaused(60.0)", "stopAm", "resume"), env.calls)
        assertEquals(1, h.handOffCount)
    }

    @Test fun exactlyOneDeadAirTransition_closedAtTheDspsFirstSound() = runTest {
        val env = FakeEnv()
        val h = AppleMusicHandOff(env)
        h.handOff(true)
        assertEquals(listOf("began:npmix-am-handoff", "starting:handoff"), env.meter)
        h.onDspAudioStarted(); h.onDspAudioStarted()
        assertEquals(listOf("began:npmix-am-handoff", "starting:handoff", "first:handoff"), env.meter)
    }

    @Test fun aPausedRowStaysPausedAndOpensNoDeadAirTransition() = runTest {
        val env = FakeEnv()
        val h = AppleMusicHandOff(env)
        assertTrue(h.handOff(play = false))
        assertEquals(listOf("engagePaused(60.0)", "stopAm"), env.calls)
        assertTrue(env.meter.isEmpty())
        h.onDspAudioStarted()
        assertTrue(env.meter.isEmpty())
    }

    @Test fun neverAutomatic_refreshingAndRowEventsNeverEngage() = runTest {
        val env = FakeEnv()
        val h = AppleMusicHandOff(env)
        h.rowChanged("u1")
        h.refresh()
        assertTrue(h.ready())
        h.refresh(); h.rowChanged("u1"); h.refresh()
        h.onDspAudioStarted()
        assertTrue(env.calls.isEmpty())
        assertTrue(env.meter.isEmpty())
        assertEquals(0, h.handOffCount)
    }

    @Test fun theTailGuardRefusesAndLeavesAppleMusicUntouched() = runTest {
        val env = FakeEnv().also { it.position = 198_000 }
        val h = AppleMusicHandOff(env)
        assertFalse(h.handOff(true))
        assertTrue(env.calls.isEmpty())
        assertTrue(env.meter.isEmpty())
    }

    @Test fun aDspRefusalKeepsAppleMusicPlaying_andTheRowIsNotRetriedThisPlay() = runTest {
        val env = FakeEnv().also { it.engageOk = false }
        val h = AppleMusicHandOff(env)
        assertFalse(h.handOff(true))
        assertEquals(listOf("engagePaused(60.0)"), env.calls)
        assertTrue(env.meter.isEmpty())
        env.engageOk = true
        assertFalse(h.handOff(true)) // refused for this row
        assertEquals(1, env.calls.size)
        h.rowChanged("u2")
        env.uid = "u2"
        assertTrue(h.handOff(true))
    }

    @Test fun aRowThatMovedOnWhileTheDspOpenedIsReleasedWithoutTouchingAppleMusic() = runTest {
        val env = object {
            val e = FakeEnv()
        }.e
        val h = AppleMusicHandOff(object : AppleMusicHandOffEnv by env {
            override suspend fun engagePaused(atSeconds: Double): Boolean { env.generation++; return true }
        })
        assertFalse(h.handOff(true))
        assertEquals(listOf("disengage"), env.calls)
        assertTrue(env.meter.isEmpty())
    }

    @Test fun anUnreadablePositionRefusesAndLeavesAppleMusicPlaying_neverRestartsAtZero() = runTest {
        val env = FakeEnv().also { it.position = null }
        val h = AppleMusicHandOff(env)
        assertFalse(h.handOff(true))
        assertTrue(env.calls.isEmpty())
        assertTrue(env.meter.isEmpty())
        assertEquals(0, h.handOffCount)
    }

    @Test fun aFailedAppleMusicStopRollsTheDspBackAndAbandonsTheMeter() = runTest {
        val env = FakeEnv()
        val h = AppleMusicHandOff(object : AppleMusicHandOffEnv by env {
            override suspend fun stopAppleMusic() { env.calls += "stopAm"; throw IllegalStateException("boom") }
            override fun meterAbandoned(reason: String) { env.meter += "abandoned" }
        })
        assertFalse(h.handOff(true))
        assertEquals(listOf("engagePaused(60.0)", "stopAm", "disengage"), env.calls)
        assertEquals("abandoned", env.meter.last())
        assertEquals(0, h.handOffCount)
        assertFalse(h.handOff(true)) // refused for this row; no second attempt
        assertEquals(3, env.calls.size)
    }

    @Test fun theDspOnlySoundsWhenAppleMusicWasSounding() = runTest {
        val env = FakeEnv().also { it.facts = facts { copy(positionMs = null, appleMusicPlaying = false) } }
        val h = AppleMusicHandOff(env)
        assertTrue(h.handOff(true)) // listener wishes play, Apple Music was paused
        assertEquals(listOf("engagePaused(60.0)", "stopAm"), env.calls)
        assertTrue(env.meter.isEmpty())
    }

    @Test fun noAppleMusicRowNoHandOff() = runTest {
        val env = FakeEnv().also { it.facts = null }
        assertFalse(AppleMusicHandOff(env).handOff(true))
        assertTrue(env.calls.isEmpty())
    }

    @Test fun readyReflectsTheVerdictAndTheBufferingGate() = runTest {
        val env = FakeEnv()
        val h = AppleMusicHandOff(env)
        assertFalse(h.ready())
        h.refresh()
        assertTrue(h.ready())
        env.buffering = false
        assertFalse(h.ready())
        env.buffering = true
        env.facts = facts { copy(localCopyComplete = false) }
        h.refresh()
        assertFalse(h.ready())
        assertTrue(env.readyChanges >= 2)
    }

    @Test fun afterAHandOffTheRowIsNoLongerReady_andASecondTouchCannotRepeatIt() = runTest {
        val env = FakeEnv()
        val h = AppleMusicHandOff(env)
        h.refresh(); assertTrue(h.ready())
        h.handOff(true)
        assertFalse(h.ready())
        env.facts = facts { copy(appleMusicActive = false, dspEngaged = true) }
        assertFalse(h.handOff(true))
        assertEquals(1, h.handOffCount)
    }
}

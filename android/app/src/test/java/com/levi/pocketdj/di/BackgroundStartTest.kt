package com.levi.pocketdj.di

import com.levi.pocketdj.playback.session.FakePlayerState
import com.levi.pocketdj.playback.session.SessionSwitchboard
import com.levi.pocketdj.playback.session.TransportOwner
import com.levi.pocketdj.playback.session.fakePlayer
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

class BackgroundStartTest {
    @Test fun workerPlanIsCoreOnlyAndOwnsNoLoop() {
        val plan = StartupPlan.steps(StartTier.CORE)
        assertTrue(plan.isNotEmpty())
        assertTrue(plan.all { it.tier == StartTier.CORE })
        assertTrue(StartupPlan.loopSteps(StartTier.CORE).isEmpty())
        for (loop in listOf(StartStep.PLAYBACK_WIRE, StartStep.NP_DSP, StartStep.WIDGETS, StartStep.RECS, StartStep.PLAY_STATS, StartStep.INTENT_SINK)) {
            assertFalse("$loop must not start from a worker", loop in plan)
        }
    }

    @Test fun playbackPlanAddsLoopsAndRecsButNotIntentSink() {
        val plan = StartupPlan.steps(StartTier.PLAYBACK)
        assertTrue(plan.containsAll(StartupPlan.steps(StartTier.CORE)))
        assertTrue(StartStep.PLAYBACK_WIRE in plan && StartStep.NP_DSP in plan && StartStep.WIDGETS in plan)
        assertTrue(StartStep.RECS in plan) // car-only sessions must still seed the rec gate + flush
        assertFalse(StartStep.INTENT_SINK in plan)
    }

    /** CORE branches of runStartStep must not touch the lazy feature registry or any loop-owning graph. */
    @Test fun coreStepActionsNeverReachFeaturesOrLoopGraphs() {
        val f = listOf("src/main/java", "app/src/main/java").map { java.io.File(it, "com/levi/pocketdj/di/AppGraph.kt") }.first { it.exists() }
        val body = f.readText().substringAfter("private fun runStartStep").substringBefore("init { startup.ensure")
        val core = StartupPlan.steps(StartTier.CORE).map { it.name }
        val branches = Regex("""StartStep\.([A-Z_]+) ->""").findAll(body).toList()
        assertTrue(branches.isNotEmpty())
        val forbidden = listOf("features", "playbackGraph", "mixGraph", "gamesGraph", "studioGraph", "browseGraph", "shellGraph")
        branches.forEachIndexed { i, m ->
            if (m.groupValues[1] !in core) return@forEachIndexed
            val end = branches.getOrNull(i + 1)?.range?.first ?: body.length
            val text = body.substring(m.range.last, end)
            for (w in forbidden) assertFalse("CORE step ${m.groupValues[1]} references $w", Regex("""\b$w\b""").containsMatchIn(text))
        }
    }


    @Test fun foregroundPlanIncludesEverythingInDependencyOrder() {
        val plan = StartupPlan.steps(StartTier.INTERACTIVE)
        assertEquals(StartStep.entries.toList(), plan)
        // the studio rung needs the sequencer wired first
        assertTrue(plan.indexOf(StartStep.PLAYBACK_WIRE) < plan.indexOf(StartStep.STUDIO_WIRE))
    }

    @Test fun ledgerRunsEachStepOnceAcrossTiers() {
        val ran = mutableListOf<StartStep>()
        val ledger = StartupLedger { ran += it }
        ledger.ensure(StartTier.CORE)
        assertEquals(StartupPlan.steps(StartTier.CORE), ran)
        assertFalse(ledger.hasRun(StartStep.RECS))
        assertFalse(ledger.hasRun(StartStep.INTENT_SINK))
        ledger.ensure(StartTier.INTERACTIVE)
        ledger.ensure(StartTier.PLAYBACK)
        ledger.ensure(StartTier.INTERACTIVE)
        assertEquals(StartStep.entries.toList(), ran) // no duplicates
    }

    @Test fun failingStepIsReportedAndDoesNotBlockTheRest() {
        val ran = mutableListOf<StartStep>()
        val errors = mutableListOf<StartStep>()
        val ledger = StartupLedger(onError = { s, _ -> errors += s }) { s ->
            if (s == StartStep.NP_DSP) error("boom")
            ran += s
        }
        ledger.ensure(StartTier.INTERACTIVE)
        assertEquals(listOf(StartStep.NP_DSP), errors)
        assertTrue(StartStep.RECS in ran && StartStep.WIDGETS in ran)
        ledger.ensure(StartTier.INTERACTIVE)
        assertEquals(listOf(StartStep.NP_DSP), errors) // not retried
    }

    @Test fun heartbeatGateOnlyBeatsWhenSomethingNeedsIt() {
        assertFalse(NpHeartbeatGate.shouldBeat(engaged = false, runExists = false, mixRunning = false))
        assertTrue(NpHeartbeatGate.shouldBeat(engaged = true, runExists = false, mixRunning = false))
        assertTrue(NpHeartbeatGate.shouldBeat(engaged = false, runExists = true, mixRunning = false))
        assertTrue(NpHeartbeatGate.shouldBeat(engaged = false, runExists = false, mixRunning = true))
    }

    private fun owner(name: String) = object : TransportOwner {
        override val engine = name
        override val hasSounded = true
        override val sessionPlayer = fakePlayer(FakePlayerState())
        override fun pauseForHandoff() {}
    }

    @Test fun switchboardListenerSeesOwnershipChangesAndSurvivesOnChangeReplacement() {
        val board = SessionSwitchboard()
        val seen = mutableListOf<String?>()
        val remove = board.addListener { seen += board.current?.engine }
        board.onChange = {} // the service replacing/clearing its hook must not drop the widget listener
        val exo = owner("exo"); val mix = owner("mix")
        board.register(exo)
        board.setOwner(mix)
        board.resign(mix)
        assertEquals(listOf<String?>("mix", null), seen)
        remove()
        board.setOwner(exo)
        assertEquals(2, seen.size)
    }
}

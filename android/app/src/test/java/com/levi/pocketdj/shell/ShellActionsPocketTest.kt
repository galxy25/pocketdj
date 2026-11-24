package com.levi.pocketdj.shell

import com.levi.pocketdj.data.catalog.MergedCatalog
import com.levi.pocketdj.data.collections.CollectionsStore
import com.levi.pocketdj.data.pockets.wheel.PocketMode
import com.levi.pocketdj.data.pockets.wheel.PocketMoment
import com.levi.pocketdj.data.pockets.wheel.PocketMomentKey
import com.levi.pocketdj.data.pockets.wheel.PocketWheelController
import com.levi.pocketdj.data.pockets.wheel.PocketWheelSnapshot
import com.levi.pocketdj.playback.QueueOutcome
import kotlinx.coroutines.ExperimentalCoroutinesApi
import kotlinx.coroutines.test.runTest
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNotNull
import org.junit.Assert.assertTrue
import org.junit.Assert.fail
import org.junit.Rule
import org.junit.Test
import org.junit.rules.TemporaryFolder

@OptIn(ExperimentalCoroutinesApi::class)
class ShellActionsPocketTest {
    @get:Rule val tmp = TemporaryFolder()

    /** Tuesday 2026-10-06 08:30 UTC. */
    private val tuesday0830 = 1_791_275_400_000.0
    private val tue8car = PocketMomentKey(8, 2, PocketMode.CAR_PLAY)

    private val snap = PocketWheelSnapshot(
        moments = listOf(
            PocketMoment(key = tue8car, plays = 10.0, distinctDays = 5, directPlays = 10, collections = mapOf("pl1" to 1.0), dominantCollectionId = "pl1"),
            PocketMoment(key = PocketMomentKey(8, 2, PocketMode.RUNNING), plays = 10.0, distinctDays = 5, directPlays = 10, collections = mapOf("pl2" to 1.0), dominantCollectionId = "pl2"),
        ),
        collectionNames = mapOf("pl1" to "Potential", "pl2" to "Run mix"),
        totalDirectPlays = 20,
    )

    private class Ready : ReadinessPort {
        var loads = 0
        override fun kickManifestRefresh() {}
        override fun loadCatalog() { loads++ }
        override suspend fun awaitCatalogSeeded() {}
    }

    private class Rig(val ready: Ready, val wheel: PocketWheelController) {
        var incomplete = false
        lateinit var actions: ShellActions
        val played = mutableListOf<String>()
        var playResult = true
    }

    private fun rig(): Rig {
        val store = CollectionsStore(file = java.io.File(tmp.root, CollectionsStore.FILE_NAME))
        store.catalogProvider = { MergedCatalog.merge(emptyList()) }
        val wheel = PocketWheelController({ snap }, { emptyList() }).also {
            it.clockMs = { tuesday0830 }
            it.tzOffsetMin = { 0 }
        }
        val r = Rig(Ready(), wheel)
        wheel.play = { p -> r.played += (p.key?.token ?: "blend") + "/" + p.mode?.token; r.playResult }
        r.actions = ShellActions(
            collections = store,
            catalog = object : ShellCatalog {
                override fun song(id: String) = null
                override fun album(id: String) = null
            },
            player = ShellPlayer { _, _ -> QueueOutcome.Started(1, 0, 1) },
            setup = SetupGate { r.incomplete },
            readiness = r.ready,
            postRoute = {},
        )
        r.actions.pocketWheel = { wheel }
        return r
    }

    @Test fun playPocketForNow_goesThroughReadiness_thenPlaysTheBestMatch_andSpeaksTheCaption() = runTest {
        val r = rig()
        val spoken = r.actions.playPocketForNow(car = true)
        assertEquals(1, r.ready.loads)
        assertEquals(listOf("h08|d2|carPlay/carPlay"), r.played)
        assertEquals("Potential, Tue 8 AM · CarPlay", spoken)
        assertEquals("Playing your pocket: Potential, Tue 8 AM · CarPlay.", pocketPlayingLine(spoken))
    }

    @Test fun carFlagForcesCarPlayMode_whileThePhoneDoorDoesNot() = runTest {
        val r = rig()
        r.actions.playPocketForNow(car = true)
        assertEquals(PocketMode.CAR_PLAY, r.wheel.carResult.value!!.profile.key!!.mode)
        assertEquals("a car refresh never touches the phone's shared result", null, r.wheel.lastNow)
        r.actions.playPocketForNow()
        assertFalse("no projection, no motion => mode unknown", r.wheel.lastNow!!.mode == PocketMode.CAR_PLAY)
    }

    @Test fun voiceAndDeepLinkDoor_plansInCarMode_whileAnAutoSessionIsConnected() = runTest {
        val tracker = com.levi.pocketdj.auto.AutoSessionTracker
        tracker.reset()
        val auto = Any()
        tracker.connected(auto)
        try {
            val r = rig()
            r.actions.playPocketForNow()
            assertEquals(listOf("h08|d2|carPlay/carPlay"), r.played)
        } finally {
            tracker.disconnected(auto)
        }
        assertFalse(tracker.isActive)
    }

    @Test fun onboardingVetoBlocksBeforeTouchingTheWheel() = runTest {
        val r = rig()
        r.incomplete = true
        try { r.actions.playPocketForNow(); fail() } catch (e: ShellActionException) {
            assertEquals(ShellActionException.SetupIncomplete, e)
        }
        try { r.actions.playPocketMoment(tue8car); fail() } catch (e: ShellActionException) {
            assertEquals(ShellActionException.SetupIncomplete, e)
        }
        assertTrue(r.played.isEmpty())
        assertEquals(0, r.ready.loads)
        assertTrue("the wheel never computed", r.wheel.result.value == null)
    }

    @Test fun aRunThatCannotStartIsTheSpeakableNotEnoughSongsError() = runTest {
        val r = rig()
        r.playResult = false
        try { r.actions.playPocketForNow(); fail() } catch (e: ShellActionException) {
            assertEquals(ShellActionException.NoPocketFits, e)
            assertTrue(e.message!!.startsWith("Not enough playable songs fit your pocket right now"))
        }
        try { r.actions.playPocketMoment(tue8car); fail() } catch (e: ShellActionException) {
            assertEquals(ShellActionException.NoPocketFits, e)
        }
    }

    @Test fun playPocketMoment_playsThatCell_andUnknownCellsDoNotFit() = runTest {
        val r = rig()
        r.actions.playPocketMoment(tue8car)
        assertEquals(listOf("h08|d2|carPlay/carPlay"), r.played)
        try { r.actions.playPocketMoment(PocketMomentKey(3, 3, PocketMode.TRIP)); fail() } catch (e: ShellActionException) {
            assertEquals(ShellActionException.NoPocketFits, e)
        }
    }

    @Test fun noWheelWired_isAnHonestError() = runTest {
        val r = rig()
        r.actions.pocketWheel = null
        try { r.actions.playPocketForNow(); fail() } catch (e: ShellActionException) {
            assertEquals("your pocket has no playable songs yet.", e.message)
        }
    }

    @Test fun linkSeam_postsTheSnackbar_orTheFailureLine() = runTest {
        val r = rig()
        val msgs = mutableListOf<String>()
        var job: kotlinx.coroutines.Job? = null
        pocketNowLinkSeam(r.actions, backgroundScope, { msgs += it }, { job = it })()
        job!!.join()
        assertEquals(listOf("Playing your pocket: Potential, Tue 8 AM · CarPlay."), msgs)
        r.playResult = false
        pocketNowLinkSeam(r.actions, backgroundScope, { msgs += it }, { job = it })()
        job!!.join()
        assertTrue(msgs.last().startsWith("Not enough playable songs"))
        assertNotNull(job)
    }

    @Test fun dispatcher_routesPocketNowThroughItsSeam_andSaysSoWhenUnwired() = runTest {
        val msgs = mutableListOf<String>()
        val gate = object : OnboardingGate {
            override val isComplete = true
            override suspend fun waitUntilComplete() {}
        }
        val seams = DeepLinkSeams()
        val d = DeepLinkDispatcher(backgroundScope, gate, seams, postRoute = {}, postMessage = { msgs += it })
        assertTrue(d.handle(DeepLinkParser.parse("pocketdj://pocket/now")))
        assertEquals(listOf("Pocket for now isn't available yet"), msgs)
        var fired = 0
        seams.pocketNow = { fired++ }
        d.handle(DeepLinkParser.parse("pocketdj://pocket/now"))
        assertEquals(1, fired)
        assertEquals(1, msgs.size)
    }
}

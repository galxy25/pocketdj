package com.levi.pocketdj.data.pockets

import kotlinx.coroutines.delay
import kotlinx.coroutines.runBlocking
import org.junit.After
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Before
import org.junit.Rule
import org.junit.Test
import org.junit.rules.TemporaryFolder

class LivePocketsBridgeTest {
    @get:Rule val tmp = TemporaryFolder()
    private lateinit var fx: PocketsFixture

    @Before fun setUp() { fx = PocketsFixture(tmp.root) }
    @After fun tearDown() { fx.close() }

    private fun bridge(svc: ListeningPocketsService, uploader: (suspend (PocketsCredentials, List<com.levi.pocketdj.data.games.inthepocket.InThePocketRoundWire>, String) -> Boolean)? = null) =
        LivePocketsBridge(svc, credentialsSource = { fx.creds }, installIdSource = { fx.history.installId }, roundsUploader = uploader)

    @Test fun inertUntilGateAndCredentialsOpen() = runBlocking {
        fx.pocketsOn = false
        val svc = fx.service()
        val b = bridge(svc)
        assertFalse(b.isEnabled.value)
        assertNull(b.credentials())            // gate closed => games can never build a cloud request
        b.refreshIfStale(); b.flushSoon()
        delay(100)
        assertTrue(fx.backend.requests.isEmpty())
        // Opt-in flips the state flow.
        fx.pocketsOn = true
        svc.enabledDidChange()
        assertTrue(b.isEnabled.value)
        assertEquals("prof-A", b.credentials()!!.profileId)
        // Credentials seam null => still no network.
        fx.creds = null
        assertNull(b.credentials())
        b.refreshIfStale()
        assertTrue(fx.backend.requests.isEmpty())
        svc.enabledDidChange()
    }

    @Test fun exposesResultsInstallIdAndFlushesRoundsAfterPlays() = runBlocking {
        fx.plays(1)
        val svc = fx.service()
        svc.enabledDidChange()
        val uploaded = mutableListOf<Pair<List<String>, Int>>()
        val b = bridge(svc) { _, wires, _ -> uploaded += wires.map { it.id } to fx.backend.eventCount(); true }
        assertTrue(b.flushesRounds)
        assertEquals(fx.history.installId, b.installId)
        b.roundsProvider = { listOf(testRoundWire("r1"), testRoundWire("r2")) }
        assertTrue(svc.flushNow())
        assertEquals(listOf(listOf("r1", "r2") to 1), uploaded)   // after the plays batch
        b.refreshIfStale()
        assertEquals(svc.results.value, b.results.value)
    }

    @Test fun noRoundsUploaderMeansGamesOwnsTheTimer() {
        val b = bridge(fx.service())
        assertFalse(b.flushesRounds)
    }

    @Test fun noRoundsProviderSkipsRounds() = runBlocking {
        fx.plays(1)
        val svc = fx.service()
        var called = false
        val b = bridge(svc) { _, _, _ -> called = true; true }
        assertTrue(svc.flushNow())
        assertFalse(called)
        assertNull(b.roundsProvider)
    }
}

package com.levi.pocketdj.data.pockets

import kotlinx.coroutines.delay
import kotlinx.coroutines.runBlocking
import org.junit.After
import org.junit.Assert.assertEquals
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Before
import org.junit.Rule
import org.junit.Test
import org.junit.rules.TemporaryFolder

class PocketsPlayListenerTest {
    @get:Rule val tmp = TemporaryFolder()
    private lateinit var fx: PocketsFixture

    @Before fun setUp() { fx = PocketsFixture(tmp.root) }
    @After fun tearDown() { fx.close() }

    @Test fun stampsCarPlayOnNewPlays() {
        var car: Boolean? = true
        PocketsPlayListener(fx.service(), { car }).attach(fx.history)
        val a = fx.history.record("a", nowMs = 1_750_000_000_000L)!!
        assertEquals(true, a.carPlay)
        car = false
        assertEquals(false, fx.history.record("b", nowMs = 1_750_000_100_000L)!!.carPlay)
        car = null   // unknown stays null (iOS: nil elsewhere)
        assertNull(fx.history.record("c", nowMs = 1_750_000_200_000L)!!.carPlay)
    }

    @Test fun throwingProbeNeverBreaksRecording() {
        PocketsPlayListener(fx.service(), { error("no uimode") }).attach(fx.history)
        val e = fx.history.record("a", nowMs = 1_750_000_000_000L)
        assertNull(e!!.carPlay)
    }

    @Test fun backgroundFlushIsGatedAndDebounced() = runBlocking {
        fx.plays(2)
        val svc = fx.service(); svc.debounceMs = 30
        val l = PocketsPlayListener(svc, { null })
        fx.pocketsOn = false
        l.onBackgrounded(); delay(150)
        assertTrue(fx.backend.requests.isEmpty())
        fx.pocketsOn = true
        l.onBackgrounded(); l.onBackgrounded()
        val deadline = System.currentTimeMillis() + 3000
        while (fx.backend.eventCount() == 0 && System.currentTimeMillis() < deadline) delay(20)
        assertEquals(1, fx.backend.eventCount())
    }
}

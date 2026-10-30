package com.levi.pocketdj.di

import com.levi.pocketdj.screens.games.PocketsOptIn
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNull
import org.junit.Assert.assertSame
import org.junit.Assert.assertTrue
import org.junit.Test
import com.levi.pocketdj.data.pockets.NoPocketsBridge

class GamesGraphBridgeTest {
    private class RecordingOptIn : PocketsOptIn {
        val choices = mutableListOf<Boolean>()
        override val recommendationsEnabled: StateFlow<Boolean> = MutableStateFlow(true)
        override fun choose(on: Boolean) { choices += on }
    }

    @Test fun loadingThenLive() {
        val h = PocketsServiceHolder()
        assertNull("no stub: unset bridge means loading", h.bridge.value)
        h.bridge.value = NoPocketsBridge
        assertSame(NoPocketsBridge, h.bridge.value)
    }

    @Test fun optInBeforeWiringIsOffAndChoiceIsReplayed() {
        val h = PocketsServiceHolder()
        assertFalse(h.optIn.recommendationsEnabled.value)
        h.optIn.choose(true)
        val real = RecordingOptIn()
        h.setOptIn(real)
        assertEquals(listOf(true), real.choices)
        assertTrue(h.optIn.recommendationsEnabled.value)
    }

    @Test fun choiceAfterWiringForwardsOnceAndNothingStale() {
        val h = PocketsServiceHolder()
        val real = RecordingOptIn()
        h.setOptIn(real)
        h.optIn.choose(false)
        assertEquals(listOf(false), real.choices)
        h.setOptIn(RecordingOptIn())
        assertEquals(listOf(false), real.choices)
    }

    @Test fun recommendationsEnabledObservesLateWiredTarget() {
        val h = PocketsServiceHolder()
        val flow = h.optIn.recommendationsEnabled // captured BEFORE wiring, as a screen does
        assertFalse(flow.value)
        val real = RecordingOptIn()
        h.setOptIn(real)
        assertTrue("captured flow must follow the target wired later", flow.value)
        (real.recommendationsEnabled as MutableStateFlow).value = false
        assertFalse(flow.value)
        h.setOptIn(null)
        assertFalse(flow.value)
    }

    @Test fun parsePocketsEnableAcceptsBooleanAndStrings() {
        assertTrue(GamesGraph.parsePocketsEnable(true))
        assertTrue(GamesGraph.parsePocketsEnable("true"))
        assertTrue(GamesGraph.parsePocketsEnable("1"))
        assertFalse(GamesGraph.parsePocketsEnable("0"))
        assertFalse(GamesGraph.parsePocketsEnable(null))
        assertFalse(GamesGraph.parsePocketsEnable(false))
    }

    @Test fun unwiredBridgeIsInertAssignedBridgeIsObservable() {
        val h = PocketsServiceHolder()
        assertNull(h.bridge.value)
        assertFalse(NoPocketsBridge.isEnabled.value)
        h.bridge.value = NoPocketsBridge
        assertSame(NoPocketsBridge, h.bridge.value)
    }

    @Test fun loadingTimeoutIsBounded() {
        assertTrue(com.levi.pocketdj.screens.games.InThePocketScreenLogic.LOADING_TIMEOUT_MS in 1_000L..30_000L)
    }
}

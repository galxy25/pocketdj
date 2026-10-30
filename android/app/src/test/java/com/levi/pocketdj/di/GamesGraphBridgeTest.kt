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
}

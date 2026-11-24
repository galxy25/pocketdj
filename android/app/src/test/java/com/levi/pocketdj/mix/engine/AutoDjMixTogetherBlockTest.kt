package com.levi.pocketdj.mix.engine

import com.levi.pocketdj.mix.model.Deck
import com.levi.pocketdj.remote.MixTogetherBlock
import org.junit.After
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Before
import org.junit.Test

/** P2-REM-6 review: Mix Together blocks Auto-DJ, ends a running mix WITHOUT cutting the decks, and the UI says why. */
class AutoDjMixTogetherBlockTest {
    @Before @After fun reset() { MixTogetherBlock.set(null); MixTogetherBlock.onChanged = null }

    @Test fun blockedStartAndEnableAreRefusedAndTheReasonIsInTheUiState() {
        val r = AutoRig()
        MixTogetherBlock.set(MixTogetherBlock.REASON)
        r.dj.onAutoBlocked()
        assertEquals(MixTogetherBlock.REASON, r.dj.ui.value.blockedReason)
        r.dj.setAutoEnabled(true)
        assertFalse(r.dj.enabled)
        r.start()
        assertFalse(r.dj.isMixing)
        MixTogetherBlock.set(null)
        r.dj.onAutoBlocked()
        assertNull("the reason clears when the session ends", r.dj.ui.value.blockedReason)
        r.dj.setAutoEnabled(true)
        assertTrue(r.dj.enabled)
    }

    @Test fun blockingARunningMixEndsAutoButTheDecksKeepPlaying() {
        val r = AutoRig()
        r.start()
        assertTrue(r.dj.isMixing)
        assertTrue(r.e.isPlaying(Deck.A))
        MixTogetherBlock.set(MixTogetherBlock.REASON)
        r.dj.onAutoBlocked()
        assertFalse(r.dj.isMixing)
        assertFalse(r.dj.enabled)
        assertTrue("the live deck keeps sounding: the session owns it now", r.e.isPlaying(Deck.A))
    }
}

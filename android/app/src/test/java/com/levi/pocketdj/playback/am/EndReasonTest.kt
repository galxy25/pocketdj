package com.levi.pocketdj.playback.am

import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test

/** The iOS `endReason` / `trackRestarted` / `neverStarted` / `stoppedByInterruption` cases, 1:1. */
class EndReasonTest {
    private fun reason(
        stopped: Boolean = false,
        paused: Boolean = false,
        t: Double,
        expected: Double = 200.0,
        max: Double = 0.0,
        intentional: Boolean = false,
    ) = EndVerdicts.endReason(stopped, paused, t, expected, max, intentional)

    @Test fun stopped_isNatural() = assertEquals(EndReason.NATURAL, reason(stopped = true, t = 0.0))

    @Test fun pausedAtEnd_isNatural() = assertEquals(EndReason.NATURAL, reason(paused = true, t = 199.6, max = 199.6))

    @Test fun pausedAtTopAfterProgress_isSystemSkip() =
        assertEquals(EndReason.SYSTEM_SKIP, reason(paused = true, t = 0.2, max = 2.0))

    @Test fun pausedAtTop_withProgress_evenIfIntentional_isSystemSkip() =
        // pause at 0:30 -> car next -> park at 0 with maxObserved 30
        assertEquals(EndReason.SYSTEM_SKIP, reason(paused = true, t = 0.0, max = 30.0, intentional = true))

    @Test fun pausedAtTop_intentionalNoProgress_isNull() =
        assertNull(reason(paused = true, t = 0.5, max = 1.0, intentional = true))

    @Test fun pausedAtTop_noProgress_notIntentional_isSystemSkip() =
        assertEquals(EndReason.SYSTEM_SKIP, reason(paused = true, t = 0.0, max = 0.0))

    @Test fun midSongPause_isNull() = assertNull(reason(paused = true, t = 90.0, max = 90.0))

    @Test fun playingMidSong_isNull() = assertNull(reason(t = 90.0, max = 90.0))

    @Test fun playingPastDuration_isNatural() = assertEquals(EndReason.NATURAL, reason(t = 199.7, max = 199.7))

    @Test fun unknownDuration_pausedNearEnd_isNotNatural() = assertNull(reason(paused = true, t = 50.0, expected = 0.0, max = 50.0))

    @Test fun trackEnded_isEndReasonNotNull() {
        assertTrue(EndVerdicts.trackEnded(true, false, 0.0, 100.0, 0.0, false))
        assertFalse(EndVerdicts.trackEnded(false, true, 50.0, 100.0, 50.0, false))
    }

    @Test fun trackRestarted_needsBigBackwardJump() {
        assertTrue(EndVerdicts.trackRestarted(playbackTime = 1.0, maxObserved = 10.5))
        assertFalse(EndVerdicts.trackRestarted(playbackTime = 1.0, maxObserved = 10.0)) // not > 10
        assertFalse(EndVerdicts.trackRestarted(playbackTime = 2.0, maxObserved = 60.0)) // not < 2
        assertFalse(EndVerdicts.trackRestarted(playbackTime = 0.5, maxObserved = 4.0)) // early: undetectable
    }

    @Test fun neverStarted_after12s_unlessPausedOrPlayed() {
        assertTrue(EndVerdicts.neverStarted(everPlayed = false, waitedSeconds = 12.0, intentionalPause = false))
        assertFalse(EndVerdicts.neverStarted(everPlayed = false, waitedSeconds = 11.9, intentionalPause = false))
        assertFalse(EndVerdicts.neverStarted(everPlayed = false, waitedSeconds = 60.0, intentionalPause = true))
        assertFalse(EndVerdicts.neverStarted(everPlayed = true, waitedSeconds = 60.0, intentionalPause = false))
    }

    @Test fun stoppedByInterruption_when10sOrMoreShort() {
        assertTrue(EndVerdicts.stoppedByInterruption(stopped = true, expectedDuration = 200.0, playedSeconds = 189.9))
        assertFalse(EndVerdicts.stoppedByInterruption(stopped = true, expectedDuration = 200.0, playedSeconds = 190.0))
        assertFalse(EndVerdicts.stoppedByInterruption(stopped = false, expectedDuration = 200.0, playedSeconds = 5.0))
        assertFalse(EndVerdicts.stoppedByInterruption(stopped = true, expectedDuration = 0.0, playedSeconds = 5.0)) // unknown length
    }
}

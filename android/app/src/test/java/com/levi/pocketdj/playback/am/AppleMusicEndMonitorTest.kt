package com.levi.pocketdj.playback.am

import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test

/** The monitor's tick state machine with a fake clock: the iOS verdict table end to end. */
class AppleMusicEndMonitorTest {
    private var now = 1_000_000L
    private val m = AppleMusicEndMonitor { now }

    private fun tick(status: AmStatus, posSec: Double, advanceMs: Long = 400): AmEvent? {
        now += advanceMs
        return m.tick(AmObservation(status, (posSec * 1000).toLong()))
    }

    private fun startPlaying(expectedMs: Long? = 200_000) {
        m.arm(expectedMs)
        assertEquals(AmEvent.FirstAudio, tick(AmStatus.PLAYING, 0.1))
    }

    @Test fun firstPlaying_isFirstAudio_once() {
        m.arm(200_000)
        assertNull(tick(AmStatus.BUFFERING, 0.0))
        assertEquals(AmEvent.FirstAudio, tick(AmStatus.PLAYING, 0.2))
        assertNull(tick(AmStatus.PLAYING, 0.6))
    }

    @Test fun neverStarted_after12s() {
        m.arm(200_000)
        assertNull(tick(AmStatus.BUFFERING, 0.0, advanceMs = 11_000))
        assertEquals(AmEvent.Ended(EndReason.NEVER_STARTED), tick(AmStatus.BUFFERING, 0.0, advanceMs = 1_000))
        assertTrue(m.isFinished)
    }

    @Test fun neverStarted_suppressedByIntentionalPause() {
        m.arm(200_000)
        m.noteIntentionalPause(true)
        assertNull(tick(AmStatus.PAUSED, 0.0, advanceMs = 30_000))
        assertFalse(m.isFinished)
    }

    @Test fun naturalEnd_viaStoppedNearEnd() {
        startPlaying()
        for (s in 1..199) tick(AmStatus.PLAYING, s.toDouble(), advanceMs = 1000)
        assertEquals(AmEvent.Ended(EndReason.NATURAL), tick(AmStatus.STOPPED, 0.0, advanceMs = 1000))
    }

    @Test fun naturalEnd_viaSdkItemEnded_once() {
        startPlaying()
        assertEquals(AmEvent.Ended(EndReason.NATURAL), m.onSdkItemEnded())
        assertNull(m.onSdkItemEnded())
        assertNull(tick(AmStatus.STOPPED, 0.0)) // finished: nothing more
    }

    @Test fun sdkItemEnded_beforeAnyAudio_isIgnored() {
        m.arm(200_000)
        assertNull(m.onSdkItemEnded())
        assertFalse(m.isFinished)
    }

    @Test fun systemSkip_parkedPausedAtTop_afterProgress() {
        startPlaying()
        for (s in 1..30) tick(AmStatus.PLAYING, s.toDouble(), advanceMs = 1000)
        assertEquals(AmEvent.Ended(EndReason.SYSTEM_SKIP), tick(AmStatus.PAUSED, 0.0))
    }

    @Test fun listenerPause_midSong_isNotAnEnd() {
        startPlaying()
        for (s in 1..30) tick(AmStatus.PLAYING, s.toDouble(), advanceMs = 1000)
        m.noteIntentionalPause(true)
        assertNull(tick(AmStatus.PAUSED, 30.0))
        assertNull(tick(AmStatus.PAUSED, 30.0))
        assertFalse(m.isFinished)
    }

    @Test fun skipThenPause_nearTop_doesNotReadAsAnotherSkip() {
        startPlaying()
        // Only ~1 s of progress, then OUR pause at 0.8 s.
        tick(AmStatus.PLAYING, 0.8)
        m.noteIntentionalPause(true)
        assertNull(tick(AmStatus.PAUSED, 0.8))
    }

    @Test fun restart_whenPositionJumpsToTopWhilePlaying() {
        startPlaying()
        for (s in 1..40) tick(AmStatus.PLAYING, s.toDouble(), advanceMs = 1000)
        assertEquals(AmEvent.Restarted, tick(AmStatus.PLAYING, 0.3))
        // Re-based: continuing from the top is normal playback, not another restart.
        assertNull(tick(AmStatus.PLAYING, 0.7))
        assertFalse(m.isFinished)
    }

    @Test fun seekBack_afterNoteSeek_isNotARestart() {
        startPlaying()
        for (s in 1..40) tick(AmStatus.PLAYING, s.toDouble(), advanceMs = 1000)
        m.noteSeek(0)
        assertNull(tick(AmStatus.PLAYING, 0.2))
    }

    @Test fun interruption_stoppedFarShort_holds_thenResumes() {
        startPlaying()
        for (s in 1..60) tick(AmStatus.PLAYING, s.toDouble(), advanceMs = 1000)
        val ev = tick(AmStatus.STOPPED, 0.0)
        assertTrue(ev is AmEvent.Interrupted)
        assertEquals(60.0, (ev as AmEvent.Interrupted).atSeconds, 1.0)
        assertTrue(m.isInterrupted)
        assertFalse(m.isFinished)
        assertNull(tick(AmStatus.STOPPED, 0.0, advanceMs = 5000)) // stays held, never ends
        assertEquals(AmEvent.Resumed, tick(AmStatus.PLAYING, 0.0))
        assertFalse(m.isInterrupted)
        // After resume at the interruption point the pre-seek 0:00 read is not a restart.
        assertNull(tick(AmStatus.PLAYING, 61.0))
    }

    @Test fun unknownLength_stopped_isNaturalEnd_notInterruption() {
        startPlaying(expectedMs = null)
        for (s in 1..5) tick(AmStatus.PLAYING, s.toDouble(), advanceMs = 1000)
        assertEquals(AmEvent.Ended(EndReason.NATURAL), tick(AmStatus.STOPPED, 0.0))
    }

    @Test fun disarm_silencesTicks() {
        startPlaying()
        m.disarm()
        assertNull(tick(AmStatus.STOPPED, 0.0))
    }

    @Test fun arm_resetsIntentionalPause() {
        m.arm(1000)
        m.noteIntentionalPause(true)
        m.arm(1000)
        assertFalse(m.intentionalPause)
    }

    @Test fun ourOwnBackwardScrub_afterNoteSeek_isNotARestart() {
        startPlaying()
        for (i in 1..40) tick(AmStatus.PLAYING, 0.1 + i) // > 10 s of progress
        m.noteSeek(500) // the in-app scrubber dragged back to 0:00.5
        assertNull(tick(AmStatus.PLAYING, 0.9))
    }

    @Test fun backwardJumpWithoutNoteSeek_isARestart() {
        startPlaying()
        for (i in 1..40) tick(AmStatus.PLAYING, 0.1 + i)
        assertEquals(AmEvent.Restarted, tick(AmStatus.PLAYING, 0.9))
    }
}

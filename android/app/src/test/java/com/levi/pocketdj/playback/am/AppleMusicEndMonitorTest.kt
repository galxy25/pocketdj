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

/** ANS-PB-3: iOS reconcilePoll self-heal + onNearEnd verdicts. */
class AppleMusicReconcileTest {
    private var now = 2_000_000L
    private val m = AppleMusicEndMonitor { now }
    private fun tick(status: AmStatus, posSec: Double, advanceMs: Long = 400): AmEvent? {
        now += advanceMs
        return m.tick(AmObservation(status, (posSec * 1000).toLong()))
    }

    @Test fun reconcile_pureTable() {
        // reported paused but position advanced 0.4 s => heal to playing
        val heal = PollReconcile.reconcile(false, false, 10.4, 10.0)
        assertEquals(PollReconcile.Verdict(true, PollReconcile.Transition.SELF_HEALED), heal)
        // genuinely resumed
        assertEquals(PollReconcile.Transition.RESUMED, PollReconcile.reconcile(true, false, 10.4, 10.0).transition)
        // genuinely paused, position frozen
        assertEquals(PollReconcile.Verdict(false, PollReconcile.Transition.PAUSED), PollReconcile.reconcile(false, true, 10.0, 10.0))
        // steady state => no transition
        assertNull(PollReconcile.reconcile(true, true, 11.0, 10.6).transition)
        // jitter below epsilon is not advancement
        assertFalse(PollReconcile.advancedDespiteReportedPause(10.2, 10.0))
    }

    @Test fun nearEnd_verdict() {
        assertTrue(PollReconcile.nearEnd(192.0, 200.0))
        assertFalse(PollReconcile.nearEnd(190.0, 200.0))
        assertFalse(PollReconcile.nearEnd(5.0, 8.0)) // too short to pre-arm
    }

    @Test fun nearEnd_firesOncePerArm_whilePlaying() {
        m.arm(60_000)
        assertEquals(AmEvent.FirstAudio, tick(AmStatus.PLAYING, 0.1))
        var fired = 0
        for (s in 1..58) if (tick(AmStatus.PLAYING, s.toDouble(), 1000) == AmEvent.NearEnd) fired++
        assertEquals(1, fired)
        m.arm(60_000)
        tick(AmStatus.PLAYING, 0.1)
        for (s in 1..45) tick(AmStatus.PLAYING, s.toDouble(), 1000)
        assertEquals(AmEvent.NearEnd, tick(AmStatus.PLAYING, 52.0, 1000))
    }

    @Test fun frozenPausedStatusOverAdvancingPosition_isHealedNotParkedSkip() {
        m.arm(200_000)
        tick(AmStatus.PLAYING, 0.1)
        for (s in 1..5) tick(AmStatus.PLAYING, s.toDouble(), 1000)
        // status glues to PAUSED while position moves; without the heal an early-song pause near 0:00 would
        // not misfire, but a frozen status must never end the track and must be counted
        assertNull(tick(AmStatus.PAUSED, 6.0, 1000)) // first paused poll: fresh pause, not yet a freeze
        assertNull(tick(AmStatus.PAUSED, 7.0, 1000)) // second: position advanced => self-heal
        assertEquals(1, m.selfHealCount)
        assertFalse(m.isFinished)
        assertNull(tick(AmStatus.PAUSED, 8.0, 1000))
        assertEquals(2, m.selfHealCount)
    }

    @Test fun genuinePause_isNotHealed() {
        m.arm(200_000)
        tick(AmStatus.PLAYING, 0.1)
        for (s in 1..5) tick(AmStatus.PLAYING, s.toDouble(), 1000)
        assertNull(tick(AmStatus.PAUSED, 5.2, 400))
        assertNull(tick(AmStatus.PAUSED, 5.2, 400))
        assertNull(tick(AmStatus.PAUSED, 5.2, 400))
        assertEquals(0, m.selfHealCount)
    }

    @Test fun healedStatus_reachesTheAdapterModel_asPlayWhenReady() {
        var changes = 0
        m.onReportedStateChanged = { changes++ }
        m.arm(200_000)
        tick(AmStatus.PLAYING, 0.1)
        for (s in 1..5) tick(AmStatus.PLAYING, s.toDouble(), 1000)
        val frozen = AmSnapshot(AmStatus.PAUSED, 8_000, 200_000)
        val track = AmTrack("s", "T", "A", null, null)
        fun wtr(snap: AmSnapshot) =
            com.levi.pocketdj.playback.session.AppleMusicAdapterStateMap.model(track, m.reconcileSnapshot(snap), true).playWhenReady
        assertFalse(wtr(frozen)) // not yet healed
        tick(AmStatus.PAUSED, 6.0, 1000)
        tick(AmStatus.PAUSED, 7.0, 1000)
        assertTrue(m.statusHealed)
        assertEquals(1, changes)
        assertTrue(wtr(frozen))
        // a real pause (position stops) un-heals and the card reads paused again
        tick(AmStatus.PAUSED, 7.0, 400)
        assertFalse(m.statusHealed)
        assertEquals(2, changes)
        assertFalse(wtr(frozen))
    }

    @Test fun scrubForwardWhilePaused_isNotHealed_andIntentionalPauseSurvives() {
        m.arm(200_000)
        tick(AmStatus.PLAYING, 0.1)
        for (s in 1..30) tick(AmStatus.PLAYING, s.toDouble(), 1000)
        m.noteIntentionalPause(true)
        assertNull(tick(AmStatus.PAUSED, 30.0))
        m.noteSeek(60_000)
        assertNull(tick(AmStatus.PAUSED, 60.0))
        assertNull(tick(AmStatus.PAUSED, 60.0))
        assertEquals(0, m.selfHealCount)
        assertTrue(m.intentionalPause)
        // drag back to the top while still paused: must not read as a parked system skip
        m.noteSeek(0)
        assertNull(tick(AmStatus.PAUSED, 0.0))
        assertNull(tick(AmStatus.PAUSED, 0.0))
        assertFalse(m.isFinished)
    }
}

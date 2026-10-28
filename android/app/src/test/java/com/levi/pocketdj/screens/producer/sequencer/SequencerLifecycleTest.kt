package com.levi.pocketdj.screens.producer.sequencer

import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

class SequencerLifecycleTest {
    @Test fun rotationDoesNotStopAPlayingPattern() {
        assertFalse(SequencerLifecycle.shouldStopOnDispose(changingConfigurations = true, ownsLoadedPattern = true, playing = true))
        assertFalse(SequencerLifecycle.shouldCancelPrepareOnDispose(changingConfigurations = true))
    }
    @Test fun leavingTheEditorStopsOnlyTheOwnedPlayingPattern() {
        assertTrue(SequencerLifecycle.shouldStopOnDispose(false, true, true))
        assertFalse(SequencerLifecycle.shouldStopOnDispose(false, false, true))
        assertFalse(SequencerLifecycle.shouldStopOnDispose(false, true, false))
        assertTrue(SequencerLifecycle.shouldCancelPrepareOnDispose(false))
    }
}

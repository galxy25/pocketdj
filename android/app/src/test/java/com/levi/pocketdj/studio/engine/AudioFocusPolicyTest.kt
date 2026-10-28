package com.levi.pocketdj.studio.engine

import android.media.AudioManager
import com.levi.pocketdj.audio.core.AudioDiag
import org.junit.After
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Before
import org.junit.Test

class AudioFocusPolicyTest {
    private val lines = ArrayList<String>()
    private var savedEmit: (String) -> Unit = {}

    @Before fun setUp() {
        AudioFocusPolicy.endMicCapture()
        AudioDiag.reset()
        savedEmit = AudioDiag.emit
        AudioDiag.emit = { lines.add(it) }
    }

    @After fun tearDown() {
        AudioFocusPolicy.endMicCapture()
        AudioDiag.emit = savedEmit
        AudioDiag.reset()
    }

    @Test fun micFlagBlocksPlaybackAndClearsOnEnd() {
        assertTrue(AudioFocusPolicy.mayStartPlayback())
        assertNull(AudioFocusPolicy.refusalReason())
        AudioFocusPolicy.beginMicCapture()
        assertFalse(AudioFocusPolicy.mayStartPlayback())
        assertEquals("mic-capture-active", AudioFocusPolicy.refusalReason())
        AudioFocusPolicy.endMicCapture()
        assertTrue(AudioFocusPolicy.mayStartPlayback())
    }

    @Test fun gateStartLogsRefusalReasonWithOwner() {
        AudioFocusPolicy.beginMicCapture()
        assertFalse(AudioFocusPolicy.gateStart("pattern"))
        assertEquals(1, lines.size)
        assertEquals("audio.play.skip owner=studio.pattern reason=mic-capture-active", lines[0])
        assertEquals(1, AudioDiag.count("play.skip", "mic-capture-active"))
    }

    @Test fun gateStartIsSilentWhenAllowed() {
        assertTrue(AudioFocusPolicy.gateStart("sample"))
        assertTrue(lines.isEmpty())
    }

    @Test fun studioDiagTagsStopAndPlayExits() {
        StudioDiag.stop("loop", "focus-loss")
        StudioDiag.play("loop", "started", started = true, detail = "id=lp_1")
        assertEquals("audio.stop owner=studio.loop reason=focus-loss", lines[0])
        assertEquals("audio.play owner=studio.loop reason=started id=lp_1", lines[1])
    }

    @Test fun onlyLossAndTransientLossParkEngines() {
        assertTrue(AudioFocusPolicy.shouldPauseOnFocusChange(AudioManager.AUDIOFOCUS_LOSS))
        assertTrue(AudioFocusPolicy.shouldPauseOnFocusChange(AudioManager.AUDIOFOCUS_LOSS_TRANSIENT))
        assertFalse(AudioFocusPolicy.shouldPauseOnFocusChange(AudioManager.AUDIOFOCUS_GAIN))
        assertFalse(AudioFocusPolicy.shouldPauseOnFocusChange(AudioManager.AUDIOFOCUS_LOSS_TRANSIENT_CAN_DUCK))
    }

    @Test fun ledgerResumesOnlyWhatWasParked() {
        val l = InterruptionLedger()
        assertTrue(l.park("pattern"))
        assertTrue(l.park("loop"))
        assertFalse("double park is a no-op", l.park("pattern"))
        l.forget("loop") // user stopped it during the interruption
        assertEquals(listOf("pattern"), l.drainForResume())
        assertEquals("drained: a second gain resumes nothing", emptyList<String>(), l.drainForResume())
        assertFalse(l.isParked("pattern"))
    }

    @Test fun ledgerKeepsParkOrder() {
        val l = InterruptionLedger()
        l.park("b"); l.park("a"); l.park("c")
        assertEquals(listOf("b", "a", "c"), l.drainForResume())
    }
}

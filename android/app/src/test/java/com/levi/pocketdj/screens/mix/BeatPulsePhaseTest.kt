package com.levi.pocketdj.screens.mix

import com.levi.pocketdj.mix.model.LoadedTrack
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNotNull
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test

class BeatPulsePhaseTest {
    private fun synth(bpm: Double = 120.0, down: Int? = 0) =
        LoadedTrack("s", "T", "A", gridBpm = bpm, firstDownbeatMs = down)

    @Test fun silentWhenPausedOrUnloaded() {
        assertEquals(BeatPulsePhase.Envelope.Silent, BeatPulsePhase.envelope(false, synth(), 1.0, 1.0))
        assertEquals(BeatPulsePhase.Envelope.Silent, BeatPulsePhase.envelope(true, null, 1.0, 1.0))
    }

    @Test fun silentWithoutAnyGrid() {
        assertEquals(BeatPulsePhase.Envelope.Silent, BeatPulsePhase.envelope(true, LoadedTrack("s", "T", "A"), 1.0, 1.0))
    }

    @Test fun silentBeforeTheFirstDownbeat() {
        assertNull(BeatPulsePhase.lastBeat(synth(down = 2000), 1.0))
    }

    @Test fun peaksOnTheBeatAndDecaysQuadratically() {
        // 120 bpm = 0.5 s/beat; position exactly on beat 1 (a non-downbeat): full intensity
        val on = BeatPulsePhase.envelope(true, synth(), 0.5, 1.0)
        assertEquals(1.0, on.intensity, 1e-9)
        assertFalse(on.down)
        // 0.11 s after a normal beat at rate 1 = half of the 0.22 s decay -> (0.5)^2
        val half = BeatPulsePhase.envelope(true, synth(), 0.61, 1.0)
        assertEquals(0.25, half.intensity, 1e-6)
        // past the decay window -> dark
        assertEquals(0.0, BeatPulsePhase.envelope(true, synth(), 0.75, 1.0).intensity, 0.0)
    }

    @Test fun everyFourthBeatIsABrighterDownbeatWithALongerDecay() {
        val down = BeatPulsePhase.envelope(true, synth(), 2.0, 1.0)      // beat index 4
        assertTrue(down.down)
        assertEquals(1.0, down.intensity, 1e-9)
        // 0.17 s after = half of 0.34 -> 0.25; the same offset after a plain beat is already quieter
        val d = BeatPulsePhase.envelope(true, synth(), 2.17, 1.0)
        assertEquals(0.25, d.intensity, 1e-6)
        val n = BeatPulsePhase.envelope(true, synth(), 0.67, 1.0)
        assertTrue(n.intensity < d.intensity)
    }

    @Test fun decayRunsInWallClockTimeSoRateScalesIt() {
        // 0.11 source seconds after a beat at rate 2 = 0.055 s wall -> 1 - 0.25 = 0.75 -> squared
        val e = BeatPulsePhase.envelope(true, synth(), 0.61, 2.0)
        assertEquals(0.75 * 0.75, e.intensity, 1e-6)
    }

    @Test fun usesTheRealPerBeatGridWhenPresent() {
        // a drifting track: beats at 0, 600, 1250 ms; 1250 is a downbeat
        val t = LoadedTrack("s", "T", "A", gridBpm = 120.0, beatsMs = listOf(0, 600, 1250), downbeatsMs = listOf(1250))
        val b = BeatPulsePhase.lastBeat(t, 1.3)
        assertNotNull(b)
        assertEquals(1.25, b!!.sec, 1e-9)
        assertTrue(b.down)
        val c = BeatPulsePhase.lastBeat(t, 0.9)!!
        assertEquals(0.6, c.sec, 1e-9)
        assertFalse(c.down)
    }

    @Test fun firstDownbeatPhaseShiftsTheGrid() {
        val t = synth(bpm = 60.0, down = 250)   // beats at 0.25, 1.25, ...
        val b = BeatPulsePhase.lastBeat(t, 2.3)!!
        assertEquals(2.25, b.sec, 1e-9)
        assertFalse(b.down)                      // idx 2
        assertTrue(BeatPulsePhase.lastBeat(t, 4.3)!!.down) // idx 4
    }

    @Test fun catalogBpmIsTheFallbackWhenGridBpmMissing() {
        val t = LoadedTrack("s", "T", "A", bpm = 120.0)
        assertEquals(1.0, BeatPulsePhase.envelope(true, t, 0.5, 1.0).intensity, 1e-9)
    }
}

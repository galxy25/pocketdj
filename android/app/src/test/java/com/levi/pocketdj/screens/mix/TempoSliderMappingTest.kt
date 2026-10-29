package com.levi.pocketdj.screens.mix

import org.junit.Assert.assertEquals
import org.junit.Test

class TempoSliderMappingTest {
    private val m = TempoSliderMapping

    @Test fun unityIsCentredAndEndsAreTheRateRange() {
        assertEquals(0.0, m.toSlider(1.0), 1e-9)
        assertEquals(-1.0, m.toSlider(0.5), 1e-9)
        assertEquals(1.0, m.toSlider(2.0), 1e-9)
        assertEquals(0.5, m.fromSlider(-1.0), 1e-9)
        assertEquals(2.0, m.fromSlider(1.0), 1e-9)
    }

    @Test fun nearCentreSnapsToUnityAndValuesRoundToHundredths() {
        assertEquals(1.0, m.fromSlider(0.01), 1e-9)
        assertEquals(1.0, m.fromSlider(-0.01), 1e-9)
        assertEquals(1.41, m.fromSlider(0.5), 1e-9)
        // Round trip within a hundredth.
        for (v in listOf(0.5, 0.8, 1.1, 1.5, 2.0)) assertEquals(v, m.fromSlider(m.toSlider(v)), 0.006)
    }
}

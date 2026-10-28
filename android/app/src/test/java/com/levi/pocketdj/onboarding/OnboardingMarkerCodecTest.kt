package com.levi.pocketdj.onboarding

import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test

class OnboardingMarkerCodecTest {
    @Test
    fun decodesIosStartedJson() {
        val m = OnboardingMarkerCodec.decode("""{"version":1,"state":"started","stage":1}""")
        assertEquals(OnboardingMarker.Started(OnboardingStage.AppleMusic), m)
    }

    @Test
    fun decodesPendingAndCompleted_withAndWithoutCompletedAt() {
        assertEquals(OnboardingMarker.Pending, OnboardingMarkerCodec.decode("""{"version":1,"state":"pending"}"""))
        assertEquals(OnboardingMarker.Completed, OnboardingMarkerCodec.decode("""{"version":1,"state":"completed"}"""))
        // Swift writes a fractional Double
        assertEquals(
            OnboardingMarker.Completed,
            OnboardingMarkerCodec.decode("""{"version":1,"state":"completed","completedAtMs":1760000000123.456}"""),
        )
    }

    @Test
    fun toleratesUnknownKeys() {
        val m = OnboardingMarkerCodec.decode("""{"version":2,"state":"started","stage":2,"future":{"a":1}}""")
        assertEquals(OnboardingMarker.Started(OnboardingStage.Sources), m)
    }

    @Test
    fun startedWithMissingOrBadStage_resumesAtProfile() {
        assertEquals(
            OnboardingMarker.Started(OnboardingStage.Profile),
            OnboardingMarkerCodec.decode("""{"version":1,"state":"started"}"""),
        )
        assertEquals(
            OnboardingMarker.Started(OnboardingStage.Profile),
            OnboardingMarkerCodec.decode("""{"version":1,"state":"started","stage":9}"""),
        )
    }

    @Test
    fun unknownStateCorruptOrBlank_isAbsent() {
        assertNull(OnboardingMarkerCodec.decode("""{"version":1,"state":"weird"}"""))
        assertNull(OnboardingMarkerCodec.decode("not json"))
        assertNull(OnboardingMarkerCodec.decode(""))
        assertNull(OnboardingMarkerCodec.decode(null))
    }

    @Test
    fun encodeMatchesIosShape_omittingNils() {
        assertEquals("""{"version":1,"state":"pending"}""", OnboardingMarkerCodec.encode(OnboardingMarker.Pending))
        assertEquals(
            """{"version":1,"state":"started","stage":2}""",
            OnboardingMarkerCodec.encode(OnboardingMarker.Started(OnboardingStage.Sources)),
        )
        val done = OnboardingMarkerCodec.encode(OnboardingMarker.Completed, nowMs = 1_760_000_000_000L)
        assertTrue(done.contains(""""state":"completed""""))
        assertTrue(done.contains("completedAtMs"))
        assertFalse(done.contains("stage"))
    }

    @Test
    fun roundTrip() {
        listOf(
            OnboardingMarker.Pending,
            OnboardingMarker.Completed,
            OnboardingMarker.Started(OnboardingStage.Profile),
            OnboardingMarker.Started(OnboardingStage.AppleMusic),
            OnboardingMarker.Started(OnboardingStage.Sources),
        ).forEach { assertEquals(it, OnboardingMarkerCodec.decode(OnboardingMarkerCodec.encode(it))) }
    }
}

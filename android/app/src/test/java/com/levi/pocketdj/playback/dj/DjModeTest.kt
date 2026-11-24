package com.levi.pocketdj.playback.dj

import kotlinx.serialization.encodeToString
import kotlinx.serialization.json.Json
import kotlinx.serialization.json.JsonObject
import kotlinx.serialization.json.JsonPrimitive
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test

class DjModeTest {
    @Test fun chipWordsAreVerbatim() {
        assertNull(DjMode.Indicator.Off.chipText)
        assertEquals("DJ — paused while the Mix tab plays", DjMode.Indicator.Suspended.chipText)
        assertEquals("DJ — paused · SharePlay session", DjMode.Indicator.SuspendedRemote.chipText)
        assertEquals("DJ — mixing", DjMode.Indicator.Mixing.chipText)
        assertEquals("DJ — next mixes in", DjMode.Indicator.NextReady.chipText)
        assertEquals("DJ — last song", DjMode.Indicator.LastTrack.chipText)
        assertEquals("DJ — buffering next", DjMode.Indicator.BufferingNext(null).chipText)
        assertEquals("DJ — buffering next 42%", DjMode.Indicator.BufferingNext(0.42).chipText)
        assertEquals("DJ — buffering next 100%", DjMode.Indicator.BufferingNext(7.0).chipText)
        assertEquals("DJ — buffering next 0%", DjMode.Indicator.BufferingNext(-1.0).chipText)
        assertEquals("DJ — transitions off", DjMode.Indicator.NoMix("transitions off").chipText)
    }

    @Test fun bufferingFlag() {
        assertTrue(DjMode.Indicator.BufferingNext(0.1).isBuffering)
        assertFalse(DjMode.Indicator.NextReady.isBuffering)
    }

    @Test fun declineReasonWords() {
        val words = DjEndReason.entries.associate { it.raw to it.chipWords }
        assertEquals("transitions off", words["transitions off"])
        assertEquals("repeating this song", words["repeat"])
        assertEquals("paused", words["halted"])
        assertEquals("last song", words["last song"])
        assertEquals("set repeats", words["set repeats"])
        assertEquals("album plays through", words["album run"])
        assertEquals("album side next", words["next starts an album side"])
        assertEquals("this song ends as is", words["plain row"])
    }

    @Test fun indicatorMappingForDeclines() {
        assertEquals(DjMode.Indicator.LastTrack, DjEndReason.indicator(DjEndReason.LAST_SONG))
        assertEquals("DJ — set repeats", DjEndReason.indicator(DjEndReason.SET_REPEATS).chipText)
        assertEquals("DJ — album plays through", DjEndReason.indicator(DjEndReason.ALBUM_RUN).chipText)
        assertEquals("DJ — repeating this song", DjEndReason.indicator(DjEndReason.REPEATING).chipText)
    }

    @Test fun timingsAndFastSkipDefaults() {
        val t = DjMode.Timings()
        assertEquals(15.0, t.lead, 0.0); assertEquals(3.0, t.fade, 0.0)
        assertEquals(10.0, t.glide, 0.0); assertEquals(15.0, t.skipFade, 0.0)
        assertEquals(5.0, DjMode.FAST_SKIP_FADE_SECONDS, 0.0)
    }

    @Test fun settingsDefaultAllOnAndPlannerOptionsFollowToggles() {
        val s = DJModeSettings()
        assertTrue(s.transitions && s.effectSweeps && s.tempoMatch && s.keyMatch && s.volumeLeveling && s.tempoWaves && s.pockets)
        assertEquals(DJModeSettings.ALL_ON, s)
        val p = s.copy(tempoWaves = false, keyMatch = false).plannerOptions
        assertEquals(DJModeSettings.PlannerOptions(tempoWaves = false, pockets = true, key = false), p)
    }

    private val json = Json { ignoreUnknownKeys = true }

    @Test fun stateDecodesIosShapeWithAndWithoutPlanner() {
        assertEquals(DJModeState(), json.decodeFromString<DJModeState>("{}"))
        val withPlanner = json.decodeFromString<DJModeState>("""{"enabled":true,"planner":{"wave":3,"seed":"x"}}""")
        assertTrue(withPlanner.enabled)
        assertEquals(JsonPrimitive(3), (withPlanner.planner as JsonObject)["wave"])
    }

    @Test fun plannerRoundTripsOpaquelyAndNullPlannerOmitted() {
        val raw = """{"enabled":true,"planner":{"wave":3,"pocket":[1,2]}}"""
        val back = json.encodeToString(json.decodeFromString<DJModeState>(raw))
        assertEquals(json.parseToJsonElement(raw), json.parseToJsonElement(back))
        // explicitNulls default would write "planner":null; iOS omits nil optionals.
        val enc = Json { explicitNulls = false; encodeDefaults = true }.encodeToString(DJModeState(enabled = false))
        assertEquals("""{"enabled":false}""", enc)
    }
}

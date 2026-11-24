package com.levi.pocketdj.mix.nowplaying

import com.levi.pocketdj.mix.nowplaying.NpMixMode.Indicator
import com.levi.pocketdj.mix.nowplaying.NpMixMode.IndicatorInput
import kotlinx.serialization.encodeToString
import kotlinx.serialization.json.Json
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test

class NpMixModeIndicatorTest {
    private val base = IndicatorInput(enabled = true, running = true)
    private fun ind(f: IndicatorInput.() -> IndicatorInput) = NpMixMode.indicator(base.f())

    @Test fun chipWordsAreVerbatimFromIos() {
        assertNull(Indicator.Off.chipText)
        assertEquals("Ready", Indicator.Ready.chipText)
        assertEquals("Ready — tap a control to switch to the local copy", Indicator.ReadyFromAppleMusic.chipText)
        assertEquals("Mixing", Indicator.Engaged.chipText)
        assertEquals("Buffering 42%", Indicator.Buffering(0.42).chipText)
        assertEquals("Buffering 100%", Indicator.Holding(1.0).chipText)
        assertEquals("Buffering…", Indicator.Buffering(null).chipText)
        assertEquals("Buffering…", Indicator.Holding(null).chipText)
        assertEquals("Loading stems…", Indicator.StemsLoading.chipText)
        assertEquals("Ripping — mixable next play", Indicator.Ripping.chipText)
        assertEquals("Ripping explicit edition — mixable next play", Indicator.RippingEdition("explicit").chipText)
        assertEquals("Storage full", Indicator.Unavailable("Storage full").chipText)
        assertEquals("Paused — Mix tab is live", Indicator.Suspended.chipText)
        assertEquals("Buffers on ▶", Indicator.Waiting.chipText)
    }

    @Test fun percentRoundsDownLikeIos() {
        assertEquals("Buffering 99%", Indicator.Buffering(0.999).chipText)
        assertEquals("Buffering 0%", Indicator.Buffering(0.004).chipText)
    }

    @Test fun offUnlessEnabledAndRunning() {
        assertEquals(Indicator.Off, ind { copy(enabled = false, mixable = true) })
        assertEquals(Indicator.Off, ind { copy(running = false, mixable = true) })
    }

    @Test fun sessionWideStatesOutrankTheRest() {
        assertEquals(Indicator.Waiting, ind { copy(held = true, mixTabLive = true, engaged = true) })
        assertEquals(Indicator.Suspended, ind { copy(mixTabLive = true, engaged = true, mixable = true) })
    }

    @Test fun engagedStates() {
        assertEquals(Indicator.Engaged, ind { copy(engaged = true) })
        assertEquals(Indicator.StemsLoading, ind { copy(engaged = true, stemsLoading = true) })
        assertEquals(Indicator.Holding(0.3), ind { copy(engaged = true, dspHolding = true, bufferFraction = 0.3, stemsLoading = true) })
    }

    @Test fun mixableRowIsReadyOrReadyFromAppleMusic() {
        assertEquals(Indicator.Ready, ind { copy(mixable = true) })
        assertEquals(Indicator.ReadyFromAppleMusic, ind { copy(mixable = true, onAppleMusic = true) })
    }

    @Test fun appleMusicRowStatesAndTheRippedFallThrough() {
        assertEquals(Indicator.Unavailable("Apple Music only"), ind { copy(onAppleMusic = true) })
        assertEquals(Indicator.Ripping, ind { copy(onAppleMusic = true, ripping = true) })
        assertEquals(Indicator.RippingEdition("clean"), ind { copy(onAppleMusic = true, ripping = true, rippingEdition = "clean") })
        // ripped AM row is never "Apple Music only": it buffers
        assertEquals(Indicator.Buffering(0.5), ind { copy(onAppleMusic = true, ripped = true, buffering = true, bufferFraction = 0.5) })
    }

    @Test fun whyACopyCannotExistFollowsTheIosOrder() {
        assertEquals(Indicator.Unavailable("Live capture"), ind { copy(live = true, storageFull = true) })
        assertEquals(Indicator.Unavailable("Storage full"), ind { copy(storageFull = true, failed = true) })
        assertEquals(Indicator.Unavailable("Download failed"), ind { copy(failed = true, buffering = true) })
        assertEquals(Indicator.Buffering(null), ind { copy(buffering = true, deviceMode = true, offline = true) })
        assertEquals(Indicator.Unavailable("Device mode — downloads only"), ind { copy(deviceMode = true, offline = true) })
        assertEquals(Indicator.Unavailable("Offline"), ind { copy(offline = true, ripped = true) })
        assertEquals(Indicator.Unavailable("Not ripped"), ind { copy() })
        assertEquals(Indicator.Unavailable("Cellular — buffering off"), ind { copy(ripped = true, cellularOff = true) })
        assertEquals(Indicator.Buffering(0.1), ind { copy(ripped = true, bufferFraction = 0.1) })
    }

    @Test fun controlsLiveAndA11y() {
        val live = listOf(Indicator.Ready, Indicator.ReadyFromAppleMusic, Indicator.Engaged, Indicator.Holding(null), Indicator.StemsLoading)
        val dead = listOf(Indicator.Off, Indicator.Buffering(null), Indicator.Ripping, Indicator.Unavailable("x"), Indicator.Suspended, Indicator.Waiting)
        live.forEach { assertTrue(it.toString(), it.controlsLive) }
        dead.forEach { assertFalse(it.toString(), it.controlsLive) }
        assertEquals("ripping", Indicator.RippingEdition("x").a11yValue)
        assertEquals("readyFromAppleMusic", Indicator.ReadyFromAppleMusic.a11yValue)
        assertEquals("stemsLoading", Indicator.StemsLoading.a11yValue)
    }

    @Test fun bufferDotGlyphs() {
        assertEquals(listOf("●", "◐", "○", "⨯"), NpMixMode.BufferDot.entries.map { it.glyph })
        assertEquals(listOf("local", "buffering", "queued", "unavailable"), NpMixMode.BufferDot.entries.map { it.raw })
    }

    @Test fun stateJsonIsIosShapedAndAbsentFieldsReadOff() {
        val json = Json { ignoreUnknownKeys = true }
        assertEquals("""{"enabled":true}""", Json { encodeDefaults = true }.encodeToString(NpMixModeState(true)))
        assertEquals(NpMixModeState(true), json.decodeFromString<NpMixModeState>("""{"enabled":true,"future":1}"""))
        assertEquals(NpMixModeState(false), json.decodeFromString<NpMixModeState>("{}"))
    }

    @Test fun bufferAheadOptionsMatchIos() {
        assertEquals(listOf(1, 3, 5, 10), NpMixMode.bufferAheadOptions)
        assertEquals(3, NpMixMode.DEFAULT_BUFFER_AHEAD)
    }
}

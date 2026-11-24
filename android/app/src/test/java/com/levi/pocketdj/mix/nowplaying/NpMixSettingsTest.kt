package com.levi.pocketdj.mix.nowplaying

import org.junit.Assert.assertEquals
import org.junit.Assert.assertNull
import org.junit.Test

class NpMixSettingsTest {
    @Test fun defaultsMatchIos() {
        val s = NpMixSettings()
        assertEquals(48.0, s.bufferTtlHours!!, 0.0)
        assertEquals(2.0, s.bufferCapGb, 0.0)
        assertEquals(3, s.bufferAhead)
        assertEquals(NpMixCellularPolicy.NEXT_SONG, s.cellular)
        assertEquals(false, s.modeDefaultOn)
        assertEquals(false, s.keepPickedFolderBuffers)
        assertEquals(2_000_000_000L, s.bufferCapBytes)
        assertEquals(s, NpMixSettingsRules.normalize(null, null, null, null, false, false))
    }

    @Test fun keysAreIosVerbatim() {
        assertEquals("npMixBufferTTLHours", NpMixSettingsKeys.BUFFER_TTL_HOURS.name)
        assertEquals("npMixBufferCapGB", NpMixSettingsKeys.BUFFER_CAP_GB.name)
        assertEquals("npMixBufferAhead", NpMixSettingsKeys.BUFFER_AHEAD.name)
        assertEquals("npMixCellular", NpMixSettingsKeys.CELLULAR.name)
        assertEquals("npMixModeDefaultOn", NpMixSettingsKeys.MODE_DEFAULT_ON.name)
        assertEquals("npMixKeepPickedFolderBuffers", NpMixSettingsKeys.KEEP_PICKED_FOLDER_BUFFERS.name)
        assertEquals("lastTemporarySweepAt", NpMixSettingsKeys.LAST_TEMPORARY_SWEEP_AT.name)
        assertEquals(48.0, NpMixSettingsKeys.BUFFER_TTL_HOURS.default, 0.0)
        assertEquals("nextSong", NpMixSettingsKeys.CELLULAR.default)
    }

    @Test fun keepSentinelIsNullTtl() {
        assertNull(NpMixSettingsRules.effectiveTtlHours(0.0))
        assertNull(NpMixSettings.TTL_OPTIONS.last().let { NpMixSettingsRules.effectiveTtlHours(it) })
        assertEquals(168.0, NpMixSettingsRules.effectiveTtlHours(168.0)!!, 0.0)
    }

    @Test fun corruptTtlReadsAsDefaultNeverKeepOrExpireNow() {
        for (bad in listOf(-1.0, -48.0, Double.NaN, Double.POSITIVE_INFINITY, Double.NEGATIVE_INFINITY)) {
            assertEquals("raw=$bad", 48.0, NpMixSettingsRules.effectiveTtlHours(bad)!!, 0.0)
        }
    }

    @Test fun capAndAheadNormalise() {
        assertEquals(2.0, NpMixSettingsRules.effectiveCapGb(0.0), 0.0)
        assertEquals(2.0, NpMixSettingsRules.effectiveCapGb(-3.0), 0.0)
        assertEquals(2.0, NpMixSettingsRules.effectiveCapGb(Double.NaN), 0.0)
        assertEquals(5.0, NpMixSettingsRules.effectiveCapGb(5.0), 0.0)
        assertEquals(3, NpMixSettingsRules.effectiveAhead(0))
        assertEquals(3, NpMixSettingsRules.effectiveAhead(-2))
        assertEquals(5, NpMixSettingsRules.effectiveAhead(5))
        assertEquals(10, NpMixSettingsRules.effectiveAhead(99))
        assertEquals(listOf(1, 3, 5, 10), NpMixSettings.AHEAD_OPTIONS)
    }

    @Test fun unknownCellularRawReadsAsDefault() {
        assertEquals(NpMixCellularPolicy.NEXT_SONG, NpMixCellularPolicy.fromRaw("wifiOnlyV9"))
        assertEquals(NpMixCellularPolicy.NEXT_SONG, NpMixCellularPolicy.fromRaw(null))
        assertEquals(NpMixCellularPolicy.OFF, NpMixCellularPolicy.fromRaw("off"))
        assertEquals(NpMixCellularPolicy.FULL, NpMixCellularPolicy.fromRaw("full"))
        assertEquals(NpMixCellularPolicy.FULL, NpMixSettingsRules.normalize(null, null, null, "full", true, true).cellular)
    }
}

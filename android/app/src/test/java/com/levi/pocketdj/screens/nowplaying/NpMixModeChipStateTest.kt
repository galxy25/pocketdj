package com.levi.pocketdj.screens.nowplaying

import androidx.datastore.preferences.core.PreferenceDataStoreFactory
import com.levi.pocketdj.data.settings.AppSettingsStore
import com.levi.pocketdj.mix.nowplaying.NpMixCellularPolicy
import com.levi.pocketdj.mix.nowplaying.NpMixMode
import com.levi.pocketdj.mix.nowplaying.NpMixSettings
import com.levi.pocketdj.mix.nowplaying.npMixSettings
import com.levi.pocketdj.mix.nowplaying.setNpMixBufferAhead
import com.levi.pocketdj.mix.nowplaying.setNpMixCellular
import com.levi.pocketdj.mix.nowplaying.setNpMixModeDefaultOn
import com.levi.pocketdj.screens.settings.sections.PlaybackSectionModel
import java.io.File
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.Job
import kotlinx.coroutines.cancel
import kotlinx.coroutines.runBlocking
import org.junit.Assert.assertEquals
import org.junit.Assert.assertNotNull
import org.junit.Assert.assertNull
import org.junit.Rule
import org.junit.Test
import org.junit.rules.TemporaryFolder
import com.levi.pocketdj.mix.nowplaying.NpMixMode.BufferDot as Dot
import com.levi.pocketdj.mix.nowplaying.NpMixMode.Indicator as Ind

class NpMixModeChipStateTest {
    @Test fun off_hasNoChip() {
        assertNull(NpMixChipState.of(Ind.Off))
    }

    @Test fun iosWordsPerIndicator() {
        val words = mapOf(
            Ind.Ready to "Ready",
            Ind.ReadyFromAppleMusic to "Ready — tap a control to switch to the local copy",
            Ind.Engaged to "Mixing",
            Ind.StemsLoading to "Loading stems…",
            Ind.Ripping to "Ripping — mixable next play",
            Ind.RippingEdition("clean") to "Ripping clean edition — mixable next play",
            Ind.Suspended to "Paused — Mix tab is live",
            Ind.Waiting to "Buffers on ▶",
            Ind.Unavailable("Apple Music only") to "Apple Music only",
            Ind.Buffering(null) to "Buffering…",
        )
        for ((ind, text) in words) assertEquals(text, NpMixChipState.of(ind)!!.text)
    }

    @Test fun bufferingAndHoldingCarryFloorPercentAndProgress() {
        val b = NpMixChipState.of(Ind.Buffering(0.426))!!
        assertEquals("Buffering 42%", b.text)
        assertEquals(0.426f, b.progress!!, 1e-6f)
        assertEquals("buffering", b.value)
        val h = NpMixChipState.of(Ind.Holding(1.5))!!
        assertEquals("Buffering 150%", h.text) // iOS formats the raw value; progress is clamped for the bar only
        assertEquals(1f, h.progress!!, 0f)
        assertNull(NpMixChipState.of(Ind.Buffering(null))!!.progress)
        assertNull(NpMixChipState.of(Ind.Ready)!!.progress)
    }

    @Test fun toneFollowsControlsLive() {
        val live = listOf(Ind.Ready, Ind.ReadyFromAppleMusic, Ind.Engaged, Ind.Holding(0.1), Ind.StemsLoading)
        for (i in live) assertEquals("$i", NpMixChipTone.ACCENT, NpMixChipState.of(i)!!.tone)
        val dim = listOf(Ind.Buffering(0.1), Ind.Ripping, Ind.Suspended, Ind.Waiting, Ind.Unavailable("Offline"))
        for (i in dim) assertEquals("$i", NpMixChipTone.DIM, NpMixChipState.of(i)!!.tone)
    }

    @Test fun glyphs() {
        assertEquals(NpMixChipGlyph.FILLED_DOT, NpMixChipState.of(Ind.Engaged)!!.glyph)
        assertEquals(NpMixChipGlyph.FILLED_DOT, NpMixChipState.of(Ind.StemsLoading)!!.glyph)
        assertEquals(NpMixChipGlyph.RING, NpMixChipState.of(Ind.Ready)!!.glyph)
        assertEquals(NpMixChipGlyph.DOWNLOAD, NpMixChipState.of(Ind.Waiting)!!.glyph)
        assertEquals(NpMixChipGlyph.DOWNLOAD, NpMixChipState.of(Ind.Holding(null))!!.glyph)
        assertEquals(NpMixChipGlyph.ALERT, NpMixChipState.of(Ind.Suspended)!!.glyph)
        assertEquals(NpMixChipGlyph.ALERT, NpMixChipState.of(Ind.Unavailable("x"))!!.glyph)
        assertEquals(NpMixChipGlyph.ALERT, NpMixChipState.of(Ind.RippingEdition("clean"))!!.glyph)
    }

    @Test fun spokenAppendsTheEditionNote() {
        assertEquals("Mixing", NpMixChipState.of(Ind.Engaged)!!.spoken)
        assertEquals("Mixing · Clean edition", NpMixChipState.of(Ind.Engaged, "Clean edition")!!.spoken)
    }

    // ---- buffer strip: a dot is full only when the file the row WILL play is local ----

    private fun facts(
        local: Boolean = false, fetching: Boolean = false, planned: Boolean = false, ripped: Boolean = false,
        device: Boolean = false, failed: Boolean = false, rip: Boolean = false,
    ) = NpMixDotFacts(local, fetching, planned, ripped, device, failed, rip)

    @Test fun dotPrecedence() {
        assertEquals(Dot.LOCAL, NpMixBufferStripModel.dot(facts(local = true, fetching = true)))
        assertEquals(Dot.BUFFERING, NpMixBufferStripModel.dot(facts(fetching = true, planned = true)))
        assertEquals(Dot.QUEUED, NpMixBufferStripModel.dot(facts(planned = true)))
        assertEquals(Dot.QUEUED, NpMixBufferStripModel.dot(facts(ripped = true)))
        assertEquals(Dot.UNAVAILABLE, NpMixBufferStripModel.dot(facts(ripped = true, device = true)))
        assertEquals(Dot.UNAVAILABLE, NpMixBufferStripModel.dot(facts(ripped = true, failed = true)))
        assertEquals(Dot.QUEUED, NpMixBufferStripModel.dot(facts(rip = true)))
        assertEquals(Dot.UNAVAILABLE, NpMixBufferStripModel.dot(facts()))
    }

    @Test fun windowAndSpokenWords() {
        assertEquals(listOf(3, 4, 5), NpMixBufferStripModel.window(10, 2, 3).toList())
        assertEquals(listOf(9), NpMixBufferStripModel.window(10, 8, 3).toList())
        assertEquals(emptyList<Int>(), NpMixBufferStripModel.window(10, 9, 3).toList())
        assertEquals(emptyList<Int>(), NpMixBufferStripModel.window(10, 2, -4).toList())
        val rows = listOf(Dot.LOCAL, Dot.BUFFERING, Dot.QUEUED, Dot.UNAVAILABLE).mapIndexed { i, d -> NpMixMode.BufferRow("$i", "t$i", d) }
        assertEquals("on device, buffering, queued, unavailable", NpMixBufferStripModel.spoken(rows))
        assertEquals(listOf("●", "◐", "○", "⨯"), rows.map { it.dot.glyph })
    }

    // ---- Settings rows ----

    @get:Rule val tmp = TemporaryFolder()

    @Test fun settingsRowsCopyAndOptions() {
        assertEquals(listOf(1, 3, 5, 10), PlaybackSectionModel.mixAheadOptions)
        assertEquals("1 song", PlaybackSectionModel.mixAheadLabel(1))
        assertEquals("10 songs", PlaybackSectionModel.mixAheadLabel(10))
        assertEquals(
            listOf("Off", "Next song only", "Same as Wi-Fi"),
            PlaybackSectionModel.mixCellularOptions.map(PlaybackSectionModel::mixCellularLabel),
        )
        assertNotNull(PlaybackSectionModel.mixCellularCaption(NpMixCellularPolicy.FULL))
    }

    @Test fun settingsRowsPersistWithIosKeysAndDefaults() = runBlocking {
        val file = File(tmp.root, "mm.preferences_pb")
        val s1 = CoroutineScope(Dispatchers.IO + Job())
        val a = AppSettingsStore(PreferenceDataStoreFactory.create(scope = s1) { file })
        assertEquals(NpMixSettings(), a.npMixSettings())
        a.setNpMixModeDefaultOn(true); a.setNpMixBufferAhead(5); a.setNpMixCellular(NpMixCellularPolicy.OFF)
        s1.cancel()
        val s2 = CoroutineScope(Dispatchers.IO + Job())
        val got = AppSettingsStore(PreferenceDataStoreFactory.create(scope = s2) { file }).npMixSettings()
        assertEquals(true, got.modeDefaultOn); assertEquals(5, got.bufferAhead); assertEquals(NpMixCellularPolicy.OFF, got.cellular)
        s2.cancel()
    }
}

package com.levi.pocketdj.screens.settings.storage

import com.levi.pocketdj.data.burns.TemporaryHold
import com.levi.pocketdj.data.burns.TemporaryHoldLedger
import com.levi.pocketdj.mix.nowplaying.NpMixSettings
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test

class MixModeBufferSectionStateTest {
    private val H = MixModeBufferState.HOUR_MS
    private fun hold(id: String, exp: Double, audio: Boolean = true, bytes: Long = 5_000_000, parts: List<String> = emptyList()) =
        TemporaryHold(id, audio = audio, stemParts = parts, createdAtMs = 0.0, expiresAtMs = exp, audioBytes = bytes,
            stemBytes = parts.associateWith { 1_000_000L })

    @Test fun ttlLabelsMatchIos() {
        assertEquals(listOf("6 h", "12 h", "24 h", "48 h", "3 days", "7 days", "Keep (treat as downloads)"),
            NpMixSettings.TTL_OPTIONS.map { MixModeBufferState.ttlLabel(it) })
        assertEquals("100 h", MixModeBufferState.ttlLabel(100.0)) // not a whole day count >= 72 -> hours
    }

    @Test fun capLabels() {
        assertEquals(listOf("500 MB", "1 GB", "2 GB", "5 GB", "10 GB", "20 GB"),
            NpMixSettings.CAP_OPTIONS.map { MixModeBufferState.capLabel(it) })
    }

    @Test fun keepSentinelMapsBothWays() {
        assertEquals(0.0, MixModeBufferState.ttlPickerValue(NpMixSettings(bufferTtlHours = null)), 0.0)
        assertEquals(48.0, MixModeBufferState.ttlPickerValue(NpMixSettings()), 0.0)
        assertEquals(0.0, MixModeBufferState.ttlToStore(0.0), 0.0)
        assertEquals(0.0, MixModeBufferState.ttlFromStore(0.0), 0.0)
        assertEquals(48.0, MixModeBufferState.ttlFromStore(null), 0.0)
        assertEquals(48.0, MixModeBufferState.ttlFromStore(-5.0), 0.0) // corrupt reads as default, never Keep
        assertEquals(12.0, MixModeBufferState.ttlFromStore(12.0), 0.0)
    }

    @Test fun unknownStoredValuesStaySelectable() {
        assertEquals(NpMixSettings.TTL_OPTIONS, MixModeBufferState.ttlOptions(48.0))
        assertEquals(NpMixSettings.TTL_OPTIONS + 30.0, MixModeBufferState.ttlOptions(30.0))
        assertTrue(3.0 in MixModeBufferState.capOptions(3.0))
        assertEquals(NpMixSettings.CAP_OPTIONS, MixModeBufferState.capOptions(2.0))
    }

    @Test fun expiryPhrases() {
        assertEquals("now", MixModeBufferState.expiryPhrase(100.0, 100.0))
        assertEquals("now", MixModeBufferState.expiryPhrase(0.0, 100.0))
        assertEquals("in 1 min", MixModeBufferState.expiryPhrase(1_000.0, 0.0))
        assertEquals("in 30 min", MixModeBufferState.expiryPhrase(0.5 * H, 0.0))
        assertEquals("in 31 h", MixModeBufferState.expiryPhrase(31 * H, 0.0))
        assertEquals("in 2 days", MixModeBufferState.expiryPhrase(48 * H, 0.0))
        assertEquals("in 7 days", MixModeBufferState.expiryPhrase(168 * H, 0.0))
        assertEquals("Buffered · expires in 3 h", MixModeBufferState.badgeText(3 * H, 0.0))
    }

    @Test fun usageAndBytes() {
        assertEquals("0 songs · 0 KB", MixModeBufferState.usageLine(0, 0))
        assertEquals("1 song · 5 MB", MixModeBufferState.usageLine(1, 5_000_000))
        assertEquals("2 songs · 1.50 GB", MixModeBufferState.usageLine(2, 1_500_000_000))
        assertEquals("812 KB", MixModeBufferState.formatBytes(812_000))
        assertEquals("12.5 MB", MixModeBufferState.formatBytes(12_500_000))
    }

    @Test fun holdsSortSoonestFirstAndNextExpiry() {
        val sorted = MixModeBufferState.sortedHolds(listOf(hold("b", 5 * H), hold("c", 2 * H), hold("a", 2 * H)))
        assertEquals(listOf("a", "c", "b"), sorted.map { it.songId })
        assertEquals("Next expiry in 2 h.", MixModeBufferState.nextExpiryLine(sorted, 0.0))
        assertNull(MixModeBufferState.nextExpiryLine(emptyList(), 0.0))
    }

    @Test fun rowLimitAndShowAll() {
        val many = (1..30).map { hold("s$it", it * H) }
        assertEquals(25, MixModeBufferState.visibleRows(many, false).size)
        assertEquals(30, MixModeBufferState.visibleRows(many, true).size)
        assertTrue(MixModeBufferState.showAllVisible(30, false))
        assertFalse(MixModeBufferState.showAllVisible(30, true))
        assertFalse(MixModeBufferState.showAllVisible(25, false))
    }

    @Test fun rowCopy() {
        val h = hold("s", 3 * H, parts = listOf("drums", "bass"), bytes = 4_000_000)
        assertEquals("song · drums · bass · 6 MB · expires in 3 h", MixModeBufferState.rowDetail(h, 0.0))
        assertEquals("bass · 1 MB · expires in 3 h",
            MixModeBufferState.rowDetail(hold("s", 3 * H, audio = false, parts = listOf("bass")), 0.0))
        assertEquals("Artist - Title", MixModeBufferState.rowTitle("Title", "Artist", "id"))
        assertEquals("Title", MixModeBufferState.rowTitle("Title", "", "id"))
        assertEquals("id", MixModeBufferState.rowTitle(null, null, "id"))
    }

    @Test fun footerFollowsTtlAndPickedFolderToggle() {
        assertTrue(MixModeBufferState.footer(48.0, false).contains("are temporary"))
        assertTrue(MixModeBufferState.footer(48.0, false).contains("removed on the same schedule"))
        assertTrue(MixModeBufferState.footer(null, true).contains("are kept like downloads. Songs already buffered"))
        assertTrue(MixModeBufferState.footer(null, true).endsWith("kept like downloads."))
    }

    @Test fun pinReasonsAreStable() {
        assertEquals(listOf("demux", "tracks-stems", "sample", "take"),
            listOf(MixModeBufferState.REASON_DEMUX, MixModeBufferState.REASON_TRACKS_STEMS,
                MixModeBufferState.REASON_SAMPLE, MixModeBufferState.REASON_TAKE))
    }

    @Test fun studioPinDropsOnlyThatSongsHoldAndKeepsOthers() {
        val l = TemporaryHoldLedger(listOf(hold("song1", H), hold("song2", H)))
        assertEquals(listOf("song1"), l.pin(listOf("song1")))
        assertFalse(l.isTemporary("song1")); assertTrue(l.isTemporary("song2"))
        assertTrue(l.pin(listOf("never-buffered")).isEmpty()) // no hold = already pinned: no-op
    }
}

package com.levi.pocketdj.screens.history

import com.levi.pocketdj.data.catalog.IndexSong
import com.levi.pocketdj.data.catalog.MergedCatalog
import com.levi.pocketdj.data.history.PlayEvent
import com.levi.pocketdj.data.history.PlayOutcome
import com.levi.pocketdj.data.history.PlaySource
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNotNull
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test

/** History Playback base-row contract (iOS `visibleEvents` / `buildItems` / `PlayRef`). */
class HistoryRowsTest {

    private fun catalog(songs: List<IndexSong> = emptyList()) = MergedCatalog.EMPTY.copy(
        songs = songs,
        songsById = songs.associateBy { it.id },
    )

    private fun play(id: String, songId: String, at: Double, skipped: Boolean? = null) =
        PlayEvent(id = id, songId = songId, playedAt = at, wasSkipped = skipped)

    @Test
    fun hideSkips_dropsOnlyExplicitSkips_nullStaysVisible() {
        val events = listOf(
            play("a", "s1", 1.0, skipped = true),
            play("b", "s2", 2.0, skipped = null), // legacy / live track: not skipped yet
            play("c", "s3", 3.0, skipped = false),
        )
        assertEquals(listOf("a", "b", "c"), visibleEvents(events, hideSkips = false).map { it.id })
        assertEquals(listOf("b", "c"), visibleEvents(events, hideSkips = true).map { it.id })
    }

    @Test
    fun buildItems_hideSkips_isAppliedAtBaseBuild_andKeepsCountsHonest() {
        val events = listOf(play("a", "s1", 1.0, skipped = true), play("b", "s1", 2.0))
        val shown = buildItems(events, catalog(), hideSkips = false, playCountOf = { 2 })
        val hidden = buildItems(events, catalog(), hideSkips = true, playCountOf = { 1 })
        assertEquals(2, shown.rows.size)
        assertEquals(1, hidden.rows.size)
        assertEquals("b", hidden.refOf(hidden.rows[0])!!.eventId)
    }

    @Test
    fun buildItems_reversesStoreOrder_withOneRowPerEvent_andParallelKeys() {
        val events = listOf(play("old", "s1", 1_000.0), play("new", "s1", 3_000.0), play("mid", "s2", 2_000.0))
        val base = buildItems(events, catalog(), hideSkips = false, playCountOf = { 1 })
        // The store is oldest -> newest insertion order; the base is its reverse (the engine sorts by time).
        assertEquals(listOf("mid", "new", "old"), base.rows.map { base.refOf(it)!!.eventId })
        assertEquals(base.rows.size, base.keys.size)
        // A song played twice is two rows with distinct event ids.
        assertEquals(2, base.rows.count { it.song.id == "s1" })
    }

    @Test
    fun playRef_carriesEventFields() {
        val song = IndexSong(id = "s1", artist = "Elton John", name = "Tiny Dancer")
        val e = PlayEvent(
            id = "e1", songId = "s1", playedAt = 5_000.0, source = PlaySource.ALBUM,
            contextName = "Madman Across the Water", wasSkipped = true, listenedFraction = 0.1,
            originInstallId = "other",
        )
        val base = buildItems(
            listOf(e), catalog(listOf(song)), hideSkips = false,
            playCountOf = { 3 }, isFromAnotherDevice = { it.originInstallId == "other" },
        )
        val row = base.rows.single()
        val ref = base.refOf(row)!!
        assertEquals("e1", ref.eventId)
        assertEquals(5_000L, ref.playedAtMs)
        assertEquals(PlaySource.ALBUM, ref.source)
        assertEquals(3, ref.count)
        assertTrue(ref.fromAnotherDevice)
        assertTrue(ref.wasSkipped)
        assertEquals(PlayOutcome.SKIPPED, ref.outcome)
        assertEquals(5_000.0, row.playedAt!!, 0.0)
        assertEquals("Album · Madman Across the Water · on another device", contextLabel(ref))
        assertEquals("Tiny Dancer", row.song.name)
    }

    @Test
    fun missingCatalogSong_fallsBackToEventSnapshot_thenUnknown() {
        val withSnapshot = PlayEvent(id = "1", songId = "gone", playedAt = 1.0, title = "Snap Title", artist = "Snap Artist")
        val bare = PlayEvent(id = "2", songId = "gone2", playedAt = 2.0)
        val base = buildItems(listOf(withSnapshot, bare), catalog(), hideSkips = false, playCountOf = { 1 })
        val byEvent = base.rows.associateBy { base.refOf(it)!!.eventId }
        assertEquals("Snap Title", byEvent.getValue("1").song.name)
        assertEquals("Snap Artist", byEvent.getValue("1").song.artist)
        assertEquals("Unknown", byEvent.getValue("2").song.name)
        assertTrue(base.keys.any { it.contains("snap title") })
    }

    @Test
    fun contextLabel_omitsBlankContext() {
        val ref = PlayRef("e", "s", 0, PlaySource.BROWSER, "  ", 1, false, false)
        assertEquals("Browser", contextLabel(ref))
    }

    @Test
    fun liveRow_requiresMatchingEventAndAnActuallySoundingPlayer() {
        val ref = PlayRef("e1", "s", 0, PlaySource.MIX, null, 1, false, false)
        assertTrue(isLiveRow(ref, "e1", playerPlaying = true))
        assertFalse(isLiveRow(ref, "e1", playerPlaying = false))
        assertFalse(isLiveRow(ref, "e2", playerPlaying = true))
        assertFalse(isLiveRow(ref, null, playerPlaying = true))
    }

    @Test
    fun emptyEvents_yieldEmptyBase() {
        val base = buildItems(emptyList(), catalog(), hideSkips = false, playCountOf = { 0 })
        assertTrue(base.rows.isEmpty())
        assertNull(base.refOf(com.levi.pocketdj.screens.browse.SongRow(IndexSong("x", null, "a", "b"), null, null, "", "")))
        assertNotNull(base.keys)
    }

    @Test
    fun visibleTabs_gateOptionalTabs() {
        assertEquals(listOf(HistoryTab.PLAYBACK, HistoryTab.COLLECTION), visibleHistoryTabs(false, false))
        assertEquals(
            listOf(HistoryTab.PLAYBACK, HistoryTab.COLLECTION, HistoryTab.POCKETS, HistoryTab.FOR_YOU),
            visibleHistoryTabs(true, true),
        )
        assertEquals(
            listOf(HistoryTab.PLAYBACK, HistoryTab.COLLECTION, HistoryTab.FOR_YOU),
            visibleHistoryTabs(false, true),
        )
    }
}

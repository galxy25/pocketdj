package com.levi.pocketdj.data.timeline

import com.levi.pocketdj.data.catalog.IndexAlbum
import com.levi.pocketdj.data.catalog.IndexSong
import java.time.ZoneId
import java.time.ZonedDateTime
import java.util.Locale
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test

class CollectionTimelineTest {
    private val utc = ZoneId.of("UTC")
    private fun ms(y: Int, m: Int, d: Int) = ZonedDateTime.of(y, m, d, 12, 0, 0, 0, utc).toInstant().toEpochMilli().toDouble()
    private fun song(id: String, album: String? = null, name: String = "Song $id", artist: String = "Art") =
        IndexSong(id = id, albumId = album, artist = artist, name = name)
    private fun album(id: String, name: String = "Album $id") = IndexAlbum(id = id, artist = "Art", name = name)
    private fun input(
        songs: List<IndexSong>, added: Map<String, Double>, grain: TimelineGrain = TimelineGrain.SONGS,
        albums: List<IndexAlbum> = emptyList(), plays: Map<String, Int> = emptyMap(),
        after: Double? = null, asc: Boolean = false, q: String = "",
    ) = CollectionTimeline.Input(songs.associateBy { it.id }, albums.associateBy { it.id }, added, plays,
        grain, after, asc, q, utc, Locale.US)

    @Test fun monthDividersAndDirection() {
        val s = listOf(song("a"), song("b"), song("c"), song("d"))
        val added = mapOf("a" to ms(2024, 3, 5), "b" to ms(2024, 3, 1), "c" to ms(2024, 1, 20), "d" to ms(2023, 12, 31))
        val desc = CollectionTimeline.build(input(s, added)).rows
        assertEquals(listOf("a", "b", "c", "d"), desc.map { it.itemId })
        assertEquals(listOf(true, false, true, true), desc.map { it.startsMonth })
        assertEquals(listOf("March 2024", "", "January 2024", "December 2023"), desc.map { it.monthLabel })
        val asc = CollectionTimeline.build(input(s, added, asc = true)).rows
        assertEquals(listOf("d", "c", "b", "a"), asc.map { it.itemId })
        assertEquals("December 2023", asc.first().monthLabel)
        assertEquals(listOf(true, true, true, false), asc.map { it.startsMonth })
    }

    @Test fun tiesBreakOnItemIdAscendingInBothDirections() {
        val s = listOf(song("z"), song("a"), song("m"))
        val t = ms(2024, 5, 5)
        val added = mapOf("z" to t, "a" to t, "m" to t)
        assertEquals(listOf("a", "m", "z"), CollectionTimeline.build(input(s, added)).rows.map { it.itemId })
        assertEquals(listOf("a", "m", "z"), CollectionTimeline.build(input(s, added, asc = true)).rows.map { it.itemId })
    }

    @Test fun undatedCountedNotPlacedAndCutoffCounted() {
        val s = listOf(song("a"), song("b"), song("c"))
        val r = CollectionTimeline.build(input(s, mapOf("a" to ms(2024, 1, 1), "b" to ms(2020, 1, 1)), after = ms(2022, 1, 1)))
        assertEquals(listOf("a"), r.rows.map { it.itemId })
        assertEquals(1, r.summary.undated)
        assertEquals(1, r.summary.beforeCutoff)
        assertEquals(1, r.summary.rows)
    }

    @Test fun songProgressAndSearchFold() {
        val s = listOf(song("a", name = "Café Noir"), song("b", name = "Other"))
        val added = mapOf("a" to ms(2024, 1, 1), "b" to ms(2024, 1, 2))
        val r = CollectionTimeline.build(input(s, added, plays = mapOf("a" to 3), q = "CAFE"))
        assertEquals(1, r.rows.size)
        assertEquals(1, r.rows[0].heard); assertEquals(3, r.rows[0].plays)
        assertTrue(r.rows[0].fullyHeard)
        assertEquals(1.0, r.summary.progress, 0.0)
    }

    @Test fun albumAggregationUsesNewestTrackAndCountsUngrouped() {
        val s = listOf(song("1", "A"), song("2", "A"), song("3", "A"), song("4"), song("5", "B"))
        val added = mapOf("1" to ms(2019, 1, 1), "2" to ms(2019, 1, 2), "3" to ms(2024, 6, 1), "4" to ms(2024, 1, 1))
        val r = CollectionTimeline.build(input(s, added, TimelineGrain.ALBUMS, listOf(album("A"), album("B")),
            plays = mapOf("1" to 2, "3" to 1)))
        assertEquals(1, r.rows.size)
        val row = r.rows[0]
        assertTrue(row.isAlbum); assertEquals("a:A", row.id)
        assertEquals(ms(2024, 6, 1), row.addedAtMs, 0.0)
        assertEquals(2, row.heard); assertEquals(3, row.total); assertEquals(3, row.plays)
        assertFalse(row.fullyHeard)
        assertEquals(1, r.summary.ungrouped)
        assertEquals(1, r.summary.undated) // album B has no dated track
        assertEquals(3, r.summary.songs)
    }

    @Test fun jumpIndexBoundaries() {
        val s = (1..5).map { song("s$it") }
        val added = (1..5).associate { "s$it" to ms(2024, it, 1) }
        val asc = CollectionTimeline.build(input(s, added, asc = true)).rows
        assertEquals(0, CollectionTimeline.jumpIndex(asc, ms(2000, 1, 1), true))
        assertEquals(2, CollectionTimeline.jumpIndex(asc, ms(2024, 3, 1), true))
        assertEquals(3, CollectionTimeline.jumpIndex(asc, ms(2024, 3, 2), true))
        assertEquals(4, CollectionTimeline.jumpIndex(asc, ms(2030, 1, 1), true)) // clamps
        val desc = CollectionTimeline.build(input(s, added)).rows
        assertEquals(0, CollectionTimeline.jumpIndex(desc, ms(2030, 1, 1), false))
        assertEquals(2, CollectionTimeline.jumpIndex(desc, ms(2024, 3, 1), false))
        assertEquals(4, CollectionTimeline.jumpIndex(desc, ms(2000, 1, 1), false))
        assertNull(CollectionTimeline.jumpIndex(emptyList(), 1.0, true))
    }

    @Test fun pickerDayIsLocalStartOfDayInNegativeOffsetZone() {
        val pdt = ZoneId.of("America/Los_Angeles")
        // Material3 DatePicker: Oct 10 2026 -> 00:00 UTC
        val picked = ZonedDateTime.of(2026, 10, 10, 0, 0, 0, 0, ZoneId.of("UTC")).toInstant().toEpochMilli()
        val local = CollectionTimeline.pickerMillisToLocalStartOfDay(picked, pdt)
        assertEquals(ZonedDateTime.of(2026, 10, 10, 0, 0, 0, 0, pdt).toInstant().toEpochMilli().toDouble(), local, 0.0)
        // an Oct 9 evening add stays out of "since Oct 10"
        assertTrue(ZonedDateTime.of(2026, 10, 9, 20, 0, 0, 0, pdt).toInstant().toEpochMilli() < local)
        // round trip seeds the picker with the same calendar day
        assertEquals(picked, CollectionTimeline.localToPickerMillis(local, pdt))
    }

    @Test fun pickerDayInPositiveOffsetZoneKeepsWholeChosenDay() {
        val tokyo = ZoneId.of("Asia/Tokyo")
        val picked = ZonedDateTime.of(2026, 10, 10, 0, 0, 0, 0, ZoneId.of("UTC")).toInstant().toEpochMilli()
        val local = CollectionTimeline.pickerMillisToLocalStartOfDay(picked, tokyo)
        assertEquals(ZonedDateTime.of(2026, 10, 10, 0, 0, 0, 0, tokyo).toInstant().toEpochMilli().toDouble(), local, 0.0)
        assertEquals(picked, CollectionTimeline.localToPickerMillis(local, tokyo))
    }

    @Test fun emptyMessageVariants() {
        assertTrue(CollectionTimeline.emptyMessage(true, null, null, "")!!.startsWith("Building"))
        val some = CollectionTimeline.Result(listOf(CollectionTimeline.Row(false, "a", "t", "a", null, 1.0, 0, 1, 0)))
        assertNull(CollectionTimeline.emptyMessage(false, some, null, ""))
        val none = CollectionTimeline.Result(emptyList(), CollectionTimeline.Summary(beforeCutoff = 3))
        assertTrue(CollectionTimeline.emptyMessage(false, none, 5.0, "")!!.contains("since-date"))
        assertTrue(CollectionTimeline.emptyMessage(false, none, null, "zz")!!.contains("zz"))
        assertTrue(CollectionTimeline.emptyMessage(false, CollectionTimeline.Result(summary = CollectionTimeline.Summary(undated = 2)), null, "")!!.contains("add date"))
    }

    @Test fun cancelCheckAbandonsSupersededBuild() {
        val songs = (0 until 3000).map { song("s$it") }
        val added = songs.associate { it.id to ms(2024, 1, 1) }
        var calls = 0
        val i = CollectionTimeline.Input(songs.associateBy { it.id }, emptyMap(), added, emptyMap(), TimelineGrain.SONGS,
            cancelCheck = { calls++; if (calls >= 2) throw IllegalStateException("cancelled") })
        try { CollectionTimeline.build(i); org.junit.Assert.fail("expected cancel") } catch (e: IllegalStateException) { assertEquals(2, calls) }
    }
}

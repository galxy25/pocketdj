package com.levi.pocketdj.data.timeline

import com.levi.pocketdj.data.catalog.IndexAlbum
import com.levi.pocketdj.data.catalog.IndexSong
import java.text.Normalizer
import java.time.Instant
import java.time.ZoneId
import java.time.format.DateTimeFormatter
import java.util.Locale

/** Which stream the Collection tab shows (iOS `TimelineGrain`). Activity is the ephemeral default. */
enum class TimelineGrain(val label: String) {
    ACTIVITY("Activity"), SONGS("Songs"), ALBUMS("Albums");

    /** Test-tag token (`collection-grain-<token>`). */
    val token: String get() = name.lowercase(Locale.ROOT)
}

/**
 * The pure, off-main core behind the Collection tab's catalog stream (iOS `CollectionTimeline`):
 * every song/album placed on one axis — when it entered the library — filterable by a since-date,
 * reversible, annotated with heard/total progress. Undated items are counted, never placed.
 */
object CollectionTimeline {

    data class Row(
        val isAlbum: Boolean,
        val itemId: String,
        val title: String,
        val artist: String,
        val albumId: String?,
        /** Epoch ms; for an album the NEWEST add-time among its indexed tracks. */
        val addedAtMs: Double,
        val heard: Int,
        val total: Int,
        val plays: Int,
        val startsMonth: Boolean = false,
        val monthLabel: String = "",
    ) {
        /** Namespaced so a song and an album never collide in a LazyColumn key space. */
        val id: String get() = (if (isAlbum) "a:" else "s:") + itemId
        val fullyHeard: Boolean get() = total > 0 && heard == total
    }

    data class Summary(
        val rows: Int = 0,
        val songs: Int = 0,
        val heard: Int = 0,
        val plays: Int = 0,
        val undated: Int = 0,
        val ungrouped: Int = 0,
        val beforeCutoff: Int = 0,
    ) {
        val progress: Double get() = if (songs > 0) heard.toDouble() / songs else 0.0
    }

    data class Result(val rows: List<Row> = emptyList(), val summary: Summary = Summary())

    class Input(
        val songsById: Map<String, IndexSong> = emptyMap(),
        val albumsById: Map<String, IndexAlbum> = emptyMap(),
        val addedAt: Map<String, Double> = emptyMap(),
        val playCounts: Map<String, Int> = emptyMap(),
        val grain: TimelineGrain = TimelineGrain.SONGS,
        val afterMs: Double? = null,
        val ascending: Boolean = false,
        val query: String = "",
        val zone: ZoneId = ZoneId.systemDefault(),
        val locale: Locale = Locale.getDefault(),
        /** Called periodically inside the builder loops; throw (e.g. CancellationException) to abandon a superseded build. */
        val cancelCheck: () -> Unit = {},
    )

    fun build(input: Input): Result {
        val raw = if (input.grain == TimelineGrain.ALBUMS) buildAlbums(input) else buildSongs(input)
        val rows = sortAndMark(raw.rows, input.ascending, input.zone, input.locale)
        return Result(rows, raw.summary.copy(rows = rows.size))
    }

    private fun buildSongs(i: Input): Result {
        val needle = fold(i.query)
        val rows = ArrayList<Row>(minOf(i.songsById.size, 4096))
        var undated = 0; var before = 0; var songs = 0; var heard = 0; var plays = 0
        var tick = 0
        for ((id, song) in i.songsById) {
            if (++tick and 1023 == 0) i.cancelCheck()
            val at = i.addedAt[id]
            if (at == null || at <= 0) { undated++; continue }
            if (i.afterMs != null && at < i.afterMs) { before++; continue }
            if (needle.isNotEmpty() && !fold(song.name + "\n" + song.artist).contains(needle)) continue
            val n = i.playCounts[id] ?: 0
            songs++; plays += n; if (n > 0) heard++
            rows.add(Row(false, id, song.name, song.artist, song.albumId, at, if (n > 0) 1 else 0, 1, n))
        }
        return Result(rows, Summary(songs = songs, heard = heard, plays = plays, undated = undated, beforeCutoff = before))
    }

    /** Album position = NEWEST add-time among its indexed tracks (iOS invariant). */
    private fun buildAlbums(i: Input): Result {
        class Agg { var at = 0.0; var heard = 0; var total = 0; var plays = 0 }
        val needle = fold(i.query)
        val byAlbum = HashMap<String, Agg>()
        var undated = 0; var ungrouped = 0; var before = 0; var songs = 0; var heard = 0; var plays = 0
        var tick = 0
        for ((id, song) in i.songsById) {
            if (++tick and 1023 == 0) i.cancelCheck()
            val at = i.addedAt[id] ?: 0.0
            val aid = song.albumId
            if (aid == null || !i.albumsById.containsKey(aid)) {
                if (at > 0) ungrouped++ else undated++
                continue
            }
            val agg = byAlbum.getOrPut(aid) { Agg() }
            agg.at = maxOf(agg.at, at)
            agg.total++
            val n = i.playCounts[id] ?: 0
            agg.plays += n
            if (n > 0) agg.heard++
        }
        val rows = ArrayList<Row>(minOf(byAlbum.size, 4096))
        for ((aid, agg) in byAlbum) {
            val album = i.albumsById[aid] ?: continue
            if (agg.at <= 0) { undated++; continue }
            if (i.afterMs != null && agg.at < i.afterMs) { before++; continue }
            if (needle.isNotEmpty() && !fold(album.name + "\n" + album.artist).contains(needle)) continue
            songs += agg.total; heard += agg.heard; plays += agg.plays
            rows.add(Row(true, aid, album.name, album.artist, aid, agg.at, agg.heard, agg.total, agg.plays))
        }
        return Result(rows, Summary(songs = songs, heard = heard, plays = plays, undated = undated,
            ungrouped = ungrouped, beforeCutoff = before))
    }

    /** Order by add date in the chosen direction (itemId ascending tiebreak) and stamp month dividers. */
    fun sortAndMark(rows: List<Row>, ascending: Boolean, zone: ZoneId = ZoneId.systemDefault(),
                    locale: Locale = Locale.getDefault()): List<Row> {
        val cmp = Comparator<Row> { a, b ->
            if (a.addedAtMs != b.addedAtMs) {
                if (ascending) a.addedAtMs.compareTo(b.addedAtMs) else b.addedAtMs.compareTo(a.addedAtMs)
            } else a.itemId.compareTo(b.itemId)
        }
        val sorted = rows.sortedWith(cmp)
        val fmt = DateTimeFormatter.ofPattern("LLLL yyyy", locale)
        var lastKey = Int.MIN_VALUE
        return sorted.map { r ->
            val z = Instant.ofEpochMilli(r.addedAtMs.toLong()).atZone(zone)
            val key = z.year * 100 + z.monthValue
            if (key != lastKey) {
                lastKey = key
                r.copy(startsMonth = true, monthLabel = fmt.format(z))
            } else r.copy(startsMonth = false, monthLabel = "")
        }
    }

    /**
     * Index of the first row at/after a cue date in the stream's direction (partition search);
     * clamps to the last row; null for an empty stream.
     */
    fun jumpIndex(rows: List<Row>, atMs: Double, ascending: Boolean): Int? {
        if (rows.isEmpty()) return null
        var lo = 0; var hi = rows.size
        while (lo < hi) {
            val mid = lo + (hi - lo) / 2
            val reached = if (ascending) rows[mid].addedAtMs >= atMs else rows[mid].addedAtMs <= atMs
            if (reached) hi = mid else lo = mid + 1
        }
        return minOf(lo, rows.size - 1)
    }

    /**
     * Material3 DatePicker reports 00:00 UTC of the chosen day; the filter wants LOCAL start of that
     * calendar day (iOS `Calendar.startOfDay`).
     */
    fun pickerMillisToLocalStartOfDay(selectedUtcMs: Long, zone: ZoneId = ZoneId.systemDefault()): Double =
        Instant.ofEpochMilli(selectedUtcMs).atZone(java.time.ZoneOffset.UTC).toLocalDate()
            .atStartOfDay(zone).toInstant().toEpochMilli().toDouble()

    /** Inverse for seeding the picker: the local calendar day of [ms] expressed as 00:00 UTC. */
    fun localToPickerMillis(ms: Double, zone: ZoneId = ZoneId.systemDefault()): Long =
        Instant.ofEpochMilli(ms.toLong()).atZone(zone).toLocalDate()
            .atStartOfDay(java.time.ZoneOffset.UTC).toInstant().toEpochMilli()

    /** Empty / loading copy for the stream; null when there are rows to show. */
    fun emptyMessage(building: Boolean, result: Result?, afterMs: Double?, query: String): String? {
        if (building || result == null) return "Building your timeline\u2026"
        if (result.rows.isNotEmpty()) return null
        val s = result.summary
        return when {
            query.isNotBlank() -> "Nothing matches \u201c${query.trim()}\u201d in this window."
            afterMs != null && s.beforeCutoff > 0 -> "Nothing in this window. Move the since-date back to see ${s.beforeCutoff} earlier."
            afterMs != null -> "Nothing in this window. Move the since-date back."
            s.undated > 0 -> "None of your items have an add date yet, so there is nothing to place on the timeline."
            else -> "Nothing in this window."
        }
    }

    private fun fold(s: String): String {
        if (s.isEmpty()) return ""
        return Normalizer.normalize(s, Normalizer.Form.NFD).replace(Regex("\\p{Mn}+"), "").lowercase(Locale.ROOT)
    }
}

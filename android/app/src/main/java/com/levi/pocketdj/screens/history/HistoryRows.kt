package com.levi.pocketdj.screens.history

import com.levi.pocketdj.data.catalog.IndexSong
import com.levi.pocketdj.data.catalog.MergedCatalog
import com.levi.pocketdj.data.history.PlayEvent
import com.levi.pocketdj.data.history.PlayOutcome
import com.levi.pocketdj.data.history.PlaySource
import com.levi.pocketdj.screens.browse.Fmt
import com.levi.pocketdj.screens.browse.Genre
import com.levi.pocketdj.screens.browse.SongRow
import java.util.IdentityHashMap

/**
 * What the History row chrome needs beyond the shared song row (iOS `PlayRef`): identity is the
 * EVENT id — a song played three times is three rows. Title/artist on the paired [SongRow]
 * resolve live-catalog first, event snapshot second, so history outlives the catalog.
 */
internal data class PlayRef(
    val eventId: String,
    val songId: String,
    val playedAtMs: Long,
    val source: PlaySource,
    val contextName: String?,
    /** Total plays of this song in the log (badge shows only when > 1). */
    val count: Int,
    val fromAnotherDevice: Boolean,
    val wasSkipped: Boolean,
    val outcome: PlayOutcome = PlayOutcome.UNKNOWN,
    val artUrl: String? = null,
)

/**
 * The expensive per-event base the filter/sort engine runs over: [rows] and [keys] are PARALLEL
 * (folded search haystacks); [refs] maps each row INSTANCE (identity — two identical plays must
 * not collide) to its [PlayRef].
 */
internal class HistoryBase(
    val rows: List<SongRow>,
    val keys: List<String>,
    private val refs: IdentityHashMap<SongRow, PlayRef>,
) {
    fun refOf(row: SongRow): PlayRef? = refs[row]

    companion object {
        val EMPTY = HistoryBase(emptyList(), emptyList(), IdentityHashMap())
    }
}

/**
 * The events the Playback timeline builds rows from under the current Hide-skips setting (iOS
 * `visibleEvents`). `wasSkipped == null` — legacy docs, peer docs, and the LIVE track whose
 * verdict hasn't happened yet — reads as NOT skipped and stays visible.
 */
internal fun visibleEvents(events: List<PlayEvent>, hideSkips: Boolean): List<PlayEvent> =
    if (!hideSkips) events else events.filter { it.wasSkipped != true }

/**
 * Build the base rows (iOS `buildItems`, timeline mode): one row per event, NEWEST FIRST so the
 * engine's stable tiebreak keeps newest-first among equal keys. Hide-skips is applied HERE, on
 * the events, so it is part of the base key (a hidden skip must not inflate nothing else).
 * [events] arrive oldest -> newest (the store's insertion order).
 */
internal fun buildItems(
    events: List<PlayEvent>,
    catalog: MergedCatalog,
    hideSkips: Boolean,
    playCountOf: (songId: String) -> Int,
    isFromAnotherDevice: (PlayEvent) -> Boolean = { false },
): HistoryBase {
    val visible = visibleEvents(events, hideSkips)
    if (visible.isEmpty()) return HistoryBase.EMPTY
    val rows = ArrayList<SongRow>(visible.size)
    val keys = ArrayList<String>(visible.size)
    val refs = IdentityHashMap<SongRow, PlayRef>(visible.size * 2)
    for (event in visible.asReversed()) {
        val live = catalog.songsById[event.songId]
        val song = live ?: IndexSong(
            id = event.songId,
            artist = event.artist.orEmpty(),
            name = event.title ?: "Unknown",
        )
        val album = live?.albumId?.let { catalog.albumsById[it] }
        val albumName = album?.name
        val playedAtMs = event.playedAt.toLong()
        val key = Fmt.fold("${song.name}\n${song.artist}\n${albumName.orEmpty()}")
        val row = SongRow(
            song = song,
            albumName = albumName,
            source = catalog.sourceOfSong[event.songId],
            genreCategory = Genre.category(album?.genre),
            searchKey = key,
            playedAt = playedAtMs.toDouble(),
        )
        rows += row
        keys += key
        refs[row] = PlayRef(
            eventId = event.id,
            songId = event.songId,
            playedAtMs = playedAtMs,
            source = event.source,
            contextName = event.contextName,
            count = playCountOf(event.songId),
            fromAnotherDevice = isFromAnotherDevice(event),
            wasSkipped = event.wasSkipped ?: false,
            outcome = event.outcome,
            artUrl = album?.artCandidates()?.firstOrNull(),
        )
    }
    return HistoryBase(rows, keys, refs)
}

/** `Source · contextName · on another device` — the label half of the context line. */
internal fun contextLabel(ref: PlayRef): String {
    var label = ref.source.label
    if (!ref.contextName.isNullOrBlank()) label += " · ${ref.contextName}"
    if (ref.fromAnotherDevice) label += " · on another device"
    return label
}

/**
 * Live speaker indicator rule (iOS `isLiveRow`): the row is the CURRENT event AND either the
 * sequencer still owns it (running, even while paused) or something is actually sounding.
 */
internal fun isLiveRow(
    ref: PlayRef,
    currentEventId: String?,
    playerPlaying: Boolean,
    sequencerRunning: Boolean = false,
): Boolean =
    currentEventId != null && ref.eventId == currentEventId && (sequencerRunning || playerPlaying)

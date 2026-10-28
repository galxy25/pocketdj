package com.levi.pocketdj.mix.engine

import com.levi.pocketdj.mix.model.Deck
import com.levi.pocketdj.playback.PlayContext
import com.levi.pocketdj.playback.PlayStarted

/**
 * Turns the Mix decks' play / end reports into History rows and per-play OUTCOMES (port of iOS
 * `State/MixPlayOutcomeBridge.swift`) - the Mix twin of `SkipTracker`, which only ever hears from
 * the sequencer and so never saw a Mix or Auto-DJ play.
 *
 * LIFECYCLE: [onSongPlayed] (engine `onSongPlayed`, once per deck load) emits a `source = "mix"`
 * [PlayStarted] on the play-event seam (contextName = the auto-mix crate label) and maps the deck to
 * the history event the store records for it. The store records asynchronously off the bus, so the
 * event id is resolved by [findEvent] with a short retry; an end that races the resolution is held
 * and applied when it lands. [onDeckTrackEnded] later reports the SAME deck's played/duration seconds
 * and WHY it ended: the fraction goes onto the event, and a skip/replaced under 50 % is a skip.
 *
 * The mapping is keyed by DECK, never song id: in a repeat-one auto mix both decks hold the same song
 * and the incoming deck's play must not capture the outgoing deck's end. Natural ends and stops are
 * never skips, however little played. Only the FIRST end per event applies.
 *
 * Pure and injectable (no engine reference): the whole verdict table is JVM-testable.
 */
class MixPlayOutcomeBridge(
    /** Emits onto the play-event seam (production: `PlayEventBus.emit`). */
    private val emit: (PlayStarted) -> Unit,
    /**
     * The history event for [songId]'s play at [atMs] (production: PlayHistoryStore). While [final] is
     * false only an event stamped exactly [atMs] counts; on the last attempt the newest local event for
     * the song stands in (the 30 s window collapsed this play into it).
     */
    private val findEvent: (songId: String, atMs: Long, final: Boolean) -> String?,
    private val noteListened: (eventId: String, fraction: Double) -> Unit,
    private val markSkipped: (eventId: String) -> Unit,
    private val wasSkipped: (eventId: String) -> Boolean,
    /** Cumulative skip-count sink (production: PlayStatsStore.noteSkipped). */
    private val noteSkip: (songId: String) -> Unit = {},
    /** Title/artist snapshot of the deck's track for the history row. */
    private val trackInfo: (Deck) -> Pair<String, String>? = { null },
    /** The auto-mix crate label (`AutoDj.sourceLabel`); null for a hand-driven mix. */
    private val contextLabel: () -> String? = { null },
    private val nowMs: () -> Long = System::currentTimeMillis,
    /** Runs [block] later, off the caller: production hops to a coroutine; tests run it inline. */
    private val resolveAsync: ((attempt: (final: Boolean) -> Boolean) -> Unit)? = null,
) {
    private class Entry(val songId: String, var eventId: String?, var pendingEnd: End?)
    private class End(val played: Double, val duration: Double, val reason: MixTrackEndReason)

    private val lock = Any()
    private val entries = HashMap<Deck, Entry>()
    private val endedOrder = ArrayDeque<String>()
    private val endedSet = HashSet<String>()

    /** Engine hook: [deck] started playing [songId]'s current load. */
    fun onSongPlayed(songId: String, deck: Deck) {
        val at = nowMs()
        val entry = Entry(songId, null, null)
        synchronized(lock) { entries[deck] = entry }
        val info = trackInfo(deck)
        emit(
            PlayStarted(
                songId = songId,
                title = info?.first,
                artist = info?.second,
                context = PlayContext(PlayContext.SOURCE_MIX, contextId = null, contextName = contextLabel()),
                atMs = at,
            ),
        )
        val attempt = { final: Boolean -> resolve(deck, entry, songId, at, final) }
        val runner = resolveAsync
        if (runner != null) runner(attempt) else { attempt(false) || attempt(true) }
    }

    /** One resolution attempt; true = settled (stop retrying). */
    private fun resolve(deck: Deck, entry: Entry, songId: String, at: Long, final: Boolean): Boolean {
        val id = findEvent(songId, at, final)
        var apply: End? = null
        var settled = false
        synchronized(lock) {
            if (entries[deck] !== entry) return true // superseded by a newer load
            if (id == null) {
                if (!final) return false
                entries.remove(deck) // never let a stale mapping take this load's end
                settled = true
            } else {
                entry.eventId = id
                apply = entry.pendingEnd
                if (apply != null) entries.remove(deck)
                settled = true
            }
        }
        apply?.let { applyEnd(id!!, songId, it) }
        return settled
    }

    /** Engine hook: [deck]'s track stopped being the music. Seconds are SOURCE seconds. */
    fun onDeckTrackEnded(songId: String, played: Double, duration: Double, reason: MixTrackEndReason, deck: Deck) {
        val end = End(played, duration, reason)
        val id: String
        synchronized(lock) {
            val entry = entries[deck] ?: return
            if (entry.songId != songId) { entries.remove(deck); return }
            val eid = entry.eventId
            if (eid == null) {
                if (entry.pendingEnd == null) entry.pendingEnd = end // first end wins
                return
            }
            entries.remove(deck)
            id = eid
        }
        applyEnd(id, songId, end)
    }

    private fun applyEnd(eventId: String, songId: String, end: End) {
        synchronized(lock) {
            if (!endedSet.add(eventId)) return // a second end for the same event
            endedOrder.addLast(eventId)
            if (endedOrder.size > ENDED_CAP) endedSet.remove(endedOrder.removeFirst())
        }
        // Unknown (zero) duration reports nothing - never guess against the listener.
        if (!(end.duration > 0) || !end.played.isFinite() || !end.duration.isFinite()) return
        val fraction = (end.played / end.duration).coerceIn(0.0, 1.0)
        noteListened(eventId, fraction)
        if ((end.reason != MixTrackEndReason.SKIP && end.reason != MixTrackEndReason.REPLACED) || fraction >= 0.5) return
        val already = wasSkipped(eventId) // a peer's verdict synced in => the cumulative count was spent
        markSkipped(eventId)
        if (!already) noteSkip(songId)
    }

    /** Test/diagnostic: is [deck] currently mapped to an event (or awaiting resolution)? */
    internal fun isMapped(deck: Deck): Boolean = synchronized(lock) { entries.containsKey(deck) }

    companion object {
        private const val ENDED_CAP = 256
        /** Mirrors `PlayHistoryStore.RECOUNT_WINDOW_MS`. */
        private const val RECOUNT_WINDOW_MS = 30_000.0

        /**
         * Event lookup rule for [findEvent]: the row stamped exactly [atMs]; on the [final] attempt the newest
         * local row for the song within the 30 s re-count window stands in (this play was collapsed into it).
         * [events] oldest -> newest as (id, songId, playedAt, local).
         */
        fun <E> pickEvent(
            events: List<E>, songId: String, atMs: Long, final: Boolean,
            id: (E) -> String, song: (E) -> String, playedAt: (E) -> Double, local: (E) -> Boolean,
        ): String? {
            val mine = events.filter { song(it) == songId && local(it) }
            mine.lastOrNull { playedAt(it) == atMs.toDouble() }?.let { return id(it) }
            if (!final) return null
            val last = mine.lastOrNull() ?: return null
            val dt = atMs - playedAt(last)
            return if (dt >= 0 && dt < RECOUNT_WINDOW_MS) id(last) else null
        }
    }
}

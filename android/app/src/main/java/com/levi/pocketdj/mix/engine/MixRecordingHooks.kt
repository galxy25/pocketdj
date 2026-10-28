package com.levi.pocketdj.mix.engine

import com.levi.pocketdj.mix.model.Deck
import com.levi.pocketdj.mix.model.LoadedTrack
import com.levi.pocketdj.mix.store.MixEventKind
import com.levi.pocketdj.mix.store.MixSessionRecorder

/**
 * The engine's outbound observation points: the session-log [recorder] (the store owns the
 * timeline, coalescing and persistence), the play-stats hook, and the play-outcome (History)
 * hook. All main-thread.
 *
 * Per-load bookkeeping mirrors iOS: [onSongPlayed] fires ONCE PER DECK LOAD (a pause->play resume
 * is the same listen); [onDeckTrackEnded] fires at most once per load and only for a load that
 * actually played, with the load's HIGH-WATER playhead (not the live one: a rewind before the deck
 * is loaded over must not turn a finished song into a skip).
 */
class MixRecordingHooks {
    /** The mix-session log sink; null = recording is a no-op (tests, restore, before wiring). */
    @Volatile var recorder: MixSessionRecorder? = null

    /** (songId, deck): fired when a deck first plays its current load. */
    var onSongPlayed: ((songId: String, deck: Deck) -> Unit)? = null

    /** (songId, playedSeconds, durationSeconds, reason, deck). */
    var onDeckTrackEnded: ((songId: String, played: Double, duration: Double, reason: MixTrackEndReason, deck: Deck) -> Unit)? = null

    private val playNoted = HashSet<Deck>()
    private val endReported = HashSet<Deck>()
    private val highWater = HashMap<Deck, Double>()

    fun emit(
        kind: MixEventKind, deck: Deck?, loaded: LoadedTrack?, posSeconds: Double?,
        param: String?, value: Double?, flag: Boolean?, slot: Int?,
    ) {
        val r = recorder ?: return
        r.logEvent(
            kind, deck?.label, loaded?.songId, loaded?.title, loaded?.artist, null, null,
            param, value, flag, posSeconds?.let { (it * 1000).toInt() }, slot,
        )
    }

    /** The `.load` event carries the track's bpm/camelot so the corpus is self-describing. */
    fun emitLoad(deck: Deck, loaded: LoadedTrack) {
        recorder?.logEvent(
            MixEventKind.Load, deck.label, loaded.songId, loaded.title, loaded.artist,
            loaded.bpm, loaded.camelot, null, null, null, 0, null,
        )
    }

    /** A deck transitioned to playing. Marks the song played in the session (deduped there). */
    fun notePlay(deck: Deck, songId: String?) {
        if (songId == null) return
        recorder?.notePlayed(songId)
        if (playNoted.add(deck)) onSongPlayed?.invoke(songId, deck)
    }

    fun noteHighWater(deck: Deck, sec: Double) {
        if (sec > (highWater[deck] ?: 0.0)) highWater[deck] = sec
    }

    /** No-op unless this load played and has not reported yet: the first reason wins. */
    fun reportEnded(deck: Deck, songId: String?, position: Double, duration: Double, reason: MixTrackEndReason) {
        if (songId == null || deck !in playNoted || deck in endReported) return
        endReported.add(deck)
        onDeckTrackEnded?.invoke(songId, maxOf(position, highWater[deck] ?: 0.0), duration, reason, deck)
    }

    /** A fresh load cycle: the next play is a new play, the next end a new end. */
    fun resetLoadCycle(deck: Deck) {
        playNoted.remove(deck)
        endReported.remove(deck)
        highWater.remove(deck)
    }

    fun hasPlayedThisLoad(deck: Deck) = deck in playNoted
}

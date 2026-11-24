package com.levi.pocketdj.data.recs

import com.levi.pocketdj.data.catalog.MergedCatalog
import com.levi.pocketdj.data.games.puzzle.PuzzleSimilarity
import com.levi.pocketdj.playback.sequencer.SequencerState

/**
 * The ONE shared 👍/👎 target for whatever is playing (port of iOS `currentRecTarget` /
 * `currentRecVerdict` / `recordNowPlayingFeedback`). Now Playing, the notification, the widget and
 * Android Auto all file through this object, so "same store, same wire event" is enforced by there
 * being exactly one record function.
 *
 * Invariants:
 *  - The target is the sequencer's CURRENT row plus `scopeForPlaying`; null unless the standalone
 *    player owns audio (a run is going, not held for resume, and no Mix session owns the deck) AND
 *    the row is one of the stamped recommendation list's rows. Surfaces hide on null.
 *  - A second tap on the lit thumb clears it (toggle).
 *  - A 👍 that LANDS accepted also adds to the scoped collection; reserved scopes (zone/new) stay pure
 *    feedback; the undo tap never un-adds.
 *  - It never touches the transport: no skip, no pause, not even on a 👎.
 */
class NowPlayingFeedback(
    private val feedback: RecFeedbackStore,
    private val sequencer: () -> SequencerState,
    private val mixSessionActive: () -> Boolean,
    private val catalog: () -> MergedCatalog?,
    /** (songId, scope) -> added. Production: [com.levi.pocketdj.data.collections.CollectionsStore.addAcceptedSong]. */
    private val addAccepted: (String, String) -> Boolean,
) {
    data class Target(val songId: String, val scope: String)

    fun currentTarget(): Target? = targetFor(feedback, sequencer(), mixSessionActive())

    /** The verdict standing for the current track (filled vs hollow thumb). */
    fun currentVerdict(): RecFeedbackStore.Verdict? {
        val t = currentTarget() ?: return null
        return feedback.verdict(t.songId, t.scope)
    }

    /**
     * Record [verdict] for whatever is playing RIGHT NOW. Returns the verdict that LANDED (null = the tap
     * cleared an existing one, or there is no target).
     */
    fun record(verdict: RecFeedbackStore.Verdict, surface: RecFeedbackStore.Surface): RecFeedbackStore.Verdict? {
        val t = currentTarget() ?: return null
        val cat = catalog()
        val song = cat?.songsById?.get(t.songId)
        val genre = song?.albumId?.let { cat.albumsById[it] }?.genre
        val landed = feedback.toggle(
            songId = t.songId,
            to = verdict,
            scope = t.scope,
            surface = surface,
            artistKey = song?.let { PuzzleSimilarity.artistKey(it.artist) },
            genre = SimilarityFamilies.canonicalGenre(genre),
        )
        if (landed == RecFeedbackStore.Verdict.ACCEPTED) addAccepted(t.songId, t.scope)
        return landed
    }

    companion object {
        /** Pure target rule (testable without the graph). */
        fun targetFor(feedback: RecFeedbackStore, seq: SequencerState, mixActive: Boolean): Target? {
            if (!seq.isRunning || seq.isHeldForResume || mixActive) return null
            val row = seq.queue.getOrNull(seq.index) ?: return null
            val scope = feedback.scopeForPlaying(row.id) ?: return null
            return Target(row.id, scope)
        }
    }
}

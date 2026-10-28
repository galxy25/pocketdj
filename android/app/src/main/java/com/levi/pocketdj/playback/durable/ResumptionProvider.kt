package com.levi.pocketdj.playback.durable

import com.levi.pocketdj.playback.sequencer.SetlistSequencer

/**
 * Launch-time restore (iOS `restorePersistedSessionIfIdle`): rebuild the deck from the durable
 * snapshot HELD - fresh uids, index clamped, running = true, NO audio, NO MediaSession activation and
 * NO file write (the file's mtime means "last actually played here"; a restore is not a write -
 * [PlaybackSessionStore.currentSnapshot] stays null until the first real play adopts the session).
 */
class SessionRestorer(
    private val store: PlaybackSessionStore,
    private val sequencer: SetlistSequencer,
    /** Any backend (Exo, Apple Music, Mix) is audibly playing: an intent/widget started playback first. */
    private val anyBackendPlaying: () -> Boolean = { false },
    private val disabled: () -> Boolean = { System.getProperty(DISABLE_PROPERTY) != null },
) {
    /** True when a held deck was installed. Skipped when running / playing / disabled / nothing persisted. */
    fun restoreIfIdle(): Boolean {
        if (disabled()) return false
        if (sequencer.isRunning || anyBackendPlaying()) return false
        val snap = store.load() ?: return false
        restore(snap)
        return sequencer.isRunning
    }

    fun restore(snap: SessionSnapshot) {
        if (sequencer.isRunning || snap.queue.isEmpty()) return
        val items = snap.toQueueItems()
        sequencer.restoreHeld(
            items = items,
            index = snap.index.coerceIn(0, items.lastIndex),
            sourceSetlistId = snap.source.id,
            context = snap.toContext(),
            origin = snap.toOrigin(),
            repeatMode = snap.repeat(),
            shuffle = snap.shuffleEnabled == true,
            resumeAtMs = snap.positionMs.takeIf { it > 0 },
            sessionId = snap.sessionId,
        )
    }

    companion object {
        /** `-DPDJ_DISABLE_SESSION_RESTORE=1` (the iOS env seam) for tests / UI automation. */
        const val DISABLE_PROPERTY = "PDJ_DISABLE_SESSION_RESTORE"
    }
}

/**
 * What the system's playback-resumption request (media button / Bluetooth after the app was killed)
 * shows for the persisted run. The held rule: the request restores the deck and surfaces the card
 * data, but NEVER starts audio - the first explicit play (or a latched remote play <= 15 s, handled
 * by the forwarding player) resumes it.
 */
data class ResumptionSnapshot(
    val songId: String,
    val title: String,
    val artist: String,
    val index: Int,
    val queueSize: Int,
    val positionMs: Long,
) {
    companion object {
        fun from(snap: SessionSnapshot): ResumptionSnapshot? {
            val i = snap.index.coerceIn(0, snap.queue.lastIndex.coerceAtLeast(0))
            val row = snap.queue.getOrNull(i) ?: return null
            return ResumptionSnapshot(row.songId, row.title, row.artist, i, snap.queue.size, snap.positionMs)
        }
    }
}

/** Service-side entry for `MediaSession.Callback.onPlaybackResumption`. */
class ResumptionProvider(private val restorer: SessionRestorer, private val store: PlaybackSessionStore) {
    /**
     * Restore the held queue (idempotent; a running deck stays untouched) and report the current row.
     * Null when there is nothing to resume. Never plays and never writes the file.
     */
    fun onPlaybackResumption(): ResumptionSnapshot? {
        restorer.restoreIfIdle()
        val snap = store.load() ?: return null
        return ResumptionSnapshot.from(snap)
    }
}

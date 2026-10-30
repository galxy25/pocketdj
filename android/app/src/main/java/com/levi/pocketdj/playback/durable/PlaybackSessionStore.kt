package com.levi.pocketdj.playback.durable

import com.levi.pocketdj.data.store.VersionedJsonWriter
import java.io.File

/**
 * Durable Playback Session store (iOS `PlaybackSessionStore`): the single overwrite-in-place
 * snapshot of the app-scoped sequencer run, written in real time. Structural changes persist
 * immediately; position refreshes while playing are throttled to [positionWriteIntervalMs]; a
 * pause/resume transition persists immediately. Every write carries a monotonic version through the
 * shared [VersionedJsonWriter], so a late stale snapshot can never overwrite a newer one, and the
 * delete [clear] issues cannot be resurrected by a straggler.
 *
 * Thread-safety: all mutators are synchronized (the writer encodes on its own executor).
 */
class PlaybackSessionStore(
    val file: File,
    private val writer: VersionedJsonWriter = VersionedJsonWriter(file),
    private val clock: () -> Long = System::currentTimeMillis,
    /** Min ms between position-only writes while playing. */
    var positionWriteIntervalMs: Long = 5_000,
) {
    private val lock = Any()
    private var current: SessionSnapshot? = null
    private var version = 0L
    private var lastWriteAt = Long.MIN_VALUE

    /** The in-memory truth of the current run's snapshot (null = no live session on this launch). */
    val currentSnapshot: SessionSnapshot? get() = synchronized(lock) { current }

    /** A STRUCTURAL change (play, index move, live edit, repeat/shuffle): persists immediately. */
    fun save(snapshot: SessionSnapshot) = synchronized(lock) {
        val now = clock()
        current = snapshot.copy(updatedAt = now.toDouble())
        writeNow(now)
    }

    /**
     * Position / play-state refresh for the CURRENT session. Throttled while playing; a pause/resume
     * TRANSITION writes immediately; steady paused state writes nothing. No-op without a live session
     * (a held restore does not adopt one until real playback starts).
     */
    fun updatePosition(ms: Long, isPlaying: Boolean) = synchronized(lock) {
        val snap = current ?: return
        val now = clock()
        val wasPlaying = snap.isPlaying
        current = snap.copy(positionMs = ms, isPlaying = isPlaying, updatedAt = now.toDouble())
        if (isPlaying != wasPlaying) {
            writeNow(now)
        } else if (isPlaying && now - lastWriteAt >= positionWriteIntervalMs) {
            writeNow(now)
        }
    }

    /** Block until every queued disk write/delete has executed (reset drain). */
    fun awaitWrites() = writer.awaitIdle()

    /** End of the session (stop / natural end-of-set): forget it and delete the file. */
    fun clear() = synchronized(lock) {
        current = null
        version++
        writer.delete(version)
    }

    /** The persisted snapshot or null; lenient (corrupt / old / empty -> null). */
    /** Number of file decodes (test seam: the resumption path must decode exactly once). */
    @Volatile var loadCount = 0
        private set

    fun load(): SessionSnapshot? = try {
        loadCount++
        if (!file.exists()) null else SessionSnapshot.decode(file.readText())
    } catch (_: Exception) {
        null
    }

    /**
     * Force-persist the live session synchronously (app -> background) so an OS kill right after
     * ON_STOP cannot drop the latest position. Raises the writer floor first, so a queued older
     * snapshot cannot regress it.
     */
    fun flush() = synchronized(lock) {
        val snap = current ?: return
        val now = clock()
        version++
        lastWriteAt = now
        val s = snap.copy(updatedAt = now.toDouble())
        current = s
        writer.flushNow(version) { SessionSnapshot.encode(s) }
    }

    private fun writeNow(now: Long) {
        val snap = current ?: return
        version++
        lastWriteAt = now
        writer.write(version) { SessionSnapshot.encode(snap) }
    }
}

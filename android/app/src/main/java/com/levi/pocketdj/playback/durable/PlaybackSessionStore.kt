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

    private var extrasState = SnapshotExtras()

    /**
     * The iOS-owned optional state (Mix Mode, FX Lock, DJ Mode, unknown top-level keys) carried across
     * writes: seeded from the file by [load] / adopted from each saved snapshot, overlaid onto any snapshot
     * saved without it. Later packages read it to restore HELD and replace it via [updateExtras].
     */
    val extras: SnapshotExtras get() = synchronized(lock) { extrasState }

    /** Replace the carried extras (e.g. Mix Mode toggled off); the live snapshot adopts them and persists. */
    fun updateExtras(transform: (SnapshotExtras) -> SnapshotExtras) = synchronized(lock) {
        extrasState = transform(extrasState)
        val snap = current ?: return
        val now = clock()
        current = snap.copy(
            npMixMode = extrasState.npMixMode, fxLock = extrasState.fxLock, djMode = extrasState.djMode,
            unknownKeys = extrasState.unknownKeys, updatedAt = now.toDouble(),
        )
        writeNow(now)
    }

    /** The in-memory truth of the current run's snapshot (null = no live session on this launch). */
    val currentSnapshot: SessionSnapshot? get() = synchronized(lock) { current }

    /** A STRUCTURAL change (play, index move, live edit, repeat/shuffle): persists immediately. */
    fun save(snapshot: SessionSnapshot) = synchronized(lock) {
        val now = clock()
        // Extras belong to the session they came from; a different session starts clean.
        val owner = extrasState.sessionId
        if (owner != null && owner != snapshot.sessionId) extrasState = SnapshotExtras()
        val merged = extrasState.overlay(snapshot)
        extrasState = SnapshotExtras.of(merged)
        current = merged.copy(updatedAt = now.toDouble())
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
        extrasState = SnapshotExtras()
        version++
        writer.delete(version)
    }

    /** The persisted snapshot or null; lenient (corrupt / old / empty -> null). */
    /** Number of file decodes (test seam: the resumption path must decode exactly once). */
    @Volatile var loadCount = 0
        private set

    fun load(): SessionSnapshot? = try {
        loadCount++
        if (!file.exists()) null else SessionSnapshot.decode(file.readText())?.also { adoptExtras(it) }
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

    /** A loaded file seeds the carried extras unless a live session already owns them. */
    private fun adoptExtras(snap: SessionSnapshot) = synchronized(lock) {
        if (current == null) extrasState = SnapshotExtras.of(snap)
    }

    private fun writeNow(now: Long) {
        val snap = current ?: return
        version++
        lastWriteAt = now
        writer.write(version) { SessionSnapshot.encode(snap) }
    }
}

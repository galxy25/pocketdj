package com.levi.pocketdj.data.recs

import java.io.File
import kotlin.coroutines.CoroutineContext
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.asStateFlow
import kotlinx.coroutines.withContext

/**
 * Durable holder of the frozen For You result (port of iOS `ForYouFeedStore`).
 * File `pocketdj-foryou-feed.json` is wire-compatible with iOS and follows the Apple ID via CloudSync.
 *
 * A document with `schemaVersion < 3` reads as NO cache. [refresh] never overwrites a good cache
 * with a ranking of nothing (empty catalog = transient), runs the build on [buildContext], commits,
 * then optionally folds a cloud zone in as a SECOND commit (skipped when it changes nothing).
 * Construction does a blocking read; build off Main.
 */
class ForYouFeedStore(
    private val file: File,
    private val buildContext: CoroutineContext = Dispatchers.Default,
) {
    data class State(
        val snapshot: ForYouFeedSnapshot = ForYouFeedSnapshot(),
        val isRefreshing: Boolean = false,
        /** Bumped on every commit / reload / clear: the grid's recompute key. */
        val revision: Int = 0,
    )

    private val lock = Any()
    private val _state = MutableStateFlow(State())
    val state: StateFlow<State> = _state.asStateFlow()

    val snapshot: ForYouFeedSnapshot get() = _state.value.snapshot
    val isRefreshing: Boolean get() = _state.value.isRefreshing
    val revision: Int get() = _state.value.revision

    init {
        readCurrent()?.let { _state.value = State(snapshot = it) }
    }

    /**
     * Recompute. No-op if a refresh is running or [inputs] has no songs (never stamp an empty
     * ranking). [cloudZone] is awaited AFTER the on-device commit so the grid is never blocked on
     * the network.
     */
    suspend fun refresh(inputs: ForYouFeedInputs, cloudZone: (suspend () -> List<ForYouCloudZoneRow>)? = null) {
        if (inputs.songs.isEmpty()) return
        synchronized(lock) {
            if (_state.value.isRefreshing) return
            _state.value = _state.value.copy(isRefreshing = true)
        }
        try {
            val built = withContext(buildContext) { ForYouFeedBuilder.build(inputs) }
            commit(built)

            val rows = cloudZone?.invoke() ?: return
            if (rows.isEmpty()) return
            val shaped = withContext(buildContext) { ForYouFeedBuilder.applyingCloudZone(built, rows, inputs) }
            // Identical => the cloud answer shaped away to nothing; don't burn a revision.
            if (shaped == built) return
            commit(shaped)
        } finally {
            synchronized(lock) { _state.value = _state.value.copy(isRefreshing = false) }
        }
    }

    /** Make [next] the current snapshot and persist it. */
    fun commit(next: ForYouFeedSnapshot) {
        synchronized(lock) {
            val cur = _state.value
            _state.value = cur.copy(snapshot = next, revision = cur.revision + 1)
            save(next)
        }
    }

    fun songIds(forTileId: String): List<String>? = snapshot.songIds(forTileId)
    fun reasons(forTileId: String): Map<String, String> = snapshot.reasons(forTileId)
    fun soundIds(forTileId: String): Set<String> = snapshot.soundIds(forTileId)

    // ── CloudSync ───────────────────────────────────────────────────────────────────────

    val syncFile: File get() = file

    /**
     * CloudSync write seam. Lands the bytes only when they decode, are current-schema, and are
     * FRESHER than ours; otherwise keeps ours and re-stamps the file mtime to OUR refresh so the
     * watermark CloudSync reads right after still describes our state.
     */
    fun applyPulledPayload(data: ByteArray) {
        synchronized(lock) {
            val incoming = runCatching { ForYouFeedSnapshot.decode(data.toString(Charsets.UTF_8)) }.getOrNull()
            if (incoming == null || !incoming.isCurrent || incoming.refreshedAtMs <= snapshot.refreshedAtMs) {
                stampMtime(snapshot.refreshedAtMs)
                return
            }
            runCatching { writeAtomically(data) }
            stampMtime(incoming.refreshedAtMs)
        }
    }

    /** Re-read the file after a pull; true when a fresher current-schema snapshot was adopted. */
    fun reloadFromDisk(): Boolean = synchronized(lock) {
        val doc = readCurrent() ?: return false
        if (doc.refreshedAtMs <= snapshot.refreshedAtMs) return false
        val cur = _state.value
        _state.value = cur.copy(snapshot = doc, revision = cur.revision + 1)
        true
    }

    fun clear() {
        synchronized(lock) {
            val cur = _state.value
            _state.value = cur.copy(snapshot = ForYouFeedSnapshot(), revision = cur.revision + 1)
            runCatching { file.delete() }
        }
    }

    // ── Persistence ─────────────────────────────────────────────────────────────────────

    private fun readCurrent(): ForYouFeedSnapshot? {
        val text = runCatching { file.readText(Charsets.UTF_8) }.getOrNull() ?: return null
        return ForYouFeedSnapshot.decode(text)?.takeIf { it.isCurrent }
    }

    private fun save(s: ForYouFeedSnapshot) {
        runCatching { writeAtomically(s.encode().toByteArray(Charsets.UTF_8)) }
        stampMtime(s.refreshedAtMs)
    }

    private fun writeAtomically(bytes: ByteArray) {
        file.parentFile?.mkdirs()
        val tmp = File(file.parentFile, file.name + ".tmp")
        tmp.writeBytes(bytes)
        if (!tmp.renameTo(file)) {
            file.writeBytes(bytes)
            tmp.delete()
        }
    }

    private fun stampMtime(refreshedAtMs: Double) {
        if (!file.exists()) return
        runCatching { file.setLastModified(maxOf(0.0, refreshedAtMs).toLong()) }
    }

    companion object {
        const val FILE_NAME = "pocketdj-foryou-feed.json"

        /** "Updated 3 hours ago" freshness caption. */
        fun updatedLabel(refreshedAtMs: Double, nowMs: Double = System.currentTimeMillis().toDouble()): String {
            if (refreshedAtMs <= 0) return "Not refreshed yet"
            val secs = maxOf(0.0, (nowMs - refreshedAtMs) / 1000)
            if (secs < 90) return "Updated just now"
            val mins = Math.round(secs / 60).toInt()
            if (mins < 60) return "Updated $mins min ago"
            val hours = Math.round(secs / 3600).toInt()
            if (hours < 24) return "Updated $hours hour${if (hours == 1) "" else "s"} ago"
            val days = Math.round(secs / 86400).toInt()
            return "Updated $days day${if (days == 1) "" else "s"} ago"
        }
    }
}

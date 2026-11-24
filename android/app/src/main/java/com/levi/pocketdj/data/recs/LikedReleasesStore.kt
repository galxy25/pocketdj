package com.levi.pocketdj.data.recs

import java.io.File
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.asStateFlow

/**
 * The per-install metadata CACHE behind "Liked - not added" (`liked-releases.json`, `filesDir`).
 *
 * A CACHE, NOT STATE. What he liked lives in [RecFeedbackStore] (synced) and what was added in
 * `DiscoverAddsStore`. This file only remembers enough about each liked release to draw its row and add it
 * later, plus the last add attempt. The feed cache can't supply that: it keeps ONE release per artist, so a
 * liked record drops out of it the moment its artist puts out something newer. Deleting the file loses
 * nothing - hydration rebuilds every row from the verdict ids - so it is deliberately NOT registered with
 * cloud sync. Same JSON as iOS (`LikedReleasesStore.swift`), lenient decode (a bad row is skipped).
 */
class LikedReleasesStore(private val file: File?) {
    data class State(val releases: Map<String, LikedRelease> = emptyMap(), val revision: Int = 0)

    private val lock = Any()
    private val _state = MutableStateFlow(State(load()))
    val state: StateFlow<State> = _state.asStateFlow()

    val releases: Map<String, LikedRelease> get() = _state.value.releases

    /**
     * Insert or refresh metadata, KEEPING the existing attempt and like time when the incoming row doesn't
     * carry them (a re-like must not erase a failed attempt's message).
     */
    fun upsert(list: List<LikedRelease>) = synchronized(lock) {
        val cur = HashMap(_state.value.releases)
        var changed = false
        for (r in list) {
            val old = cur[r.storeId]
            val merged = if (old == null) r else r.copy(
                attempt = r.attempt ?: old.attempt,
                likedAtMs = r.likedAtMs ?: old.likedAtMs,
                tombstoned = r.tombstoned ?: old.tombstoned,
            )
            if (old != merged) { cur[r.storeId] = merged; changed = true }
        }
        if (changed) publish(cur)
    }

    fun upsert(r: LikedRelease) = upsert(listOf(r))

    fun setAttempt(storeId: String, attempt: LikeAddAttempt?) = synchronized(lock) {
        val cur = _state.value.releases
        val r = cur[storeId] ?: return@synchronized
        if (r.attempt == attempt) return@synchronized
        publish(cur + (storeId to r.copy(attempt = attempt)))
    }

    /** Drop rows whose verdict is no longer `accepted` (cleared or flipped). */
    fun prune(keepingAccepted: Set<String>) = synchronized(lock) {
        val cur = _state.value.releases
        val keep = cur.filterKeys { it in keepingAccepted }
        if (keep.size != cur.size) publish(keep)
    }

    private fun publish(map: Map<String, LikedRelease>) {
        _state.value = State(map, _state.value.revision + 1)
        save(map)
    }

    private fun save(map: Map<String, LikedRelease>) {
        val f = file ?: return
        runCatching {
            val tmp = File(f.parentFile, f.name + ".tmp")
            tmp.writeText(LikedReleasesCodec.encode(map.values.toList()))
            if (!tmp.renameTo(f)) { f.writeText(tmp.readText()); tmp.delete() }
        }
    }

    private fun load(): Map<String, LikedRelease> {
        val f = file?.takeIf { it.exists() } ?: return emptyMap()
        val rows = runCatching { LikedReleasesCodec.decode(f.readText()) }.getOrNull() ?: return emptyMap()
        return rows.associate { r ->
            // `adding` is never trusted across launches: the process that was adding is gone. `offline` is
            // what the sweep retries, so a crash mid-add heals itself.
            val a = r.attempt
            val fixed = if (a != null && a.state == LikeAddState.ADDING) {
                r.copy(attempt = a.copy(state = LikeAddState.OFFLINE, message = OFFLINE_MESSAGE))
            } else r
            r.storeId to fixed
        }
    }

    companion object {
        const val FILE_NAME = "liked-releases.json"
        /** The status line of an interrupted or offline add (the screen re-exports it as `NewReleaseLikeAdder.OFFLINE_MESSAGE`). */
        const val OFFLINE_MESSAGE = "Will add when you’re back online"
    }
}

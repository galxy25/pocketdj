package com.levi.pocketdj.auto

import com.levi.pocketdj.data.collections.NOW_PLAYING_PLAYLIST_ID
import com.levi.pocketdj.data.collections.NOW_PLAYING_SETLIST_ID

/** A pocket or playlist a song can be added to from the car. */
data class AutoTarget(val kind: AutoTargetKind, val id: String, val name: String)

/** The collection writes the chooser needs (production: CollectionsStore through the shared AddToActions). */
interface AutoAddSink {
    fun pockets(): List<AutoTarget>
    fun playlists(): List<AutoTarget>
    /** Adds the song; false when the target vanished. */
    fun add(songId: String, kind: AutoTargetKind, targetId: String): Boolean
}

/**
 * "Add to…" from the car: targets are pockets then playlists (A-Z within each), never the reserved
 * Now Playing set/playlist. Adding returns the target's display name for the confirmation toast.
 */
class AutoAddTargets(private val sink: AutoAddSink) {
    fun targets(): List<AutoTarget> {
        fun ok(t: AutoTarget) = t.id != NOW_PLAYING_SETLIST_ID && t.id != NOW_PLAYING_PLAYLIST_ID
        return sink.pockets().filter(::ok).sortedBy { it.name.lowercase() } +
            sink.playlists().filter(::ok).sortedBy { it.name.lowercase() }
    }

    /** Chooser rows for [songId] (non-playable, non-browsable; the callback treats a tap as the add). */
    fun nodes(songId: String): List<AutoNode> {
        val ts = targets()
        if (ts.isEmpty()) return listOf(AutoNode(AutoId.Empty(AutoId.AddTo(songId).encoded).encoded, "No pockets or playlists"))
        return ts.map {
            AutoNode(
                id = AutoId.AddTarget(songId, it.kind, it.id).encoded,
                title = it.name,
                subtitle = if (it.kind == AutoTargetKind.POCKET) "Pocket" else "Playlist",
                playable = true,
            )
        }
    }

    /** The display name added to, or null for an unknown/reserved target. */
    fun add(songId: String, kind: AutoTargetKind, targetId: String): String? {
        val t = targets().firstOrNull { it.kind == kind && it.id == targetId } ?: return null
        return if (sink.add(songId, kind, targetId)) t.name else null
    }

    /** Target for the one-tap custom action: the most recently used when still valid, else the first. */
    fun defaultTarget(recent: List<Pair<AutoTargetKind, String>>): AutoTarget? {
        val ts = targets()
        for ((k, id) in recent) ts.firstOrNull { it.kind == k && it.id == id }?.let { return it }
        return ts.firstOrNull()
    }
}

package com.levi.pocketdj.screens.collections

import com.levi.pocketdj.data.collections.AddTarget
import com.levi.pocketdj.data.collections.CollectionsStore
import com.levi.pocketdj.data.collections.Playlist
import com.levi.pocketdj.data.collections.PlaylistNode
import com.levi.pocketdj.data.collections.Pocket

/** What the Add-to UI is adding: a catalog song, a multi-select batch of songs, or an album. */
sealed interface AddToItem {
    data class Song(val id: String) : AddToItem
    data class Songs(val ids: List<String>) : AddToItem
    data class Album(val id: String) : AddToItem
}

/** A rec-engine collection suggestion on the wire (`kind` is "pocket" | "playlist"). */
data class CollectionSuggestion(val kind: String, val id: String)

/**
 * Pure outcome of tapping a target row — shared by the sheet and the context submenu so the
 * `onAdded` / `stayOpenAfterAdd` contract has one definition (iOS: onAdded fires after a
 * successful ADD only — never on a REMOVE, never on a batch that landed nothing).
 */
data class TapOutcome(val remove: Boolean, val fireOnAdded: Boolean, val dismiss: Boolean)

object AddToSheetParams {
    /**
     * [member] = the row was ✓ at tap time (⇒ remove). [added] = the add landed something
     * (only meaningful when not [member]). Default behaviour (stayOpenAfterAdd=false) dismisses
     * after an add; a remove never dismisses.
     */
    fun tapOutcome(member: Boolean, added: Boolean, stayOpenAfterAdd: Boolean): TapOutcome =
        if (member) {
            TapOutcome(remove = true, fireOnAdded = false, dismiss = false)
        } else {
            TapOutcome(remove = false, fireOnAdded = added, dismiss = added && !stayOpenAfterAdd)
        }
}

/**
 * The ONE shared add/remove/membership logic behind the Add-to sheet and the context-menu
 * "Add to Playlist" submenu (iOS `AddToActions`). Extend this, never duplicate it.
 */
class AddToActions(
    private val item: AddToItem,
    private val store: CollectionsStore,
) {
    // MARK: Quick targets (Suggested + Recent)

    /** The store's Recent MRU filtered to targets that STILL RESOLVE, capped at [limit]. */
    fun recentTargets(limit: Int): List<AddTarget> =
        store.state.value.recentAddTargets.filter { store.lastTargetLabel(it) != null }.take(limit)

    /**
     * Suggestions resolved to live targets: unknown kinds / unresolvable ids dropped, deduped
     * against [excluding] by (kind,id) (sequenceId ignored), capped.
     */
    fun suggestedTargets(
        wire: List<CollectionSuggestion>,
        excluding: List<AddTarget>,
        limit: Int,
    ): List<AddTarget> {
        val st = store.state.value
        val pocketIds = st.pockets.mapTo(HashSet()) { it.id }
        val playlistIds = st.playlists.mapTo(HashSet()) { it.id }
        val excluded = excluding.mapTo(HashSet()) { it.kind to it.id }
        val out = ArrayList<AddTarget>()
        for (s in wire) {
            if (out.size >= limit) break
            val kind = when (s.kind) {
                "pocket" -> AddTarget.Kind.POCKET
                "playlist" -> AddTarget.Kind.PLAYLIST
                else -> continue
            }
            val resolves = if (kind == AddTarget.Kind.POCKET) s.id in pocketIds else s.id in playlistIds
            if (!resolves || (kind to s.id) in excluded) continue
            out += AddTarget(kind, s.id)
        }
        return out
    }

    /**
     * Suggested first (SONG items only; an unwired [suggest] seam ⇒ none), then Recent, deduped
     * by (kind,id), capped at [limit].
     */
    fun quickTargets(limit: Int = QUICK_LIMIT, suggest: ((String) -> List<CollectionSuggestion>)? = null): List<AddTarget> {
        val recent = recentTargets(limit)
        val songId = (item as? AddToItem.Song)?.id
        val wire = if (songId != null && suggest != null) suggest(songId) else emptyList()
        val suggested = suggestedTargets(wire, excluding = recent, limit = limit)
        return (suggested + recent).take(limit)
    }

    // MARK: Membership

    /** A multi-song item is a member only when EVERY id is (one Set per row, never per id). */
    fun inPocket(p: Pocket): Boolean = when (item) {
        is AddToItem.Song -> item.id in p.songIds
        is AddToItem.Songs -> item.ids.isNotEmpty() && p.songIds.toHashSet().let { m -> item.ids.all { it in m } }
        is AddToItem.Album -> item.id in p.albumIds
    }

    fun inPlaylist(pl: Playlist): Boolean = when (item) {
        is AddToItem.Song -> item.id in memberIds(pl, PlaylistNode.Kind.SONG)
        is AddToItem.Songs -> item.ids.isNotEmpty() &&
            memberIds(pl, PlaylistNode.Kind.SONG).let { m -> item.ids.all { it in m } }
        is AddToItem.Album -> item.id in memberIds(pl, PlaylistNode.Kind.ALBUM)
    }

    fun isMember(target: AddTarget): Boolean {
        val st = store.state.value
        return when (target.kind) {
            AddTarget.Kind.POCKET -> st.pockets.firstOrNull { it.id == target.id }?.let(::inPocket) ?: false
            AddTarget.Kind.PLAYLIST -> st.playlists.firstOrNull { it.id == target.id }?.let(::inPlaylist) ?: false
        }
    }

    // MARK: Mutations

    /**
     * Adds the item through the store's MRU/activity choke points. Returns false only for a
     * `Songs` batch that landed nothing (every id already present).
     */
    fun add(
        target: AddTarget,
        dedupe: CollectionsStore.BatchDedupe = CollectionsStore.BatchDedupe.WHOLE_COLLECTION,
    ): Boolean {
        when (item) {
            is AddToItem.Song -> store.addSong(item.id, target)
            is AddToItem.Songs -> return store.addSongs(item.ids, target, dedupe) > 0
            is AddToItem.Album -> store.addAlbum(item.id, target)
        }
        return true
    }

    /** Toggle-OFF: pocket ⇒ its membership; playlist ⇒ EVERY chapter (nested included). */
    fun remove(target: AddTarget) {
        when (target.kind) {
            AddTarget.Kind.POCKET -> when (item) {
                is AddToItem.Songs -> store.removeSongsFromPocket(item.ids, target.id)
                is AddToItem.Song -> store.removeSongsFromPocket(listOf(item.id), target.id)
                is AddToItem.Album -> store.removeAlbumFromPocket(item.id, target.id)
            }
            AddTarget.Kind.PLAYLIST -> when (item) {
                is AddToItem.Songs -> store.removeSongsFromPlaylist(item.ids, target.id)
                is AddToItem.Song -> store.removeSongsFromPlaylist(listOf(item.id), target.id)
                is AddToItem.Album -> {
                    val pl = store.playlist(target.id) ?: return
                    albumNodeIds(pl.sequences, item.id).forEach { store.removeNode(it, target.id) }
                }
            }
        }
    }

    /**
     * Add if absent, remove if present — what a ✓ row does on tap. Returns the outcome so a
     * caller can fire `onAdded` / dismiss per [AddToSheetParams.tapOutcome].
     */
    fun toggle(target: AddTarget, stayOpenAfterAdd: Boolean = false): TapOutcome {
        val member = isMember(target)
        if (member) {
            remove(target)
            return AddToSheetParams.tapOutcome(member = true, added = false, stayOpenAfterAdd = stayOpenAfterAdd)
        }
        val added = add(target)
        return AddToSheetParams.tapOutcome(member = false, added = added, stayOpenAfterAdd = stayOpenAfterAdd)
    }

    private fun memberIds(pl: Playlist, kind: PlaylistNode.Kind): Set<String> {
        val out = HashSet<String>()
        fun walk(nodes: List<PlaylistNode>) {
            for (n in nodes) {
                if (n.kind == kind) (if (kind == PlaylistNode.Kind.SONG) n.songId else n.albumId)?.let(out::add)
                n.children?.let(::walk)
            }
        }
        walk(pl.sequences)
        return out
    }

    private fun albumNodeIds(sequences: List<PlaylistNode>, albumId: String): List<String> =
        sequences.flatMap { seq ->
            seq.children.orEmpty().filter { it.kind == PlaylistNode.Kind.ALBUM && it.albumId == albumId }.map { it.nodeId }
        }

    companion object {
        const val QUICK_LIMIT = 5
    }
}

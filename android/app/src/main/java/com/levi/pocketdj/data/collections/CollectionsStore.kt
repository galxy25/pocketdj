package com.levi.pocketdj.data.collections

import com.levi.pocketdj.data.PdjJson
import com.levi.pocketdj.data.catalog.MergedCatalog
import com.levi.pocketdj.data.catalog.SourcePlaylist
import com.levi.pocketdj.data.rips.PlayResolver
import com.levi.pocketdj.playback.PlayContext
import java.io.File
import kotlin.random.Random
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.asStateFlow
import kotlinx.serialization.json.Json

/**
 * On-device store for pockets + playlists + setlists + folders, persisted as
 * the versioned `CollectionsDocument` — the Android mirror of iOS
 * `State/CollectionsStore.swift` (specs/collections-schema.md §7,
 * specs/realize-play.md §4.5–§5).
 *
 * Persistence doctrine (the `PlayHistoryStore` idiom): atomic temp-file+rename
 * write synchronously-ordered after every mutation; corrupt bytes QUARANTINE to
 * `.bak` instead of being silently overwritten; a transiently-unreadable file
 * is salvaged (union by item id) before the first overwrite.
 *
 * Thread-safe: mutations serialize on an internal lock; the UI observes
 * [state] (revision-keyed).
 */
class CollectionsStore(
    private val file: File,
    private val json: Json = PdjJson.lenient,
    /** Injectable clock (epoch ms) for tests. */
    private val now: () -> Double = { System.currentTimeMillis().toDouble() },
) {
    /** One immutable snapshot for Compose; recompute keys off [State.revision]. */
    data class State(
        val pockets: List<Pocket>,
        val playlists: List<Playlist>,
        val setlists: List<Setlist>,
        val folders: List<PlaylistFolder>,
        val lastAddTarget: AddTarget?,
        /** MRU, most-recent first (top entry mirrors [lastAddTarget]). */
        val recentAddTargets: List<AddTarget>,
        /** Monotonic restart token for the reserved Now Playing setlist. */
        val nowPlayingRevision: Int,
        /** PlayContext source token of whatever last populated Now Playing. */
        val nowPlayingSource: String?,
        /** The collection id the reserved Now Playing setlist was built from. */
        val nowPlayingOriginId: String?,
        /** Monotonic; bumped on every real mutation. */
        val revision: Int,
    )

    /**
     * The payload of an [onActivity] emission — a user add/remove, snapshotted
     * at fire time (mirrors the iOS `ActivityHook`).
     */
    data class ActivityHook(
        val kind: Kind,
        val itemId: String,
        val itemTitle: String? = null,
        val collectionId: String? = null,
        /** AddTarget.Kind raw token ("pocket" / "playlist"). */
        val collectionKind: String? = null,
        val collectionName: String? = null,
    ) {
        enum class Kind(val token: String) { ADD("add"), REMOVE("remove") }
    }

    /** What `addSong(songId, toIndexPlaylist)` did (specs/collections-schema.md §8.3). */
    data class IndexPlaylistAdd(
        /** The on-device duplicate the song landed in. */
        val playlist: Playlist,
        /** The duplicate was minted by THIS call. */
        val createdDuplicate: Boolean,
        /** The song was already a member — nothing was appended. */
        val alreadyPresent: Boolean,
        /** ALWAYS false on Android (no MusicKit write-back — locked decision). */
        val writeBackEligible: Boolean = false,
        val appleMusicId: String? = null,
    )

    /** How many recent add-targets we retain (UI shows the top 3 that resolve). */
    val maxRecentTargets: Int get() = MAX_RECENT_TARGETS

    /**
     * The catalog the resolvers + realize engine read (wired in AppGraph to the
     * live [MergedCatalog]). Null until wired — every consumer degrades.
     */
    var catalogProvider: (() -> MergedCatalog?)? = null

    /** Fired after every persisted mutation (post-save). Reserved seam (iOS Spotlight/Siri). */
    var onChange: (() -> Unit)? = null

    /**
     * The collection-activity seam: fired ONLY from the user-facing add/remove
     * choke points (`addSong(to:)`/`addAlbum(to:)`/the five removes) — NEVER
     * from source-sync reconcile, decode, or low-level membership methods.
     * Wired in AppGraph to `CollectionActivityStore.record`.
     */
    var onActivity: ((ActivityHook) -> Unit)? = null

    private val lock = Any()
    private val _state: MutableStateFlow<State>
    val state: StateFlow<State>

    /** See PlayHistoryStore: an unreadable (not corrupt) file must not be clobbered. */
    private var salvagePending = false

    init {
        var loaded: CollectionsDocument? = null
        when (val read = readDocument()) {
            is ReadResult.Ok -> loaded = read.doc
            ReadResult.Absent -> Unit
            ReadResult.Corrupt -> {
                // Decode failure only (lenient+lossy decode absorbs schema
                // evolution): quarantine the bytes instead of overwriting them.
                runCatching { file.renameTo(File(file.parentFile, file.name + ".bak")) }
            }
            ReadResult.Unreadable -> salvagePending = true
        }
        val doc = loaded ?: CollectionsDocument()
        _state = MutableStateFlow(
            State(
                pockets = doc.pockets,
                playlists = doc.playlists,
                // LIFECYCLE: drop any stale reserved Now Playing setlist persisted
                // last session — it is per-session scratch and never shows on launch.
                setlists = doc.setlists.filterNot {
                    it.id == NOW_PLAYING_SETLIST_ID || it.playlistId == NOW_PLAYING_PLAYLIST_ID
                },
                folders = doc.folders,
                lastAddTarget = doc.lastAddTarget,
                recentAddTargets = doc.recentAddTargets ?: emptyList(),
                nowPlayingRevision = 0,
                nowPlayingSource = null,
                nowPlayingOriginId = null,
                revision = 0,
            ),
        )
        state = _state.asStateFlow()
    }

    // MARK: Lookups

    val pockets: List<Pocket> get() = _state.value.pockets
    val playlists: List<Playlist> get() = _state.value.playlists
    val setlists: List<Setlist> get() = _state.value.setlists
    val folders: List<PlaylistFolder> get() = _state.value.folders
    val lastAddTarget: AddTarget? get() = _state.value.lastAddTarget
    val recentAddTargets: List<AddTarget> get() = _state.value.recentAddTargets

    fun pocket(id: String): Pocket? = pockets.firstOrNull { it.id == id }
    fun playlist(id: String): Playlist? = playlists.firstOrNull { it.id == id }
    fun setlist(id: String): Setlist? = setlists.firstOrNull { it.id == id }
    fun folder(id: String): PlaylistFolder? = folders.firstOrNull { it.id == id }

    /**
     * Setlists for a playlist, most-recent first. The reserved Now Playing
     * setlist is never a member (its synthetic parent id is filtered).
     */
    fun setlistsForPlaylist(playlistId: String): List<Setlist> {
        if (playlistId == NOW_PLAYING_PLAYLIST_ID) return emptyList()
        return setlists.filter { it.playlistId == playlistId }.sortedByDescending { it.generatedAt }
    }

    /** The reserved, reusable Now Playing setlist (null until a first ▶/🔀). */
    fun nowPlayingSetlist(): Setlist? = setlist(NOW_PLAYING_SETLIST_ID)

    // MARK: Pockets

    fun createPocket(name: String, kind: PocketKind = PocketKind.HARMONIC): Pocket =
        synchronized(lock) {
            val p = CollectionsFactory.makePocket(name, kind, now())
            publish { it.copy(pockets = it.pockets + p) }
            save()
            p
        }

    /** One-shot creation from an explicit ordered song list (order kept, deduped). */
    fun createPocket(name: String, songIds: List<String>, description: String? = null): Pocket =
        synchronized(lock) {
            val p = CollectionsFactory.makePocket(name, PocketKind.HARMONIC, now())
                .copy(songIds = songIds.distinct(), description = description)
            publish { it.copy(pockets = it.pockets + p) }
            save()
            p
        }

    fun renamePocket(id: String, name: String) = mutatePocket(id) { it.copy(name = name) }

    /** Delete a pocket AND scrub its id from every other pocket's childPocketIds. */
    fun deletePocket(id: String) = synchronized(lock) {
        publish { s ->
            s.copy(
                pockets = s.pockets.filterNot { it.id == id }.map { p ->
                    if (id in p.childPocketIds) {
                        p.copy(childPocketIds = p.childPocketIds.filterNot { it == id })
                    } else {
                        p
                    }
                },
            )
        }
        save()
    }

    /** Membership add — set-like (no-op when present). Studio ids ride verbatim. */
    fun addSongToPocket(songId: String, pocketId: String) = mutatePocket(pocketId) { p ->
        if (songId in p.songIds) p else p.copy(songIds = p.songIds + songId)
    }

    fun addAlbumToPocket(albumId: String, pocketId: String) = mutatePocket(pocketId) { p ->
        if (albumId in p.albumIds) p else p.copy(albumIds = p.albumIds + albumId)
    }

    /** Nest `childId` under `parentId`; false (no-op) if it would form a cycle. */
    fun addChildPocket(childId: String, parentId: String): Boolean = synchronized(lock) {
        if (childId == parentId || wouldCycle(parent = parentId, child = childId)) return false
        mutatePocketLocked(parentId) { p ->
            if (childId in p.childPocketIds) p else p.copy(childPocketIds = p.childPocketIds + childId)
        }
        true
    }

    /** True if making `child` a child of `parent` would create a cycle. */
    fun wouldCycle(parent: String, child: String): Boolean {
        val stack = ArrayDeque(listOf(child))
        val seen = HashSet<String>()
        while (stack.isNotEmpty()) {
            val cur = stack.removeLast()
            if (cur == parent) return true
            if (!seen.add(cur)) continue
            pocket(cur)?.childPocketIds?.let(stack::addAll)
        }
        return false
    }

    /** Append a free-text NOTE (never counted as a member). */
    fun addNoteToPocket(text: String, pocketId: String): PocketNote? = synchronized(lock) {
        val note = PocketNote(
            id = CollectionsFactory.newPocketNoteId(),
            text = text,
            position = pocket(pocketId)?.notes?.size ?: 0,
        )
        mutatePocketLocked(pocketId) { it.copy(notes = it.notes + note) }
        pocket(pocketId)?.notes?.lastOrNull()
    }

    fun setNoteText(noteId: String, text: String, pocketId: String) = mutatePocket(pocketId) { p ->
        p.copy(notes = p.notes.map { if (it.id == noteId) it.copy(text = text) else it })
    }

    fun removeNoteFromPocket(noteId: String, pocketId: String) = mutatePocket(pocketId) { p ->
        p.copy(notes = p.notes.filterNot { it.id == noteId })
    }

    /** USER remove — clears the songRepeats entry too, and logs one remove activity. */
    fun removeSongFromPocket(songId: String, pocketId: String) = synchronized(lock) {
        val name = pocket(pocketId)?.name
        mutatePocketLocked(pocketId) { p ->
            p.copy(
                songIds = p.songIds.filterNot { it == songId },
                songRepeats = p.songRepeats - songId,
            )
        }
        emitRemoveActivity(itemId = songId, collectionId = pocketId, kind = AddTarget.Kind.POCKET, name = name)
    }

    fun removeAlbumFromPocket(albumId: String, pocketId: String) = synchronized(lock) {
        val name = pocket(pocketId)?.name
        mutatePocketLocked(pocketId) { p -> p.copy(albumIds = p.albumIds.filterNot { it == albumId }) }
        emitRemoveActivity(itemId = albumId, collectionId = pocketId, kind = AddTarget.Kind.POCKET, name = name)
    }

    /** Remove a NESTING (the child pocket itself survives). Logs one remove activity. */
    fun removeChildPocket(childId: String, pocketId: String) = synchronized(lock) {
        val parentName = pocket(pocketId)?.name
        val childName = pocket(childId)?.name // the catalog can't name a pocket
        mutatePocketLocked(pocketId) { p ->
            p.copy(childPocketIds = p.childPocketIds.filterNot { it == childId })
        }
        emitRemoveActivity(
            itemId = childId,
            collectionId = pocketId,
            kind = AddTarget.Kind.POCKET,
            name = parentName,
            itemTitle = childName,
        )
    }

    /** Set a pocket member's repeat (loop) count; ≤ 1 clears the key. */
    fun setSongRepeat(songId: String, count: Int, pocketId: String) = mutatePocket(pocketId) { p ->
        val stored = CollectionMembership.storedRepeat(count)
        p.copy(
            songRepeats = if (stored == null) p.songRepeats - songId else p.songRepeats + (songId to stored),
        )
    }

    fun repeatCountForSong(songId: String, pocketId: String): Int =
        CollectionMembership.normalizedRepeat(pocket(pocketId)?.songRepeats?.get(songId))

    fun movePocketSongs(pocketId: String, from: Int, to: Int) =
        mutatePocket(pocketId) { it.copy(songIds = it.songIds.moved(from, to)) }

    fun movePocketAlbums(pocketId: String, from: Int, to: Int) =
        mutatePocket(pocketId) { it.copy(albumIds = it.albumIds.moved(from, to)) }

    fun movePocketChildren(pocketId: String, from: Int, to: Int) =
        mutatePocket(pocketId) { it.copy(childPocketIds = it.childPocketIds.moved(from, to)) }

    fun movePocketNotes(pocketId: String, from: Int, to: Int) =
        mutatePocket(pocketId) { it.copy(notes = it.notes.moved(from, to)) }

    // MARK: Playlists

    fun createPlaylist(name: String): Playlist = synchronized(lock) {
        val p = CollectionsFactory.makePlaylist(name, now())
        publish { it.copy(playlists = it.playlists + p) }
        save()
        p
    }

    /**
     * Create a fresh editable playlist seeded with `songIds` in its default
     * chapter. PROVENANCE (v6): pass `source` when duplicating a "From your
     * sources" playlist — the duplicate remembers where it came from and
     * snapshots the membership.
     */
    fun createPlaylist(name: String, songIds: List<String>, source: SourcePlaylist? = null): Playlist =
        synchronized(lock) {
            var pl = CollectionsFactory.makePlaylist(name, now())
            pl = pl.copy(
                sequences = listOf(
                    pl.sequences[0].copy(
                        children = songIds.map {
                            PlaylistNode(
                                nodeId = CollectionsFactory.newNodeId(),
                                kind = PlaylistNode.Kind.SONG,
                                songId = it,
                            )
                        },
                    ),
                ),
                sourcePlaylistId = source?.playlist?.id,
                sourceName = source?.sourceName,
                sourceSongIds = source?.playlist?.songIds,
            )
            publish { it.copy(playlists = it.playlists + pl) }
            save()
            pl
        }

    fun renamePlaylist(id: String, name: String) = mutatePlaylist(id) { it.copy(name = name) }

    /** Delete a playlist — CASCADES to its frozen setlists. */
    fun deletePlaylist(id: String) = synchronized(lock) {
        publish { s ->
            s.copy(
                playlists = s.playlists.filterNot { it.id == id },
                setlists = s.setlists.filterNot { it.playlistId == id },
            )
        }
        save()
    }

    /** Append a leaf node to a chapter (the default chapter when `sequenceId` is null). */
    fun addNode(node: PlaylistNode, playlistId: String, sequenceId: String? = null) =
        mutatePlaylist(playlistId) { pl ->
            val seqIdx = sequenceId?.let { sid -> pl.sequences.indexOfFirst { it.nodeId == sid } } ?: 0
            if (seqIdx !in pl.sequences.indices) return@mutatePlaylist pl
            val seq = pl.sequences[seqIdx]
            pl.copy(
                sequences = pl.sequences.replaceAt(
                    seqIdx,
                    seq.copy(children = seq.children.orEmpty() + node),
                ),
            )
        }

    fun addSongToPlaylist(
        songId: String,
        playlistId: String,
        sequenceId: String? = null,
        repeatCount: Int? = null,
    ) = addNode(
        PlaylistNode(
            nodeId = CollectionsFactory.newNodeId(),
            kind = PlaylistNode.Kind.SONG,
            songId = songId,
            repeatCount = CollectionMembership.storedRepeat(repeatCount ?: 1),
        ),
        playlistId,
        sequenceId,
    )

    fun addAlbumToPlaylist(albumId: String, playlistId: String, sequenceId: String? = null) =
        addNode(
            PlaylistNode(
                nodeId = CollectionsFactory.newNodeId(),
                kind = PlaylistNode.Kind.ALBUM,
                albumId = albumId,
            ),
            playlistId,
            sequenceId,
        )

    fun addPocketRef(pocketId: String, playlistId: String, sequenceId: String? = null) =
        addNode(
            PlaylistNode(
                nodeId = CollectionsFactory.newNodeId(),
                kind = PlaylistNode.Kind.POCKET,
                pocketId = pocketId,
            ),
            playlistId,
            sequenceId,
        )

    fun addTextToPlaylist(text: String, playlistId: String, sequenceId: String? = null) =
        addNode(
            PlaylistNode(
                nodeId = CollectionsFactory.newNodeId(),
                kind = PlaylistNode.Kind.TEXT,
                text = text,
            ),
            playlistId,
            sequenceId,
        )

    fun addSequence(name: String, playlistId: String) = mutatePlaylist(playlistId) { pl ->
        pl.copy(sequences = pl.sequences + CollectionsFactory.makeSequence(name))
    }

    fun renameSequence(sequenceId: String, name: String, playlistId: String) =
        mutatePlaylist(playlistId) { pl ->
            pl.copy(
                sequences = pl.sequences.map {
                    if (it.nodeId == sequenceId) it.copy(name = name) else it
                },
            )
        }

    /** Refuses when it's the last chapter (the guard is load-bearing). */
    fun removeSequence(sequenceId: String, playlistId: String) = mutatePlaylist(playlistId) { pl ->
        if (pl.sequences.size <= 1) pl
        else pl.copy(sequences = pl.sequences.filterNot { it.nodeId == sequenceId })
    }

    fun setSequenceTarget(sequenceId: String, ms: Long?, playlistId: String) =
        mutatePlaylist(playlistId) { pl ->
            pl.copy(
                sequences = pl.sequences.map {
                    if (it.nodeId == sequenceId) it.copy(targetMs = ms) else it
                },
            )
        }

    fun setNodeNote(nodeId: String, note: String?, playlistId: String) =
        mutatePlaylist(playlistId) { pl ->
            pl.copy(
                sequences = pl.sequences.map { seq ->
                    seq.copy(
                        children = seq.children?.map {
                            if (it.nodeId == nodeId) it.copy(note = note) else it
                        },
                    )
                },
            )
        }

    /** Set a node's repeat (loop) count; ≤ 1 clears the field. */
    fun setNodeRepeat(nodeId: String, count: Int, playlistId: String) =
        mutatePlaylist(playlistId) { pl ->
            pl.copy(
                sequences = pl.sequences.map { seq ->
                    seq.copy(
                        children = seq.children?.map {
                            if (it.nodeId == nodeId) {
                                it.copy(repeatCount = CollectionMembership.storedRepeat(count))
                            } else {
                                it
                            }
                        },
                    )
                },
            )
        }

    fun repeatCountForNode(nodeId: String, playlistId: String): Int {
        val pl = playlist(playlistId) ?: return 1
        for (seq in pl.sequences) {
            seq.children?.firstOrNull { it.nodeId == nodeId }?.let {
                return CollectionMembership.normalizedRepeat(it.repeatCount)
            }
        }
        return 1
    }

    /** USER remove of a node — logs one remove activity (itemId = songId ?? albumId ?? pocketId ?? nodeId). */
    fun removeNode(nodeId: String, playlistId: String) = synchronized(lock) {
        // Snapshot the removed node + collection name BEFORE the mutation.
        val removed = playlist(playlistId)?.sequences
            ?.firstNotNullOfOrNull { seq -> seq.children?.firstOrNull { it.nodeId == nodeId } }
        val itemId = removed?.songId ?: removed?.albumId ?: removed?.pocketId ?: nodeId
        val name = playlist(playlistId)?.name
        mutatePlaylistLocked(playlistId) { pl ->
            pl.copy(
                sequences = pl.sequences.map { seq ->
                    seq.copy(children = seq.children?.filterNot { it.nodeId == nodeId })
                },
            )
        }
        emitRemoveActivity(itemId = itemId, collectionId = playlistId, kind = AddTarget.Kind.PLAYLIST, name = name)
    }

    /** Reorder a node within its chapter by `delta` (−1 up / +1 down; no-op at the ends). */
    fun moveNode(nodeId: String, playlistId: String, delta: Int) {
        if (delta == 0) return
        mutatePlaylist(playlistId) { pl ->
            for ((s, seq) in pl.sequences.withIndex()) {
                val children = seq.children ?: continue
                val from = children.indexOfFirst { it.nodeId == nodeId }
                if (from < 0) continue
                val to = from + delta
                if (to !in children.indices) return@mutatePlaylist pl // at an end → no-op
                val m = children.toMutableList()
                val node = m.removeAt(from)
                m.add(to, node)
                return@mutatePlaylist pl.copy(sequences = pl.sequences.replaceAt(s, seq.copy(children = m)))
            }
            pl
        }
    }

    fun moveNodeUp(nodeId: String, playlistId: String) = moveNode(nodeId, playlistId, -1)
    fun moveNodeDown(nodeId: String, playlistId: String) = moveNode(nodeId, playlistId, 1)

    /** Drag reorder within one chapter (display indices). */
    fun moveNodes(playlistId: String, sequenceId: String, from: Int, to: Int) =
        mutatePlaylist(playlistId) { pl ->
            val s = pl.sequences.indexOfFirst { it.nodeId == sequenceId }
            if (s < 0) return@mutatePlaylist pl
            val seq = pl.sequences[s]
            pl.copy(
                sequences = pl.sequences.replaceAt(s, seq.copy(children = seq.children.orEmpty().moved(from, to))),
            )
        }

    fun moveSequences(playlistId: String, from: Int, to: Int) = mutatePlaylist(playlistId) { pl ->
        pl.copy(sequences = pl.sequences.moved(from, to))
    }

    /** DIRECT membership test (no album/pocket expansion, no catalog needed). */
    fun playlistContains(playlistId: String, songId: String): Boolean {
        val pl = playlist(playlistId) ?: return false
        return songId in songIdsInNodes(pl.sequences)
    }

    private fun songIdsInNodes(nodes: List<PlaylistNode>): Set<String> {
        val out = HashSet<String>()
        fun walk(ns: List<PlaylistNode>) {
            for (n in ns) {
                if (n.kind == PlaylistNode.Kind.SONG) n.songId?.let(out::add)
                n.children?.let(::walk)
            }
        }
        walk(nodes)
        return out
    }

    // MARK: Source playlist → on-device duplicate (find-or-create)

    /**
     * The ONE find-or-create primitive for "the on-device duplicate of this
     * source playlist" — every caller must go through it or the user ends up
     * with two competing copies. Matches on BOTH `sourcePlaylistId` AND
     * `sourceName` (ids are unique only within a source namespace); a LEGACY
     * duplicate with nil sourceName matches by id alone.
     */
    fun duplicateForSource(source: SourcePlaylist): Playlist {
        existingDuplicate(source)?.let { return it }
        return createPlaylist(source.playlist.name, source.playlist.songIds, source)
    }

    /** The existing duplicate WITHOUT creating one. */
    fun existingDuplicate(source: SourcePlaylist): Playlist? =
        playlists.firstOrNull {
            it.sourcePlaylistId == source.playlist.id && it.sourceName == source.sourceName
        } ?: playlists.firstOrNull {
            it.sourcePlaylistId == source.playlist.id && it.sourceName == null
        }

    /**
     * Add a song "to" a read-only source playlist: find-or-create the duplicate
     * + append to its default chapter. DELIBERATELY does NOT advance
     * `sourceSongIds` (the three-way-merge base — advancing it early would make
     * the next refresh classify the user's add as a source REMOVAL), does NOT
     * set `lastAddTarget`, and logs NO activity event (iOS parity — the add
     * routes through the low-level membership path).
     * `writeBackEligible` is ALWAYS false on Android (no MusicKit).
     */
    fun addSongToIndexPlaylist(songId: String, source: SourcePlaylist): IndexPlaylistAdd = synchronized(lock) {
        val existing = existingDuplicate(source)
        val pl = existing ?: duplicateForSource(source)
        val created = existing == null

        val present = songId in songIdsInNodes(pl.sequences)
        if (!present) {
            addSongToPlaylist(songId, pl.id, sequenceId = pl.sequences.firstOrNull()?.nodeId)
        }
        IndexPlaylistAdd(
            playlist = playlist(pl.id) ?: pl,
            createdDuplicate = created,
            alreadyPresent = present,
            writeBackEligible = false,
            appleMusicId = null,
        )
    }

    // MARK: Convert → pocket

    /**
     * Convert an editable playlist TEMPLATE into a NEW pocket: song/album/pocket
     * node refs become direct members (order kept, per-kind deduped; albums and
     * pockets kept as REFS), text cues become ordered notes.
     */
    fun convertPlaylistToPocket(playlistId: String): Pocket? {
        val pl = playlist(playlistId) ?: return null
        val songIds = ArrayList<String>()
        val albumIds = ArrayList<String>()
        val childPocketIds = ArrayList<String>()
        val noteTexts = ArrayList<String>()
        val sSeen = HashSet<String>()
        val aSeen = HashSet<String>()
        val pSeen = HashSet<String>()
        fun walk(nodes: List<PlaylistNode>) {
            for (n in nodes) {
                when (n.kind) {
                    PlaylistNode.Kind.SONG -> n.songId?.let { if (sSeen.add(it)) songIds.add(it) }
                    PlaylistNode.Kind.ALBUM -> n.albumId?.let { if (aSeen.add(it)) albumIds.add(it) }
                    PlaylistNode.Kind.POCKET -> n.pocketId?.let { if (pSeen.add(it)) childPocketIds.add(it) }
                    PlaylistNode.Kind.TEXT -> n.text?.takeIf { it.isNotBlank() }?.let(noteTexts::add)
                    PlaylistNode.Kind.SEQUENCE -> walk(n.children.orEmpty())
                }
            }
        }
        walk(pl.sequences)
        return makeAndSavePocket(pl.name, songIds, albumIds, childPocketIds, noteTexts)
    }

    /**
     * Convert a read-only source playlist into a NEW pocket of its songs
     * (order preserved, deduped), PROVENANCE-stamped so a future sync can
     * follow the source.
     */
    fun convertSourceToPocket(source: SourcePlaylist): Pocket = synchronized(lock) {
        val ids = source.playlist.songIds.distinct()
        val p = makeAndSavePocketLocked(source.playlist.name, ids)
        mutatePocketLocked(p.id) {
            it.copy(
                sourcePlaylistId = source.playlist.id,
                sourceName = source.sourceName,
                sourceSongIds = ids,
            )
        }
        pocket(p.id) ?: p
    }

    private fun makeAndSavePocket(
        name: String,
        songIds: List<String> = emptyList(),
        albumIds: List<String> = emptyList(),
        childPocketIds: List<String> = emptyList(),
        noteTexts: List<String> = emptyList(),
    ): Pocket = synchronized(lock) {
        makeAndSavePocketLocked(name, songIds, albumIds, childPocketIds, noteTexts)
    }

    private fun makeAndSavePocketLocked(
        name: String,
        songIds: List<String> = emptyList(),
        albumIds: List<String> = emptyList(),
        childPocketIds: List<String> = emptyList(),
        noteTexts: List<String> = emptyList(),
    ): Pocket {
        val ts = now()
        val notes = noteTexts.mapIndexed { i, t ->
            PocketNote(id = CollectionsFactory.newPocketNoteId(), text = t, position = i)
        }
        val p = Pocket(
            id = CollectionsFactory.newPocketId(),
            name = name,
            songIds = songIds,
            albumIds = albumIds,
            childPocketIds = childPocketIds,
            notes = notes,
            createdAt = ts,
            updatedAt = ts,
        )
        publish { it.copy(pockets = it.pockets + p) }
        save()
        return p
    }

    // MARK: Source sync (manual "Sync from source now" — auto pass deferred)

    private fun liveSourcePlaylist(plId: String, sourceName: String?): SourcePlaylist? =
        catalogProvider?.invoke()?.playlists?.firstOrNull {
            it.playlist.id == plId && (sourceName == null || it.sourceName == sourceName)
        }

    fun sourcePlaylistForPocket(id: String): SourcePlaylist? {
        val p = pocket(id) ?: return null
        val plId = p.sourcePlaylistId ?: return null
        return liveSourcePlaylist(plId, p.sourceName)
    }

    fun sourcePlaylistForPlaylist(id: String): SourcePlaylist? {
        val pl = playlist(id) ?: return null
        val plId = pl.sourcePlaylistId ?: return null
        return liveSourcePlaylist(plId, pl.sourceName)
    }

    /** Per-item sync opt-out; no-ops on nil-provenance items. */
    fun setPocketSourceSyncEnabled(enabled: Boolean, pocketId: String) {
        if (pocket(pocketId)?.hasSource != true) return
        mutatePocket(pocketId) { it.copy(sourceSyncEnabled = enabled) }
    }

    fun setPlaylistSourceSyncEnabled(enabled: Boolean, playlistId: String) {
        if (playlist(playlistId)?.hasSource != true) return
        mutatePlaylist(playlistId) { it.copy(sourceSyncEnabled = enabled) }
    }

    /**
     * Reconcile every sync-enabled converted pocket AND duplicated playlist
     * against fresh catalog playlists (the DEFERRED auto pass calls this later;
     * exposed now for the manual path + tests). An item whose source is MISSING
     * from the refresh is left untouched. NEVER emits activity events.
     */
    fun syncConvertedCollections(sourcePlaylists: List<SourcePlaylist>): Int = synchronized(lock) {
        fun match(plId: String?, sourceName: String?): SourcePlaylist? {
            if (plId == null) return null
            return sourcePlaylists.firstOrNull {
                it.playlist.id == plId && (sourceName == null || it.sourceName == sourceName)
            }
        }
        var changed = 0
        for (p in pockets.filter { it.syncsWithSource }) {
            val sp = match(p.sourcePlaylistId, p.sourceName) ?: continue
            if (reconcilePocket(p.id, sp)) changed++
        }
        for (pl in playlists.filter { it.syncsWithSource }) {
            val sp = match(pl.sourcePlaylistId, pl.sourceName) ?: continue
            if (reconcilePlaylist(pl.id, sp)) changed++
        }
        changed
    }

    /** MANUAL "Sync from source now" — ignores the toggles (explicit user action). */
    fun syncPocketFromSourceNow(id: String): Boolean = synchronized(lock) {
        val sp = sourcePlaylistForPocket(id) ?: return false
        reconcilePocket(id, sp)
    }

    fun syncPlaylistFromSourceNow(id: String): Boolean = synchronized(lock) {
        val sp = sourcePlaylistForPlaylist(id) ?: return false
        reconcilePlaylist(id, sp)
    }

    /**
     * Three-way merge of one pocket against its source, base = `sourceSongIds`:
     * source ADDS appended (unless the user already has them); source REMOVES
     * removed (repeat counts too); the user's own edits survive; the snapshot
     * advances. Persists nothing on a no-change refresh.
     */
    private fun reconcilePocket(id: String, sp: SourcePlaylist): Boolean {
        val p = pocket(id) ?: return false
        val srcIds = sp.playlist.songIds.distinct()
        val snapshot = p.sourceSongIds ?: emptyList()
        val snapSet = snapshot.toSet()
        val removals = snapSet - srcIds.toSet()
        val current = p.songIds.toSet()
        val additions = srcIds.filter { it !in snapSet && it !in current }
        val newSongIds = p.songIds.filterNot { it in removals } + additions
        if (newSongIds == p.songIds && srcIds == snapshot) return false
        mutatePocketLocked(id) {
            it.copy(
                songIds = newSongIds,
                sourceSongIds = srcIds,
                sourceSyncedAt = now(),
                songRepeats = it.songRepeats - removals,
            )
        }
        return true
    }

    /**
     * The playlist twin: source removals drop every `.song` node carrying that
     * id (recursing into sub-sequences); source adds append fresh song nodes to
     * the DEFAULT chapter. Chapters, cues, albums, pockets, and the user's own
     * nodes are untouched.
     */
    private fun reconcilePlaylist(id: String, sp: SourcePlaylist): Boolean {
        val pl = playlist(id) ?: return false
        val srcIds = sp.playlist.songIds.distinct()
        val snapshot = pl.sourceSongIds ?: emptyList()
        val snapSet = snapshot.toSet()
        val removals = snapSet - srcIds.toSet()

        val currentSongIds = songIdsInNodes(pl.sequences)
        val additions = srcIds.filter { it !in snapSet && it !in currentSongIds }

        var removedCount = 0
        fun prune(nodes: List<PlaylistNode>): List<PlaylistNode> = nodes.mapNotNull { n ->
            if (n.kind == PlaylistNode.Kind.SONG && n.songId != null && n.songId in removals) {
                removedCount++
                null
            } else {
                if (n.children != null) n.copy(children = prune(n.children)) else n
            }
        }
        val pruned = prune(pl.sequences)

        if (removedCount == 0 && additions.isEmpty() && srcIds == snapshot) return false
        mutatePlaylistLocked(id) {
            var seqs = pruned
            if (additions.isNotEmpty()) {
                if (seqs.isEmpty()) seqs = listOf(CollectionsFactory.makeSequence("Default"))
                val newNodes = additions.map { sid ->
                    PlaylistNode(
                        nodeId = CollectionsFactory.newNodeId(),
                        kind = PlaylistNode.Kind.SONG,
                        songId = sid,
                    )
                }
                seqs = seqs.replaceAt(0, seqs[0].copy(children = seqs[0].children.orEmpty() + newNodes))
            }
            it.copy(sequences = seqs, sourceSongIds = srcIds, sourceSyncedAt = now())
        }
        return true
    }

    // MARK: Folders (flat)

    /** Folders, name-ordered (case-insensitive) for stable display. */
    fun foldersOrdered(): List<PlaylistFolder> =
        folders.sortedWith(compareBy(String.CASE_INSENSITIVE_ORDER) { it.name })

    /** Playlists in a folder (null ⇒ top level), ordered by the chosen sort. */
    fun playlistsInFolder(folderId: String?, order: CollectionSortOrder = CollectionSortOrder.NAME): List<Playlist> =
        order.sorted(playlists.filter { it.folderId == folderId })

    /** Pockets in a folder (null ⇒ top level), ordered by the chosen sort. */
    fun pocketsInFolder(folderId: String?, order: CollectionSortOrder = CollectionSortOrder.NAME): List<Pocket> =
        order.sorted(pockets.filter { it.folderId == folderId })

    fun createFolder(name: String): PlaylistFolder = synchronized(lock) {
        val ts = now()
        val f = PlaylistFolder(id = CollectionsFactory.newFolderId(), name = name, createdAt = ts, updatedAt = ts)
        publish { it.copy(folders = it.folders + f) }
        save()
        f
    }

    fun renameFolder(id: String, name: String) = synchronized(lock) {
        if (folders.none { it.id == id }) return
        publish { s ->
            s.copy(
                folders = s.folders.map {
                    if (it.id == id) it.copy(name = name, updatedAt = now()) else it
                },
            )
        }
        save()
    }

    /** Delete a folder; member playlists AND pockets fall back to the top level. */
    fun deleteFolder(id: String) = synchronized(lock) {
        val ts = now()
        publish { s ->
            s.copy(
                folders = s.folders.filterNot { it.id == id },
                playlists = s.playlists.map {
                    if (it.folderId == id) it.copy(folderId = null, updatedAt = ts) else it
                },
                pockets = s.pockets.map {
                    if (it.folderId == id) it.copy(folderId = null, updatedAt = ts) else it
                },
            )
        }
        save()
    }

    fun setPlaylistFolder(playlistId: String, folderId: String?) =
        mutatePlaylist(playlistId) { it.copy(folderId = folderId) }

    fun setPocketFolder(pocketId: String, folderId: String?) =
        mutatePocket(pocketId) { it.copy(folderId = folderId) }

    // MARK: Add-to memory (last target + MRU) — the ACTIVITY choke points

    fun setLastAddTarget(target: AddTarget?) = synchronized(lock) {
        publish { it.copy(lastAddTarget = target) }
        save()
    }

    /**
     * The Add-to sheet's seam — the ONLY add path that records the MRU, sets
     * `lastAddTarget`, and emits one `add` activity event. The id is
     * prefix-agnostic (studio ids ride verbatim).
     */
    fun addSong(songId: String, target: AddTarget, repeatCount: Int? = null) = synchronized(lock) {
        when (target.kind) {
            AddTarget.Kind.POCKET -> {
                mutatePocketLocked(target.id) { p ->
                    if (songId in p.songIds) p else p.copy(songIds = p.songIds + songId)
                }
                CollectionMembership.storedRepeat(repeatCount ?: 1)?.let { r ->
                    mutatePocketLocked(target.id) { it.copy(songRepeats = it.songRepeats + (songId to r)) }
                }
            }
            AddTarget.Kind.PLAYLIST -> addSongToPlaylist(songId, target.id, target.sequenceId, repeatCount)
        }
        noteRecentTarget(target)
        publish { it.copy(lastAddTarget = target) }
        save()
        emitAddActivity(itemId = songId, target = target)
    }

    fun addAlbum(albumId: String, target: AddTarget) = synchronized(lock) {
        when (target.kind) {
            AddTarget.Kind.POCKET -> mutatePocketLocked(target.id) { p ->
                if (albumId in p.albumIds) p else p.copy(albumIds = p.albumIds + albumId)
            }
            AddTarget.Kind.PLAYLIST -> addAlbumToPlaylist(albumId, target.id, target.sequenceId)
        }
        noteRecentTarget(target)
        publish { it.copy(lastAddTarget = target) }
        save()
        emitAddActivity(itemId = albumId, target = target)
    }

    /**
     * MRU push: dedupe by (kind,id) IGNORING sequenceId (freshest chapter wins),
     * move-to-front, cap at [MAX_RECENT_TARGETS].
     */
    private fun noteRecentTarget(target: AddTarget) {
        publish { s ->
            val kept = s.recentAddTargets.filterNot { it.kind == target.kind && it.id == target.id }
            s.copy(recentAddTargets = (listOf(target) + kept).take(MAX_RECENT_TARGETS))
        }
    }

    /** "Pocket" or "Playlist › Chapter" for a remembered target — null if gone. */
    fun lastTargetLabel(target: AddTarget): String? = when (target.kind) {
        AddTarget.Kind.POCKET -> pocket(target.id)?.name
        AddTarget.Kind.PLAYLIST -> {
            val pl = playlist(target.id)
            if (pl == null) {
                null
            } else {
                val seq = target.sequenceId?.let { sid -> pl.sequences.firstOrNull { it.nodeId == sid } }
                if (seq != null) "${pl.name} › ${seq.name ?: "Chapter"}" else pl.name
            }
        }
    }

    // MARK: Activity emission (the ONLY two onActivity call sites)

    /** Display-title snapshot for an item id — catalog song, then album, else null. */
    private fun activityTitle(id: String): String? {
        val merged = catalogProvider?.invoke() ?: return null
        return merged.songsById[id]?.name ?: merged.albumsById[id]?.name
    }

    private fun plainCollectionName(target: AddTarget): String? = when (target.kind) {
        AddTarget.Kind.POCKET -> pocket(target.id)?.name
        AddTarget.Kind.PLAYLIST -> playlist(target.id)?.name
    }

    private fun emitAddActivity(itemId: String, target: AddTarget) {
        onActivity?.invoke(
            ActivityHook(
                kind = ActivityHook.Kind.ADD,
                itemId = itemId,
                itemTitle = activityTitle(itemId),
                collectionId = target.id,
                collectionKind = target.kind.token,
                collectionName = plainCollectionName(target),
            ),
        )
    }

    private fun emitRemoveActivity(
        itemId: String,
        collectionId: String,
        kind: AddTarget.Kind,
        name: String?,
        itemTitle: String? = null,
    ) {
        onActivity?.invoke(
            ActivityHook(
                kind = ActivityHook.Kind.REMOVE,
                itemId = itemId,
                itemTitle = itemTitle ?: activityTitle(itemId),
                collectionId = collectionId,
                collectionKind = kind.token,
                collectionName = name,
            ),
        )
    }

    // MARK: Resolution (songIds = rip/burn-facing, studio-stripped · playableIds = playback)

    private fun collectionCatalog(): CollectionCatalog {
        val merged = catalogProvider?.invoke()
        return CollectionCatalog(
            songsById = merged?.songsById ?: emptyMap(),
            albumsById = merged?.albumsById ?: emptyMap(),
            pocketsById = pockets.associateBy { it.id },
        )
    }

    /** Container stats for subtitles ("n songs · m:ss"). */
    fun statsForPlaylist(playlistId: String): CollectionCatalog.Stats {
        val pl = playlist(playlistId) ?: return CollectionCatalog.Stats()
        return collectionCatalog().statsForPlaylist(pl)
    }

    fun statsForChapter(chapter: PlaylistNode): CollectionCatalog.Stats =
        collectionCatalog().statsForChapter(chapter)

    fun statsForPocket(pocketId: String): CollectionCatalog.Stats =
        collectionCatalog().statsForPocket(pocketId)

    /** Rip/burn/CSV-facing resolvers — studio ids STRIPPED. */
    fun songIdsForPlaylist(playlistId: String): List<String> =
        playableIdsForPlaylist(playlistId).filterNot(PlayResolver::isStudioId)

    fun songIdsForPocket(pocketId: String): List<String> =
        playableIdsForPocket(pocketId).filterNot(PlayResolver::isStudioId)

    fun songIdsForSetlist(setlistId: String): List<String> =
        playableIdsForSetlist(setlistId).filterNot(PlayResolver::isStudioId)

    /** Playback companions — same resolution + order, studio ids KEPT. */
    fun playableIdsForPlaylist(playlistId: String): List<String> {
        val pl = playlist(playlistId) ?: return emptyList()
        return collectionCatalog().songsInPlaylist(pl).map { it.id }
    }

    fun playableIdsForPocket(pocketId: String): List<String> {
        val seen = HashSet<String>()
        return collectionCatalog().resolvePocketSongs(pocketId, seen).map { it.id }
    }

    /** A frozen setlist's playable ids in FROZEN ORDER (text cues drop out). */
    fun playableIdsForSetlist(setlistId: String): List<String> {
        val sl = setlist(setlistId) ?: return emptyList()
        return sl.tracks.filter { it.isText != true && it.songId.isNotEmpty() }.map { it.songId }
    }

    // MARK: Realize (📋 Make set list — the frozen take)

    /** The read-only ctx the engine resolves against; null until the catalog is wired. */
    fun makeCtx(): RealizeCtx? {
        val merged = catalogProvider?.invoke() ?: return null
        return RealizeCtx(
            songsById = merged.songsById,
            albumsById = merged.albumsById,
            pocketsById = pockets.associateBy { it.id },
            candidates = merged.songs.filter { it.bpm != null && it.camelot != null },
        )
    }

    /** "Name — take N". */
    private fun nextSetlistName(playlistId: String): String {
        val base = playlist(playlistId)?.name ?: "Set"
        val take = setlistsForPlaylist(playlistId).size + 1
        return "$base — take $take"
    }

    /**
     * Realize a playlist into a fresh, persisted Setlist. Deterministic given a
     * `seed`; when null, a fresh per-call seed yields a new "take" each Play.
     * Null when the playlist or the catalog context is unavailable.
     */
    fun realize(playlistId: String, seed: String? = null, name: String? = null): Setlist? =
        synchronized(lock) {
            val pl = playlist(playlistId) ?: return null
            val ctx = makeCtx() ?: return null
            val theSeed = seed ?: CollectionsFactory.uid()
            val theName = name ?: nextSetlistName(playlistId)
            val setlist = RealizeEngine.buildSetlist(pl, ctx, seed = theSeed, name = theName, now = now())
            publish { it.copy(setlists = it.setlists + setlist) }
            save()
            setlist
        }

    /**
     * Realize an explicit ordered id list into a fresh Setlist (the read-only
     * source playlist's ▶ Play): builds a TRANSIENT one-chapter playlist (never
     * persisted) and runs the standard path.
     */
    fun realize(songIds: List<String>, name: String): Setlist? = synchronized(lock) {
        val ctx = makeCtx() ?: return null
        val ts = now()
        val seq = CollectionsFactory.makeSequence("Set").copy(
            children = songIds.map {
                PlaylistNode(nodeId = CollectionsFactory.newNodeId(), kind = PlaylistNode.Kind.SONG, songId = it)
            },
        )
        val transient = Playlist(
            id = CollectionsFactory.newPlaylistId(),
            name = name,
            sequences = listOf(seq),
            createdAt = ts,
            updatedAt = ts,
        )
        val setlist = RealizeEngine.buildSetlist(
            transient,
            ctx,
            seed = CollectionsFactory.uid(),
            name = name,
            now = ts,
        )
        publish { it.copy(setlists = it.setlists + setlist) }
        save()
        setlist
    }

    // MARK: playNow — the reserved, reusable Now Playing setlist (▶ Play / 🔀 Shuffle)

    /**
     * Build the reserved Now Playing setlist DIRECTLY from `songIds` — literal
     * order, NO realize. Unresolvable ids DROP; `shuffle` re-orders fresh each
     * call (unseeded); UPSERTS the reserved setlist and bumps the monotonic
     * restart token. Null when the catalog isn't wired.
     */
    fun playNow(
        songIds: List<String>,
        name: String = "Now Playing",
        shuffle: Boolean = false,
        sourceToken: String? = null,
        repeats: Map<String, Int> = emptyMap(),
        originId: String? = null,
        random: Random = Random,
    ): Setlist? = synchronized(lock) {
        val merged = catalogProvider?.invoke() ?: return null
        var tracks = songIds.mapNotNull { id ->
            val rep = CollectionMembership.storedRepeat(repeats[id] ?: 1)
            val s = merged.songsById[id] ?: return@mapNotNull null // drop unresolvable ids
            SetlistTrack(
                songId = s.id,
                artist = s.artist,
                name = s.name,
                bpm = s.bpm,
                camelot = s.camelot,
                lengthMs = s.length,
                source = TrackSource.EXPLICIT,
                repeatCount = rep,
            )
        }
        if (shuffle) tracks = tracks.shuffled(random)
        val totalMs = tracks.sumOf { it.shownMs }
        val set = Setlist(
            id = NOW_PLAYING_SETLIST_ID,
            playlistId = NOW_PLAYING_PLAYLIST_ID,
            name = name,
            seed = "now-playing",
            generatedAt = now(),
            totalMs = totalMs,
            tracks = tracks,
        )
        publish { s ->
            val idx = s.setlists.indexOfFirst { it.id == NOW_PLAYING_SETLIST_ID }
            s.copy(
                setlists = if (idx >= 0) s.setlists.replaceAt(idx, set) else s.setlists + set,
                nowPlayingRevision = s.nowPlayingRevision + 1,
                nowPlayingSource = sourceToken,
                nowPlayingOriginId = originId,
            )
        }
        save()
        set
    }

    /** ▶ Play a playlist (literal resolved order) — stamps `lastPlayedAt` first. */
    fun playNowPlaylist(playlistId: String, shuffle: Boolean = false, random: Random = Random): Setlist? {
        markPlaylistPlayed(playlistId)
        return playNow(
            songIds = playableIdsForPlaylist(playlistId),
            name = playlist(playlistId)?.name ?: "Now Playing",
            shuffle = shuffle,
            sourceToken = PlayContext.SOURCE_PLAYLIST,
            repeats = playlistRepeatMap(playlistId),
            originId = playlistId,
            random = random,
        )
    }

    /** ▶ Play a pocket (DAG-resolved order) — stamps `lastPlayedAt` first. */
    fun playNowPocket(pocketId: String, shuffle: Boolean = false, random: Random = Random): Setlist? {
        markPocketPlayed(pocketId)
        return playNow(
            songIds = playableIdsForPocket(pocketId),
            name = pocket(pocketId)?.name ?: "Now Playing",
            shuffle = shuffle,
            sourceToken = PlayContext.SOURCE_POCKET,
            repeats = pocket(pocketId)?.songRepeats ?: emptyMap(),
            originId = pocketId,
            random = random,
        )
    }

    /** songId → repeat count from the template's song nodes (later wins). */
    private fun playlistRepeatMap(playlistId: String): Map<String, Int> {
        val pl = playlist(playlistId) ?: return emptyMap()
        val map = HashMap<String, Int>()
        fun walk(nodes: List<PlaylistNode>) {
            for (n in nodes) {
                if (n.kind == PlaylistNode.Kind.SONG && n.songId != null) {
                    n.repeatCount?.takeIf { it > 1 }?.let { map[n.songId] = it }
                }
                n.children?.let(::walk)
            }
        }
        for (seq in pl.sequences) walk(seq.children.orEmpty())
        return map
    }

    /**
     * Resolve the History context for a sequencer run tagged with
     * `sourceSetlistId` (specs/realize-play.md §7). For the reserved Now
     * Playing setlist the source token is whatever `playNow` recorded; a real
     * setlist resolves to (`setlist`, its name); browser singles carry nothing.
     */
    fun historyContext(sourceSetlistId: String?): PlayContext {
        if (sourceSetlistId == null) return PlayContext(PlayContext.SOURCE_SETLIST)
        if (sourceSetlistId == NOW_PLAYING_SETLIST_ID) {
            val src = _state.value.nowPlayingSource ?: PlayContext.SOURCE_SETLIST
            if (src == PlayContext.SOURCE_BROWSER) return PlayContext.BROWSER
            return PlayContext(src, contextId = sourceSetlistId, contextName = setlist(sourceSetlistId)?.name)
        }
        setlist(sourceSetlistId)?.let {
            return PlayContext(PlayContext.SOURCE_SETLIST, contextId = sourceSetlistId, contextName = it.name)
        }
        // Defensive: a real playlist/pocket id ever threaded directly.
        playlist(sourceSetlistId)?.let {
            return PlayContext(PlayContext.SOURCE_PLAYLIST, contextId = sourceSetlistId, contextName = it.name)
        }
        pocket(sourceSetlistId)?.let {
            return PlayContext(PlayContext.SOURCE_POCKET, contextId = sourceSetlistId, contextName = it.name)
        }
        return PlayContext(PlayContext.SOURCE_SETLIST, contextId = sourceSetlistId)
    }

    /**
     * The navigable origin collection of the current Now Playing run (the Up
     * Next header's "open collection" seam) — (source token, collection id), or
     * null when there is none / it no longer resolves.
     */
    fun originCollection(sourceSetlistId: String?): Pair<String, String>? {
        if (sourceSetlistId == null) return null
        if (sourceSetlistId == NOW_PLAYING_SETLIST_ID) {
            val src = _state.value.nowPlayingSource ?: return null
            val oid = _state.value.nowPlayingOriginId ?: return null
            return src to oid
        }
        if (setlist(sourceSetlistId) != null) return PlayContext.SOURCE_SETLIST to sourceSetlistId
        if (playlist(sourceSetlistId) != null) return PlayContext.SOURCE_PLAYLIST to sourceSetlistId
        if (pocket(sourceSetlistId) != null) return PlayContext.SOURCE_POCKET to sourceSetlistId
        return null
    }

    // MARK: Recently-played stamps (DIRECT save — never disturbs updatedAt)

    /** Stamp a playlist's `lastPlayedAt` = now WITHOUT touching `updatedAt`. */
    fun markPlaylistPlayed(id: String) = synchronized(lock) {
        if (playlists.none { it.id == id }) return
        publish { s ->
            s.copy(playlists = s.playlists.map { if (it.id == id) it.copy(lastPlayedAt = now()) else it })
        }
        save()
    }

    /** Stamp a pocket's `lastPlayedAt` = now WITHOUT touching `updatedAt`. */
    fun markPocketPlayed(id: String) = synchronized(lock) {
        if (pockets.none { it.id == id }) return
        publish { s ->
            s.copy(pockets = s.pockets.map { if (it.id == id) it.copy(lastPlayedAt = now()) else it })
        }
        save()
    }

    // MARK: Setlist post-Play edits (stay editable; totals recomputed from shownMs)

    fun deleteSetlist(id: String) = synchronized(lock) {
        publish { s -> s.copy(setlists = s.setlists.filterNot { it.id == id }) }
        save()
    }

    fun renameSetlist(id: String, name: String): Setlist? = mutateSetlist(id) { it.copy(name = name) }

    /** Edit one frozen track's performer note (by index). */
    fun setSetlistTrackNote(id: String, trackIndex: Int, note: String?): Setlist? = mutateSetlist(id) { sl ->
        if (trackIndex !in sl.tracks.indices) return@mutateSetlist sl
        sl.copy(
            tracks = sl.tracks.replaceAt(trackIndex, sl.tracks[trackIndex].copy(note = note)),
        ).recomputedTotal()
    }

    fun removeSetlistTrack(id: String, index: Int): Setlist? = mutateSetlist(id) { sl ->
        if (index !in sl.tracks.indices) return@mutateSetlist sl
        sl.copy(tracks = sl.tracks.toMutableList().also { it.removeAt(index) }).recomputedTotal()
    }

    fun moveSetlistTrack(id: String, from: Int, to: Int): Setlist? = mutateSetlist(id) { sl ->
        sl.copy(tracks = sl.tracks.moved(from, to)).recomputedTotal()
    }

    /** Append a free-text NOTE row (isText, 0 ms; groups with the last chapter). */
    fun addSetlistNote(text: String, setlistId: String): Setlist? = mutateSetlist(setlistId) { sl ->
        sl.copy(
            tracks = sl.tracks + SetlistTrack(
                songId = "",
                artist = "",
                name = text,
                source = TrackSource.EXPLICIT,
                sequenceName = sl.tracks.lastOrNull()?.sequenceName,
                isText = true,
            ),
        ).recomputedTotal()
    }

    private fun Setlist.recomputedTotal(): Setlist = copy(totalMs = tracks.sumOf { it.shownMs })

    // MARK: Full wipe

    /** Reset every family AND delete the on-disk document (Settings/tests seam). */
    fun clear() = synchronized(lock) {
        salvagePending = false
        publish {
            it.copy(
                pockets = emptyList(),
                playlists = emptyList(),
                setlists = emptyList(),
                folders = emptyList(),
                lastAddTarget = null,
                recentAddTargets = emptyList(),
            )
        }
        runCatching { file.delete() }
        onChange?.invoke()
    }

    // MARK: Internals (call under lock)

    private fun publish(transform: (State) -> State) {
        val next = transform(_state.value)
        _state.value = next.copy(revision = next.revision + 1)
    }

    private fun mutatePocket(id: String, body: (Pocket) -> Pocket) = synchronized(lock) {
        mutatePocketLocked(id, body)
    }

    /** EVERY pocket membership/rename/reorder edit funnels here: body → stamp updatedAt → save. */
    private fun mutatePocketLocked(id: String, body: (Pocket) -> Pocket) {
        val idx = pockets.indexOfFirst { it.id == id }
        if (idx < 0) return // missing id ⇒ silent no-op
        publish { s ->
            s.copy(pockets = s.pockets.replaceAt(idx, body(s.pockets[idx]).copy(updatedAt = now())))
        }
        save()
    }

    private fun mutatePlaylist(id: String, body: (Playlist) -> Playlist) = synchronized(lock) {
        mutatePlaylistLocked(id, body)
    }

    private fun mutatePlaylistLocked(id: String, body: (Playlist) -> Playlist) {
        val idx = playlists.indexOfFirst { it.id == id }
        if (idx < 0) return
        publish { s ->
            s.copy(playlists = s.playlists.replaceAt(idx, body(s.playlists[idx]).copy(updatedAt = now())))
        }
        save()
    }

    private fun mutateSetlist(id: String, body: (Setlist) -> Setlist): Setlist? = synchronized(lock) {
        val idx = setlists.indexOfFirst { it.id == id }
        if (idx < 0) return null
        publish { s -> s.copy(setlists = s.setlists.replaceAt(idx, body(s.setlists[idx]))) }
        save()
        setlist(id)
    }

    private sealed interface ReadResult {
        data class Ok(val doc: CollectionsDocument) : ReadResult
        data object Absent : ReadResult
        data object Corrupt : ReadResult
        data object Unreadable : ReadResult
    }

    private fun readDocument(): ReadResult {
        if (!file.exists()) return ReadResult.Absent
        val text = try {
            file.readText()
        } catch (_: Exception) {
            return ReadResult.Unreadable
        }
        return try {
            ReadResult.Ok(CollectionsCodec.decode(json, text))
        } catch (_: Exception) {
            ReadResult.Corrupt
        }
    }

    /**
     * One-shot recovery for a launch-time transient read failure: before the
     * first overwrite, union the disk doc's items (by id) with anything created
     * since, so an intact file is never clobbered by an empty in-memory doc.
     */
    private fun salvageIfPending() {
        if (!salvagePending) return
        salvagePending = false
        val disk = (readDocument() as? ReadResult.Ok)?.doc ?: return
        publish { s ->
            fun <T> union(memory: List<T>, fromDisk: List<T>, idOf: (T) -> String): List<T> {
                val seen = memory.mapTo(HashSet(), idOf)
                return memory + fromDisk.filterNot { idOf(it) in seen }
            }
            s.copy(
                pockets = union(s.pockets, disk.pockets) { it.id },
                playlists = union(s.playlists, disk.playlists) { it.id },
                setlists = union(
                    s.setlists,
                    disk.setlists.filterNot {
                        it.id == NOW_PLAYING_SETLIST_ID || it.playlistId == NOW_PLAYING_PLAYLIST_ID
                    },
                ) { it.id },
                folders = union(s.folders, disk.folders) { it.id },
                lastAddTarget = s.lastAddTarget ?: disk.lastAddTarget,
                recentAddTargets = s.recentAddTargets.ifEmpty { disk.recentAddTargets ?: emptyList() },
            )
        }
    }

    /** Atomic write (temp + rename), ordered after every mutation. */
    private fun save() {
        salvageIfPending()
        val s = _state.value
        val doc = CollectionsDocument(
            schemaVersion = COLLECTIONS_SCHEMA_VERSION,
            pockets = s.pockets,
            playlists = s.playlists,
            setlists = s.setlists,
            folders = s.folders,
            lastAddTarget = s.lastAddTarget,
            // Written as ABSENT when empty (iOS parity).
            recentAddTargets = s.recentAddTargets.ifEmpty { null },
        )
        try {
            file.parentFile?.mkdirs()
            val tmp = File(file.parentFile, file.name + ".tmp")
            tmp.writeText(CollectionsCodec.encode(json, doc))
            if (!tmp.renameTo(file)) {
                // renameTo can fail when the destination exists. Overwrite-copy
                // in place (no file.delete() window that a process kill could turn
                // into total loss with a complete .tmp sitting unused) then drop
                // the temp.
                tmp.copyTo(file, overwrite = true)
                tmp.delete()
            }
        } catch (_: Exception) {
            // Persistence is best-effort; in-memory state stays authoritative.
        }
        onChange?.invoke()
    }

    companion object {
        /** iOS parity: `pocketdj-collections.json` in the app-private dir. */
        const val FILE_NAME = "pocketdj-collections.json"

        /** MRU retention (UI shows the top 3 that still resolve). */
        const val MAX_RECENT_TARGETS = 10
    }
}

// MARK: - Small list helpers

private fun <T> List<T>.replaceAt(index: Int, item: T): List<T> =
    toMutableList().also { it[index] = item }

private fun <T> List<T>.moved(from: Int, to: Int): List<T> {
    if (from == to || from !in indices) return this
    val m = toMutableList()
    val item = m.removeAt(from)
    m.add(to.coerceIn(0, m.size), item)
    return m
}

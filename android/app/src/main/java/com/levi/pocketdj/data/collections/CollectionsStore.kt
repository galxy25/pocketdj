package com.levi.pocketdj.data.collections

import com.levi.pocketdj.data.PdjJson
import com.levi.pocketdj.data.activity.ActivityEvent
import com.levi.pocketdj.data.activity.ActivityKind
import com.levi.pocketdj.data.applemusic.PlaylistWriteBack
import com.levi.pocketdj.data.catalog.MergedCatalog
import com.levi.pocketdj.data.catalog.SourcePlaylist
import com.levi.pocketdj.data.rips.PlayResolver
import com.levi.pocketdj.data.store.VersionedJsonWriter
import com.levi.pocketdj.playback.PlayContext
import java.io.File
import kotlin.random.Random
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.asStateFlow
import kotlinx.coroutines.flow.getAndUpdate
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
    /** Version-ordered document writer; production wires a background executor (AppGraph). */
    private val writer: VersionedJsonWriter = VersionedJsonWriter(file),
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
        val itemArtist: String? = null,
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
        /**
         * The source is a real Apple Music playlist AND the song can be written back (a store id OR
         * title+artist to resolve one at delivery). False = local-only by nature.
         */
        val writeBackEligible: Boolean = false,
        val appleMusicId: String? = null,
        /** A NEW upstream job was queued by this call (the write-back seam took it). */
        val writeBackQueued: Boolean = false,
        /** The song is already in Apple Music's own membership (the source snapshot) — nothing owed. */
        val alreadyUpstream: Boolean = false,
        /** Eligible, but the queue already holds / delivered this song ("already on its way"). */
        val writeBackDeduped: Boolean = false,
        /** Apple Music source, but the song has neither a store id nor title+artist to match with. */
        val writeBackNoIdentity: Boolean = false,
    )

    /** How many recent add-targets we retain (UI shows the top 3 that resolve). */
    val maxRecentTargets: Int get() = MAX_RECENT_TARGETS

    /**
     * The catalog the resolvers + realize engine read (wired in AppGraph to the
     * live [MergedCatalog]). Null until wired — every consumer degrades.
     */
    var catalogProvider: (() -> MergedCatalog?)? = null

    /**
     * STU-7 Studio seam (iOS `studioLookup`): resolve a studio id to title + REAL length so counts /
     * runtime / realize / playNow include studio items. null = unwired = studio ids drop out.
     * Consulted lazily, only for an id that misses the catalog AND has a studio shape.
     */
    @Volatile var studioLookup: StudioLookup? = null

    /** Performer label on synthesized studio rows (the profile's "PocketDJ name"), "Studio" when unset. */
    @Volatile var studioArtist: () -> String = { STUDIO_ARTIST }

    /**
     * iOS `StudioAnalyzer.prepare(forStudioId:)` seam: fired (outside the store lock's critical work, once per
     * studio id) from the add choke points so an item gets its Camelot key + pre-bounce/render at ADD time,
     * not at its turn in a set. Wired in AppGraph; null in tests that don't care.
     */
    @Volatile var onStudioIdsAdded: ((List<String>) -> Unit)? = null

    /** True when any pocket / playlist holds a studio id (AppGraph warms the studio store off-main for it). */
    fun hasStudioItems(): Boolean {
        val st = state.value
        return st.pockets.any { p -> p.songIds.any(PlayResolver::isStudioId) } ||
            st.playlists.any { pl -> songIdsInNodes(pl.sequences).any(PlayResolver::isStudioId) }
    }

    private fun notifyStudioAdded(ids: Collection<String>) {
        val studio = ids.filter { PlayResolver.isStudioId(it) }.distinct()
        if (studio.isEmpty()) return
        runCatching { onStudioIdsAdded?.invoke(studio) }
    }

    /** Display info for a studio id (the row UI), or null for a non-studio / unknown id. */
    fun studioInfo(id: String): StudioItemInfo? =
        if (PlayResolver.isStudioId(id)) studioLookup?.info(id) else null

    /**
     * APPLE-MUSIC WRITE-BACK SEAM (COL-8, iOS `enqueueSourceWriteBack`): wired by CollectionsGraph to
     * `PlaylistWriteBack.enqueue` + `runSoon` (behind its own `canWriteBack` gate). Called from the
     * user-facing add choke points whenever a song lands in a collection CONVERTED/DUPLICATED from an
     * Apple Music source playlist. A SEAM, not a direct reference, so the store stays unit-testable
     * with no account. Returns TRUE when a NEW job was queued. nil = nothing can be written.
     */
    @Volatile var enqueueSourceWriteBack: ((PlaylistWriteBack.EnqueueItem) -> Boolean)? = null

    /** Batch twin (wired to `enqueueMany` + ONE `runSoon`); falls back to N single enqueues when unwired. */
    @Volatile var enqueueSourceWriteBackBatch: ((List<PlaylistWriteBack.EnqueueItem>) -> Int)? = null

    /**
     * Whether THIS session can deliver upstream writes at all (signed in + transport). Consulted
     * before parking a large batch for confirmation. Unwired (tests) = treated as capable.
     */
    @Volatile var canWriteBackUpstream: (() -> Boolean)? = null

    /**
     * Cancel still-undelivered write-backs owed to the OLD source playlist id for the given songs
     * (wired to `PlaylistWriteBack.cancelPending`). Fired when a pocket is re-linked away from a source.
     */
    var cancelPendingWriteBacks: ((indexPlaylistId: String, songIds: Set<String>) -> Unit)? = null

    /** Fired after every persisted mutation (post-save). Reserved seam (iOS Spotlight/Siri). */
    var onChange: (() -> Unit)? = null

    /**
     * The collection-activity seam: fired ONLY from the user-facing add/remove
     * choke points (`addSong(to:)`/`addAlbum(to:)`/the five removes) — NEVER
     * from source-sync reconcile, decode, or low-level membership methods.
     * Wired in AppGraph to `CollectionActivityStore.record`.
     */
    var onActivity: ((ActivityHook) -> Unit)? = null

    /**
     * Batch seam: ONE emission per gesture (a select-all add). When unwired the
     * batch falls back to N [onActivity] calls.
     */
    var onActivityBatch: ((List<ActivityHook>) -> Unit)? = null

    private val lock = Any()
    private var saveVersion = 0L
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

    /**
     * Remove every ALBUM node for [albumId] from a playlist (nested included) in ONE mutation
     * with ONE remove activity — port of iOS `removeAlbum(_:fromPlaylist:)`. Returns nodes pruned.
     */
    fun removeAlbumFromPlaylist(albumId: String, playlistId: String): Int = synchronized(lock) {
        val pl = playlist(playlistId) ?: return 0
        var removed = 0
        fun prune(nodes: List<PlaylistNode>): List<PlaylistNode> = nodes.mapNotNull { n ->
            if (n.kind == PlaylistNode.Kind.ALBUM && n.albumId == albumId) {
                removed++
                null
            } else {
                n.children?.let { n.copy(children = prune(it)) } ?: n
            }
        }
        val pruned = prune(pl.sequences)
        if (removed == 0) return 0
        mutatePlaylistLocked(playlistId) { it.copy(sequences = pruned) }
        emitRemoveActivity(itemId = albumId, collectionId = playlistId, kind = AddTarget.Kind.PLAYLIST, name = pl.name)
        removed
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
        val song = catalogProvider?.invoke()?.songsById?.get(songId)
        val amId = song?.appleMusicId.orEmpty().trim()
        val title = song?.name.orEmpty().trim()
        val artist = song?.artist.orEmpty().trim()
        // Eligible when the target is a real Apple Music playlist AND we have SOMETHING to write with.
        val eligible = PlaylistWriteBack.isAppleMusicSource(source.sourceName) &&
            (amId.isNotEmpty() || (title.isNotEmpty() && artist.isNotEmpty()))
        // The source snapshot IS Apple Music's membership: a song already in it is already upstream,
        // and re-adding would DUPLICATE the track.
        val upstream = songId in source.playlist.songIds
        var queued = false
        var deduped = false
        // iOS addToSource: eligible + not in the source snapshot enqueues even when the local copy
        // already holds it (the queue dedups) - recovers adds made before write-back existed.
        if (eligible && !upstream) {
            val enqueue = enqueueSourceWriteBack
            if (enqueue != null) {
                queued = enqueue(
                    PlaylistWriteBack.EnqueueItem(
                        indexPlaylistId = source.playlist.id, playlistName = source.playlist.name,
                        songId = songId, appleMusicId = amId.ifEmpty { null }, title = title, artist = artist,
                        album = song?.albumId?.let { catalogProvider?.invoke()?.albumsById?.get(it)?.name },
                        durationMs = song?.length?.toInt(),
                    ),
                )
                deduped = !queued && canWriteBackUpstream?.invoke() != false
            }
        }
        IndexPlaylistAdd(
            playlist = playlist(pl.id) ?: pl,
            createdDuplicate = created,
            alreadyPresent = present,
            writeBackEligible = eligible,
            appleMusicId = amId.ifEmpty { null },
            writeBackQueued = queued,
            alreadyUpstream = eligible && upstream,
            writeBackDeduped = deduped,
            writeBackNoIdentity = PlaylistWriteBack.isAppleMusicSource(source.sourceName) && !eligible,
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
        val made = makeAndSavePocket(pl.name, songIds, albumIds, childPocketIds, noteTexts)
        // Carry the source link (iOS 113508b): duplicate → convert must stay two-way-synced.
        if (pl.sourcePlaylistId != null) {
            mutatePocket(made.id) {
                it.copy(
                    sourcePlaylistId = pl.sourcePlaylistId,
                    sourceName = pl.sourceName,
                    sourceSongIds = pl.sourceSongIds,
                    sourceSyncEnabled = pl.sourceSyncEnabled,
                )
            }
        }
        return pocket(made.id) ?: made
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
        for (p in pockets.filter { it.syncsWithSource && it.amSyncDir.allowsPull }) {
            val sp = match(p.sourcePlaylistId, p.sourceName) ?: continue
            if (reconcilePocket(p.id, sp)) changed++
        }
        for (pl in playlists.filter { it.syncsWithSource && it.amSyncDir.allowsPull }) {
            val sp = match(pl.sourcePlaylistId, pl.sourceName) ?: continue
            if (reconcilePlaylist(pl.id, sp)) changed++
        }
        changed
    }

    /**
     * Link an EXISTING pocket to a source playlist after the fact (iOS linkPocketToSource).
     * Snapshots the source's CURRENT deduped membership as the merge base (the pocket's extra
     * songs read as user adds, never source removals). Never forces sourceSyncEnabled: a first
     * link leaves it null (enabled by default) and a re-link preserves an explicit OFF. Re-linking
     * to a DIFFERENT source cancels pending write-backs owed to the old one for this pocket's songs.
     * False when the pocket is gone.
     */
    fun linkPocketToSource(pocketId: String, source: SourcePlaylist): Boolean = synchronized(lock) {
        val p = pocket(pocketId) ?: return false
        val old = p.sourcePlaylistId
        if (old != null && old != source.playlist.id) {
            cancelPendingWriteBacks?.invoke(old, p.songIds.toSet())
        }
        val ids = source.playlist.songIds.distinct()
        mutatePocketLocked(pocketId) {
            it.copy(
                sourcePlaylistId = source.playlist.id,
                sourceName = source.sourceName,
                sourceSongIds = ids,
            )
        }
        true
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
        // NAME+ARTIST (+ same-release) duplicate gate: a source add whose recording already sits
        // in the pocket under a DIFFERENT id is skipped.
        val keptAfterRemovals = p.songIds.filterNot { it in removals }
        val present = SongDuplicateJudge.Seen()
        for (sid in keptAfterRemovals) duplicateIdentity(sid)?.let { present.insert(it) }
        val additions = srcIds.filter { sid ->
            if (sid in snapSet || sid in current) return@filter false
            val ident = duplicateIdentity(sid) ?: return@filter true
            present.insert(ident)
        }
        val newSongIds = keptAfterRemovals + additions
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
        val presentPl = SongDuplicateJudge.Seen()
        for (sid in currentSongIds - removals) duplicateIdentity(sid)?.let { presentPl.insert(it) }
        val additions = srcIds.filter { sid ->
            if (sid in snapSet || sid in currentSongIds) return@filter false
            val ident = duplicateIdentity(sid) ?: return@filter true
            presentPl.insert(ident)
        }

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

    // MARK: Remove duplicates (same recording under two ids)

    /** The same-release identity of a catalog song (null = not in the live catalog). */
    fun duplicateIdentity(songId: String): SongDuplicateJudge.Identity? {
        val merged = catalogProvider?.invoke() ?: return null
        val song = merged.songsById[songId] ?: return null
        return SongDuplicateJudge.Identity(
            name = song.name,
            artist = song.artist,
            album = song.albumId?.let { merged.albumsById[it]?.name },
            appleMusicId = song.appleMusicId,
        )
    }

    private fun duplicatePlan(ids: List<String>): SongDuplicateJudge.CollapsePlan {
        if (catalogProvider?.invoke() == null) return SongDuplicateJudge.CollapsePlan()
        return SongDuplicateJudge.collapsePlan(ids) { duplicateIdentity(it) }
    }

    /** Pure rewrite of a pocket; returns (new pocket, removed count). No stamping, no save. */
    private fun collapsed(p: Pocket): Pair<Pocket, Int> {
        val plan = duplicatePlan(p.songIds)
        if (plan.isEmpty) return p to 0
        val songIds = p.songIds.filterNot { it in plan.drop }.map { plan.rename[it] ?: it }
        // The slot's repeat count follows it onto the survivor; every other twin's goes.
        val survivors = plan.rename.values.toSet()
        val repeats = p.songRepeats.toMutableMap()
        for (gone in plan.drop) if (gone !in survivors) repeats.remove(gone)
        for ((from, to) in plan.rename) {
            val v = repeats.remove(from)
            if (v != null) repeats[to] = v else repeats.remove(to)
        }
        return p.copy(songIds = songIds, songRepeats = repeats) to (p.songIds.size - songIds.size)
    }

    private fun collapsed(pl: Playlist): Pair<Playlist, Int> {
        val order = ArrayList<String>()
        fun collect(ns: List<PlaylistNode>) {
            for (n in ns) {
                if (n.kind == PlaylistNode.Kind.SONG) n.songId?.let(order::add)
                n.children?.let(::collect)
            }
        }
        collect(pl.sequences)
        val plan = duplicatePlan(order)
        if (plan.isEmpty) return pl to 0
        var removed = 0
        fun rewrite(ns: List<PlaylistNode>): List<PlaylistNode> = ns.mapNotNull { n ->
            var c = n
            val sid = c.songId
            if (c.kind == PlaylistNode.Kind.SONG && sid != null) {
                if (sid in plan.drop) { removed++; return@mapNotNull null } // prune by ORIGINAL id first
                plan.rename[sid]?.let { c = c.copy(songId = it) }
            }
            c.children?.let { c = c.copy(children = rewrite(it)) }
            c
        }
        return pl.copy(sequences = rewrite(pl.sequences)) to removed
    }

    /**
     * Collapse same-recording twins in one pocket. Survivor prefers an Apple Music id and takes
     * the group's earliest slot. NOT emitted as remove activity (a dedupe is not a "don't want
     * this" signal). Returns how many songs were removed.
     */
    fun removeDuplicatesInPocket(id: String): Int = synchronized(lock) {
        val p = pocket(id) ?: return 0
        val (next, n) = collapsed(p)
        if (n > 0) mutatePocketLocked(id) { next }
        n
    }

    fun removeDuplicatesInPlaylist(id: String): Int = synchronized(lock) {
        val pl = playlist(id) ?: return 0
        val (next, n) = collapsed(pl)
        if (n > 0) mutatePlaylistLocked(id) { next }
        n
    }

    /** Every pocket + playlist, ONE save (the document is multi-MB). Returns the removed total. */
    fun removeDuplicatesEverywhere(): Int = synchronized(lock) {
        var total = 0
        val ts = now()
        val newPockets = pockets.map { p ->
            val (next, n) = collapsed(p)
            if (n > 0) { total += n; next.copy(updatedAt = ts) } else p
        }
        val newPlaylists = playlists.map { pl ->
            val (next, n) = collapsed(pl)
            if (n > 0) { total += n; next.copy(updatedAt = ts) } else pl
        }
        if (total > 0) {
            publish { it.copy(pockets = newPockets, playlists = newPlaylists) }
            save()
        }
        total
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
        notifyStudioAdded(listOf(songId))
        writeBackSong(songId, target.kind, target.id)
        Unit
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

    /** Which membership an [addSongs] batch dedupes against on a playlist. */
    enum class BatchDedupe { WHOLE_COLLECTION, TARGET_CHAPTER }

    /**
     * Batch add choke point: ONE document write, ONE MRU stamp, ONE activity
     * batch for the whole gesture. Dedupes against existing membership AND
     * within [songIds]; appends in order; returns the count added. Zero added
     * => no MRU stamp, no activity (a playlist self-heal still persists once).
     */
    fun addSongs(
        songIds: List<String>,
        target: AddTarget,
        dedupe: BatchDedupe = BatchDedupe.WHOLE_COLLECTION,
    ): Int = synchronized(lock) {
        val added: List<String> = when (target.kind) {
            AddTarget.Kind.POCKET -> {
                val idx = pockets.indexOfFirst { it.id == target.id }
                if (idx < 0) return 0
                val p = pockets[idx]
                val seen = HashSet(p.songIds)
                val fresh = songIds.filter { it.isNotEmpty() && seen.add(it) }
                if (fresh.isEmpty()) return 0
                publish { s ->
                    s.copy(pockets = s.pockets.replaceAt(idx, p.copy(songIds = p.songIds + fresh, updatedAt = now())))
                }
                fresh
            }
            AddTarget.Kind.PLAYLIST -> {
                val idx = playlists.indexOfFirst { it.id == target.id }
                if (idx < 0) return 0
                var pl = playlists[idx]
                // Self-heal: a playlist with no chapters gets a Default one.
                val healed = pl.sequences.isEmpty()
                if (healed) pl = pl.copy(sequences = listOf(CollectionsFactory.makeSequence("Default")))
                val seqIdx = target.sequenceId
                    ?.let { sid -> pl.sequences.indexOfFirst { it.nodeId == sid }.takeIf { it >= 0 } } ?: 0
                val seq = pl.sequences.getOrNull(seqIdx)
                val seen = HashSet<String>()
                if (seq != null) {
                    seen += when (dedupe) {
                        BatchDedupe.WHOLE_COLLECTION -> songIdsInNodes(pl.sequences)
                        BatchDedupe.TARGET_CHAPTER -> songIdsInNodes(seq.children.orEmpty())
                    }
                }
                val fresh = if (seq == null) emptyList() else songIds.filter { it.isNotEmpty() && seen.add(it) }
                if (fresh.isEmpty() && !healed) return 0
                val nodes = fresh.map {
                    PlaylistNode(nodeId = CollectionsFactory.newNodeId(), kind = PlaylistNode.Kind.SONG, songId = it)
                }
                val next = if (seq == null) pl else pl.copy(
                    sequences = pl.sequences.replaceAt(seqIdx, seq.copy(children = seq.children.orEmpty() + nodes)),
                )
                publish { s -> s.copy(playlists = s.playlists.replaceAt(idx, next.copy(updatedAt = now()))) }
                if (fresh.isEmpty()) {
                    save()
                    return 0
                }
                fresh
            }
        }
        noteRecentTarget(target)
        publish { it.copy(lastAddTarget = target) }
        save()
        emitBatch(added.map { addHook(it, target) })
        notifyStudioAdded(added)
        writeBackBatch(added, target)
        added.size
    }

    // MARK: Two-way source sync - push a converted/duplicated collection's add upstream (COL-8)

    /**
     * The outcome of a single write-back decision - rich enough to drive the force-sync feedback.
     * The per-add path + backfill only care about [QUEUED] (a NEW job was enqueued).
     */
    enum class WriteBackAttempt {
        /** The queue accepted a NEW upstream job. */
        QUEUED,

        /** The seam took nothing: an equivalent job is queued/delivered, UNRESOLVABLE, or this session can't write. */
        DEDUPED,

        /** No Apple Music source playlist to write to (a plain pocket, or a vinyl / digital source). */
        NOT_LINKED,

        /** The collection's sync direction is "Get only"/"Off": upstream writes are disabled. */
        PUSH_DISABLED,

        /** A Studio/performance/profile item - not an Apple Music catalog song. */
        NOT_CATALOG_SONG,

        /** A catalog song with NEITHER a store id NOR a title+artist to resolve one. */
        NO_IDENTITY,

        /** Already in the source SNAPSHOT (already upstream). Only the non-force path returns it. */
        ALREADY_UPSTREAM,
    }

    /**
     * A large batch's upstream leg awaiting the user's OK. Transient (never persisted); the LOCAL add
     * has already been committed when this appears - only the Apple Music push waits.
     */
    data class PendingWriteBackBatch(
        val items: List<PlaylistWriteBack.EnqueueItem>,
        val playlistName: String,
    ) {
        val count: Int get() = items.size
    }

    private val _pendingWriteBackBatch = MutableStateFlow<PendingWriteBackBatch?>(null)
    val pendingWriteBackBatch: StateFlow<PendingWriteBackBatch?> = _pendingWriteBackBatch.asStateFlow()

    /** The user confirmed the parked batch - push it upstream (one queue write + one drain). */
    fun confirmPendingWriteBackBatch() {
        val pending = _pendingWriteBackBatch.getAndUpdate { null } ?: return
        enqueueWriteBackItems(pending.items)
    }

    /** The user declined - the local add stands; Apple Music is left untouched. */
    fun discardPendingWriteBackBatch() { _pendingWriteBackBatch.value = null }

    private sealed interface WriteBackResolution {
        data class Eligible(val item: PlaylistWriteBack.EnqueueItem) : WriteBackResolution
        data class Ineligible(val verdict: WriteBackAttempt) : WriteBackResolution
    }

    /**
     * One song's write-back eligibility: AM provenance (source is "Apple Music (Local)"/"Apple Music"),
     * a CATALOG song (profile "pdj_" ids and studio ids fenced out), a store id OR title+artist, and
     * not in the source SNAPSHOT unless [force]. The SINGLE implementation both the per-add path and
     * the batch path run, so their eligibility can never drift.
     */
    private fun writeBackPayload(
        songId: String,
        sourcePlaylistId: String?,
        sourceName: String?,
        sourceSnapshot: Set<String>,
        collectionName: String,
        force: Boolean,
    ): WriteBackResolution {
        val plId = sourcePlaylistId
        if (plId == null || !PlaylistWriteBack.isAppleMusicSource(sourceName)) {
            return WriteBackResolution.Ineligible(WriteBackAttempt.NOT_LINKED)
        }
        // Device-local custom audio ("Pocket DJ" profile source) has NO Apple Music counterpart.
        if (songId.startsWith(PROFILE_SONG_PREFIX) || PlayResolver.isStudioId(songId)) {
            return WriteBackResolution.Ineligible(WriteBackAttempt.NOT_CATALOG_SONG)
        }
        val merged = catalogProvider?.invoke()
        val song = merged?.songsById?.get(songId)
            ?: return WriteBackResolution.Ineligible(WriteBackAttempt.NOT_CATALOG_SONG)
        val amId = song.appleMusicId.orEmpty().trim()
        val title = song.name.trim()
        val artist = song.artist.trim()
        if (amId.isEmpty() && (title.isEmpty() || artist.isEmpty())) {
            return WriteBackResolution.Ineligible(WriteBackAttempt.NO_IDENTITY)
        }
        // A FORCE sync overrides the snapshot guard (stale / over-broad snapshot); the transport's own
        // "already in the playlist?" pre-check is the backstop against a true duplicate.
        if (!force && songId in sourceSnapshot) {
            return WriteBackResolution.Ineligible(WriteBackAttempt.ALREADY_UPSTREAM)
        }
        val album = song.albumId?.let { merged.albumsById[it]?.name }
        // Prefer the live source playlist's current name (drift-proof), else the collection's own name.
        val name = liveSourcePlaylist(plId, sourceName)?.playlist?.name?.takeIf { it.isNotEmpty() } ?: collectionName
        return WriteBackResolution.Eligible(
            PlaylistWriteBack.EnqueueItem(
                indexPlaylistId = plId, playlistName = name, songId = songId,
                appleMusicId = amId.ifEmpty { null }, title = title, artist = artist,
                album = album, durationMs = song.length?.toInt(),
            ),
        )
    }

    /** The eligible queue item for one collection add, or null (any verdict that would not queue). */
    private fun writeBackItem(songId: String, kind: AddTarget.Kind, collectionId: String): PlaylistWriteBack.EnqueueItem? {
        val t = when (kind) {
            AddTarget.Kind.POCKET -> pocket(collectionId)?.let {
                WbTarget(it.sourcePlaylistId, it.sourceName, it.sourceSongIds, it.name, it.amSyncDir.allowsPush)
            }
            AddTarget.Kind.PLAYLIST -> playlist(collectionId)?.let {
                WbTarget(it.sourcePlaylistId, it.sourceName, it.sourceSongIds, it.name, it.amSyncDir.allowsPush)
            }
        } ?: return null
        if (!t.allowsPush) return null
        return (writeBackPayload(songId, t.plId, t.sourceName, t.snapshot.orEmpty().toSet(), t.name, false)
            as? WriteBackResolution.Eligible)?.item
    }

    /** Resolve a collection's provenance from its id + kind, then decide whether to write [songId] back. */
    private fun writeBackSong(
        songId: String,
        kind: AddTarget.Kind,
        collectionId: String,
        force: Boolean = false,
    ): WriteBackAttempt {
        val (plId, sourceName, snapshot, name, allowsPush) = when (kind) {
            AddTarget.Kind.POCKET -> {
                val p = pocket(collectionId) ?: return WriteBackAttempt.NOT_LINKED
                WbTarget(p.sourcePlaylistId, p.sourceName, p.sourceSongIds, p.name, p.amSyncDir.allowsPush)
            }
            AddTarget.Kind.PLAYLIST -> {
                val pl = playlist(collectionId) ?: return WriteBackAttempt.NOT_LINKED
                WbTarget(pl.sourcePlaylistId, pl.sourceName, pl.sourceSongIds, pl.name, pl.amSyncDir.allowsPush)
            }
        }
        // Direction gate: a "Get only"/"Off" collection never writes upstream.
        if (!allowsPush) return WriteBackAttempt.PUSH_DISABLED
        val enqueue = enqueueSourceWriteBack ?: return WriteBackAttempt.NOT_LINKED
        return when (
            val r = writeBackPayload(songId, plId, sourceName, snapshot.orEmpty().toSet(), name, force)
        ) {
            is WriteBackResolution.Ineligible -> r.verdict
            is WriteBackResolution.Eligible -> if (enqueue(r.item)) WriteBackAttempt.QUEUED else WriteBackAttempt.DEDUPED
        }
    }

    private data class WbTarget(
        val plId: String?,
        val sourceName: String?,
        val snapshot: List<String>?,
        val name: String,
        val allowsPush: Boolean,
    )

    /**
     * FORCE a write-back attempt for one song, bypassing the "already in the source snapshot" guard -
     * the manual escape hatch behind "Force Apple Music sync". It only ever ENQUEUES, never removes.
     */
    fun forceWriteBackSong(songId: String, kind: AddTarget.Kind, collectionId: String): WriteBackAttempt =
        writeBackSong(songId, kind, collectionId, force = true)

    /**
     * Batch twin of the per-add write-back: resolves provenance ONCE, builds every eligible item, then
     * either enqueues the whole batch as ONE queue write (<= threshold) or parks it behind the
     * confirmation gate (> threshold) - upstream adds are append-only and not retractable.
     */
    private fun writeBackBatch(songIds: List<String>, target: AddTarget) {
        if (songIds.isEmpty() || (enqueueSourceWriteBack == null && enqueueSourceWriteBackBatch == null)) return
        val t = when (target.kind) {
            AddTarget.Kind.POCKET -> pocket(target.id)?.let {
                WbTarget(it.sourcePlaylistId, it.sourceName, it.sourceSongIds, it.name, it.amSyncDir.allowsPush)
            }
            AddTarget.Kind.PLAYLIST -> playlist(target.id)?.let {
                WbTarget(it.sourcePlaylistId, it.sourceName, it.sourceSongIds, it.name, it.amSyncDir.allowsPush)
            }
        } ?: return
        if (!t.allowsPush || t.plId == null || !PlaylistWriteBack.isAppleMusicSource(t.sourceName)) return
        val snap = t.snapshot.orEmpty().toSet() // scanned per song - Set it once
        val items = songIds.mapNotNull {
            (writeBackPayload(it, t.plId, t.sourceName, snap, t.name, force = false) as? WriteBackResolution.Eligible)?.item
        }
        if (items.isEmpty()) return
        if (items.size > WRITE_BACK_CONFIRM_THRESHOLD) {
            // A session that can't deliver must never show a confirm dialog for nothing.
            if (canWriteBackUpstream?.invoke() == false) return
            _pendingWriteBackBatch.value = PendingWriteBackBatch(items, items[0].playlistName)
        } else {
            enqueueWriteBackItems(items)
        }
    }

    private fun enqueueWriteBackItems(items: List<PlaylistWriteBack.EnqueueItem>) {
        val batch = enqueueSourceWriteBackBatch
        val single = enqueueSourceWriteBack
        if (batch != null) {
            batch(items)
        } else if (single != null) {
            items.forEach { single(it) }
        }
    }

    /**
     * BACKFILL the outbound write-back from the collection ACTIVITY history: for every ADD in the last
     * [days] days (clamped 1..90) to a converted/duplicated Apple Music collection, re-drive the same
     * decision the per-add path makes. Recovers adds made before write-back existed or while offline.
     *
     * IDEMPOTENT: each (collection, song) is considered once (newest add first), a song still in the
     * source snapshot is skipped, a song since REMOVED from the collection is skipped, and the queue
     * dedups against queued/delivered jobs. LOCAL-ORIGIN ONLY: the activity log is cloud-synced but the
     * queue is device-local, so a PEER's add (originInstallId != [localInstallId]) is skipped; a legacy
     * event with no origin counts as local. Returns the number of songs NEWLY queued.
     */
    fun backfillSourceWriteBacks(
        events: List<ActivityEvent>,
        days: Int,
        localInstallId: String?,
        nowMs: Double = now(),
    ): Int {
        if (enqueueSourceWriteBack == null) return 0
        val clamped = days.coerceIn(1, WRITE_BACK_BACKFILL_MAX_DAYS)
        val sinceMs = nowMs - clamped * 86_400_000.0
        val seen = HashSet<String>()
        var queued = 0
        val items = ArrayList<PlaylistWriteBack.EnqueueItem>()
        // Newest-first so a re-add after a remove is judged on the LATEST add's timestamp.
        for (e in events.asReversed()) {
            if (e.kind != ActivityKind.ADD || e.at < sinceMs) continue
            if (e.originInstallId != null && e.originInstallId != localInstallId) continue
            val cid = e.collectionId ?: continue
            if (e.itemId.isEmpty()) continue
            val kind = AddTarget.Kind.entries.firstOrNull { it.token == e.collectionKind } ?: continue
            if (!seen.add(cid + "\u0001" + e.itemId)) continue
            val stillMember = when (kind) {
                AddTarget.Kind.POCKET -> pocket(cid)?.songIds?.contains(e.itemId) ?: false
                AddTarget.Kind.PLAYLIST -> playlistContains(cid, e.itemId)
            }
            if (!stillMember) continue
            val item = writeBackItem(e.itemId, kind, cid) ?: continue
            items += item
        }
        if (items.isEmpty()) return 0
        // ONE queue write + one drain (not a synchronous full-file write per add).
        val batch = enqueueSourceWriteBackBatch
        if (batch != null) return batch(items)
        val single = enqueueSourceWriteBack ?: return 0
        for (it in items) if (single(it)) queued++
        return queued
    }

    /** Remove many songs from a pocket in ONE mutate/write/activity batch. */
    fun removeSongsFromPocket(songIds: Collection<String>, pocketId: String): Int = synchronized(lock) {
        val p = pocket(pocketId) ?: return 0
        val drop = songIds.toSet()
        val gone = p.songIds.filter { it in drop }.distinct()
        if (gone.isEmpty()) return 0
        mutatePocketLocked(pocketId) {
            it.copy(songIds = it.songIds.filterNot { id -> id in drop }, songRepeats = it.songRepeats - drop)
        }
        emitBatch(gone.map { removeHook(it, pocketId, AddTarget.Kind.POCKET, p.name) })
        gone.size
    }

    /** Prune every `.song` node with these ids across nested sequences in ONE mutate. */
    fun removeSongsFromPlaylist(songIds: Collection<String>, playlistId: String): Int = synchronized(lock) {
        val pl = playlist(playlistId) ?: return 0
        val drop = songIds.toSet()
        val present = songIdsInNodes(pl.sequences).filter { it in drop }
        if (present.isEmpty()) return 0
        fun prune(nodes: List<PlaylistNode>): List<PlaylistNode> = nodes.mapNotNull { n ->
            if (n.kind == PlaylistNode.Kind.SONG && n.songId in drop) {
                null
            } else {
                n.children?.let { n.copy(children = prune(it)) } ?: n
            }
        }
        mutatePlaylistLocked(playlistId) { it.copy(sequences = prune(it.sequences)) }
        emitBatch(songIds.filter { it in present }.distinct().map { removeHook(it, playlistId, AddTarget.Kind.PLAYLIST, pl.name) })
        present.size
    }

    private fun emitBatch(hooks: List<ActivityHook>) {
        if (hooks.isEmpty()) return
        val batch = onActivityBatch
        if (batch != null) batch(hooks) else onActivity?.let { f -> hooks.forEach(f) }
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
        return merged.songsById[id]?.name ?: merged.albumsById[id]?.name ?: studioInfo(id)?.title
    }

    private fun activityArtist(id: String): String? {
        val merged = catalogProvider?.invoke() ?: return null
        return (merged.songsById[id]?.artist ?: merged.albumsById[id]?.artist)?.takeIf { it.isNotEmpty() }
    }

    private fun plainCollectionName(target: AddTarget): String? = when (target.kind) {
        AddTarget.Kind.POCKET -> pocket(target.id)?.name
        AddTarget.Kind.PLAYLIST -> playlist(target.id)?.name
    }

    private fun emitAddActivity(itemId: String, target: AddTarget) {
        onActivity?.invoke(addHook(itemId, target))
    }

    private fun addHook(itemId: String, target: AddTarget): ActivityHook =
            ActivityHook(
                kind = ActivityHook.Kind.ADD,
                itemId = itemId,
                itemTitle = activityTitle(itemId),
                itemArtist = activityArtist(itemId),
                collectionId = target.id,
                collectionKind = target.kind.token,
                collectionName = plainCollectionName(target),
            )

    private fun emitRemoveActivity(
        itemId: String,
        collectionId: String,
        kind: AddTarget.Kind,
        name: String?,
        itemTitle: String? = null,
    ) {
        onActivity?.invoke(removeHook(itemId, collectionId, kind, name, itemTitle))
    }

    private fun removeHook(
        itemId: String,
        collectionId: String,
        kind: AddTarget.Kind,
        name: String?,
        itemTitle: String? = null,
    ): ActivityHook =
            ActivityHook(
                kind = ActivityHook.Kind.REMOVE,
                itemId = itemId,
                itemTitle = itemTitle ?: activityTitle(itemId),
                itemArtist = activityArtist(itemId),
                collectionId = collectionId,
                collectionKind = kind.token,
                collectionName = name,
            )

    // MARK: Resolution (songIds = rip/burn-facing, studio-stripped · playableIds = playback)

    private fun collectionCatalog(): CollectionCatalog {
        val merged = catalogProvider?.invoke()
        return CollectionCatalog(
            songsById = merged?.songsById ?: emptyMap(),
            albumsById = merged?.albumsById ?: emptyMap(),
            pocketsById = pockets.associateBy { it.id },
            studioLookup = studioLookup,
            studioArtist = studioArtist().ifBlank { STUDIO_ARTIST },
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
            // Candidates come from the CATALOG only: a studio item is never an autofill bridge.
            candidates = merged.songs.filter { it.bpm != null && it.camelot != null },
            studioLookup = studioLookup,
            studioArtist = studioArtist().ifBlank { STUDIO_ARTIST },
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
            // Catalog first, then a synthesized studio pseudo-song (real length); else drop.
            val s = resolveSongOrStudio(merged.songsById, id, studioLookup, studioArtist().ifBlank { STUDIO_ARTIST })
                ?: return@mapNotNull null // drop unresolvable ids
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

    /** One live-queue row for [materializeNowPlayingSetlist]. */
    data class QueueRowSnapshot(
        val id: String,
        val title: String,
        val artist: String,
        val lengthMs: Long? = null,
        val repeatCount: Int? = null,
    )

    /**
     * The Up Next header's SETLIST button target: the reserved Now Playing setlist if it still exists,
     * else MATERIALIZED from the live queue (a durable-session restore leaves the queue only in the
     * sequencer). Rows carry their own snapshot; bpm/camelot re-attach from the catalog when the id
     * still resolves. Does not bump the restart token or touch the origin (it is not a new play).
     */
    fun materializeNowPlayingSetlistIfMissing(name: String?, queue: List<QueueRowSnapshot>): Setlist? = synchronized(lock) {
        setlist(NOW_PLAYING_SETLIST_ID)?.let { return it }
        if (queue.isEmpty()) return null
        val songs = catalogProvider?.invoke()?.songsById
        val tracks = queue.map { row ->
            val s = songs?.get(row.id)
            SetlistTrack(
                songId = row.id,
                artist = row.artist,
                name = row.title,
                bpm = s?.bpm,
                camelot = s?.camelot,
                lengthMs = row.lengthMs ?: s?.length,
                source = TrackSource.EXPLICIT,
                repeatCount = CollectionMembership.storedRepeat(row.repeatCount ?: 1),
            )
        }
        val set = Setlist(
            id = NOW_PLAYING_SETLIST_ID,
            playlistId = NOW_PLAYING_PLAYLIST_ID,
            name = name ?: "Now Playing",
            seed = "now-playing",
            generatedAt = now(),
            totalMs = tracks.sumOf { it.shownMs },
            tracks = tracks,
        )
        publish { st -> st.copy(setlists = st.setlists + set) }
        save()
        set
    }

    /**
     * "Open set list": upsert ONLY the reserved Now Playing setlist from the LIVE queue (every row
     * kept, non-catalog rows with their own title/artist, per-row repeat preserved). Unlike
     * [playNow] it never bumps the restart revision nor touches the source/origin.
     */
    fun materializeNowPlayingSetlist(
        name: String,
        queue: List<com.levi.pocketdj.playback.sequencer.QueueItem>,
    ): Setlist = synchronized(lock) {
        val merged = catalogProvider?.invoke()
        val tracks = queue.map { q ->
            val s = merged?.songsById?.get(q.id)
            SetlistTrack(
                songId = q.id,
                artist = s?.artist ?: q.artist.orEmpty(),
                name = s?.name ?: q.title,
                bpm = s?.bpm,
                camelot = s?.camelot,
                lengthMs = s?.length ?: q.lengthMs,
                source = TrackSource.EXPLICIT,
                repeatCount = q.repeatCount?.let { CollectionMembership.storedRepeat(it) },
            )
        }
        val set = Setlist(
            id = NOW_PLAYING_SETLIST_ID,
            playlistId = NOW_PLAYING_PLAYLIST_ID,
            name = name,
            seed = "now-playing",
            generatedAt = now(),
            totalMs = tracks.sumOf { it.shownMs },
            tracks = tracks,
        )
        publish { s ->
            val idx = s.setlists.indexOfFirst { it.id == NOW_PLAYING_SETLIST_ID }
            s.copy(setlists = if (idx >= 0) s.setlists.replaceAt(idx, set) else s.setlists + set)
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

    // MARK: Cloud sync (SVC-7)

    /**
     * The profile's PocketDJ name, mirrored in by `ProfileStore.onNameApplied` (iOS
     * `collections.performerName`). Stamped on performance items; blank means "Studio" at the consumers.
     */
    @Volatile var performerName: String = ""

    /**
     * Re-decode the on-disk document after the sync engine pulled a newer cloud copy (whole-document
     * LWW). Mirrors init's decode + stale Now Playing cleanup, then fires [onChange]. Returns false
     * when the file is absent/undecodable (state untouched).
     */
    fun reloadFromDisk(): Boolean {
        val doc = (readDocument() as? ReadResult.Ok)?.doc ?: return false
        synchronized(lock) {
            salvagePending = false
            publish {
                it.copy(
                    pockets = doc.pockets,
                    playlists = doc.playlists,
                    setlists = doc.setlists.filterNot { s ->
                        s.id == NOW_PLAYING_SETLIST_ID || s.playlistId == NOW_PLAYING_PLAYLIST_ID
                    },
                    folders = doc.folders,
                    lastAddTarget = doc.lastAddTarget,
                    recentAddTargets = doc.recentAddTargets ?: emptyList(),
                )
            }
            // The file now holds cloud-pulled content newer than anything the async writer may still
            // have queued: invalidate those stragglers so a pre-pull save cannot overwrite the pull.
            dirty = false
            writer.invalidate(++saveVersion)
        }
        onChange?.invoke()
        return true
    }

    /**
     * Cloud-pull write seam: write the pulled bytes INLINE through this store's own version-ordered
     * writer, superseding any queued pre-pull straggler so stale local bytes can never land after the
     * pulled document. Follow with [reloadFromDisk].
     */
    fun applyPulledPayload(bytes: ByteArray) = synchronized(lock) {
        dirty = false
        val version = ++saveVersion
        writer.flushNow(version) { String(bytes, Charsets.UTF_8) }
    }

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
        dirty = false
        writer.delete(++saveVersion)
        onChange?.invoke()
    }

    // MARK: Internals (call under lock)

    // MARK: Per-collection flags (iOS setAMSyncDirection / setCleanOnly / setRecommendationsEnabled)

    fun setAMSyncDirectionForPocket(direction: CollectionSyncDirection, pocketId: String) =
        mutatePocket(pocketId) { it.copy(amSyncDirection = direction.raw) }

    fun setAMSyncDirectionForPlaylist(direction: CollectionSyncDirection, playlistId: String) =
        mutatePlaylist(playlistId) { it.copy(amSyncDirection = direction.raw) }

    /** Stored `true`/null (never false) so an untouched collection's bytes are unchanged. */
    fun setCleanOnlyForPocket(on: Boolean, pocketId: String) =
        mutatePocket(pocketId) { it.copy(cleanOnly = if (on) true else null) }

    fun setCleanOnlyForPlaylist(on: Boolean, playlistId: String) =
        mutatePlaylist(playlistId) { it.copy(cleanOnly = if (on) true else null) }

    /** Stored `false`/null (never true) — ON is the default. */
    fun setRecommendationsEnabledForPocket(on: Boolean, pocketId: String) =
        mutatePocket(pocketId) { it.copy(recsEnabled = if (on) null else false) }

    fun setRecommendationsEnabledForPlaylist(on: Boolean, playlistId: String) =
        mutatePlaylist(playlistId) { it.copy(recsEnabled = if (on) null else false) }

    /** Binds a collection to its Apple Music playlist. DIRECT write (updatedAt untouched), idempotent. */
    fun linkToAppleMusic(playlistId: String, amPlaylistId: String) = synchronized(lock) {
        val idx = playlists.indexOfFirst { it.id == playlistId }
        if (idx < 0 || playlists[idx].amPlaylistId == amPlaylistId) return@synchronized
        publish { s -> s.copy(playlists = s.playlists.replaceAt(idx, s.playlists[idx].copy(amPlaylistId = amPlaylistId))) }
        save()
    }

    fun linkPocketToAppleMusic(pocketId: String, amPlaylistId: String) = synchronized(lock) {
        val idx = pockets.indexOfFirst { it.id == pocketId }
        if (idx < 0 || pockets[idx].amPlaylistId == amPlaylistId) return@synchronized
        publish { s -> s.copy(pockets = s.pockets.replaceAt(idx, s.pockets[idx].copy(amPlaylistId = amPlaylistId))) }
        save()
    }

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

    private fun snapshotDocument(): CollectionsDocument {
        val s = _state.value
        return CollectionsDocument(
            schemaVersion = COLLECTIONS_SCHEMA_VERSION,
            pockets = s.pockets,
            playlists = s.playlists,
            setlists = s.setlists,
            folders = s.folders,
            lastAddTarget = s.lastAddTarget,
            // Written as ABSENT when empty (iOS parity).
            recentAddTargets = s.recentAddTargets.ifEmpty { null },
        )
    }

    /**
     * Snapshot (immutable data classes) + hand to the version-ordered writer;
     * encode and disk IO happen on the writer's executor. Call under [lock].
     */
    /** True when a mutation was handed to the writer and no inline flush has superseded it. */
    private var dirty = false

    private fun save() {
        salvageIfPending()
        dirty = true
        val doc = snapshotDocument()
        val version = ++saveVersion
        writer.write(version) { CollectionsCodec.encode(json, doc) }
        onChange?.invoke()
    }

    /**
     * Background barrier (ON_STOP): supersede queued stragglers, then write the
     * latest state inline so a process kill right after cannot lose it.
     */
    fun flushNow() = synchronized(lock) {
        // Nothing mutated since the last write/flush: never rewrite an untouched document.
        if (!dirty) return@synchronized
        salvageIfPending()
        dirty = false
        val doc = snapshotDocument()
        val version = ++saveVersion
        writer.flushNow(version) { CollectionsCodec.encode(json, doc) }
    }

    companion object {
        /** iOS parity: `pocketdj-collections.json` in the app-private dir. */
        const val FILE_NAME = "pocketdj-collections.json"

        /** MRU retention (UI shows the top 3 that still resolve). */
        const val MAX_RECENT_TARGETS = 10

        /** Above this many upstream-owed songs a batch add PARKS its write-back behind a confirmation. */
        const val WRITE_BACK_CONFIRM_THRESHOLD = 50
        const val WRITE_BACK_BACKFILL_DEFAULT_DAYS = 2
        const val WRITE_BACK_BACKFILL_MAX_DAYS = 90

        /** Ids of the per-profile "Pocket DJ" custom-audio source (device-local, no Apple Music twin). */
        const val PROFILE_SONG_PREFIX = "pdj_"
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

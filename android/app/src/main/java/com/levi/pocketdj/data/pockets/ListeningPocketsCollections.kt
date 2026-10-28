package com.levi.pocketdj.data.pockets

import com.levi.pocketdj.data.activity.ActivityEvent
import com.levi.pocketdj.data.activity.ActivityKind
import com.levi.pocketdj.data.collections.CollectionFlattener
import com.levi.pocketdj.data.collections.NOW_PLAYING_SETLIST_ID
import com.levi.pocketdj.data.collections.Playlist
import com.levi.pocketdj.data.collections.PlaylistNode
import com.levi.pocketdj.data.collections.Pocket
import com.levi.pocketdj.data.history.PlaySource
import java.security.MessageDigest

/**
 * POCKETS × COLLECTIONS — the upload half (port of apple ListeningPocketsCollections.swift): the
 * flattened membership snapshot + song-level add history, built from [CollectionFlattener]. PURE.
 * Privacy: ids only — collection NAMES never reach this wire.
 */
object ListeningPocketsCollections {

    data class Input(
        val source: CollectionFlattener.Source = CollectionFlattener.Source(),
        val activity: List<ActivityEvent> = emptyList(),
    )

    data class Payload(
        val collections: List<ListeningPocketsCollectionWire>,
        val addEvents: List<ListeningPocketsAddEventWire>,
        /** Content hash over both lists (no send timestamps) — the re-send gate. */
        val hash: String,
    ) {
        val isEmpty: Boolean get() = collections.isEmpty() && addEvents.isEmpty()
    }

    // Caps mirror rec-engine cleanSnapshot.
    const val COLLECTION_CAP = 500
    const val SONG_CAP = 5_000
    const val TOTAL_SONG_CAP = 100_000
    const val ADD_EVENTS_CAP = 5_000
    const val ADD_EVENTS_WINDOW_DAYS = 365.0
    /** Re-send an unchanged snapshot at least this often. */
    const val RESEND_AFTER_MS = 24.0 * 3_600_000
    /** Keep the encoded payload well under the server's 4 MB body ceiling. */
    const val BYTE_CAP = 3_500_000

    /**
     * Flattened, capped membership. A SOURCE playlist bigger than one collection's cap is a
     * library-sized "everything" list: left out rather than truncated.
     */
    fun flattened(source: CollectionFlattener.Source): List<CollectionFlattener.Collection> {
        val src = source.copy(sourcePlaylists = source.sourcePlaylists.filter { it.songIds.size <= SONG_CAP })
        return CollectionFlattener.capped(CollectionFlattener.flatten(src), COLLECTION_CAP, SONG_CAP, TOTAL_SONG_CAP)
    }

    /** Capped, flattened membership + add history. [floorMs] ("Delete cloud data") bounds history from below. */
    fun build(input: Input, nowMs: Double, floorMs: Double = 0.0): Payload {
        val flat = flattened(input.source)
        val adds = CollectionFlattener.addTimes(flat, input.activity, input.source.pockets, input.source.albumTracks)
        val collections = flat.map { c ->
            val a = adds[c.id].orEmpty()
            ListeningPocketsCollectionWire(
                c.id, c.kind, c.songIds,
                c.songIds.mapNotNull { s -> a[s]?.let { ListeningPocketsCollectionWire.Add(s, it.toLong()) } },
            )
        }
        val since = maxOf(nowMs - ADD_EVENTS_WINDOW_DAYS * 86_400_000, floorMs)
        val events = CollectionFlattener.addEvents(
            input.activity, input.source.pockets, input.source.albumTracks, since, ADD_EVENTS_CAP,
        ).map { ListeningPocketsAddEventWire(it.songId, it.collectionId, it.atMs.toLong(), it.kind) }
        return enforceByteCap(Payload(collections, events, hash(collections, events)))
    }

    /**
     * Fit the encoded batch under [BYTE_CAP]: shed add events first (oldest, they are newest-first),
     * then trailing collections, re-hashing so the hash describes what is sent.
     */
    internal fun enforceByteCap(p: Payload, cap: Int = BYTE_CAP): Payload {
        fun size(c: List<ListeningPocketsCollectionWire>, e: List<ListeningPocketsAddEventWire>): Int =
            ListeningPocketsUploadBatch(null, "", 0, emptyList(), collections = c, addEvents = e)
                .toJson().toString().toByteArray(Charsets.UTF_8).size
        var cols = p.collections
        var evs = p.addEvents
        if (size(cols, evs) <= cap) return p
        while (evs.isNotEmpty() && size(cols, evs) > cap) evs = evs.take(evs.size / 2)
        while (cols.isNotEmpty() && size(cols, evs) > cap) cols = cols.take(cols.size / 2)
        return Payload(cols, evs, hash(cols, evs))
    }

    fun hash(collections: List<ListeningPocketsCollectionWire>, events: List<ListeningPocketsAddEventWire>): String {
        val lines = ArrayList<String>(collections.size + 1)
        for (c in collections) {
            val adds = c.adds.joinToString(",") { "${it.songId}@${it.atMs}" }
            lines += "c|${c.id}|${c.kind}|${c.songIds.joinToString(",")}|$adds"
        }
        lines.sort()
        lines += "e|" + events.joinToString(";") { "${it.songId}|${it.collectionId}|${it.atMs}|${it.kind}" }
        val d = MessageDigest.getInstance("SHA-256").digest(lines.joinToString("\n").toByteArray(Charsets.UTF_8))
        return d.joinToString("") { "%02x".format(it) }
    }

    /** Due when content changed, there was no prior send, or the last send is ≥ 24 h old (or in the future). */
    fun isDue(hash: String, lastHash: String?, lastSentAtMs: Double?, nowMs: Double): Boolean {
        if (hash != lastHash || lastSentAtMs == null) return true
        return nowMs - lastSentAtMs >= RESEND_AFTER_MS || nowMs < lastSentAtMs
    }

    /** Every album id a source could need expanded (lets the app build `albumTracks` for just these). */
    fun referencedAlbumCandidates(pockets: List<Pocket>, playlists: List<Playlist>, activity: List<ActivityEvent>): Set<String> {
        val ids = HashSet<String>()
        for (p in pockets) ids += p.albumIds
        fun walk(nodes: List<PlaylistNode>) {
            for (n in nodes) {
                if (n.kind == PlaylistNode.Kind.ALBUM) n.albumId?.let { ids += it }
                n.children?.let { walk(it) }
            }
        }
        for (pl in playlists) walk(pl.sequences)
        for (e in activity) {
            if (e.collectionId != null && (e.kind == ActivityKind.ADD || e.kind == ActivityKind.REMOVE)) ids += e.itemId
        }
        return ids
    }

    // MARK: - Event context

    /**
     * `contextKind` for a play: from the collection id (prefix first — factories mint `pkt_`/`pls_`/`set_`),
     * else from its source surface. The reserved Now Playing setlist is a queue, never a context.
     */
    fun context(contextId: String?, source: PlaySource): Pair<String, String>? {
        val id = contextId?.takeIf { it.isNotEmpty() && it != NOW_PLAYING_SETLIST_ID } ?: return null
        return when {
            id.startsWith("pkt_") -> id to "pocket"
            id.startsWith("pls_") -> id to "playlist"
            id.startsWith("set_") -> id to "setlist"
            else -> when (source) {
                PlaySource.POCKET -> id to "pocket"
                PlaySource.PLAYLIST -> id to "source"   // a non-`pls_` playlist id is a catalog source playlist
                else -> null   // game runs, mix sessions, albums, artists
            }
        }
    }
}

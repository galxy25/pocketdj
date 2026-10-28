package com.levi.pocketdj.data.collections.io

import com.levi.pocketdj.data.PdjJson
import com.levi.pocketdj.data.collections.CollectionsCodec
import com.levi.pocketdj.data.collections.CollectionsDocument
import com.levi.pocketdj.data.collections.Playlist
import com.levi.pocketdj.data.collections.PlaylistFolder
import com.levi.pocketdj.data.collections.PlaylistNode
import com.levi.pocketdj.data.collections.Pocket
import com.levi.pocketdj.data.collections.Setlist
import kotlinx.serialization.json.Json

/** What an imported file is, sniffed from its BYTES (never its extension). */
enum class ImportKind { PLAYLIST, POCKET, BACKUP, COLLECTIONS_JSON }

/** Counts reported to the user after an import (snackbar). */
data class ImportSummary(val kind: ImportKind, val pockets: Int = 0, val playlists: Int = 0, val setlists: Int = 0, val folders: Int = 0,
    /** Incoming items that were new / changed an existing item / changed nothing (sum = items processed). */
    val added: Int = 0, val merged: Int = 0, val unchanged: Int = 0,
) {
    /** True when the import changed nothing ("already up to date"). */
    val alreadyUpToDate: Boolean get() = added == 0 && merged == 0
}

/**
 * Content routing + the single-item `CollectionsDocument` envelope (iOS `exportPocket/exportPlaylist/
 * importCollection`, `detectKind`) and the pure idempotent merge ([Merge]).
 *
 * `.pdjcollection` is simply the playlist/pocket zip under the app's own extension, so routing is by
 * zip magic + manifest `kind`, with a plain JSON `CollectionsDocument` as the legacy fallback.
 */
object CollectionFile {

    /** Zip ⇒ manifest `kind` (playlist/pocket/backup; a PWA backup omits it ⇒ backup). Non-zip ⇒ JSON envelope. */
    fun detectKind(data: ByteArray, json: Json = PdjJson.lenient): ImportKind {
        val entries = ZipIo.read(data) ?: return ImportKind.COLLECTIONS_JSON
        ZipManifest.parse(entries, json)?.let { man ->
            when (ZipManifest.str(man, "kind")) {
                "pocket" -> return ImportKind.POCKET
                "playlist" -> return ImportKind.PLAYLIST
                "backup" -> return ImportKind.BACKUP
            }
        }
        if (entries.containsKey("playlist.json")) return ImportKind.PLAYLIST
        if (entries.containsKey("pocket.json")) return ImportKind.POCKET
        return ImportKind.BACKUP
    }

    /** One pocket as a versioned `CollectionsDocument` JSON envelope. */
    fun pocketEnvelope(pocket: Pocket, json: Json = PdjJson.lenient): ByteArray =
        CollectionsCodec.encode(json, CollectionsDocument(pockets = listOf(pocket))).toByteArray(Charsets.UTF_8)

    /** One playlist as a versioned `CollectionsDocument` JSON envelope. */
    fun playlistEnvelope(playlist: Playlist, json: Json = PdjJson.lenient): ByteArray =
        CollectionsCodec.encode(json, CollectionsDocument(playlists = listOf(playlist))).toByteArray(Charsets.UTF_8)

    fun decodeEnvelope(data: ByteArray, json: Json = PdjJson.lenient): CollectionsDocument =
        CollectionsCodec.decode(json, String(data, Charsets.UTF_8))

    /** The four collection families the merge operates on. */
    data class Sets(
        val pockets: List<Pocket> = emptyList(),
        val playlists: List<Playlist> = emptyList(),
        val setlists: List<Setlist> = emptyList(),
        val folders: List<PlaylistFolder> = emptyList(),
    )

    /**
     * Match-by-id IDEMPOTENT merge (iOS `mergeBackupCollections` / `importCollection` doctrine): ids are
     * PRESERVED, an incoming item whose id exists is MERGED (members unioned, songs deduped), never
     * duplicated, so a re-import is a no-op and a modified re-import adds only genuinely-new members.
     * Existing items are only re-stamped (`updatedAt`) when the merge actually changed them.
     */
    object Merge {
        /** Result of a merge: the new families + how many incoming items were processed. */
        data class Result(val sets: Sets, val pockets: Int, val playlists: Int, val setlists: Int, val folders: Int,
            val added: Int = 0, val merged: Int = 0, val unchanged: Int = 0)

        /**
         * @param clearFolderOnInsert a single-item transfer carries no folder context: a NEW pocket's
         *   folderId is cleared (an existing local pocket keeps its own folder).
         * @param keepSetlistsWithPlaylist setlists survive only when their parent playlist is present.
         */
        fun merge(
            current: Sets,
            incomingFolders: List<PlaylistFolder> = emptyList(),
            incomingPockets: List<Pocket> = emptyList(),
            incomingPlaylists: List<Playlist> = emptyList(),
            incomingSetlists: List<Setlist> = emptyList(),
            nowMs: Double,
            clearFolderOnInsert: Boolean = false,
        ): Result {
            var folders = current.folders
            var pockets = current.pockets
            var playlists = current.playlists
            var setlists = current.setlists
            for (f in incomingFolders) folders = upsertFolder(folders, f, nowMs)
            for (p in incomingPockets) pockets = upsertPocket(pockets, p, nowMs, clearFolderOnInsert)
            for (pl in incomingPlaylists) playlists = upsertPlaylist(playlists, pl, nowMs)
            for (sl in incomingSetlists) {
                if (playlists.any { it.id == sl.playlistId }) setlists = upsertSetlist(setlists, sl)
            }
            val (dp0, dpl0) = dropDanglingRefs(pockets, playlists, folders)
            // A merge that unions a ref in which dangling-drop then removes again (a ghost child) nets to NO
            // change: keep the original so `updatedAt` isn't re-stamped and a re-import stays a true no-op.
            val curP = current.pockets.associateBy { it.id }
            val curPl = current.playlists.associateBy { it.id }
            val dp = dp0.map { p -> curP[p.id]?.takeIf { it == p.copy(updatedAt = it.updatedAt) } ?: p }
            val dpl = dpl0.map { p -> curPl[p.id]?.takeIf { it == p.copy(updatedAt = it.updatedAt) } ?: p }
            val sets = Sets(dp, dpl, setlists, folders)
            var added = 0; var merged = 0; var unchanged = 0
            fun <T> tally(inc: List<T>, id: (T) -> String, before: List<T>, after: List<T>) {
                val b = before.associateBy(id); val a = after.associateBy(id)
                for (x in inc) {
                    val k = id(x)
                    when {
                        !b.containsKey(k) -> if (a.containsKey(k)) added++ else unchanged++
                        b[k] == a[k] -> unchanged++
                        else -> merged++
                    }
                }
            }
            tally(incomingFolders, { it.id }, current.folders, sets.folders)
            tally(incomingPockets, { it.id }, current.pockets, sets.pockets)
            tally(incomingPlaylists, { it.id }, current.playlists, sets.playlists)
            tally(incomingSetlists, { it.id }, current.setlists, sets.setlists)
            return Result(
                sets,
                incomingPockets.size, incomingPlaylists.size, incomingSetlists.size, incomingFolders.size,
                added, merged, unchanged,
            )
        }

        /** Union [incoming] into [base], order preserved, appending only ids not already present. */
        fun unionIds(base: List<String>, incoming: List<String>): List<String> {
            val seen = HashSet(base)
            val out = ArrayList(base)
            for (id in incoming) if (seen.add(id)) out += id
            return out
        }

        /** Content identity of a LEAF node; chapters match by nodeId so they return null. */
        private fun nodeContentKey(n: PlaylistNode): String? = when (n.kind) {
            PlaylistNode.Kind.SONG -> n.songId?.let { "s:$it" }
            PlaylistNode.Kind.ALBUM -> n.albumId?.let { "a:$it" }
            PlaylistNode.Kind.POCKET -> n.pocketId?.let { "p:$it" }
            PlaylistNode.Kind.TEXT -> n.text?.let { "t:$it" }
            PlaylistNode.Kind.SEQUENCE -> null
        }

        private fun mergeChapterChildren(existing: PlaylistNode, incoming: PlaylistNode): PlaylistNode {
            val kids = ArrayList(existing.children.orEmpty())
            val present = kids.mapNotNull(::nodeContentKey).toHashSet()
            for (child in incoming.children.orEmpty()) {
                val key = nodeContentKey(child) ?: continue // never nest a chapter in a chapter
                if (present.add(key)) kids += child
            }
            return existing.copy(children = kids)
        }

        fun upsertPocket(pockets: List<Pocket>, inc: Pocket, nowMs: Double, clearFolderOnInsert: Boolean = false): List<Pocket> {
            val i = pockets.indexOfFirst { it.id == inc.id }
            if (i < 0) {
                // The Apple Music link is stripped on INSERT: an imported collection is not necessarily
                // this user's own, and a synced copy would push the importer's edits into the sharer's library.
                val p = inc.copy(
                    createdAt = if (inc.createdAt == 0.0) nowMs else inc.createdAt,
                    updatedAt = nowMs,
                    amPlaylistId = null,
                    folderId = if (clearFolderOnInsert) null else inc.folderId,
                )
                return pockets + p
            }
            val cur = pockets[i]
            val haveNote = cur.notes.map { it.id }.toHashSet()
            val repeats = LinkedHashMap(cur.songRepeats)
            for ((k, v) in inc.songRepeats) if (!repeats.containsKey(k)) repeats[k] = v
            val merged = cur.copy(
                songIds = unionIds(cur.songIds, inc.songIds),
                albumIds = unionIds(cur.albumIds, inc.albumIds),
                childPocketIds = unionIds(cur.childPocketIds, inc.childPocketIds),
                notes = cur.notes + inc.notes.filter { it.id !in haveNote },
                songRepeats = repeats,
            )
            if (merged == cur) return pockets
            return pockets.toMutableList().also { it[i] = merged.copy(updatedAt = nowMs) }
        }

        fun upsertPlaylist(playlists: List<Playlist>, inc: Playlist, nowMs: Double): List<Playlist> {
            val i = playlists.indexOfFirst { it.id == inc.id }
            if (i < 0) {
                return playlists + inc.copy(
                    createdAt = if (inc.createdAt == 0.0) nowMs else inc.createdAt,
                    updatedAt = nowMs,
                    amPlaylistId = null,
                )
            }
            val cur = playlists[i]
            val seqs = ArrayList(cur.sequences)
            val byNodeId = HashMap<String, Int>()
            seqs.forEachIndexed { idx, s -> byNodeId.putIfAbsent(s.nodeId, idx) }
            for (incSeq in inc.sequences) {
                val idx = byNodeId[incSeq.nodeId]
                if (idx != null) {
                    seqs[idx] = mergeChapterChildren(seqs[idx], incSeq)
                } else {
                    seqs += incSeq
                    byNodeId[incSeq.nodeId] = seqs.size - 1
                }
            }
            val merged = cur.copy(sequences = seqs)
            if (merged == cur) return playlists
            return playlists.toMutableList().also { it[i] = merged.copy(updatedAt = nowMs) }
        }

        fun upsertFolder(folders: List<PlaylistFolder>, inc: PlaylistFolder, nowMs: Double): List<PlaylistFolder> {
            if (folders.any { it.id == inc.id }) return folders
            return folders + inc.copy(
                createdAt = if (inc.createdAt == 0.0) nowMs else inc.createdAt,
                updatedAt = nowMs,
            )
        }

        /** Frozen snapshots: add by id if absent, never merged. */
        fun upsertSetlist(setlists: List<Setlist>, inc: Setlist): List<Setlist> =
            if (setlists.any { it.id == inc.id }) setlists else setlists + inc

        /**
         * Drop refs that resolve to NOTHING: a folder / child-pocket id that exists neither in the import
         * nor locally. A ref to an item that DOES exist (the point of match-by-id) is kept. Idempotent.
         */
        fun dropDanglingRefs(
            pockets: List<Pocket>,
            playlists: List<Playlist>,
            folders: List<PlaylistFolder>,
        ): Pair<List<Pocket>, List<Playlist>> {
            val folderIds = folders.map { it.id }.toHashSet()
            val pocketIds = pockets.map { it.id }.toHashSet()
            val p2 = pockets.map { p ->
                val f = p.folderId?.takeIf { it in folderIds }
                val kids = p.childPocketIds.filter { it in pocketIds }
                if (f == p.folderId && kids == p.childPocketIds) p else p.copy(folderId = f, childPocketIds = kids)
            }
            val pl2 = playlists.map { pl ->
                if (pl.folderId != null && pl.folderId !in folderIds) pl.copy(folderId = null) else pl
            }
            return p2 to pl2
        }
    }
}

package com.levi.pocketdj.auto

import com.levi.pocketdj.data.recs.ForYouFeedSnapshot
import com.levi.pocketdj.data.recs.ForYouGrid
import com.levi.pocketdj.data.recs.ForYouReleaseSource
import com.levi.pocketdj.data.recs.ForYouCollections
import com.levi.pocketdj.data.recs.ForYouTile
import com.levi.pocketdj.data.recs.ForYouTileKind
import com.levi.pocketdj.data.recs.RecFeedbackStore

/** A New-tile row: an out-now release (not a catalog song). [releaseId] is the Apple Music store id. */
data class AutoRelease(val releaseId: String, val title: String, val artist: String, val feedbackId: String)

/** What the For You tab reads. Production: the CACHED [ForYouFeedStore] snapshot + live feedback/collections. */
interface AutoForYouSource {
    /** The frozen snapshot. Reading it never refreshes or ranks anything. */
    fun snapshot(): ForYouFeedSnapshot
    val collections: ForYouCollections
    val feedback: RecFeedbackStore?
    val releaseSource: ForYouReleaseSource?
    /** Out-now releases, newest first, with thumbed-up / thumbed-down rows already removed (see [AutoForYou.liveReleases]). */
    fun outNowReleases(nowMs: Double): List<AutoRelease>
}

/** What a For You selection should start. Resolved purely so the car glue only executes it. */
sealed interface AutoForYouPlay {
    /** Catalog songs: `playSongIds` then stamp the recommendation scope ([scope]) with [ids]. */
    data class Songs(val ids: List<String>, val name: String, val scope: String, val shuffle: Boolean) : AutoForYouPlay
    /** New-tile releases: expanded to `am:<storeId>` rows, no feedback scope. */
    data class Releases(val releaseIds: List<String>, val shuffle: Boolean) : AutoForYouPlay
}

/**
 * The Android Auto "For You" tab (iOS `CarPlayForYou`). FROZEN and READ-ONLY: the tiles come from the cached
 * feed snapshot through the SAME `ForYouGrid.tiles` -> `ForYouTiles.build` the phone grid uses, so the car
 * cannot drift from the phone. Nothing here refreshes, ranks or touches the network; a cold cache shows one
 * note row instead of computing a ranking at the worst possible moment.
 */
class AutoForYou(
    private val source: AutoForYouSource,
    private val song: (String) -> AutoSongInfo?,
    private val clock: () -> Double = { System.currentTimeMillis().toDouble() },
    private val maxRows: Int = AutoBrowseTree.MAX_SONGS,
) {
    fun tabNode(): AutoNode = AutoNode(
        AutoId.Tab(AutoId.Tab.Which.FOR_YOU).encoded, "For You",
        browsable = true, childBrowsableStyle = AutoStyle.LIST,
    )

    private fun tiles(nowMs: Double): List<ForYouTile> =
        ForYouGrid.tiles(source.snapshot(), source.collections, source.feedback, source.releaseSource, nowMs)

    private fun tile(tileId: String, nowMs: Double): ForYouTile? = tiles(nowMs).firstOrNull { it.id == tileId }

    private fun songIds(t: ForYouTile, nowMs: Double): List<String> =
        ForYouGrid.songIds(t, source.snapshot(), source.collections, source.feedback, nowMs)

    private fun isNew(t: ForYouTile) = t.route.kind == ForYouTileKind.NEW

    /** The tab's rows: one per tile in the phone's order, or ONE note row on a cold cache. */
    fun children(): List<AutoNode> {
        if (!source.snapshot().hasResult) return listOf(AutoNode(AutoId.ForYouNote.encoded, COLD_NOTE))
        val now = clock()
        val releases = lazy { source.outNowReleases(now) }
        return tiles(now).map { tileNode(it, now, releases) }
    }

    private fun tileNode(t: ForYouTile, now: Double, releases: Lazy<List<AutoRelease>>): AutoNode {
        // New counts what the car can PLAY (out-now releases), not the phone's out-now + pre-orders badge.
        val n = if (isNew(t)) releases.value.size else t.count
        val ids = if (isNew(t)) emptyList() else songIds(t, now)
        return AutoNode(
            id = AutoId.ForYouTile(t.id).encoded,
            title = t.title,
            subtitle = tileDetail(n, isNew(t), t.subtitle),
            artUrl = ids.firstNotNullOfOrNull { song(it)?.artUrl },
            browsable = true,
            childPlayableStyle = AutoStyle.LIST,
            childBrowsableStyle = AutoStyle.LIST,
            childCount = n,
        )
    }

    /** At zero the tile's own wording wins ("Play a few songs to build your zone"); otherwise "12 songs · note". */
    internal fun tileDetail(count: Int, isNew: Boolean, note: String): String {
        if (count <= 0) return note
        val unit = if (isNew) (if (count == 1) "release" else "releases") else (if (count == 1) "song" else "songs")
        return "$count $unit · $note"
    }

    /** One tile's drill-in: Play all / Shuffle all, then its playable rows. Null for an unknown tile. */
    fun tileChildren(tileId: String): List<AutoNode>? {
        val now = clock()
        val t = tile(tileId, now) ?: return null
        val parent = AutoId.ForYouTile(tileId).encoded
        val rows = rows(t, now)
        if (rows.isEmpty()) {
            return listOf(AutoNode(AutoId.Empty(parent).encoded, if (isNew(t)) "No new releases yet" else "Nothing here yet"))
        }
        return listOf(
            AutoNode(AutoId.ForYouAll(tileId, shuffle = false).encoded, "Play all", subtitle = t.title, playable = true),
            AutoNode(AutoId.ForYouAll(tileId, shuffle = true).encoded, "Shuffle all", subtitle = t.title, playable = true),
        ) + rows
    }

    private fun rows(t: ForYouTile, now: Double): List<AutoNode> {
        if (isNew(t)) {
            return source.outNowReleases(now).take(maxRows).map {
                AutoNode(
                    AutoId.ForYouRow(t.id, RELEASE_PREFIX + it.releaseId).encoded,
                    it.title, subtitle = it.artist, playable = true,
                )
            }
        }
        val out = ArrayList<AutoNode>()
        for (id in songIds(t, now)) {
            if (out.size >= maxRows) break
            val s = song(id) ?: continue
            out += songNode(t.id, id, s)
        }
        return out
    }

    private fun songNode(tileId: String, songId: String, s: AutoSongInfo) = AutoNode(
        id = AutoId.ForYouRow(tileId, songId).encoded,
        title = s.title,
        subtitle = if (s.playable) s.artist else "${s.artist} · ${AutoBrowseTree.UNAVAILABLE}",
        artUrl = s.artUrl,
        playable = s.playable,
        addToAction = true,
    )

    /** A single For You node (Media3 getItem). */
    fun item(id: AutoId): AutoNode? {
        val now = clock()
        return when (id) {
            AutoId.ForYouNote -> AutoNode(id.encoded, COLD_NOTE)
            is AutoId.ForYouTile -> tile(id.tileId, now)?.let { tileNode(it, now, lazy { source.outNowReleases(now) }) }
            is AutoId.ForYouAll -> tile(id.tileId, now)?.let {
                AutoNode(id.encoded, if (id.shuffle) "Shuffle all" else "Play all", it.title, playable = true)
            }
            is AutoId.ForYouRow -> {
                val t = tile(id.tileId, now) ?: return null
                if (id.rowId.startsWith(RELEASE_PREFIX)) {
                    source.outNowReleases(now).firstOrNull { it.releaseId == id.rowId.removePrefix(RELEASE_PREFIX) }?.let {
                        AutoNode(id.encoded, it.title, subtitle = it.artist, playable = true)
                    }
                } else song(id.rowId)?.let { songNode(t.id, id.rowId, it) }
            }
            else -> null
        }
    }

    /** The song id behind a For You row (null for a release / note row): what "Add to…" files. */
    fun songIdOf(id: AutoId.ForYouRow): String? = id.rowId.takeUnless { it.startsWith(RELEASE_PREFIX) }

    /**
     * Resolve a selection to a play plan. Tile and Play/Shuffle all play the whole tile; a row plays from
     * there on ("play from here"); a release row plays that release alone. Null = nothing playable.
     */
    fun plan(id: AutoId): AutoForYouPlay? {
        val now = clock()
        return when (id) {
            is AutoId.ForYouTile -> planTile(id.tileId, false, now)
            is AutoId.ForYouAll -> planTile(id.tileId, id.shuffle, now)
            is AutoId.ForYouRow -> {
                val t = tile(id.tileId, now) ?: return null
                if (id.rowId.startsWith(RELEASE_PREFIX)) {
                    val rid = id.rowId.removePrefix(RELEASE_PREFIX)
                    if (rid.isEmpty()) null else AutoForYouPlay.Releases(listOf(rid), false)
                } else {
                    val ids = songIds(t, now)
                    val i = ids.indexOf(id.rowId)
                    if (i < 0) null else AutoForYouPlay.Songs(ids.subList(i, ids.size), t.title, t.route.feedbackContext, false)
                }
            }
            else -> null
        }
    }

    private fun planTile(tileId: String, shuffle: Boolean, now: Double): AutoForYouPlay? {
        val t = tile(tileId, now) ?: return null
        if (isNew(t)) {
            val ids = source.outNowReleases(now).map { it.releaseId }
            return if (ids.isEmpty()) null else AutoForYouPlay.Releases(ids, shuffle)
        }
        val ids = songIds(t, now)
        return if (ids.isEmpty()) null else AutoForYouPlay.Songs(ids, t.title, t.route.feedbackContext, shuffle)
    }

    companion object {
        /** Namespaces a release row so it can never be mistaken for a catalog song id. */
        const val RELEASE_PREFIX = "rel:"
        const val COLD_NOTE = "Open For You on your phone to build your recommendations"

        /**
         * The New tile's rows: still offered (anything thumbed up removed, the thumbed-down tail removed),
         * order preserved. A pre-order is never in [items] (the source passes out-now only).
         */
        fun liveReleases(items: List<AutoRelease>, accepted: Map<String, Double>, tombstones: Map<String, Double>): List<AutoRelease> =
            if (accepted.isEmpty() && tombstones.isEmpty()) items
            else items.filter { tombstones[it.feedbackId] == null && accepted[it.feedbackId] == null }
    }
}

package com.levi.pocketdj.auto

import com.levi.pocketdj.assistant.MediaSearchResolver
import java.net.URLDecoder
import java.net.URLEncoder

/** Which kind of collection a browse node opens (iOS CarPlay: user playlists, pockets, source playlists). */
enum class AutoCollectionKind(val token: String) {
    PLAYLIST("pl"),
    POCKET("pk"),
    SOURCE("src"),
    ;

    companion object {
        fun fromToken(t: String): AutoCollectionKind? = entries.firstOrNull { it.token == t }
    }
}

/** A collection reference. [sourceName] is set only for [AutoCollectionKind.SOURCE] (ids are unique per source). */
data class AutoCollectionRef(val kind: AutoCollectionKind, val id: String, val sourceName: String? = null)

/**
 * Every media id the Auto tree hands out, with a lossless text codec. Components are URL-encoded so ids that
 * contain ':' (or unicode, '%', spaces) survive the round trip.
 */
sealed interface AutoId {
    val encoded: String

    data object Root : AutoId { override val encoded = "root" }
    data class Tab(val tab: Which) : AutoId {
        enum class Which(val token: String) { PLAYLISTS("playlists"), POCKETS("pockets") }
        override val encoded get() = "tab:${tab.token}"
    }
    data object Continue : AutoId { override val encoded = "continue" }
    data object Loading : AutoId { override val encoded = "loading" }
    /** Placeholder row inside an empty collection / tab. */
    data class Empty(val parent: String) : AutoId { override val encoded get() = "empty:${enc(parent)}" }
    data class Collection(val ref: AutoCollectionRef) : AutoId { override val encoded get() = "col:${encRef(ref)}" }
    data class PlayAll(val ref: AutoCollectionRef) : AutoId { override val encoded get() = "all:${encRef(ref)}" }
    data class ShuffleAll(val ref: AutoCollectionRef) : AutoId { override val encoded get() = "shuf:${encRef(ref)}" }
    data class Song(val ref: AutoCollectionRef, val songId: String) : AutoId {
        override val encoded get() = "song:${encRef(ref)}:${enc(songId)}"
    }
    /** A song found by search (not inside a collection): plays alone. */
    data class Solo(val songId: String) : AutoId { override val encoded get() = "solo:${enc(songId)}" }
    /** The "Add to…" chooser for [songId]. */
    data class AddTo(val songId: String) : AutoId { override val encoded get() = "addto:${enc(songId)}" }
    /** One chooser row: add [songId] to the pocket/playlist [targetId]. */
    data class AddTarget(val songId: String, val targetKind: AutoTargetKind, val targetId: String) : AutoId {
        override val encoded get() = "addt:${enc(songId)}:${targetKind.token}:${enc(targetId)}"
    }

    companion object {
        internal fun enc(s: String): String = URLEncoder.encode(s, "UTF-8")
        internal fun dec(s: String): String = URLDecoder.decode(s, "UTF-8")
        private fun encRef(r: AutoCollectionRef) = "${r.kind.token}:${enc(r.id)}:${enc(r.sourceName.orEmpty())}"

        private fun decRef(kind: String, id: String, src: String): AutoCollectionRef? {
            val k = AutoCollectionKind.fromToken(kind) ?: return null
            val s = dec(src).ifEmpty { null }
            if (k == AutoCollectionKind.SOURCE && s == null) return null
            return AutoCollectionRef(k, dec(id), if (k == AutoCollectionKind.SOURCE) s else null)
        }

        /** Null for anything that is not one of ours (a foreign id, a malformed one). */
        fun decode(raw: String): AutoId? = try {
            val p = raw.split(':')
            when (p.firstOrNull()) {
                "root" -> if (p.size == 1) Root else null
                "continue" -> if (p.size == 1) Continue else null
                "loading" -> if (p.size == 1) Loading else null
                "tab" -> if (p.size == 2) Tab.Which.entries.firstOrNull { it.token == p[1] }?.let(::Tab) else null
                "empty" -> if (p.size == 2) Empty(dec(p[1])) else null
                "col" -> if (p.size == 4) decRef(p[1], p[2], p[3])?.let(::Collection) else null
                "all" -> if (p.size == 4) decRef(p[1], p[2], p[3])?.let(::PlayAll) else null
                "shuf" -> if (p.size == 4) decRef(p[1], p[2], p[3])?.let(::ShuffleAll) else null
                "song" -> if (p.size == 5) decRef(p[1], p[2], p[3])?.let { Song(it, dec(p[4])) } else null
                "solo" -> if (p.size == 2) Solo(dec(p[1])) else null
                "addto" -> if (p.size == 2) AddTo(dec(p[1])) else null
                "addt" -> if (p.size == 4) {
                    AutoTargetKind.fromToken(p[2])?.let { AddTarget(dec(p[1]), it, dec(p[3])) }
                } else null
                else -> null
            }
        } catch (_: IllegalArgumentException) {
            null
        }
    }
}

enum class AutoTargetKind(val token: String) {
    POCKET("pocket"),
    PLAYLIST("playlist"),
    ;

    companion object {
        fun fromToken(t: String): AutoTargetKind? = entries.firstOrNull { it.token == t }
    }
}

/** Auto content-style hints (MediaConstants.EXTRAS_VALUE_CONTENT_STYLE_*). */
enum class AutoStyle(val value: Int) { LIST(1), GRID(2), CATEGORY_LIST(3), CATEGORY_GRID(4) }

/** One browse row, platform-free. [AutoLibraryCallback] maps it to a Media3 MediaItem. */
data class AutoNode(
    val id: String,
    val title: String,
    val subtitle: String? = null,
    val artUrl: String? = null,
    val browsable: Boolean = false,
    val playable: Boolean = false,
    /** Style the CHILDREN of this node should use (read by the host from this node's metadata). */
    val childBrowsableStyle: AutoStyle? = null,
    val childPlayableStyle: AutoStyle? = null,
    /** Shows the "Add to…" custom browser action on this row. */
    val addToAction: Boolean = false,
    val childCount: Int? = null,
)

data class AutoCollectionInfo(val ref: AutoCollectionRef, val name: String, val songCount: Int, val badge: String? = null)

data class AutoSongInfo(
    val id: String,
    val title: String,
    val artist: String,
    val artUrl: String? = null,
    /** False for AM-only songs with no public rip and no Apple Music sign-in: shown, never played. */
    val playable: Boolean = true,
)

data class AutoHeld(val title: String, val artist: String)

/** Everything the tree reads. Production: CollectionsStore + the merged catalog + rips + the durable session. */
interface AutoLibraryData {
    /** The catalog snapshot is available (songs resolve). */
    val catalogReady: Boolean
    fun playlists(): List<AutoCollectionInfo>
    fun sourcePlaylists(): List<AutoCollectionInfo>
    fun pockets(): List<AutoCollectionInfo>
    fun collection(ref: AutoCollectionRef): AutoCollectionInfo?
    /** The collection's song ids in play order (DAG-resolved for pockets). */
    fun songIds(ref: AutoCollectionRef): List<String>
    fun song(id: String): AutoSongInfo?
    fun searchSongs(query: String, limit: Int): List<AutoSongInfo>
    fun held(): AutoHeld?
}

/**
 * The Android Auto browse tree (iOS CarPlayModel minus For You and Mix): root = Playlists / Pockets tabs, with a
 * Continue row first only when a held session exists. Pure and synchronous; a connect never mutates anything.
 */
class AutoBrowseTree(
    private val data: AutoLibraryData,
    private val maxSongs: Int = MAX_SONGS,
) {
    fun root(): AutoNode = AutoNode(
        id = AutoId.Root.encoded,
        title = "PocketDJ",
        browsable = true,
        childBrowsableStyle = AutoStyle.CATEGORY_LIST,
    )

    fun children(parentId: String, page: Int = 0, pageSize: Int = Int.MAX_VALUE): List<AutoNode>? {
        val all = childrenAll(parentId) ?: return null
        if (pageSize == Int.MAX_VALUE) return if (page == 0) all else emptyList()
        val from = (page.toLong() * pageSize).coerceAtMost(all.size.toLong()).toInt()
        return all.subList(from, minOf(all.size, from + pageSize))
    }

    private fun childrenAll(parentId: String): List<AutoNode>? {
        return when (val id = AutoId.decode(parentId) ?: return null) {
            AutoId.Root -> rootChildren()
            is AutoId.Tab -> if (!data.catalogReady) listOf(loadingNode()) else tabChildren(id.tab)
            is AutoId.Collection -> collectionChildren(id.ref)
            is AutoId.AddTo -> null // resolved by AutoLibraryCallback (needs AutoAddTargets)
            else -> null
        }
    }

    private fun loadingNode() = AutoNode(AutoId.Loading.encoded, "Loading…", subtitle = "Getting your library ready")

    private fun rootChildren(): List<AutoNode> {
        // The catalog isn't warm yet: ONE "Loading…" child; the callback notifies the root once it is.
        if (!data.catalogReady) return listOf(loadingNode())
        val out = ArrayList<AutoNode>(3)
        data.held()?.let { h ->
            out += AutoNode(
                id = AutoId.Continue.encoded,
                title = "Continue",
                subtitle = listOf(h.title, h.artist).filter { it.isNotBlank() }.joinToString(" – "),
                playable = true,
            )
        }
        out += AutoNode(
            AutoId.Tab(AutoId.Tab.Which.PLAYLISTS).encoded, "Playlists",
            browsable = true, childBrowsableStyle = AutoStyle.LIST,
        )
        out += AutoNode(
            AutoId.Tab(AutoId.Tab.Which.POCKETS).encoded, "Pockets",
            browsable = true, childBrowsableStyle = AutoStyle.LIST,
        )
        return out
    }

    private fun tabChildren(tab: AutoId.Tab.Which): List<AutoNode> {
        val infos = when (tab) {
            AutoId.Tab.Which.PLAYLISTS -> sortedByName(data.playlists()) + sortedByName(data.sourcePlaylists())
            AutoId.Tab.Which.POCKETS -> sortedByName(data.pockets())
        }
        if (infos.isEmpty()) {
            val what = if (tab == AutoId.Tab.Which.PLAYLISTS) "playlists" else "pockets"
            return listOf(AutoNode(AutoId.Empty(AutoId.Tab(tab).encoded).encoded, "No $what yet"))
        }
        return infos.map(::collectionNode)
    }

    private fun sortedByName(l: List<AutoCollectionInfo>) = l.sortedBy { it.name.lowercase() }

    private fun collectionNode(i: AutoCollectionInfo): AutoNode {
        val count = if (i.songCount == 1) "1 song" else "${i.songCount} songs"
        return AutoNode(
            id = AutoId.Collection(i.ref).encoded,
            title = i.name,
            subtitle = if (i.badge != null) "${i.badge} · $count" else count,
            browsable = true,
            childPlayableStyle = AutoStyle.LIST,
            childBrowsableStyle = AutoStyle.LIST,
            childCount = i.songCount,
        )
    }

    private fun collectionChildren(ref: AutoCollectionRef): List<AutoNode>? {
        val info = data.collection(ref) ?: return null
        val parent = AutoId.Collection(ref).encoded
        val songs = ArrayList<AutoNode>()
        for (sid in data.songIds(ref)) {
            if (songs.size >= maxSongs) break
            val s = data.song(sid) ?: continue
            songs += songNode(AutoId.Song(ref, sid).encoded, s)
        }
        if (songs.isEmpty()) return listOf(AutoNode(AutoId.Empty(parent).encoded, "No songs"))
        return listOf(
            AutoNode(AutoId.PlayAll(ref).encoded, "Play all", subtitle = info.name, playable = true),
            AutoNode(AutoId.ShuffleAll(ref).encoded, "Shuffle all", subtitle = info.name, playable = true),
        ) + songs
    }

    private fun songNode(id: String, s: AutoSongInfo) = AutoNode(
        id = id,
        title = s.title,
        subtitle = if (s.playable) s.artist else "${s.artist} · $UNAVAILABLE",
        artUrl = s.artUrl,
        playable = s.playable,
        addToAction = true,
    )

    /** A single node by id (Media3 getItem). */
    fun item(mediaId: String): AutoNode? {
        return when (val id = AutoId.decode(mediaId) ?: return null) {
            AutoId.Root -> root()
            AutoId.Loading -> loadingNode()
            AutoId.Continue -> data.held()?.let { h ->
                AutoNode(id.encoded, "Continue", listOf(h.title, h.artist).filter { it.isNotBlank() }.joinToString(" – "), playable = true)
            }
            is AutoId.Tab -> AutoNode(
                id.encoded, if (id.tab == AutoId.Tab.Which.PLAYLISTS) "Playlists" else "Pockets",
                browsable = true, childBrowsableStyle = AutoStyle.LIST,
            )
            is AutoId.Collection -> data.collection(id.ref)?.let(::collectionNode)
            is AutoId.PlayAll -> data.collection(id.ref)?.let { AutoNode(id.encoded, "Play all", it.name, playable = true) }
            is AutoId.ShuffleAll -> data.collection(id.ref)?.let { AutoNode(id.encoded, "Shuffle all", it.name, playable = true) }
            is AutoId.Song -> data.song(id.songId)?.let { songNode(id.encoded, it) }
            is AutoId.Solo -> data.song(id.songId)?.let { songNode(id.encoded, it) }
            is AutoId.Empty, is AutoId.AddTo, is AutoId.AddTarget -> null
        }
    }

    /** Voice / search box: matching collections first (playlists, sources, pockets), then songs. */
    fun search(query: String, songLimit: Int = SEARCH_SONGS): List<AutoNode> {
        val q = query.trim()
        if (q.isEmpty() || !data.catalogReady) return emptyList()
        val cols = (data.playlists() + data.pockets() + data.sourcePlaylists())
            .map { it to MediaSearchResolver.tier(q, it.name) }
            .filter { it.second > 0 }
            .sortedWith(compareByDescending<Pair<AutoCollectionInfo, Int>> { it.second }.thenBy { it.first.name.lowercase() })
            .map { collectionNode(it.first) }
        val songs = data.searchSongs(q, songLimit).map { songNode(AutoId.Solo(it.id).encoded, it) }
        return cols + songs
    }

    companion object {
        const val MAX_SONGS = 200
        const val SEARCH_SONGS = 20
        const val UNAVAILABLE = "Not available here"
    }
}

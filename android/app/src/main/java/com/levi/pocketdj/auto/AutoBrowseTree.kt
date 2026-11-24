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
        enum class Which(val token: String) { PLAYLISTS("playlists"), POCKETS("pockets"), FOR_YOU("foryou") }
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

    /** A For You tile (`fy:<tileId>`: "new" / "zone" / "col-<id>"); browsable, and playing it plays the whole tile. */
    data class ForYouTile(val tileId: String) : AutoId { override val encoded get() = "fy:${enc(tileId)}" }
    /** Play all / Shuffle all inside a For You tile. */
    data class ForYouAll(val tileId: String, val shuffle: Boolean) : AutoId {
        override val encoded get() = "${if (shuffle) "fyshuf" else "fyall"}:${enc(tileId)}"
    }
    /** One row inside a For You tile: a catalog song id, or `rel:<storeId>` for a New release. */
    data class ForYouRow(val tileId: String, val rowId: String) : AutoId {
        override val encoded get() = "fyrow:${enc(tileId)}:${enc(rowId)}"
    }
    /** The browsable Up Next list (`upnext`, SURF-8). */
    data object UpNext : AutoId { override val encoded = "upnext" }
    /** One unplayed sequencer row (`upnext:<uid>`); identity is the row uid, so a repeated song is distinct. */
    data class UpNextRow(val uid: String) : AutoId { override val encoded get() = "upnext:${enc(uid)}" }

    /** The cold-cache note row. */
    data object ForYouNote : AutoId { override val encoded = "fynote" }

    /** "▶ Pocket for now" (`pocketwheel:now`, P2-POC-16): playable, the wheel's best match for right now. */
    data object PocketNow : AutoId { override val encoded = "pocketwheel:now" }
    /** The browsable "Pockets right now" folder (`pocketwheel:list`). */
    data object PocketList : AutoId { override val encoded = "pocketwheel:list" }
    /** One wheel moment in that folder (`pocketwheel:m:<token>`, token like `h08|d2|carPlay`: no ':' inside). */
    data class PocketMoment(val key: com.levi.pocketdj.data.pockets.wheel.PocketMomentKey) : AutoId {
        override val encoded get() = "pocketwheel:m:${key.token}"
    }

    /** A Mix-tab node (SURF-9). [a]/[b] are kind-specific payloads (deck, crate key, session id). */
    data class Mix(val kind: AutoMixKind, val a: String = "", val b: String = "") : AutoId {
        override val encoded get() = "mix:${kind.token}:${enc(a)}:${enc(b)}"
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
                "fy" -> if (p.size == 2) ForYouTile(dec(p[1])) else null
                "fyall" -> if (p.size == 2) ForYouAll(dec(p[1]), false) else null
                "fyshuf" -> if (p.size == 2) ForYouAll(dec(p[1]), true) else null
                "fyrow" -> if (p.size == 3) ForYouRow(dec(p[1]), dec(p[2])) else null
                "upnext" -> when (p.size) { 1 -> UpNext; 2 -> UpNextRow(dec(p[1])); else -> null }
                "fynote" -> if (p.size == 1) ForYouNote else null
                "mix" -> if (p.size == 4) {
                    AutoMixKind.fromToken(p[1])?.let { Mix(it, dec(p[2]), dec(p[3])) }
                } else null
                "pocketwheel" -> when {
                    p.size == 2 && p[1] == "now" -> PocketNow
                    p.size == 2 && p[1] == "list" -> PocketList
                    p.size == 3 && p[1] == "m" ->
                        com.levi.pocketdj.data.pockets.wheel.PocketMomentKey.fromToken(p[2])?.let(::PocketMoment)
                    else -> null
                }
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
    /** Shows the Up Next per-row buttons (Play next / Move to end / Remove) on this row (SURF-8). */
    val upNextActions: Boolean = false,
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
    /** The Mix tab (SURF-9). Null until a MixFacade is wired: the tab is then hidden entirely. */
    val mix: AutoMixTab? = null,
    /** The For You tab (SURF-7): frozen cached tiles. Null hides the tab. */
    val forYou: AutoForYou? = null,
    /** P2-POC-16: "▶ Pocket for now" + "Pockets right now" at the top of the For You tab. Null = absent. */
    val pockets: AutoPockets? = null,
    /** SURF-8: the Up Next list. Null hides it. The tab shows only while rows are upcoming. */
    val upNext: AutoUpNext? = null,
) {
    /** The For You tab exists when either its tiles or the pocket rows do. */
    val hasForYouTab: Boolean get() = forYou != null || pockets != null

    /**
     * The host's BROWSER_ROOT_HINTS_KEY_ROOT_CHILDREN_LIMIT (null = unknown / unlimited). When the root would
     * exceed it, the Continue row folds into a top row inside Playlists.
     */
    @Volatile var rootLimit: Int? = null

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
            is AutoId.Mix -> mix?.children(id)
            AutoId.UpNext -> upNext?.children()
            is AutoId.ForYouTile -> forYou?.tileChildren(id.tileId)
            AutoId.PocketList -> pockets?.listChildren()
            is AutoId.AddTo -> null // resolved by AutoLibraryCallback (needs AutoAddTargets)
            else -> null
        }
    }

    private fun loadingNode() = AutoNode(AutoId.Loading.encoded, "Loading…", subtitle = "Getting your library ready")

    private fun continueNode(h: AutoHeld) = AutoNode(
        id = AutoId.Continue.encoded,
        title = "Continue",
        subtitle = listOf(h.title, h.artist).filter { it.isNotBlank() }.joinToString(" – "),
        playable = true,
    )

    /** The tab rows below Continue, in the phone's order: Playlists, Pockets, For You, then Mix. */
    private fun tabNodes(): List<AutoNode> {
        val out = ArrayList<AutoNode>(4)
        out += AutoNode(
            AutoId.Tab(AutoId.Tab.Which.PLAYLISTS).encoded, "Playlists",
            browsable = true, childBrowsableStyle = AutoStyle.LIST,
        )
        out += AutoNode(
            AutoId.Tab(AutoId.Tab.Which.POCKETS).encoded, "Pockets",
            browsable = true, childBrowsableStyle = AutoStyle.LIST,
        )
        if (hasForYouTab) out += forYouTabNode()
        mix?.let { out += it.tabNode() }
        return out
    }

    private fun forYouTabNode() = AutoNode(
        AutoId.Tab(AutoId.Tab.Which.FOR_YOU).encoded, "For You",
        browsable = true, childBrowsableStyle = AutoStyle.LIST,
    )

    /** True when a held session exists and the root has no room for a Continue row beside the tabs. */
    private fun continueFolded(held: AutoHeld?): Boolean {
        val limit = rootLimit ?: return false
        return held != null && tabNodes().size + 1 > limit
    }

    /** True while upcoming rows exist (the Up Next entry is contextual, like iOS's Now Playing button). */
    private fun upNextShown(): Boolean = upNext?.hasRows == true

    /**
     * Up Next folds into the top of Playlists (like Continue) when the root has no room for it. Continue keeps its
     * root slot first, so Up Next is the one that folds when only one of them fits.
     */
    private fun upNextFolded(held: AutoHeld?): Boolean {
        val limit = rootLimit ?: return false
        if (!upNextShown()) return false
        val continueRoot = held != null && !continueFolded(held)
        return tabNodes().size + (if (continueRoot) 1 else 0) + 1 > limit
    }

    private fun foldedUpNext(): List<AutoNode> {
        val u = upNext ?: return emptyList()
        return if (upNextShown() && upNextFolded(data.held())) listOf(u.tabNode()) else emptyList()
    }

    private fun rootChildren(): List<AutoNode> {
        // The catalog isn't warm yet: ONE "Loading…" child; the callback notifies the root once it is.
        if (!data.catalogReady) return listOf(loadingNode())
        val held = data.held()
        val out = ArrayList<AutoNode>(6)
        if (held != null && !continueFolded(held)) out += continueNode(held)
        if (upNextShown() && !upNextFolded(held)) out += upNext!!.tabNode()
        out += tabNodes()
        val limit = rootLimit
        return if (limit != null && limit > 0 && out.size > limit) out.take(limit) else out
    }

    private fun tabChildren(tab: AutoId.Tab.Which): List<AutoNode> {
        val infos = when (tab) {
            AutoId.Tab.Which.PLAYLISTS -> sortedByName(data.playlists()) + sortedByName(data.sourcePlaylists())
            AutoId.Tab.Which.POCKETS -> sortedByName(data.pockets())
            AutoId.Tab.Which.FOR_YOU ->
                return pockets?.forYouRows().orEmpty() + forYou?.children().orEmpty()
        }
        if (infos.isEmpty()) {
            // Continue folded into the first Playlists row (root-limit hint): keep it even with no playlists.
            val folded = if (tab == AutoId.Tab.Which.PLAYLISTS) foldedUpNext() + foldedContinue() else emptyList()
            val what = if (tab == AutoId.Tab.Which.PLAYLISTS) "playlists" else "pockets"
            return folded + AutoNode(AutoId.Empty(AutoId.Tab(tab).encoded).encoded, "No $what yet")
        }
        val rows = infos.map(::collectionNode)
        return if (tab == AutoId.Tab.Which.PLAYLISTS) foldedUpNext() + foldedContinue() + rows else rows
    }

    private fun foldedContinue(): List<AutoNode> {
        val h = data.held()
        return if (h != null && continueFolded(h)) listOf(continueNode(h)) else emptyList()
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
            AutoId.Continue -> data.held()?.let(::continueNode)
            is AutoId.Tab -> AutoNode(
                id.encoded,
                when (id.tab) {
                    AutoId.Tab.Which.PLAYLISTS -> "Playlists"
                    AutoId.Tab.Which.POCKETS -> "Pockets"
                    AutoId.Tab.Which.FOR_YOU -> "For You"
                },
                browsable = true, childBrowsableStyle = AutoStyle.LIST,
            )
            is AutoId.Collection -> data.collection(id.ref)?.let(::collectionNode)
            is AutoId.PlayAll -> data.collection(id.ref)?.let { AutoNode(id.encoded, "Play all", it.name, playable = true) }
            is AutoId.ShuffleAll -> data.collection(id.ref)?.let { AutoNode(id.encoded, "Shuffle all", it.name, playable = true) }
            is AutoId.Song -> data.song(id.songId)?.let { songNode(id.encoded, it) }
            is AutoId.Solo -> data.song(id.songId)?.let { songNode(id.encoded, it) }
            is AutoId.Mix -> mix?.item(id)
            AutoId.UpNext, is AutoId.UpNextRow -> upNext?.item(id)
            AutoId.PocketNow, AutoId.PocketList, is AutoId.PocketMoment -> pockets?.item(id)
            AutoId.ForYouNote, is AutoId.ForYouTile, is AutoId.ForYouAll, is AutoId.ForYouRow -> forYou?.item(id)
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

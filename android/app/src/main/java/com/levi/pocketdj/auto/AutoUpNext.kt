package com.levi.pocketdj.auto

/** One not-yet-played sequencer row. Identity is [uid] (the same song queued twice is two rows). */
data class AutoUpNextRow(val uid: String, val songId: String, val title: String, val artist: String?)

/**
 * The sequencer as the Up Next list sees it. Production: [AppAutoUpNextSource] (state flow reads + uid-addressed
 * edits posted to Main). Edits re-resolve the uid against the LIVE queue, so a stale tap is a no-op.
 */
interface AutoUpNextSource {
    /** The unplayed rows after the current one, in play order. Empty when idle. */
    fun upcoming(): List<AutoUpNextRow>
    fun jump(uid: String)
    fun playNext(uid: String)
    fun moveToEnd(uid: String)
    fun remove(uid: String)
}

/**
 * Android Auto "Up Next" (iOS CarPlay `showUpNext` / `presentUpNextActions`): a browsable node of the unplayed
 * sequencer rows. A row tap is "Play now" (jumpToUpcoming); Play next / Move to end / Remove are per-row command
 * buttons. There is deliberately NO Media3 Timeline for this (D11: the sequencer owns the queue).
 */
class AutoUpNext(
    private val source: AutoUpNextSource,
    /** Catalog lookup for artwork / the canonical title; the queue's own title is the fallback. */
    private val song: (String) -> AutoSongInfo?,
    private val maxRows: Int = MAX_ROWS,
) {
    fun rows(): List<AutoUpNextRow> = source.upcoming().take(maxRows)

    val hasRows: Boolean get() = source.upcoming().isNotEmpty()

    /** Identity + order of the rows: the notify filter (an unchanged list is never re-notified). */
    fun signature(): String = rows().joinToString(",") { it.uid }

    fun tabNode(): AutoNode {
        val n = source.upcoming().size
        return AutoNode(
            id = AutoId.UpNext.encoded, title = "Up Next",
            subtitle = if (n == 1) "1 song coming up" else "$n songs coming up",
            browsable = true, childPlayableStyle = AutoStyle.LIST, childBrowsableStyle = AutoStyle.LIST,
            childCount = n,
        )
    }

    fun children(): List<AutoNode> {
        val rows = rows()
        if (rows.isEmpty()) return listOf(AutoNode(AutoId.Empty(AutoId.UpNext.encoded).encoded, "Nothing up next"))
        return rows.map(::rowNode)
    }

    fun item(id: AutoId): AutoNode? = when (id) {
        AutoId.UpNext -> tabNode()
        is AutoId.UpNextRow -> rows().firstOrNull { it.uid == id.uid }?.let(::rowNode)
        else -> null
    }

    private fun rowNode(r: AutoUpNextRow): AutoNode {
        val info = song(r.songId)
        return AutoNode(
            id = AutoId.UpNextRow(r.uid).encoded,
            title = info?.title ?: r.title,
            subtitle = info?.artist ?: r.artist,
            artUrl = info?.artUrl,
            playable = true,
            upNextActions = true,
        )
    }

    /** A row tap = Play now. False when [uid] is no longer upcoming (played, removed): nothing happens. */
    fun playNow(uid: String): Boolean {
        if (source.upcoming().none { it.uid == uid }) return false
        source.jump(uid)
        return true
    }

    /** A per-row command button. False for an unknown action or a row that is no longer upcoming. */
    fun command(action: String, uid: String): Boolean {
        if (action !in ACTIONS || source.upcoming().none { it.uid == uid }) return false
        when (action) {
            ACTION_PLAY_NEXT -> source.playNext(uid)
            ACTION_MOVE_TO_END -> source.moveToEnd(uid)
            ACTION_REMOVE -> source.remove(uid)
        }
        return true
    }

    companion object {
        const val MAX_ROWS = 100
        const val ACTION_PLAY_NEXT = "pdj.upNextPlayNext"
        const val ACTION_MOVE_TO_END = "pdj.upNextToEnd"
        const val ACTION_REMOVE = "pdj.upNextRemove"
        const val LABEL_PLAY_NEXT = "Play next"
        const val LABEL_MOVE_TO_END = "Move to end"
        const val LABEL_REMOVE = "Remove"
        val ACTIONS = listOf(ACTION_PLAY_NEXT, ACTION_MOVE_TO_END, ACTION_REMOVE)
    }
}

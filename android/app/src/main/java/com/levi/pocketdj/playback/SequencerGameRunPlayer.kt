package com.levi.pocketdj.playback

import com.levi.pocketdj.data.rips.PlayAction
import com.levi.pocketdj.playback.sequencer.QueueItem
import com.levi.pocketdj.playback.sequencer.ResolveContext
import com.levi.pocketdj.playback.sequencer.Rung
import com.levi.pocketdj.playback.sequencer.RowSource
import com.levi.pocketdj.playback.sequencer.RowSourceResolver
import com.levi.pocketdj.playback.sequencer.SetlistSequencer
import com.levi.pocketdj.playback.sequencer.StreamSource
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.async
import kotlinx.coroutines.awaitAll
import kotlinx.coroutines.coroutineScope
import kotlinx.coroutines.flow.distinctUntilChanged
import kotlinx.coroutines.flow.map
import kotlinx.coroutines.flow.collectLatest
import kotlinx.coroutines.launch
import kotlinx.coroutines.CancellationException
import java.util.concurrent.ConcurrentHashMap
import kotlinx.coroutines.withTimeoutOrNull

/**
 * [GameRunPlayer] over the shared [SetlistSequencer] (the Android `SetlistPlayer`). Runs are queue
 * plays tagged `PlayContext.game(tag, label)`; the tag rides every row (`appendRows(runTag)`).
 *
 * Game runs are ExoPlayer-only: manifest rips and burned files resolve through the normal ladder,
 * a non-manifest song with an `appleMusicId` rides as its cached 30-second AM preview via
 * [GamePreviewResolver]. Full-track Apple Music is never used inside a game queue.
 */
class SequencerGameRunPlayer(
    private val sequencer: SetlistSequencer,
    private val previews: GamePreviewResolver,
    private val scope: CoroutineScope,
) : GameRunPlayer {

    // ---- ownership ---------------------------------------------------------------------------
    // Android foreign plays often never reach sequencer.play (Browse album -> abandonRun, a
    // non-member single -> retirePendingStart), so the sequencer's state alone cannot say who is
    // sounding. A takeover is: a different session is running, OR PlaybackController reported a
    // sequencer-bypassing play since ours began (SetlistSequencer.foreignPlayCount). Latched until
    // the next playRun so a foreign play that later ends is never mistaken for our run returning.
    @Volatile private var ourTag: String? = null
    @Volatile private var ourSession: String? = null
    @Volatile private var foreignBase: Int = 0
    @Volatile private var lost: Boolean = false

    private fun taken(): Boolean {
        if (ourSession == null) return false
        if (lost) return true
        val st = sequencer.state.value
        if (sequencer.foreignPlayCount != foreignBase || (st.isRunning && st.sessionId != ourSession)) lost = true
        return lost
    }

    override val runningTag: String?
        get() {
            val st = sequencer.state.value
            return when {
                taken() -> if (st.isRunning && st.sessionId != ourSession) st.runTagOrSource() ?: FOREIGN_TAG else FOREIGN_TAG
                st.isRunning -> st.runTagOrSource()
                else -> null
            }
        }

    override val isRunning: Boolean get() = sequencer.state.value.isRunning || taken()

    override val position: Int get() = sequencer.state.value.index

    override fun ownsRun(tag: String): Boolean {
        // After a process restart the durable session restores the queue but this player has no
        // session of its own: fall back to the iOS rule (running && source tag == tag).
        if (ourSession == null && ourTag == null) {
            return sequencer.state.value.let { it.isRunning && it.runTagOrSource() == tag }
        }
        return ownsOwnRun(tag)
    }

    private fun ownsOwnRun(tag: String): Boolean =
        !taken() && ourTag == tag && sequencer.state.value.let { it.isRunning && it.sessionId == ourSession }

    private fun com.levi.pocketdj.playback.sequencer.SequencerState.runTagOrSource(): String? =
        capturedContext?.contextId ?: sourceSetlistId

    init {
        // Keep the preview cache warm LOOKAHEAD rows ahead of wherever the cursor is.
        scope.launch {
            sequencer.state.map { it.sessionId to it.index }.distinctUntilChanged().collectLatest {
                if (ourSession != null && !taken()) warmWindow()
            }
        }
    }

    override fun playRun(items: List<RunItem>, tag: String, label: String) {
        if (items.isEmpty()) return
        foreignBase = sequencer.foreignPlayCount
        lost = false
        ourTag = tag
        sequencer.play(
            items = items.map { it.toQueueItem(tag) },
            sourceSetlistId = tag,
            context = PlayContext.game(tag, label),
        )
        ourSession = sequencer.state.value.sessionId
        scope.launch { warmWindow() }
    }

    override fun appendRun(items: List<RunItem>, tag: String): Boolean {
        if (items.isEmpty() || !ownsRun(tag)) return false
        sequencer.appendRows(items.map { it.toQueueItem(tag) }, tag)
        return true
    }

    override fun skipNext(tag: String): Boolean {
        if (!ownsRun(tag)) return false
        sequencer.skipNext()
        return true
    }

    override fun stopRun(tag: String): Boolean {
        if (!ownsRun(tag)) return false
        sequencer.stop()
        ourSession = null
        ourTag = null
        return true
    }

    override suspend fun filterResolvable(items: List<RunItem>): List<RunItem> {
        val verdicts = previews.canPlay(items.map { it.songId })
        return items.filter { verdicts[it.songId] != false }
    }

    private fun RunItem.toQueueItem(tag: String) =
        QueueItem(id = songId, title = title, artist = artist, lengthMs = lengthMs, runTag = tag)

    /** Resolve previews for [cursor, cursor + LOOKAHEAD) so the sequencer's resolve is a cache hit. */
    private suspend fun warmWindow() {
        val st = sequencer.state.value
        if (!st.isRunning) return
        previews.warm(st.queue.drop(st.index).take(LOOKAHEAD).map { it.id })
    }

    companion object {
        /** Preview URLs are resolved this many rows ahead of the cursor. */
        const val LOOKAHEAD = 12

        /** `runningTag` reported while a sequencer-bypassing foreign play sounds. */
        const val FOREIGN_TAG = "foreign"
    }
}

/**
 * Knows which songs can make sound in a game run and resolves AM previews for the rest.
 * [localPlayable] = a manifest rip or burned file exists (instant). [appleMusicId] = the catalog
 * join key. [previewUrl] = cached 30-s preview lookup (null = none).
 */
class GamePreviewResolver(
    private val localPlayable: (String) -> Boolean,
    private val appleMusicId: (String) -> String?,
    private val previewUrl: suspend (String) -> String?,
    private val probeTimeoutMs: Long = 4_000,
) {
    /** AM ids whose lookup came back empty this session: never re-fetched (iTunes lookup is rate limited). */
    private val misses = ConcurrentHashMap.newKeySet<String>()

    private suspend fun lookup(amId: String): String? {
        if (amId in misses) return null
        val url = try {
            previewUrl(amId)
        } catch (e: CancellationException) {
            throw e
        } catch (_: Exception) {
            null
        }
        if (url == null) misses += amId
        return url
    }

    /**
     * songId -> true (plays) / false (cannot). The first chunk of [SequencerGameRunPlayer.LOOKAHEAD]
     * network-bound songs is probed within the budget; anything not answered in time is UNKNOWN and
     * treated like the rest of the unprobed tail (optimistic, skipped at its turn if it misses).
     */
    suspend fun canPlay(songIds: List<String>): Map<String, Boolean> {
        val out = HashMap<String, Boolean>()
        val network = ArrayList<String>()
        for (id in songIds) {
            when {
                localPlayable(id) -> out[id] = true
                appleMusicId(id) == null -> out[id] = false
                else -> network += id
            }
        }
        val first = network.take(SequencerGameRunPlayer.LOOKAHEAD)
        val answered = ConcurrentHashMap<String, Boolean>()
        withTimeoutOrNull(probeTimeoutMs) {
            coroutineScope {
                first.map { id -> async { answered[id] = urlFor(id) != null } }.awaitAll()
            }
        }
        for (id in first) out[id] = answered[id] ?: true
        for (id in network.drop(first.size)) out[id] = true
        return out
    }

    /** Resolve (and cache) previews for the network-bound ids, a chunk at a time. */
    suspend fun warm(songIds: List<String>) {
        songIds.filter { !localPlayable(it) && appleMusicId(it) != null }
            .chunked(SequencerGameRunPlayer.LOOKAHEAD)
            .forEach { chunk -> coroutineScope { chunk.map { async { urlFor(it) } }.awaitAll() } }
    }

    /** The URL for the sequencer rung. */
    suspend fun urlFor(songId: String): String? = appleMusicId(songId)?.let { lookup(it) }
}

/**
 * Ladder rung for game-run rows that no rip/burn rung claimed: the cached AM preview as a plain
 * ExoPlayer stream. Only rows stamped with a run tag are eligible, so ordinary queues keep
 * their "no 30 s preview inside a set" rule.
 */
class GamePreviewRowResolver(private val previews: GamePreviewResolver) : RowSourceResolver {
    override val id: String = "game-preview"
    override val rung: Rung = Rung.FALLBACK
    override suspend fun resolve(item: QueueItem, ctx: ResolveContext): RowSource? {
        if (item.runTag == null) return null
        val url = previews.urlFor(item.id) ?: return null
        return StreamSource(PlayAction.Stream(url))
    }
}

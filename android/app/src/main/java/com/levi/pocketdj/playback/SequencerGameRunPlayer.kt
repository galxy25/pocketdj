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
import kotlinx.coroutines.launch
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

    override val runningTag: String?
        get() = sequencer.state.value.let { if (it.isRunning) it.runTagOrSource() else null }

    override val isRunning: Boolean get() = sequencer.state.value.isRunning

    override val position: Int get() = sequencer.state.value.index

    private fun com.levi.pocketdj.playback.sequencer.SequencerState.runTagOrSource(): String? =
        capturedContext?.contextId ?: sourceSetlistId

    override fun playRun(items: List<RunItem>, tag: String, label: String) {
        if (items.isEmpty()) return
        sequencer.play(
            items = items.map { it.toQueueItem(tag) },
            sourceSetlistId = tag,
            context = PlayContext.game(tag, label),
        )
        warmAhead(items, fromIndex = 0)
    }

    override fun appendRun(items: List<RunItem>, tag: String): Boolean {
        if (items.isEmpty() || !ownsRun(tag)) return false
        sequencer.appendRows(items.map { it.toQueueItem(tag) }, tag)
        warmAhead(items, fromIndex = 0)
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
        return true
    }

    override suspend fun filterResolvable(items: List<RunItem>): List<RunItem> {
        val verdicts = previews.canPlay(items.map { it.songId })
        return items.filter { verdicts[it.songId] != false }
    }

    private fun RunItem.toQueueItem(tag: String) =
        QueueItem(id = songId, title = title, artist = artist, lengthMs = lengthMs, runTag = tag)

    /** Warm the preview cache [LOOKAHEAD] rows at a time so the sequencer's resolve is a cache hit. */
    private fun warmAhead(items: List<RunItem>, fromIndex: Int) {
        val ids = items.drop(fromIndex).map { it.songId }
        scope.launch { previews.warm(ids) }
    }

    companion object {
        /** Preview URLs are resolved this many rows ahead of the cursor. */
        const val LOOKAHEAD = 12
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
    /** songId -> true (plays) / false (cannot). Chunks of [SequencerGameRunPlayer.LOOKAHEAD], first chunk awaited. */
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
        val probed = withTimeoutOrNull(probeTimeoutMs) { probe(first) } ?: emptyMap()
        for (id in first) out[id] = probed[id] == true
        // Beyond the first chunk: optimistic; resolved when the cursor gets near (the ladder rung
        // returns null for a miss and the sequencer skips that row at its turn).
        for (id in network.drop(first.size)) out[id] = true
        return out
    }

    /** Resolve (and cache) previews for the network-bound ids, a chunk at a time. */
    suspend fun warm(songIds: List<String>) {
        songIds.filter { !localPlayable(it) && appleMusicId(it) != null }
            .chunked(SequencerGameRunPlayer.LOOKAHEAD)
            .forEach { probe(it) }
    }

    private suspend fun probe(ids: List<String>): Map<String, Boolean> = coroutineScope {
        ids.map { id ->
            async { id to (appleMusicId(id)?.let { runCatching { previewUrl(it) }.getOrNull() } != null) }
        }.awaitAll().toMap()
    }

    /** The URL for the sequencer rung. */
    suspend fun urlFor(songId: String): String? =
        appleMusicId(songId)?.let { runCatching { previewUrl(it) }.getOrNull() }
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

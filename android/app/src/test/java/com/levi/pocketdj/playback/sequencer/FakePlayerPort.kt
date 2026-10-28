package com.levi.pocketdj.playback.sequencer

import kotlinx.coroutines.CompletableDeferred

/** Records what the sequencer asked the engine to do; loads can be gated or made to fail per song. */
class FakePlayerPort : PlayerPort {
    val loads = mutableListOf<PlayRequest>()
    val urls = mutableListOf<UrlRequest>()
    var stops = 0
    var pauses = 0
    var resumes = 0

    /** Songs whose load suspends until the deferred completes (complete exceptionally to fail it). */
    val gates = mutableMapOf<String, CompletableDeferred<Unit>>()

    /** Songs whose load throws immediately. */
    val failing = mutableSetOf<String>()

    /** Ids in load-COMPLETION order (the audio that actually "sounded"). */
    val sounded = mutableListOf<String>()

    /** Runs inside load() just before it returns (e.g. an engine reporting first audio mid-load). */
    var duringLoad: ((String) -> Unit)? = null

    override suspend fun load(request: PlayRequest) {
        loads += request
        val id = request.item.id
        gates[id]?.await()
        if (id in failing) error("dead source $id")
        sounded += id
        held = id
        preloadedId = null // setMediaItems replaces the whole window
        duringLoad?.invoke(id)
    }

    /** Song ids restarted in place. */
    val replays = mutableListOf<String>()

    /** What the engine "holds" (last loaded id); [replay] succeeds only for it. */
    var held: String? = null
    var replayWorks = true

    override suspend fun replay(songId: String): Boolean {
        if (!replayWorks || held != songId) return false
        replays += songId
        return true
    }

    override suspend fun loadUrl(request: UrlRequest) {
        held = null
        urls += request
    }

    /** PB-10: every preloadNext call (song id, or null = slot emptied) and the slot the "engine" holds now. */
    val preloadCalls = mutableListOf<String?>()
    var preloadedId: String? = null

    override suspend fun preloadNext(request: PlayRequest?): Boolean {
        preloadCalls += request?.item?.id
        preloadedId = request?.item?.id
        return true
    }

    override suspend fun pause() { pauses++ }
    override suspend fun resume() { resumes++ }
    override suspend fun seekTo(positionMs: Long) = Unit
    override suspend fun stop() { stops++ }

    val loadedIds: List<String> get() = loads.map { it.item.id }
}

/** A resolver backed by a map; unmapped ids pass down the ladder. */
class MapResolver(
    override val id: String,
    override val rung: Rung,
    private val sources: Map<String, RowSource>,
    private val gates: Map<String, CompletableDeferred<Unit>> = emptyMap(),
) : RowSourceResolver {
    val seenContexts = mutableListOf<ResolveContext>()
    override suspend fun resolve(item: QueueItem, ctx: ResolveContext): RowSource? {
        seenContexts += ctx
        gates[item.id]?.await()
        return sources[item.id]
    }
}

fun stream(id: String) = StreamSource(
    com.levi.pocketdj.data.rips.PlayAction.Stream("https://rips/$id.mp3"),
)

fun rows(vararg ids: String): List<QueueItem> = ids.map { QueueItem(id = it, title = it) }

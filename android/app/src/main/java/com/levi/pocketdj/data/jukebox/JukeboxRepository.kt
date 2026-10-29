package com.levi.pocketdj.data.jukebox

import android.content.Context
import com.levi.pocketdj.data.catalog.CatalogRepository
import com.levi.pocketdj.data.catalog.IndexSong
import com.levi.pocketdj.data.config.Endpoints
import com.levi.pocketdj.data.rips.RipsRepository
import com.levi.pocketdj.playback.PlaybackController
import com.levi.pocketdj.playback.PlayContext
import com.levi.pocketdj.playback.sequencer.QueueItem
import com.levi.pocketdj.playback.sequencer.SequencerState
import com.levi.pocketdj.playback.sequencer.SetlistSequencer
import java.util.concurrent.atomic.AtomicBoolean
import kotlin.random.Random
import kotlinx.coroutines.CancellationException
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.Job
import kotlinx.coroutines.flow.MutableSharedFlow
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.asStateFlow
import kotlinx.coroutines.flow.first
import kotlinx.coroutines.flow.update
import kotlinx.coroutines.isActive
import kotlinx.coroutines.launch
import kotlinx.coroutines.sync.Mutex
import kotlinx.coroutines.sync.withLock
import kotlinx.coroutines.withContext
import kotlinx.coroutines.withTimeoutOrNull

/**
 * The DJ session engine — the Android `JukeboxStore` equivalent
 * (specs/jukebox.md §4). App-scoped singleton: the 4 s loop runs in the app
 * scope so it survives navigation, and the session persists so a relaunch
 * re-adopts a running party.
 *
 * Loop shape (§4.2): one coroutine while live; each tick posts a player-state
 * snapshot (on change, or on the 15 s heartbeat) and polls guest requests.
 * Posting honest snapshots IS how songs get marked played — the broker derives
 * the played history from now-playing transitions across the posts (§1); this
 * store mirrors that derivation locally for the played-history section.
 *
 * Transport errors never stop the loop; 404/410 folds the session (§2.4).
 */
class JukeboxRepository(
    context: Context,
    private val client: JukeboxClient,
    private val sessionStore: JukeboxSessionStore,
    private val catalog: CatalogRepository,
    private val rips: RipsRepository,
    private val playback: PlaybackController,
    private val scope: CoroutineScope,
    /** The PocketDJ name (Settings ▸ Profile); "" when unset. */
    private val pocketDjName: suspend () -> String = { "" },
    /** Seam: broadcast-into-Mix placement (Mix area wires it; default no-op). */
    @Volatile var placementSink: JukeboxPlacementSink = JukeboxPlacementSink.None,
    /** Seam: Apple-Music catalog match stage (device-only; default null). */
    @Volatile var externalMatch: JukeboxExternalMatch = JukeboxExternalMatch.None,
    /** Where accepted requests land: the sequencer (null in tests that never place). */
    @Volatile var queue: JukeboxQueue? = null,
    /** Seam: the live Mix (MIX-16). Consulted per call so a mix started after construction is picked up. */
    private val mixSource: () -> MixJukeboxSource? = { MixJukeboxSeam.source },
) {
    private val appContext by lazy { context.applicationContext }

    /** Match state for one inbox row (§4.4). */
    sealed interface Match {
        /** Row shows "Matching…" until the async match lands. */
        data object Searching : Match

        /** No catalog candidate — Deny is the only enabled action. */
        data object None : Match

        /**
         * A catalog candidate; [playable] is true only when a public rip exists
         * — a match without audio must stay Deny-only (§5.1).
         */
        data class Found(val song: IndexSong, val playable: Boolean) : Match
    }

    data class RequestRow(
        val request: JukeboxRequest,
        val match: Match = Match.Searching,
    )

    data class UiState(
        val session: JukeboxSessionInfo? = null,
        val starting: Boolean = false,
        /** View + Hear (§5.3) — every new session starts OFF. */
        val hear: Boolean = false,
        /** Pending guest requests, oldest first. */
        val requests: List<RequestRow> = emptyList(),
        /** Locally-derived played history, newest first (mirror of §1). */
        val played: List<JukeboxPlayedEntry> = emptyList(),
        /** Queue items after the current one, from the last loop tick. */
        val upNextCount: Int = 0,
        /**
         * A live auto mix owns the audio, so an accepted request joins ITS queue (parked behind a burn when
         * the song is not on disk yet): the accept buttons must not wait for a rip-playable match.
         */
        val mixOwns: Boolean = false,
        /** Transient broker trouble — shown as a subtle hint; loop keeps going. */
        val transientError: String? = null,
        /** Create-view message: start failure or "This jukebox has ended." */
        val notice: String? = null,
    )

    private val _state = MutableStateFlow(UiState())
    val state: StateFlow<UiState> = _state.asStateFlow()

    private var loopJob: Job? = null
    private val tickKick = MutableSharedFlow<Unit>(extraBufferCapacity = 1)
    private val bootstrapped = AtomicBoolean(false)

    /** Requests already decided locally — the poll re-delivers decided ids
     *  because a decision bumps their seq server-side (§2.5, §4.2). Synchronized:
     *  written from the UI thread in [decide], read on Default in [ingest]. */
    private val decided: MutableSet<String> =
        java.util.Collections.synchronizedSet(mutableSetOf<String>())
    private var sinceSeq = 0L
    private var lastPosted: JukeboxStatePayload? = null
    private var lastPostAtMs = 0L
    private var lastOnAir: Pair<String, String>? = null

    /** Serializes session commits (bootstrap / start / adopt) so a slow
     *  coroutine can't overwrite a session another one already committed. */
    private val commitLock = Mutex()

    /** Runs [block] only when no session other than [allowId] is active. */
    private suspend fun commitIfFree(allowId: String?, block: suspend () -> Unit): Boolean =
        commitLock.withLock {
            val current = _state.value.session
            if (current != null && current.jukeboxId != allowId) {
                false
            } else {
                block()
                true
            }
        }

    /** Re-adopt a persisted session at app start (§4.1 Resume). Idempotent. */
    fun bootstrap() {
        if (!bootstrapped.compareAndSet(false, true)) return
        scope.launch {
            val persisted = sessionStore.load() ?: return@launch
            commitLock.withLock {
                if (_state.value.session != null || _state.value.starting) return@launch
                _state.update { it.copy(session = persisted.session, hear = persisted.hear) }
                startLoop()
            }
        }
    }

    /** Start a session (§4.1). Errors land in [UiState.notice]; stay on create. */
    fun start(name: String, requiresToken: Boolean) {
        if (_state.value.session != null || _state.value.starting) return
        _state.update { it.copy(starting = true, notice = null) }
        scope.launch {
            try {
                val created = client.createSession(
                    name = name.trim().ifEmpty { JukeboxSettings.defaultSessionName(pocketDjName()) },
                    requiresToken = requiresToken,
                )
                // Stamp the intent locally — the server doesn't echo it (§3.1).
                val stamped = created.copy(requiresToken = requiresToken)
                val committed = commitIfFree(null) {
                    sessionStore.save(stamped)
                    sessionStore.setHear(false)
                    resetLoopBookkeeping()
                    _state.value = UiState(session = stamped, hear = false)
                    startLoop()
                }
                if (!committed) {
                    runCatching { client.end(stamped) }
                    _state.update { it.copy(starting = false) }
                }
            } catch (error: CancellationException) {
                throw error
            } catch (error: Exception) {
                _state.update {
                    it.copy(
                        starting = false,
                        notice = error.message ?: "Couldn't start the jukebox",
                    )
                }
            }
        }
    }

    /** Every live session on the broker (picker surfaces). */
    suspend fun listSessions(): List<JukeboxSessionRow> = client.listSessions()

    /**
     * Become the publisher of an existing session (iOS `adopt`): no-op for the
     * current one, refused while a different one is active or a start is in
     * flight; otherwise adopt, reset loop bookkeeping, persist, start the loop.
     */
    fun adopt(jukeboxId: String) {
        val current = _state.value
        when (JukeboxAdoptGuard.decide(current.session?.jukeboxId, current.starting, jukeboxId)) {
            JukeboxAdoptDecision.NO_OP, JukeboxAdoptDecision.REFUSE -> return
            JukeboxAdoptDecision.PROCEED -> Unit
        }
        _state.update { it.copy(starting = true, notice = null) }
        scope.launch {
            try {
                val info = client.sessionInfo(jukeboxId)
                val committed = commitIfFree(jukeboxId) {
                    sessionStore.save(info)
                    sessionStore.setHear(false)
                    resetLoopBookkeeping()
                    _state.value = UiState(session = info, hear = false)
                    startLoop()
                }
                if (!committed) _state.update { it.copy(starting = false) }
            } catch (error: CancellationException) {
                throw error
            } catch (error: Exception) {
                _state.update {
                    it.copy(starting = false, notice = error.message ?: "Couldn't adopt the jukebox")
                }
            }
        }
    }

    /**
     * End the party (§4.1): POST /end best-effort, then clear the local session
     * EVEN IF the POST failed — an unreachable broker must not trap the host.
     */
    fun end() {
        val session = _state.value.session ?: return
        loopJob?.cancel()
        loopJob = null
        scope.launch {
            runCatching { client.end(session) }
            sessionStore.clear()
            resetLoopBookkeeping()
            _state.value = UiState()
        }
    }

    /**
     * Account deletion / reset (iOS awaits `jukebox.end()`): end the party even when this process never opened the
     * Jukebox tab (load the persisted session), bounded POST /end, then clear the store and the in-memory state.
     */
    suspend fun endAndAwait(timeoutMs: Long = 8_000) {
        loopJob?.cancel()
        loopJob = null
        val session = _state.value.session ?: runCatching { sessionStore.load()?.session }.getOrNull()
        if (session != null) {
            kotlinx.coroutines.withTimeoutOrNull(timeoutMs) {
                try {
                    client.end(session)
                } catch (e: CancellationException) {
                    throw e
                } catch (_: Exception) {
                    // best-effort: an unreachable broker must not trap the host
                }
            }
        }
        sessionStore.clear()
        resetLoopBookkeeping()
        _state.value = UiState()
    }

    /**
     * Switch hosting to [jukeboxId]: end the current party (awaited, so adopt's guard sees it gone), then adopt.
     * Runs on the repository's own scope so a dismissed sheet can't cancel it halfway (iOS: unstructured Task).
     * Failures surface as [UiState.notice].
     */
    fun switchTo(jukeboxId: String) {
        scope.launch {
            try {
                endAndAwait()
                adopt(jukeboxId)
            } catch (e: CancellationException) {
                throw e
            } catch (e: Exception) {
                _state.update { it.copy(notice = e.message ?: "Couldn't switch session") }
            }
        }
    }

    /** Flip View + Hear; an immediate tick shows guests the flip promptly. */
    fun setHear(enabled: Boolean) {
        if (_state.value.session == null) return
        _state.update { it.copy(hear = enabled) }
        scope.launch { sessionStore.setHear(enabled) }
        kick()
    }

    /** Local-intent-only toggle (§3.1, §9) — persisted, never claimed enforced. */
    fun setRequiresTokenIntent(required: Boolean) {
        val session = _state.value.session ?: return
        val stamped = session.copy(requiresToken = required)
        _state.update { it.copy(session = stamped) }
        scope.launch { sessionStore.save(stamped) }
    }

    /**
     * Decide a request (§4.3): the id joins the decided set and leaves the inbox
     * immediately; the POST is fire-and-forget (the local queue edit is the
     * user-visible truth). Placements apply only with a playable match.
     */
    fun decide(requestId: String, action: JukeboxDecisionAction) {
        val session = _state.value.session ?: return
        val row = _state.value.requests.firstOrNull { it.request.id == requestId } ?: return
        decided += requestId
        _state.update { current ->
            current.copy(requests = current.requests.filterNot { it.request.id == requestId })
        }
        scope.launch { runCatching { client.decide(session, requestId, action) } }
        if (action.isPlacement) {
            val found = row.match as? Match.Found ?: return
            // A live auto mix owns the setlist: even an un-ripped match joins ITS queue (parked behind a
            // burn-when-ripped intent); the sequencer path below still needs a playable match.
            scope.launch {
                val mixOwns = runCatching { onMain { mixSource()?.autoMixing } == true }.getOrDefault(false)
                if (mixOwns) {
                    try {
                        if (onMain { mixSource()?.place(found.song, action) } == true) {
                            kick()
                            return@launch
                        }
                    } catch (c: CancellationException) {
                        throw c
                    } catch (e: Exception) {
                        // Never fall back to the sequencer: it would sound on top of the live mix.
                        _state.update { it.copy(transientError = e.message ?: "Couldn't add to the mix") }
                        return@launch
                    }
                }
                if (!found.playable) return@launch
                val handled = try {
                    placementSink.place(found.song, action)
                } catch (c: CancellationException) {
                    throw c
                } catch (e: Exception) {
                    false
                }
                if (!handled) applyPlacement(found.song, action)
            }
        }
    }

    // ---- loop --------------------------------------------------------------

    private fun startLoop() {
        loopJob?.cancel()
        loopJob = scope.launch {
            while (isActive && _state.value.session != null) {
                tick()
                withTimeoutOrNull(TICK_MS) { tickKick.first() }
            }
        }
    }

    /** Request an immediate tick (hear flip, fresh placement). */
    private fun kick() {
        tickKick.tryEmit(Unit)
    }

    private suspend fun tick() {
        val session = _state.value.session ?: return
        val hear = _state.value.hear
        try {
            // 1. Compose + post the snapshot (on change or 15 s heartbeat).
            // "Post positions honestly" (§1): a FAILED player read must skip the
            // state POST for this tick — posting nowPlaying=null would make the
            // broker log the still-playing song as played and flash guests
            // "Nothing playing" over a transient binder hiccup.
            // Parked broadcast inserts whose burn landed; ones whose mix ended go to a running sequencer.
            runCatching { onMain { mixSource()?.drainPending() } }.getOrNull()?.forEach { landed ->
                if (queue?.isRunning == true) applyPlacement(landed.song, landed.action)
            }
            val snapshotResult = runCatching { readPlayer() }
            snapshotResult.exceptionOrNull()?.let { if (it is CancellationException) throw it }
            if (snapshotResult.isSuccess) {
                val snapshot = snapshotResult.getOrNull()
                derivePlayed(snapshot)
                val mixOwns = runCatching { onMain { mixSource()?.autoMixing } == true }.getOrDefault(false)
                _state.update { it.copy(upNextCount = snapshot?.upNext?.size ?: 0, mixOwns = mixOwns) }
                val payload = composePayload(snapshot, hear)
                val now = System.currentTimeMillis()
                if (payload != lastPosted || now - lastPostAtMs > HEARTBEAT_MS) {
                    client.postState(session, payload)
                    lastPosted = payload
                    lastPostAtMs = now
                }
            }

            // 2. Poll guest requests above the seq high-water mark.
            val page = client.requests(session, sinceSeq)
            sinceSeq = maxOf(sinceSeq, page.seq)
            ingest(page.requests)

            // 3. Success clears the reconnect hint.
            _state.update { it.copy(transientError = null) }
        } catch (error: CancellationException) {
            throw error
        } catch (error: JukeboxClient.JukeboxException) {
            if (error.code == 404 || error.code == 410) {
                foldSession()
            } else {
                _state.update { it.copy(transientError = error.message) }
            }
        } catch (error: Exception) {
            _state.update {
                it.copy(transientError = error.message ?: "Jukebox server unreachable — retrying")
            }
        }
    }

    /** Server-side death (§2.4): clear everything, back to the create view. */
    private suspend fun foldSession() {
        sessionStore.clear()
        resetLoopBookkeeping()
        _state.value = UiState(notice = "This jukebox has ended.")
    }

    private fun resetLoopBookkeeping() {
        decided.clear()
        sinceSeq = 0
        lastPosted = null
        lastPostAtMs = 0
        lastOnAir = null
    }

    private fun ingest(incoming: List<JukeboxRequest>) {
        val inboxIds = _state.value.requests.map { it.request.id }.toSet()
        val fresh = incoming.filter { request ->
            request.status == JukeboxRequest.STATUS_PENDING &&
                request.id !in decided &&
                request.id !in inboxIds
        }
        if (fresh.isEmpty()) return
        _state.update { current ->
            current.copy(requests = current.requests + fresh.map(::RequestRow))
        }
        fresh.forEach { request ->
            scope.launch(Dispatchers.Default) { computeMatch(request) }
        }
    }

    private suspend fun computeMatch(request: JukeboxRequest) {
        // A cold start that never visited Browse has no catalog in memory; matching against nothing
        // would flag every request "No match found". Load it (cache-seeded) and wait a bounded time.
        if (catalog.state.value.catalog == null) {
            catalog.loadIfNeeded()
            withTimeoutOrNull(CATALOG_WAIT_MS) { catalog.state.first { it.catalog != null } }
        }
        val songs = catalog.state.value.catalog?.songs.orEmpty()
        val song = JukeboxMatcher.match(request.title, request.artist, songs)
            ?: try {
                externalMatch.match(request.title, request.artist)
            } catch (c: CancellationException) {
                throw c
            } catch (e: Exception) {
                null
            }
        val match = song?.let { Match.Found(it, rips.isPlayable(it.id)) } ?: Match.None
        _state.update { current ->
            current.copy(
                requests = current.requests.map { row ->
                    if (row.request.id == request.id) row.copy(match = match) else row
                },
            )
        }
    }

    // ---- snapshots ---------------------------------------------------------

    private data class PlayerSnapshot(
        val songId: String?,
        val title: String?,
        val artist: String?,
        val durationMs: Long?,
        val positionMs: Long,
        val upNext: List<JukeboxStatePayload.Track>,
    )

    private fun composePayload(snapshot: PlayerSnapshot?, hear: Boolean): JukeboxStatePayload {
        val nowPlaying = snapshot?.songId?.let { songId ->
            JukeboxStatePayload.NowPlaying(
                title = snapshot.title.orEmpty(),
                artist = snapshot.artist.orEmpty(),
                lengthMs = snapshot.durationMs,
                positionMs = snapshot.positionMs,
                streamUrl = if (hear) publicRipUrl(songId) else null,
            )
        }
        return JukeboxStatePayload(
            hear = hear,
            nowPlaying = nowPlaying,
            upNext = snapshot?.upNext.orEmpty(),
        )
    }

    /**
     * Hear-mode gate (§5.3, client-side and load-bearing): ONLY the public https
     * rips-bucket mp3 ever leaves the device — no manifest entry, no streamUrl.
     */
    private fun publicRipUrl(songId: String): String? =
        rips.entry(songId)?.key?.let(Endpoints::ripAudioUrl)

    /**
     * Local mirror of the broker's played-history derivation (§1): a snapshot
     * replacing one track with a different one (or nothing) logs the outgoing
     * track, one row per track (see [JukeboxPlayedDedup]).
     */
    private fun derivePlayed(snapshot: PlayerSnapshot?) {
        val current = snapshot?.songId?.let {
            snapshot.title.orEmpty() to snapshot.artist.orEmpty()
        }
        val previous = lastOnAir
        val now = System.currentTimeMillis()
        _state.update {
            it.copy(
                played = JukeboxPlayedDedup.apply(
                    it.played,
                    previous?.let { p -> JukeboxOnAir(p.first, p.second) },
                    current?.let { c -> JukeboxOnAir(c.first, c.second) },
                    now,
                    PLAYED_CAP,
                ),
            )
        }
        lastOnAir = current
    }

    // ---- playback integration (§4.3, §5) -----------------------------------

    private suspend fun applyPlacement(song: IndexSong, action: JukeboxDecisionAction) {
        try {
            val target = queue
            if (target == null) {
                // Not wired (unit tests): fall back to a plain play so a request is never silently lost.
                playback.play(song.id, queueAlbumContext = false)
                kick()
                return
            }
            if (!rips.isPlayable(song.id)) {
                _state.update { it.copy(transientError = "“${song.name}” isn't playable anymore") }
                return
            }
            // Studio mic capture owns the audio path: nothing may start sounding into the take.
            if (!com.levi.pocketdj.studio.engine.AudioFocusPolicy.gateStartRaw("jukebox")) {
                _state.update { it.copy(transientError = "Recording in progress - request not queued") }
                return
            }
            val item = QueueItem(id = song.id, title = song.name, artist = song.artist, lengthMs = song.length)
            val np = playback.nowPlaying.value
            val foreign = if (!target.isRunning && np != null && np.songId.isNotEmpty()) {
                ForeignPlayback(
                    QueueItem(id = np.songId, title = np.title ?: np.songId, artist = np.artist, lengthMs = np.durationMs),
                    runCatching { playback.currentPositionMs() }.getOrDefault(0L),
                )
            } else {
                null
            }
            // The sequencer is Main-confined; every queue mutation hops there.
            withContext(Dispatchers.Main) { JukeboxPlacement.place(target, item, action, foreign = foreign) }
            kick()
        } catch (error: CancellationException) {
            throw error
        } catch (error: Exception) {
            _state.update { it.copy(transientError = error.message ?: "Couldn't queue the request") }
        }
    }

    /** Mix state is Main-confined; with no mix wired (tests, no Mix built) there is nothing to hop for. */
    private suspend fun <T> onMain(block: suspend () -> T?): T? =
        if (mixSource() == null) null else withContext(Dispatchers.Main) { block() }

    /** One read of now-playing + the upcoming queue tail, from the sequencer (never the MediaController). */
    private suspend fun readPlayer(): PlayerSnapshot {
        // BROADCAST mode (iOS stateSnapshot): a live auto mix owns the audio - the on-air deck + the queue tail.
        onMain { mixSource()?.snapshot() }?.let { mix ->
            return PlayerSnapshot(
                songId = mix.songId, title = mix.title, artist = mix.artist,
                durationMs = mix.durationMs, positionMs = mix.positionMs ?: 0L,
                upNext = mix.upNext,
            )
        }
        val seq = queue?.snapshot()
        val current = seq?.current
        val np = playback.nowPlaying.value
        val position = runCatching { playback.currentPositionMs() }.getOrDefault(0L)
        val songId = current?.id ?: np?.songId
        return PlayerSnapshot(
            songId = songId,
            title = current?.title ?: np?.title,
            artist = current?.artist ?: np?.artist,
            durationMs = np?.durationMs ?: current?.lengthMs,
            positionMs = position,
            upNext = seq?.upcomingPlayable.orEmpty().map {
                JukeboxStatePayload.Track(title = it.title, artist = it.artist.orEmpty())
            },
        )
    }

    companion object {
        /** Upper bound on waiting for a cold catalog before matching a guest request. */
        const val CATALOG_WAIT_MS = 10_000L
        const val DEFAULT_SESSION_NAME = "PocketDJ Jukebox"
        private const val TICK_MS = 4_000L
        private const val HEARTBEAT_MS = 15_000L
        private const val PLAYED_CAP = 30
    }
}

/** The slice of the sequencer the jukebox needs - a seam so placement is unit-testable without Media3. */
interface JukeboxQueue {
    /** Is a run active (accepting inserts)? */
    val isRunning: Boolean
    fun snapshot(): SequencerState
    fun insertNext(item: QueueItem)
    fun append(item: QueueItem)
    /** Insert at a uniformly random slot of [slots] (index+1..count); [slot] is injectable. */
    fun insertRandom(item: QueueItem, slot: (IntRange) -> Int)
    /** Nothing running: start a one-item run tagged with [context]. */
    fun startRun(item: QueueItem, context: PlayContext)
    /**
     * Audio is sounding outside any sequencer run (album queue, browse single, AM, stream): fold it
     * into a one-row run at [positionMs] so an insert lands after it instead of replacing it.
     */
    fun adoptForeign(current: QueueItem, positionMs: Long, context: PlayContext)
}

/** What is audible while the sequencer is idle. */
data class ForeignPlayback(val item: QueueItem, val positionMs: Long)

/** Production [JukeboxQueue]: every accepted request goes through the [SetlistSequencer]. */
class SequencerJukeboxQueue(private val sequencer: SetlistSequencer) : JukeboxQueue {
    override val isRunning: Boolean get() = sequencer.state.value.isRunning
    override fun snapshot(): SequencerState = sequencer.state.value
    override fun insertNext(item: QueueItem) = sequencer.insertNextInQueue(listOf(item))
    override fun append(item: QueueItem) = sequencer.appendToQueue(listOf(item))
    override fun insertRandom(item: QueueItem, slot: (IntRange) -> Int) =
        sequencer.insertRandomInQueue(listOf(item), slot)
    override fun startRun(item: QueueItem, context: PlayContext) = sequencer.play(listOf(item), context = context)
    override fun adoptForeign(current: QueueItem, positionMs: Long, context: PlayContext) {
        sequencer.adoptForeign(current, positionMs, context)
    }
}

/** Placement rules for an accepted request (§4.3, §5). */
object JukeboxPlacement {
    /** History context of a run the jukebox started. */
    val CONTEXT = PlayContext(source = "jukebox", contextName = "Jukebox")

    fun place(
        queue: JukeboxQueue,
        item: QueueItem,
        action: JukeboxDecisionAction,
        slot: (IntRange) -> Int = { Random.nextInt(it.first, it.last + 1) },
        foreign: ForeignPlayback? = null,
    ) {
        if (!action.isPlacement) return
        if (!queue.isRunning) {
            if (foreign == null) {
                // Nothing playing: the accepted request starts the music with a one-item queue.
                queue.startRun(item, CONTEXT)
                return
            }
            // Something is sounding outside the sequencer: keep it, queue the request behind it.
            queue.adoptForeign(foreign.item, foreign.positionMs, CONTEXT)
        }
        when (action) {
            JukeboxDecisionAction.NEXT -> queue.insertNext(item)
            JukeboxDecisionAction.END -> queue.append(item)
            else -> queue.insertRandom(item, slot)
        }
    }
}

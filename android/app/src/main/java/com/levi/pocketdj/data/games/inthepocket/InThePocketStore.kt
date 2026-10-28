package com.levi.pocketdj.data.games.inthepocket

import com.levi.pocketdj.data.catalog.IndexAlbum
import com.levi.pocketdj.data.catalog.IndexSong
import com.levi.pocketdj.data.games.GameKind
import com.levi.pocketdj.data.games.GameScoreboardStore
import com.levi.pocketdj.data.history.PlayHistoryStore
import com.levi.pocketdj.data.pockets.ListeningContextTag
import com.levi.pocketdj.data.pockets.NoPocketsBridge
import com.levi.pocketdj.data.pockets.PocketsBridge
import com.levi.pocketdj.playback.GameRunPlayer
import com.levi.pocketdj.playback.RunItem
import java.io.File
import java.util.TimeZone
import java.util.UUID
import java.util.concurrent.atomic.AtomicBoolean
import kotlinx.coroutines.CancellationException
import kotlinx.coroutines.CoroutineDispatcher
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.Job
import kotlinx.coroutines.delay
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.asStateFlow
import kotlinx.coroutines.isActive
import kotlinx.coroutines.launch
import kotlinx.coroutines.withContext
import kotlinx.serialization.json.Json
import kotlinx.serialization.json.JsonArray
import kotlinx.serialization.json.JsonObject
import kotlinx.serialization.json.JsonPrimitive
import kotlinx.serialization.json.contentOrNull

/**
 * IN THE POCKET - the APP-SCOPED game store (port of InThePocketStore.swift). A running round
 * survives tab switches and leaving the game screen. It:
 *  - builds a round OFF the main thread with the pure [InThePocketScorer];
 *  - plays it through the ONE shared sequencer ([GameRunPlayer]) under `itp_<round id>`, so
 *    History reads "Game - In the Pocket";
 *  - tracks it with the pure [InThePocketRoundEvaluator] over the play-history log on a 1 Hz
 *    ticker that runs whether or not the game screen is showing;
 *  - persists every round (`pocketdj-in-the-pocket.json`, DEVICE-LOCAL: it holds free-text
 *    feedback, and the cloud copy is the opt-in upload) and records finished ones on the scoreboard;
 *  - hands finished rounds to the pockets upload ([uploadWires], [onRoundsChanged]).
 */
class InThePocketStore(
    private val history: PlayHistoryStore,
    private val scoreboard: GameScoreboardStore,
    private val player: GameRunPlayer,
    private val file: File,
    private val bridge: PocketsBridge = NoPocketsBridge,
    private val scope: CoroutineScope,
    private val buildDispatcher: CoroutineDispatcher = Dispatchers.Default,
    /** false = persist inline (tests); true = coalesced off-thread writes. */
    private val asyncPersist: Boolean = true,
) {
    sealed class BuildState {
        data object Idle : BuildState()
        data object Building : BuildState()
        data class Failed(val message: String) : BuildState()
    }

    data class State(
        /** Oldest -> newest. */
        val rounds: List<InThePocketRound> = emptyList(),
        /** The round the game screen shows (built, playing, or just finished). */
        val currentRoundId: UUID? = null,
        val buildState: BuildState = BuildState.Idle,
        /** Index of the song playing now in the active round. */
        val currentSongIndex: Int? = null,
    ) {
        val current: InThePocketRound? get() = currentRoundId?.let { id -> rounds.lastOrNull { it.id == id } }
        val activeRound: InThePocketRound? get() = rounds.lastOrNull { it.isActive }
    }

    private val lock = Any()
    private val fileLock = Any()
    private val _state = MutableStateFlow(State())
    val state: StateFlow<State> = _state.asStateFlow()

    val rounds: List<InThePocketRound> get() = _state.value.rounds
    val current: InThePocketRound? get() = _state.value.current
    val activeRound: InThePocketRound? get() = _state.value.activeRound
    val currentRoundId: UUID? get() = _state.value.currentRoundId
    val buildState: BuildState get() = _state.value.buildState
    val currentSongIndex: Int? get() = _state.value.currentSongIndex

    // MARK: - Dependencies (closures, so tests need no app graph)

    var now: () -> Double = { System.currentTimeMillis().toDouble() }

    /** The catalog (songs + albums for genre categories). Empty by default. */
    var catalogSnapshot: () -> Pair<Map<String, IndexSong>, Map<String, IndexAlbum>> =
        { emptyMap<String, IndexSong>() to emptyMap() }

    /** What can make sound right now. */
    var audioAvailability: () -> InThePocketAudio = { InThePocketAudio() }

    /** This device's collections (pockets x collections). Empty => the scorer ignores them. */
    var collectionsInput: () -> List<InThePocketScorer.CollectionInfo> = { emptyList() }

    /** Current place / trip GUESS + its display label (null when location is off / unavailable). */
    var contextGuess: () -> Pair<ListeningContextTag?, String?> = { null to null }

    /** A round finished, or a finished round's feedback/rating changed: upload soon. */
    var onRoundsChanged: () -> Unit = { bridge.flushSoon() }
    var appVersion: String? = null

    /** Test seam: unit tests drive [evaluate] themselves instead of the 1 Hz ticker. */
    var tickerEnabled = true
    private var tickerJob: Job? = null
    private var ownershipLostAtMs: Double? = null
    private val chipsById = HashMap<UUID, List<String>>()

    init {
        loadFromDisk()
        bridge.roundsProvider = { installId -> uploadWires(installId) }
    }

    // MARK: - Build

    /** Build a new round for NOW (replaces an unstarted one; refused while building or playing). */
    suspend fun buildRound(seed: ULong? = null) {
        val nowMs: Double
        synchronized(lock) {
            if (buildState == BuildState.Building || activeRound != null) return
            publish { it.copy(buildState = BuildState.Building) }
            nowMs = now()
        }
        try {
            val tz = TimeZone.getDefault().getOffset(nowMs.toLong()) / 60_000
            val guess = contextGuess()
            val context = InThePocketContext.make(nowMs, tz, guess.first)
            val label = if (context.ctx == null) null else guess.second
            val (songs, albums) = catalogSnapshot()
            val audio = audioAvailability()
            val events = history.events
            // Privacy gate: cloud results only exist for the build while pockets are enabled.
            val results = if (bridge.isEnabled.value) bridge.results.value else null
            val past = rounds.filter { it.isFinished }
            val collections = collectionsInput()
            val theSeed = seed ?: randomSeed()

            val outcome = withContext(buildDispatcher) {
                InThePocketScorer.build(
                    InThePocketInputs.makeInput(
                        context, label, results, songs, albums, audio, events, past, nowMs, theSeed, collections,
                    ),
                )
            }
            when (outcome) {
                is InThePocketScorer.BuildResult.Failed -> publishBuild(
                    BuildState.Failed(
                        when (outcome.failure) {
                            InThePocketScorer.Failure.NOTHING_PLAYABLE ->
                                "Nothing can play right now. Connect Apple Music, or download some songs, then try again."
                            InThePocketScorer.Failure.NOT_ENOUGH_CANDIDATES ->
                                "Not enough fresh, playable songs fit this moment yet. Play some music and try again."
                        },
                    ),
                )
                is InThePocketScorer.BuildResult.Success -> {
                    val out = outcome.output
                    val bpmTarget = out.bpmBand?.let {
                        listOf(
                            InThePocketTarget(
                                "bpm", "${it.start.toInt()}-${it.endInclusive.toInt()}",
                                "${it.start.toInt()}–${it.endInclusive.toInt()} BPM", InThePocketScorer.BPM_WEIGHT,
                            ),
                        )
                    } ?: emptyList()
                    val round = InThePocketRound(
                        id = UUID.randomUUID(), createdAtMs = nowMs, startedAtMs = null, endedAtMs = null,
                        updatedAtMs = nowMs, tzOffsetMin = tz, context = context, contextLabel = label,
                        mode = out.mode, seed = theSeed.toString(), algoVersion = InThePocketScorer.ALGO_VERSION,
                        targets = out.targets + bpmTarget,
                        songs = out.picks.map {
                            InThePocketSong(
                                id = it.song.id, title = it.song.title, artist = it.song.artist,
                                lengthMs = it.song.lengthMs, score = it.score, why = it.why,
                            )
                        },
                        appVersion = appVersion,
                    )
                    synchronized(lock) {
                        chipsById[round.id] = out.chips
                        var list = _state.value.rounds
                        // An unstarted round is simply replaced (it predicted nothing yet).
                        val cur = _state.value.current
                        if (cur != null && cur.startedAtMs == null) list = list.filter { it.id != cur.id }
                        list = trimmed(list + round, round.id)
                        _state.value = _state.value.copy(
                            rounds = list, currentRoundId = round.id, buildState = BuildState.Idle,
                        )
                    }
                    persist()
                }
            }
        } catch (e: CancellationException) {
            // Never wedge on "building" when the caller goes away mid-build.
            publishBuild(BuildState.Idle)
            throw e
        }
    }

    /** The round's "why" chips. Kept for the session; rebuilt from the round otherwise. */
    fun chips(round: InThePocketRound): List<String> {
        synchronized(lock) { chipsById[round.id] }?.let { return it }
        val out = mutableListOf(round.context.timePhrase)
        round.contextLabel?.let { out.add(it) }
        round.targets.firstOrNull { it.dim == "bpm" }?.let { out.add(it.label) }
        val genres = round.targets.filter { it.dim == "genre" }.take(2).map { it.label }
        if (genres.isNotEmpty()) out.add(genres.joinToString("/"))
        return out
    }

    // MARK: - Play + track

    /** Play the current (unstarted) round. */
    fun start() {
        val round: InThePocketRound
        synchronized(lock) {
            val cur = _state.value.current ?: return
            if (cur.startedAtMs != null || activeRound != null) return
            val t = now()
            round = cur.copy(startedAtMs = t, updatedAtMs = t)
            ownershipLostAtMs = null
            replace(round)
        }
        persist()
        player.playRun(
            round.songs.map { RunItem(it.id, it.title, it.artist, it.lengthMs?.toLong()) },
            runTag(round.id), GameKind.InThePocket.label,
        )
        startTicker()
    }

    /** App launch / foreground: keep tracking a round that was playing when the process went away. */
    fun resumeTrackingIfNeeded() {
        if (activeRound != null) startTicker()
    }

    private fun startTicker() {
        if (!tickerEnabled) return
        synchronized(lock) {
            if (tickerJob?.isActive == true) return
            tickerJob = scope.launch {
                while (isActive && activeRound != null) {
                    evaluate()
                    delay(1000)
                }
            }
        }
    }

    /** One evaluation of the active round: the ticker's body, and the test seam. */
    fun evaluate(forceEnd: Boolean = false) {
        var finished: InThePocketRound? = null
        var changed = false
        synchronized(lock) {
            val st = _state.value
            val i = st.rounds.indexOfLast { it.isActive }
            val started = if (i >= 0) st.rounds[i].startedAtMs else null
            if (i < 0 || started == null) {
                if (st.currentSongIndex != null) _state.value = st.copy(currentSongIndex = null)
                return
            }
            val t = now()
            val old = st.rounds[i]
            val tag = runTag(old.id)
            if (player.ownsRun(tag)) ownershipLostAtMs = null
            else if (ownershipLostAtMs == null) ownershipLostAtMs = t
            val lost = if (forceEnd) t - InThePocketRoundEvaluator.SETTLE_MS else ownershipLostAtMs
            val mine = history.installId
            val obs = ArrayList<InThePocketRoundEvaluator.Observation>()
            val events = history.events
            for (k in events.indices.reversed()) {
                val e = events[k]
                if (e.playedAt < started - InThePocketRoundEvaluator.START_TOLERANCE_MS) break
                if (e.originInstallId != null && e.originInstallId != mine) continue
                obs.add(
                    InThePocketRoundEvaluator.Observation(
                        eventUuid(e.id), e.songId, e.playedAt, e.wasSkipped == true, e.listenedFraction,
                    ),
                )
            }
            val v = InThePocketRoundEvaluator.evaluate(old.songs.map { it.id }, started, obs, lost, t)
            var r = old.copy(
                songs = old.songs.mapIndexed { k, s ->
                    s.copy(state = v.states[k], eventId = v.eventIds[k], fraction = v.fractions[k])
                },
            )
            var songIndex = v.currentIndex
            val outcome = v.outcome
            if (outcome != null) {
                r = r.copy(outcome = outcome, endedAtMs = t, updatedAtMs = t)
                finished = r
                songIndex = null
                changed = true
            } else if (r != old) {
                changed = true
            }
            val rounds = st.rounds.toMutableList().also { it[i] = r }
            _state.value = st.copy(rounds = rounds, currentSongIndex = songIndex)
        }
        if (changed) persist()
        finished?.let { r ->
            val completed = r.songs.count { it.state == InThePocketSongState.COMPLETED }
            scoreboard.record(
                game = GameKind.InThePocket, score = completed,
                settingsSummary = chips(r).joinToString(" · "),
                detail = mapOf(
                    "outcome" to (r.outcome?.token ?: ""), "roundId" to r.id.toString().uppercase(),
                    "songs" to r.songs.size.toString(),
                ),
                atMs = r.endedAtMs ?: now(),
            )
            onRoundsChanged()
        }
    }

    /** "End round": stop tracking now; the verdict is whatever the log already says. */
    fun endActiveRound() = evaluate(forceEnd = true)

    /** Clear the screen for a fresh round (the finished one stays in the log). */
    fun dismissCurrent() {
        synchronized(lock) {
            val st = _state.value
            val cur = st.current
            if (cur?.isActive == true) return
            val list = if (cur != null && cur.startedAtMs == null) st.rounds.filter { it.id != cur.id } else st.rounds
            _state.value = st.copy(rounds = list, currentRoundId = null, buildState = BuildState.Idle)
        }
        persist()
    }

    // MARK: - Feedback

    /**
     * Save the round's free-text feedback (capped) and optional 1..5 rating. Allowed during and after
     * the round; a FINISHED round's change re-uploads (its `updatedAtMs` moves).
     */
    fun saveFeedback(roundId: UUID, text: String?, rating: Int?) {
        var finished = false
        synchronized(lock) {
            val st = _state.value
            val i = st.rounds.indexOfLast { it.id == roundId }
            if (i < 0) return
            val capped = InThePocketRound.capFeedback(text)
            val r = rating?.takeIf { it in 1..5 }
            val old = st.rounds[i]
            if (capped == old.feedback && r == old.rating) return
            val updated = old.copy(
                feedback = capped, rating = r, updatedAtMs = maxOf(now(), old.updatedAtMs + 1),
            )
            _state.value = st.copy(rounds = st.rounds.toMutableList().also { it[i] = updated })
            finished = updated.isFinished
        }
        persist()
        if (finished) onRoundsChanged()
    }

    // MARK: - Upload + stats

    /** Every FINISHED round as an upload row (the client filters by its own ack fingerprints). */
    fun uploadWires(installId: String): List<InThePocketRoundWire> = rounds.mapNotNull { it.wire(installId) }

    /** Account deletion: drop every round and the file. */
    fun clearLocal() {
        synchronized(lock) {
            tickerJob?.cancel(); tickerJob = null
            chipsById.clear()
            _state.value = State()
        }
        synchronized(fileLock) { file.delete(); File(file.parentFile, file.name + ".tmp").delete() }
    }

    // MARK: - Persistence

    private fun publish(f: (State) -> State) { _state.value = f(_state.value) }
    private fun publishBuild(b: BuildState) = synchronized(lock) { publish { it.copy(buildState = b) } }

    private fun replace(round: InThePocketRound) {
        publish { st -> st.copy(rounds = st.rounds.map { if (it.id == round.id) round else it }) }
    }

    /** Keep <= [MAX_ROUNDS], dropping the OLDEST that are neither active nor the current round. */
    private fun trimmed(list: List<InThePocketRound>, currentId: UUID?): List<InThePocketRound> {
        if (list.size <= MAX_ROUNDS) return list
        var overflow = list.size - MAX_ROUNDS
        return list.filter { r ->
            if (overflow > 0 && !r.isActive && r.id != currentId) { overflow--; false } else true
        }
    }

    private val writePending = AtomicBoolean(false)

    private fun persist() {
        if (!asyncPersist) { write(); return }
        if (writePending.compareAndSet(false, true)) {
            scope.launch(Dispatchers.IO) { writePending.set(false); write() }
        }
    }

    /** Test/lifecycle seam: write the latest state now. */
    fun flush() = write()

    private fun write() = synchronized(fileLock) {
        val st = _state.value
        if (st.rounds.isEmpty() && st.currentRoundId == null) {
            file.delete()
            return@synchronized
        }
        runCatching {
            val bytes = codec.encodeToString(Document.serializer(), Document(rounds = st.rounds, currentRoundId = st.currentRoundId))
            val tmp = File(file.parentFile, file.name + ".tmp")
            tmp.writeText(bytes)
            if (!tmp.renameTo(file)) { file.writeText(bytes); tmp.delete() }
        }
    }

    private fun loadFromDisk() {
        val text = runCatching { file.readText() }.getOrNull() ?: return
        val doc = decodeDocument(text) ?: return
        _state.value = State(rounds = doc.rounds, currentRoundId = doc.currentRoundId)
    }

    /** Persisted shape (iOS `Document`): schemaVersion, rounds, currentRoundId. */
    @kotlinx.serialization.Serializable
    data class Document(
        val schemaVersion: Int = 1,
        val rounds: List<InThePocketRound> = emptyList(),
        @kotlinx.serialization.Serializable(with = UuidStringSerializer::class) val currentRoundId: UUID? = null,
    )

    companion object {
        const val RUN_TAG_PREFIX = "itp_"
        const val MAX_ROUNDS = 300
        const val FILE_NAME = "pocketdj-in-the-pocket.json"

        fun runTag(id: UUID): String = RUN_TAG_PREFIX + id.toString().uppercase()

        private val codec = Json { ignoreUnknownKeys = true; encodeDefaults = true; explicitNulls = false }

        /**
         * Per-element lenient (the PlayHistoryStore doctrine): one unreadable round written by a newer
         * build must not take the rest with it.
         */
        fun decodeDocument(text: String): Document? {
            val obj = runCatching { codec.parseToJsonElement(text) as? JsonObject }.getOrNull() ?: return null
            val rounds = (obj["rounds"] as? JsonArray).orEmpty().mapNotNull { el ->
                runCatching { codec.decodeFromJsonElement(InThePocketRound.serializer(), el) }.getOrNull()
            }
            val cur = (obj["currentRoundId"] as? JsonPrimitive)?.takeIf { it.isString }?.contentOrNull
                ?.let { runCatching { UUID.fromString(it) }.getOrNull() }
            val v = (obj["schemaVersion"] as? JsonPrimitive)?.contentOrNull?.toIntOrNull() ?: 1
            return Document(v, rounds, cur)
        }

        private fun JsonArray?.orEmpty(): List<kotlinx.serialization.json.JsonElement> = this ?: emptyList()

        /** History event ids are UUID strings; anything else gets a stable name-based UUID. */
        internal fun eventUuid(id: String): UUID =
            runCatching { UUID.fromString(id) }.getOrElse { UUID.nameUUIDFromBytes(id.toByteArray()) }

        private fun randomSeed(): ULong {
            val r = java.util.concurrent.ThreadLocalRandom.current().nextLong()
            return (if (r == 0L) 1L else r).toULong()
        }
    }
}

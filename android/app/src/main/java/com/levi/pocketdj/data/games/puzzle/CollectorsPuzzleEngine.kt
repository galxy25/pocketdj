package com.levi.pocketdj.data.games.puzzle

import com.levi.pocketdj.data.catalog.IndexAlbum
import com.levi.pocketdj.data.catalog.IndexSong
import com.levi.pocketdj.data.collections.AddTarget
import com.levi.pocketdj.data.games.GameKind
import com.levi.pocketdj.data.games.GameScoreboardStore
import com.levi.pocketdj.data.history.PlayEvent
import com.levi.pocketdj.data.rips.RipManifestEntry
import com.levi.pocketdj.playback.GameRunPlayer
import com.levi.pocketdj.playback.RunItem
import java.util.UUID
import kotlin.coroutines.CoroutineContext
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
import kotlinx.coroutines.withTimeoutOrNull

/** What the engine reads from the rest of the app (narrow on purpose; GamesGraph wires the real stores). */
interface CollectorsPuzzleEnv {
    fun songs(): List<IndexSong>
    fun albumsById(): Map<String, IndexAlbum>
    fun favoriteIds(): Set<String>

    /** LIFETIME play counts for the play-count bias. */
    fun playCounts(): Map<String, Int> = emptyMap()
    fun memberIds(collectionId: String): List<String>
    fun collectionExists(collectionId: String): Boolean
    fun collectionName(collectionId: String): String?
    fun addSong(songId: String, target: AddTarget)

    /** Is the song STILL in this target right now (the picker's rows are toggles)? */
    fun stillContains(songId: String, target: AddTarget): Boolean
    fun ripManifest(): Map<String, RipManifestEntry> = emptyMap()
    fun burnedIds(): Set<String> = emptySet()
    fun lastPlayedMs(): Map<String, Double> = emptyMap()
    fun playHistory(): List<PlayEvent> = emptyList()
    fun allCollectionMemberships(): List<List<String>> = emptyList()

    /** Songs thumbed down for [collectionId] and still inside their tombstone. */
    fun recSuppressed(collectionId: String): Set<String> = emptySet()
}

/** Where the last-used round settings persist (iOS `pdj.puzzle.settings.v1`). */
interface PuzzleSettingsPersistence {
    fun load(): String?
    fun save(json: String)
}

/** A filed card on the round summary. */
data class AssignedRow(
    val songId: String,
    val title: String,
    val artist: String,
    val collectionId: String,
    val collectionName: String,
)

/** Immutable snapshot published after every mutation (for Compose). */
data class PuzzleRoundState(
    val phase: Phase = Phase.IDLE,
    /** 3..1 while [phase] is COUNTDOWN. */
    val countdown: Int = 0,
    val settings: PuzzleSettings = PuzzleSettings(),
    val roundId: String = "",
    val queue: List<IndexSong> = emptyList(),
    val queueIndex: Int = 0,
    val score: Int = 0,
    val assigned: List<AssignedRow> = emptyList(),
    val deadlineMs: Long = 0,
    val filingSongId: String? = null,
    val filedTargets: List<AddTarget> = emptyList(),
    val lastRunRecord: com.levi.pocketdj.data.games.RunRecord? = null,
    val isNewHighScore: Boolean = false,
    val lastError: String? = null,
    val poolExhausted: Boolean = false,
) {
    enum class Phase { IDLE, SAMPLING, COUNTDOWN, RUNNING, FINISHED }

    val current: IndexSong? get() = if (phase == Phase.RUNNING) queue.getOrNull(queueIndex) else null
}

/**
 * The Gem Collector round engine (port of iOS `CollectorsPuzzleEngine`) - APP-SCOPED so a running
 * round survives tab switches. Audio flows ONLY through [GameRunPlayer] (the one audio owner);
 * the engine is authoritative for SCORING, the player for audio POSITION - the ticker's drift
 * re-sync records "expired" for every card the audio advanced past without a player action.
 *
 * Threading: every mutator runs on [scope]'s dispatcher (Main in production); only the heavy
 * sampling hops to [computeContext].
 */
class CollectorsPuzzleEngine(
    private val env: CollectorsPuzzleEnv,
    private val player: GameRunPlayer,
    private val scoreboard: GameScoreboardStore,
    private val decisions: PuzzleDecisionStore,
    private val persistence: PuzzleSettingsPersistence,
    private val scope: CoroutineScope,
    private val computeContext: CoroutineContext = Dispatchers.Default,
    /** Wall clock (epoch ms); tests inject virtual time. */
    private val clockMs: () -> Long = System::currentTimeMillis,
    private val newRoundId: () -> String = { UUID.randomUUID().toString().uppercase() },
) {
    // ---- test seams -----------------------------------------------------------------------
    @Volatile var rng: () -> Double = { kotlin.random.Random.nextDouble() }

    /** Tests skip the 3-2-1. */
    @Volatile var countdownEnabled = true

    /** The CLOUD similarity booster: collection ids -> similar song ids, best first. */
    @Volatile var cloudSimilarProvider: suspend (List<String>) -> List<String> = { emptyList() }

    /** Heavy sampler (swappable so a test can gate a top-up). */
    @Volatile var sampler: suspend (n: Int, settings: PuzzleSettings, inputs: PuzzleSampler.Inputs, excluding: Set<String>) -> List<IndexSong> =
        { n, s, i, ex -> withContext(computeContext) { PuzzleSampler.sample(n, s, i, rng, ex) } }

    /** Builds [PuzzleSampler.Inputs] off the main thread. */
    @Volatile var inputsBuilder: suspend (PuzzleSampler.RawInputs) -> PuzzleSampler.Inputs =
        { raw -> withContext(computeContext) { PuzzleSampler.Inputs.fromRaw(raw) } }

    @Volatile var cloudBudgetMs: Long = CLOUD_BUDGET_MS

    // ---- state ----------------------------------------------------------------------------
    private var settings: PuzzleSettings
    private var phase = PuzzleRoundState.Phase.IDLE
    private var countdown = 0
    private var roundId = newRoundId()
    private var queue: List<IndexSong> = emptyList()
    private var queueIndex = 0
    private var score = 0
    private var assigned: List<AssignedRow> = emptyList()
    private var deadlineMs = 0L
    private var lastRunRecord: com.levi.pocketdj.data.games.RunRecord? = null
    private var isNewHighScore = false
    private var lastError: String? = null
    private var poolExhausted = false

    private var filingSongId: String? = null
    private var filingStartedAt = 0L
    private var filedTargets: List<AddTarget> = emptyList()

    private var tickerJob: Job? = null
    private var toppingUp = false

    /** Which round-queue position the player's own index 0 maps to (the watchdog re-hands a tail). */
    private var audioBaseIndex = 0

    /** The last queue position audio was armed for: the watchdog re-arms AT MOST ONCE per card. */
    private var lastAudioArmIndex: Int? = null

    /** Songs the player could not resolve this round; never sampled again (no retry loop on top-up). */
    private val droppedIds = HashSet<String>()

    /** THIS round's cloud rank map, frozen at [startRound]. */
    private var cloudRanks: Map<String, Double> = emptyMap()

    private val _state = MutableStateFlow(PuzzleRoundState())
    val state: StateFlow<PuzzleRoundState> = _state.asStateFlow()

    // Read-through accessors (tests and the view).
    val currentSettings: PuzzleSettings get() = settings
    val currentPhase: PuzzleRoundState.Phase get() = phase
    val currentRoundId: String get() = roundId
    val currentQueue: List<IndexSong> get() = queue
    val currentQueueIndex: Int get() = queueIndex
    val currentScore: Int get() = score
    val current: IndexSong? get() = _state.value.current
    val runTag: String get() = "$RUN_TAG_PREFIX$roundId"
    val isPoolExhausted: Boolean get() = poolExhausted
    val currentError: String? get() = lastError
    val currentFilingSongId: String? get() = filingSongId

    /**
     * Whole seconds left. While the Add-to sheet is open the clock is HELD: read against the
     * moment the sheet opened so the digits FREEZE behind the modal.
     */
    fun remainingSeconds(): Int {
        val ref = if (filingSongId != null) filingStartedAt else clockMs()
        val ms = (deadlineMs - ref).coerceAtLeast(0)
        return ((ms + 999) / 1000).toInt()
    }

    init {
        settings = PuzzleSettings.fromJson(persistence.load())
        // A target/filter collection the user has since DELETED must not survive the reload: the
        // setup screen would have no checked row yet a live Start button.
        settings = settings.copy(
            targetCollectionIds = settings.targetCollectionIds.filter(env::collectionExists),
            membershipCollectionIds = settings.membershipCollectionIds.filter(env::collectionExists).toSet(),
        )
        publish()
    }

    /** Update + persist the round settings (last-used settings survive relaunch). */
    fun updateSettings(s: PuzzleSettings) {
        settings = s
        runCatching { persistence.save(s.toJson()) }
        publish()
    }

    private fun publish() {
        _state.value = PuzzleRoundState(
            phase = phase, countdown = countdown, settings = settings, roundId = roundId,
            queue = queue, queueIndex = queueIndex, score = score, assigned = assigned,
            deadlineMs = deadlineMs, filingSongId = filingSongId, filedTargets = filedTargets,
            lastRunRecord = lastRunRecord, isNewHighScore = isNewHighScore, lastError = lastError,
            poolExhausted = poolExhausted,
        )
    }

    // ---- ownership -------------------------------------------------------------------------

    /** True while the shared player is still running the queue THIS round handed it. */
    private val ownsAudio: Boolean get() = player.ownsRun(runTag)

    /** Someone ELSE is playing: never skip, stop or extend that run. (Distinct from "nothing plays".) */
    private val takenOver: Boolean get() = player.isRunning && !player.ownsRun(runTag)

    // ---- sampler inputs --------------------------------------------------------------------

    private fun snapshotRawInputs(): PuzzleSampler.RawInputs {
        val wantsSimilarity = settings.similarity != PuzzleSettings.Similarity.OFF &&
            settings.targetCollectionIds.isNotEmpty()
        val wantsRecency = settings.recencyBias != PuzzleSettings.Bias.OFF || wantsSimilarity
        val lastPlayed = if (wantsRecency) env.lastPlayedMs() else emptyMap()
        return PuzzleSampler.RawInputs(
            songs = env.songs(),
            albumsById = env.albumsById(),
            favoriteIds = env.favoriteIds(),
            playCounts = env.playCounts(),
            membershipCollections = settings.membershipCollectionIds.map(env::memberIds),
            targetCollections = settings.targetCollectionIds.map(env::memberIds),
            ripManifest = env.ripManifest(),
            burnedIds = env.burnedIds(),
            allCollections = if (wantsSimilarity) env.allCollectionMemberships() else emptyList(),
            plays = if (wantsSimilarity) env.playHistory() else emptyList(),
            cloudRanks = cloudRanks,
            buildSimilarityProfile = wantsSimilarity,
            lastPlayedMs = lastPlayed,
            hasRecency = lastPlayed.isNotEmpty(),
            nowMs = clockMs().toDouble(),
            suppressedForTargets = settings.targetCollectionIds.fold(emptySet()) { acc, id -> acc + env.recSuppressed(id) },
        )
    }

    /** How many songs match the settings (+ the similar shortlist) for the setup readout. */
    suspend fun poolStats(): PuzzleSampler.PoolStats {
        val raw = snapshotRawInputs()
        val s = settings
        return withContext(computeContext) { PuzzleSampler.poolStats(s, PuzzleSampler.Inputs.fromRaw(raw)) }
    }

    // ---- round lifecycle ---------------------------------------------------------------------

    /**
     * Sample -> countdown -> hand the queue to the player -> run. TARGETS ARE OPTIONAL: a round
     * needs exactly one thing to start, a non-empty sample; with no targets every card is filed
     * through the Add-to picker.
     */
    suspend fun startRound() {
        if (phase != PuzzleRoundState.Phase.IDLE && phase != PuzzleRoundState.Phase.FINISHED) return
        lastError = null
        poolExhausted = false
        // A sheet the PREVIOUS round left open must never hold the new round's ticker hostage.
        filingSongId = null
        filedTargets = emptyList()
        // A stale top-up from the previous round is round-guarded and can never clear this flag.
        toppingUp = false
        droppedIds.clear()
        phase = PuzzleRoundState.Phase.SAMPLING
        publish()
        // THE ONE CLOUD CALL: before the sample, hidden behind the sampling spinner, budgeted,
        // and never from tickOnce.
        refreshCloudRanks()
        val raw = snapshotRawInputs()
        val s = settings
        val inputs = inputsBuilder(raw)
        // Nobody can clear more than ~1 song/sec: sample enough to never starve.
        val n = maxOf(60, s.roundSeconds)
        val sampled = sampler(n, s, inputs, emptySet())
        val playable = if (sampled.isEmpty()) sampled else resolvable(sampled)
        if (playable.isEmpty()) {
            lastError = "No songs match these settings."
            phase = PuzzleRoundState.Phase.IDLE
            publish()
            return
        }
        queue = playable
        queueIndex = 0
        score = 0
        assigned = emptyList()
        isNewHighScore = false
        lastRunRecord = null
        roundId = newRoundId()
        if (countdownEnabled) {
            for (c in 3 downTo 1) {
                phase = PuzzleRoundState.Phase.COUNTDOWN
                countdown = c
                publish()
                delay(1000)
            }
            countdown = 0
        }
        armAudio(0)
        deadlineMs = clockMs() + s.roundSeconds * 1000L
        phase = PuzzleRoundState.Phase.RUNNING
        publish()
        startTicker()
    }

    /** Drop songs the player cannot make sound for, remembering them so top-ups never re-sample them. */
    private suspend fun resolvable(songs: List<IndexSong>): List<IndexSong> {
        val (kept, dropped) = partitionResolvable(songs)
        droppedIds += dropped
        return kept
    }

    /** (playable, dropped ids) without touching engine state - safe to call from a stale continuation. */
    private suspend fun partitionResolvable(songs: List<IndexSong>): Pair<List<IndexSong>, Set<String>> {
        val keep = player.filterResolvable(songs.map(::runItem)).map { it.songId }.toSet()
        return songs.filter { it.id in keep } to songs.filter { it.id !in keep }.mapTo(HashSet()) { it.id }
    }

    private suspend fun refreshCloudRanks() {
        cloudRanks = emptyMap()
        val ids = settings.targetCollectionIds
        if (settings.similarity == PuzzleSettings.Similarity.OFF || ids.isEmpty()) return
        val provider = cloudSimilarProvider
        // A slow server must LOSE, not stall the countdown; a throwing one is the same as absent.
        val ranked = withTimeoutOrNull(cloudBudgetMs) { runCatching { provider(ids) }.getOrNull() } ?: emptyList()
        if (ranked.isEmpty()) return
        val n = ranked.size.toDouble()
        val out = HashMap<String, Double>()
        // A duplicate id in a server response keeps the better (earlier) rank.
        ranked.forEachIndexed { i, id -> out[id] = maxOf(out[id] ?: 0.0, maxOf(0.0, 1.0 - i / n)) }
        cloudRanks = out
    }

    private fun runItem(s: IndexSong) = RunItem(songId = s.id, title = s.name, artist = s.artist, lengthMs = s.length)

    /** The single place audio is ever armed, so [audioBaseIndex] and the once-per-card guard can't drift apart. */
    private fun armAudio(fromQueueIndex: Int) {
        if (fromQueueIndex >= queue.size) return
        audioBaseIndex = fromQueueIndex
        lastAudioArmIndex = fromQueueIndex
        player.playRun(queue.drop(fromQueueIndex).map(::runItem), runTag, GameKind.CollectorsPuzzle.label)
    }

    private fun startTicker() {
        tickerJob?.cancel()
        tickerJob = scope.launch {
            while (isActive) {
                tickOnce()
                delay(TICK_MS)
            }
        }
    }

    /** One ticker turn - also the test seam (tests drive ticks directly, no timers). */
    fun tickOnce() {
        if (phase != PuzzleRoundState.Phase.RUNNING) return
        // Ownership first: another surface replaced the shared queue. Its index says NOTHING about
        // this round - end cleanly and leave THEIR audio alone.
        if (takenOver) {
            endRound(stopAudio = false)
            return
        }
        // FILING HOLD - the Add-to sheet owns the round. This return sits BEFORE the deadline,
        // watchdog, drift and top-up on purpose: audio keeps running behind the sheet and a drift
        // re-sync here would advance queueIndex PAST the card the sheet is filing.
        if (filingSongId != null) return
        if (clockMs() >= deadlineMs) {
            endRound()
            return
        }
        // AUDIO WATCHDOG: the player stops itself when a run runs out or every source failed, which
        // from here is silence with nobody owning it. Re-hand the queue from the CURRENT card, at
        // most once per card.
        if (!player.isRunning && current != null && lastAudioArmIndex != queueIndex) {
            armAudio(queueIndex)
            return
        }
        // Drift re-sync: audio advanced past the engine (natural end / lock-screen skip) - each
        // passed card EXPIRED without a player action; audio stays authoritative for position.
        val audioPosition = audioBaseIndex + player.position
        if (ownsAudio && audioPosition > queueIndex) {
            val target = minOf(audioPosition, queue.size)
            // ONE persist for the whole burst.
            decisions.recordBatch(
                (queueIndex until target).map {
                    PuzzleDecisionStore.BatchRow(queue[it].id, "expired", it)
                },
                roundId = roundId,
                settings = settings,
                nowMs = clockMs().toDouble(),
            )
            queueIndex = target
            publish()
        }
        // Top-up: never let the visible queue starve mid-round (single-flight).
        if (queue.size - queueIndex < TOP_UP_BELOW && !toppingUp && !poolExhausted) topUp()
    }

    private fun topUp() {
        toppingUp = true
        val shown = queue.mapTo(HashSet()) { it.id } + droppedIds
        val raw = snapshotRawInputs()
        val s = settings
        // The round this top-up was armed FOR: `phase == RUNNING` alone cannot tell "this round
        // still runs" from "a DIFFERENT round now runs".
        val armedRoundId = roundId
        scope.launch {
            val inputs = inputsBuilder(raw)
            val extra = sampler(TOP_UP_COUNT, s, inputs, shown)
            // A stale round's continuation mutates NOTHING - not even toppingUp, which belongs to
            // the new round now (startRound reset it).
            if (roundId != armedRoundId) return@launch
            if (phase != PuzzleRoundState.Phase.RUNNING) {
                toppingUp = false
                return@launch
            }
            val (playable, dropped) = if (extra.isEmpty()) extra to emptySet() else partitionResolvable(extra)
            if (roundId != armedRoundId) return@launch
            droppedIds += dropped
            toppingUp = false
            if (phase != PuzzleRoundState.Phase.RUNNING) return@launch
            if (extra.isEmpty()) {
                poolExhausted = true
                publish()
                return@launch
            }
            // The ROUND's queue always grows (it is this engine's own data; the round stays fully
            // playable with no audio). The AUDIO queue grows only while we still own the player:
            // appending into THEIR queue would hijack that playback.
            if (playable.isNotEmpty()) {
                queue = queue + playable
                publish()
                player.appendRun(playable.map(::runItem), runTag)
            }
        }
    }

    // ---- player actions ------------------------------------------------------------------------

    /** File the current song into target [i] - one point. */
    fun assign(toTargetIndex: Int) {
        if (phase != PuzzleRoundState.Phase.RUNNING) return
        if (takenOver) {
            endRound(stopAudio = false)
            return
        }
        val song = current ?: return
        val cid = settings.targetCollectionIds.getOrNull(toTargetIndex) ?: return
        val target = targetFor(cid)
        env.addSong(song.id, target)
        creditFiling(song, listOf(target))
    }

    private fun targetFor(cid: String) =
        AddTarget(if (cid.startsWith("pkt_")) AddTarget.Kind.POCKET else AddTarget.Kind.PLAYLIST, cid)

    /**
     * THE ONE PLACE A FILING SCORES: the point, the summary row, the decision row(s) and the
     * advance can never drift apart between the one-tap and Add-to-sheet paths. ONE POINT PER
     * CARD even when [targets] holds five collections.
     */
    private fun creditFiling(song: IndexSong, targets: List<AddTarget>) {
        val primary = targets.firstOrNull() ?: return
        score += POINTS_PER_FILED_CARD
        assigned = assigned + AssignedRow(
            song.id, song.name, song.artist, primary.id,
            filedLabel(targets.map { collectionName(it.id) }),
        )
        // The POINT is capped at one; the TRAINING SIGNAL is not.
        for (t in targets) {
            decisions.record(
                roundId = roundId, songId = song.id, action = "assigned",
                collectionId = t.id, collectionName = collectionName(t.id),
                positionInRound = queueIndex, settings = settings, nowMs = clockMs().toDouble(),
            )
        }
        advance()
    }

    /**
     * The view calls this BEFORE presenting the Add-to sheet. False when there is nothing to file
     * (not running, no card, a sheet already up, or the player was taken over - which ends the
     * round exactly as assign/skip do).
     */
    fun beginFiling(): Boolean {
        if (phase != PuzzleRoundState.Phase.RUNNING || filingSongId != null) return false
        val song = current ?: return false
        if (takenOver) {
            endRound(stopAudio = false)
            return false
        }
        filingSongId = song.id
        filedTargets = emptyList()
        filingStartedAt = clockMs()
        publish()
        return true
    }

    /**
     * The picker added the card to [target] while the sheet is STILL OPEN. RECORDS ONLY: no point,
     * no advance, no clock release. Ignored when no sheet is open; deduped by (kind,id).
     */
    fun noteFiled(target: AddTarget) {
        if (filingSongId == null) return
        if (filedTargets.any { it.kind == target.kind && it.id == target.id }) return
        filedTargets = filedTargets + target
        publish()
    }

    /**
     * The ONE settle point of a filing: credits the held clock, scores the opening ONCE, advances.
     * A cancelled opening means no point and NO advance (cancel is not a skip). IDEMPOTENT.
     * [assignedTo] is the legacy single-shot path; the view passes null and lets the opening's own
     * noted targets decide.
     */
    fun endFiling(assignedTo: AddTarget? = null) {
        val songId = filingSongId ?: return
        filingSongId = null
        val noted = filedTargets
        filedTargets = emptyList()
        // The multi-select path re-checks LIVE membership: add-then-uncheck filed nothing there.
        val filed = if (assignedTo != null) listOf(assignedTo) else noted.filter { env.stillContains(songId, it) }
        // Credit the held time; scales with how many collections were filed, ceilinged.
        val allowance = minOf(
            MAX_FILING_CREDIT_SECONDS + FILING_CREDIT_PER_EXTRA_TARGET * maxOf(0, filed.size - 1),
            MAX_FILING_CREDIT_CEILING_SECONDS,
        )
        val heldSeconds = maxOf(0.0, (clockMs() - filingStartedAt) / 1000.0)
        deadlineMs += (minOf(heldSeconds, allowance) * 1000).toLong()
        // Verified BY ID: a stale sheet (round ended / queue moved) files nothing.
        val song = current
        if (filed.isNotEmpty() && phase == PuzzleRoundState.Phase.RUNNING && song != null && song.id == songId) {
            creditFiling(song, filed)
        }
        // Re-marry audio to the card the round is now showing (audio ran on behind the sheet).
        if (phase == PuzzleRoundState.Phase.RUNNING && current != null && !takenOver &&
            (!player.isRunning || audioBaseIndex + player.position != queueIndex)
        ) {
            armAudio(queueIndex)
        }
        publish()
    }

    /** Pass on the current song: no point, logged as a real signal. */
    fun skip() {
        if (phase != PuzzleRoundState.Phase.RUNNING) return
        if (takenOver) {
            endRound(stopAudio = false)
            return
        }
        val song = current ?: return
        decisions.record(
            roundId = roundId, songId = song.id, action = "skipped",
            positionInRound = queueIndex, settings = settings, nowMs = clockMs().toDouble(),
        )
        advance()
    }

    private fun advance() {
        queueIndex += 1
        // Only ever skip OUR run: a foreign queue's track is not ours to advance.
        if (ownsAudio) player.skipNext(runTag)
        publish()
    }

    /**
     * End the round (deadline or the End button): stop audio, record the run. `stopAudio = false`
     * is the ownership-lost path: whatever ELSE is playing keeps playing.
     */
    fun endRound(stopAudio: Boolean = true) {
        if (phase != PuzzleRoundState.Phase.RUNNING) return
        tickerJob?.cancel()
        tickerJob = null
        if (stopAudio && ownsAudio) player.stopRun(runTag)
        // Land the round's rows now without blocking on an MB-scale encode.
        decisions.flushAsync()
        phase = PuzzleRoundState.Phase.FINISHED
        val best = scoreboard.bestScore(GameKind.CollectorsPuzzle) ?: 0
        isNewHighScore = score > best
        lastRunRecord = scoreboard.record(
            game = GameKind.CollectorsPuzzle,
            score = score,
            settingsSummary = settings.summaryLine,
            detail = mapOf("assigned" to assigned.size.toString(), "roundSeconds" to settings.roundSeconds.toString()),
        )
        publish()
    }

    /** Dismiss the summary back to setup (settings kept). Only from FINISHED. */
    fun reset() {
        if (phase != PuzzleRoundState.Phase.FINISHED) return
        phase = PuzzleRoundState.Phase.IDLE
        poolExhausted = false
        publish()
    }

    fun collectionName(id: String): String = env.collectionName(id) ?: "Collection"

    companion object {
        const val RUN_TAG_PREFIX = "puzzle_"
        const val TICK_MS = 250L
        const val TOP_UP_BELOW = 10
        const val TOP_UP_COUNT = 40
        const val CLOUD_BUDGET_MS = 2_500L

        /** ONE POINT PER CARD, not per collection - the single place a filing scores. */
        const val POINTS_PER_FILED_CARD = 1

        /** Max seconds of round clock a SINGLE sheet opening can buy back. */
        const val MAX_FILING_CREDIT_SECONDS = 20.0

        /** Extra allowance per collection filed BEYOND the first. */
        const val FILING_CREDIT_PER_EXTRA_TARGET = 10.0

        /** Hard ceiling on a single opening's credit however many crates were filed. */
        const val MAX_FILING_CREDIT_CEILING_SECONDS = 60.0

        /** "Crate A" / "Crate A +2 more". */
        fun filedLabel(names: List<String>): String {
            val first = names.firstOrNull() ?: return "Collection"
            return if (names.size > 1) "$first +${names.size - 1} more" else first
        }
    }
}

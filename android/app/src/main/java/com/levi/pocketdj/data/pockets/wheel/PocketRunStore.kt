package com.levi.pocketdj.data.pockets.wheel

import com.levi.pocketdj.data.edition.SongVariant
import com.levi.pocketdj.data.games.inthepocket.InThePocketScorer
import com.levi.pocketdj.data.history.PlayEvent
import com.levi.pocketdj.data.history.PocketRunTag
import com.levi.pocketdj.diag.NPLog
import com.levi.pocketdj.playback.PlayContext
import com.levi.pocketdj.playback.sequencer.PlanTag
import com.levi.pocketdj.playback.sequencer.QueueItem
import com.levi.pocketdj.playback.sequencer.ReplaceableRow
import com.levi.pocketdj.playback.sequencer.SequencerState
import com.levi.pocketdj.playback.sequencer.SetlistSequencer
import kotlinx.coroutines.CoroutineDispatcher
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.CoroutineStart
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.Job
import kotlinx.coroutines.delay
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.asStateFlow
import kotlinx.coroutines.isActive
import kotlinx.coroutines.launch
import kotlinx.coroutines.withContext
import kotlinx.serialization.Serializable
import kotlinx.serialization.json.Json
import java.io.File
import java.util.UUID
import kotlin.random.Random
import kotlin.random.nextULong

/** The sequencer surface a pocket run drives (a seam so the whole store is JVM-testable). */
interface PocketRunPlayer {
    fun state(): SequencerState
    fun play(items: List<QueueItem>, tag: String, label: String)
    fun stop()
    fun replaceableUpcomingRows(runId: String): List<ReplaceableRow>
    fun replaceUpcoming(replacements: Map<String, QueueItem>, removing: Set<String>): Int
    fun appendRunRows(items: List<QueueItem>)
}

/** [PocketRunPlayer] over the shared [SetlistSequencer]. Call from the main thread (the sequencer's thread). */
class SequencerRunPlayer(private val sequencer: SetlistSequencer) : PocketRunPlayer {
    override fun state(): SequencerState = sequencer.state.value
    override fun play(items: List<QueueItem>, tag: String, label: String) {
        sequencer.play(items, sourceSetlistId = tag, context = PlayContext.pocket(tag, label))
    }
    override fun stop() = sequencer.stop()
    override fun replaceableUpcomingRows(runId: String) = sequencer.replaceableUpcomingRows(runId)
    override fun replaceUpcoming(replacements: Map<String, QueueItem>, removing: Set<String>) =
        sequencer.replaceUpcoming(replacements, removing)
    override fun appendRunRows(items: List<QueueItem>) = sequencer.appendRunRows(items)
}

/**
 * The app-scoped adaptive pocket run (iOS `PocketRunStore`, design §10.4). Builds the plan off-main, plays it through
 * the ONE shared sequencer under `pwr_<runId>`, and on a 1 Hz ticker reads the run's own verdicts from the play-history
 * log (the existing SkipTracker -> History pipeline - never a second one) to:
 *  - learn per-feature multipliers and ban skipped artists for the rest of THIS run (W5);
 *  - re-plan upcoming rows slot-wise, debounced, through the sequencer's protected `replaceUpcoming`;
 *  - keep exactly enough rows queued for 100 PLAYED-THROUGH songs (W2) and stop at the 100th, never starting a 101st.
 * Run state that must survive a relaunch lives in `pocketdj-pocket-run.json` (device-local); what was LEARNED is derived
 * from History ([PocketTuning.fold]), never stored.
 *
 * Threading: every public member is called on ONE thread (the main thread in production, the test thread in tests);
 * only the planner compute hops to [compute].
 */
class PocketRunStore(
    private val file: File,
    private val player: PocketRunPlayer?,
    private val scope: CoroutineScope,
    private val compute: CoroutineDispatcher = Dispatchers.Default,
) {
    /** One run's persisted state (iOS `RunState`; field names are the on-disk keys). */
    @Serializable
    data class RunState(
        /** Verbatim UUID string (iOS writes uppercase); also the `PocketRunTag.runId` of every play. */
        val runId: String,
        val momentKey: String? = null,
        val label: String,
        val seed: String,
        val profile: PocketProfile,
        val bench: List<PocketRunPlanner.BenchEntry> = emptyList(),
        val banned: List<String> = emptyList(),
        val playedThrough: Int = 0,
        val skips: Int = 0,
        val startedAtMs: Double,
        val endedAtMs: Double? = null,
        val finished: Boolean = false,
        val viaMix: Boolean = false,
        /** History events already counted. */
        val processed: List<String> = emptyList(),
        val completedSinceRescore: Int = 0,
        /** songId -> slot / row collection for the Mix path's history tags. */
        val mixSlots: Map<String, Int> = emptyMap(),
        val mixCollections: Map<String, String> = emptyMap(),
        val nextSlot: Int = TARGET + 1,
        /** The mode a sustained activity change re-targeted the run to (once per mode; P2-POC-12). */
        val retargetedMode: PocketMode? = null,
    ) {
        val tag: String get() = PocketWheelIds.runTag(runId)
    }

    /** A finished run, kept for the card's "Past runs" strip. */
    @Serializable
    data class RunSummary(
        val id: String,
        val momentKey: String? = null,
        val label: String,
        val startedAtMs: Double,
        val playedThrough: Int,
        val skips: Int,
        val finished: Boolean,
    )

    @Serializable
    data class Document(
        val schemaVersion: Int = 1,
        val active: RunState? = null,
        val past: List<RunSummary> = emptyList(),
    )

    sealed interface BuildState {
        data object Idle : BuildState
        data object Building : BuildState
        data class Failed(val message: String) : BuildState
    }

    private val _active = MutableStateFlow<RunState?>(null)
    val active: StateFlow<RunState?> get() = _active.asStateFlow()
    private val _past = MutableStateFlow<List<RunSummary>>(emptyList())
    val past: StateFlow<List<RunSummary>> get() = _past.asStateFlow()
    private val _buildState = MutableStateFlow<BuildState>(BuildState.Idle)
    val buildState: StateFlow<BuildState> get() = _buildState.asStateFlow()
    private val _revision = MutableStateFlow(0)

    /** Bumped on every visible change (centre progress ring, Up Next badges). */
    val revision: StateFlow<Int> get() = _revision.asStateFlow()
    private val _retuned = MutableStateFlow<Set<String>>(emptySet())

    /**
     * Rows re-tuned by the last re-plan / re-target (Up Next "Re-tuned" badge for a few seconds). Only rows that
     * actually LANDED in the queue (a protected row the player declined to swap is NOT re-tuned); cleared
     * [retunedBadgeMs] after the LATEST swap.
     */
    val retunedUids: StateFlow<Set<String>> get() = _retuned.asStateFlow()

    /** How long the badge shows (seam so tests needn't wait 4 s). */
    var retunedBadgeMs: Long = RETUNED_BADGE_MS
    private var retunedGeneration = 0

    val isRunning: Boolean get() = _active.value.let { it != null && !it.finished }

    /** (played-through, target, moment) of the running run, else null. */
    val progress: Triple<Int, Int, PocketMomentKey?>?
        get() {
            val a = _active.value ?: return null
            if (a.finished) return null
            return Triple(a.playedThrough, TARGET, a.momentKey?.let { PocketMomentKey.fromToken(it) })
        }

    // ---- seams -------------------------------------------------------------------------------

    var now: () -> Double = { System.currentTimeMillis().toDouble() }
    var tickerEnabled = true
    var log: (String) -> Unit = { NPLog.lane("pocketrun", it) }

    /** The play-history log, chronological (oldest first). */
    var historyEvents: () -> List<PlayEvent> = { emptyList() }
    var installId: () -> String = { "" }

    /** The candidate universe (playable songs -> planner candidates). Called from [start], off the main thread. */
    var candidates: suspend () -> Map<String, PocketRunPlanner.Candidate> = { emptyMap() }

    /** Lifetime thumbs-down song ids. */
    var thumbsDown: () -> Set<String> = { emptySet() }

    /** The history event of the track sounding NOW (its verdict is still pending). */
    var currentEventId: () -> String? = { null }

    /** W7: start the run's songs as a Mix Auto-DJ queue; returns how many were loadable. null = no Mix path here. */
    var playThroughMix: ((List<PocketRunPlanner.Row>, String) -> Int)? = null
    var mixOwnsRun: (String) -> Boolean = { false }
    var onRunEnded: ((RunSummary) -> Unit)? = null

    private var tickerJob: Job? = null
    private var topUpJob: Job? = null
    private var replanJob: Job? = null
    private var topUpBackoffUntilMs = 0.0
    private var ownershipLostAtMs: Double? = null
    private var cachedCandidates: Map<String, PocketRunPlanner.Candidate> = emptyMap()
    private var runTuning: PocketTuning.Multipliers = PocketTuning.Multipliers.NEUTRAL
    private var priorEvidence = PocketTuning.Evidence()

    init {
        val doc = runCatching { json.decodeFromString(Document.serializer(), file.readText()) }.getOrNull()
        if (doc != null) {
            _active.value = doc.active
            _past.value = doc.past
            doc.active?.let { runNames[it.tag] = it.label }
        }
    }

    private val nowMs: Double get() = now()

    private fun recencyNow(): Map<String, Double> =
        PocketRunPlanner.recency(lastPlayed(historyEvents()), nowMs)

    // ---- start -------------------------------------------------------------------------------

    /** Build and start a run for [profile]. A running run is replaced (its summary is kept). */
    suspend fun start(profile: PocketProfile, seed: ULong? = null): Boolean {
        if (_buildState.value == BuildState.Building) return false
        _buildState.value = BuildState.Building
        try {
            return startBuilding(profile, seed)
        } finally {
            // A throw or cancellation mid-build must not wedge every later start() at the Building guard.
            if (_buildState.value == BuildState.Building) _buildState.value = BuildState.Idle
        }
    }

    private suspend fun startBuilding(profile: PocketProfile, seed: ULong?): Boolean {
        val runId = UUID.randomUUID().toString().uppercase()
        val theSeed = seed ?: Random.nextULong(1uL, ULong.MAX_VALUE)
        val t = nowMs
        val events = historyEvents()
        val thumbs = thumbsDown()
        val pool = candidates()
        cachedCandidates = pool
        val moment = profile.key
        val (plan, prior, runProfile) = withContext(compute) {
            val recent = events.filter { t - it.playedAt < 12 * 3_600_000.0 }.mapTo(HashSet()) { SongVariant.baseId(it.songId) }
            val plays = events.map {
                InThePocketScorer.Play(
                    songId = SongVariant.baseId(it.songId), atMs = it.playedAt,
                    tzOffsetMin = it.tzOffsetMin ?: 0, outcome = it.outcome.name.lowercase(), ctx = null,
                )
            }
            val fam = InThePocketScorer.familiarity(plays)
            val recency = PocketRunPlanner.recency(lastPlayed(events), t)
            // allowBans = false: bans never cross runs (W5); the prior only shifts multipliers.
            val priorEv = PocketTuning.fold(PocketTuning.verdicts(events).map { it.second }, moment, t) { pool[it]?.features }
            val tuning = PocketTuning.multipliers(priorEv, allowBans = false)
            val expanded = PocketRunPlanner.derived(profile, pool)
            val planned = PocketRunPlanner.plan(
                PocketRunPlanner.Input(
                    profile = expanded, candidates = pool, excluded = recent + thumbs, familiarity = fam,
                    recency = recency, tuning = tuning, seed = theSeed,
                ),
            )
            Triple(planned, priorEv, expanded)
        }
        if (plan.rows.isEmpty()) {
            _buildState.value = BuildState.Failed(NOT_ENOUGH_SONGS)
            return false
        }
        // Only now is the new plan known good: end the previous run (a finished-not-dismissed one is just cleared).
        endOrClearActive()
        priorEvidence = prior
        runTuning = PocketTuning.multipliers(prior, allowBans = false)
        val label = "Pocket · " + (moment?.shortLabel?.replace(" · ", " ") ?: profile.caption)
        var state = RunState(
            runId = runId, momentKey = moment?.token, label = label, seed = theSeed.toString(), profile = runProfile,
            bench = plan.bench, startedAtMs = t,
        )
        runNames[state.tag] = label
        // W7: a Mix moment plays through Mix Auto-DJ when enough of the run can load on the decks (no live re-plan there).
        val mix = playThroughMix
        if (profile.mode == PocketMode.MIX && mix != null) {
            val loaded = mix(plan.rows, label)
            if (loaded >= MIX_MIN_LOADABLE) {
                state = state.copy(
                    viaMix = true,
                    mixSlots = plan.rows.associate { it.songId to it.slot },
                    mixCollections = plan.rows.mapNotNull { r -> r.collectionId?.let { r.songId to it } }.toMap(),
                )
            }
        }
        if (!state.viaMix) {
            player?.play(plan.rows.mapNotNull { item(it, runId) }, state.tag, label)
        }
        _active.value = state
        _buildState.value = BuildState.Idle
        ownershipLostAtMs = null
        bump()
        persist()
        val recencyAtStart = recencyNow()
        val fresh = plan.rows.count { (recencyAtStart[it.songId] ?: 0.0) <= 0.0 }
        log("start run=${runId.take(8)} moment=${moment?.token ?: profile.tier.name.lowercase()} rows=${plan.rows.size} fresh=$fresh bench=${plan.bench.size} mix=${state.viaMix}")
        startTicker()
        return true
    }

    private fun item(row: PocketRunPlanner.Row, runId: String): QueueItem? {
        val c = cachedCandidates[row.songId] ?: return null
        return QueueItem(
            id = c.id, title = c.title, artist = c.artist, lengthMs = c.lengthMs?.toLong(),
            plan = PlanTag(runId = runId, slot = row.slot, collectionId = row.collectionId, score = row.score, pinned = false),
        )
    }

    /** Is the shared sequencer still playing THIS run? Every queue edit is gated on it (iOS `ownsSequencer`). */
    fun ownsSequencer(a: RunState): Boolean {
        if (a.viaMix) return false
        val st = player?.state() ?: return false
        return st.isRunning && st.sourceSetlistId == a.tag
    }

    /** The History tag for a play the sequencer is making now (null when it isn't a row of the active run). */
    fun tag(forPlan: PlanTag?): PocketRunTag? {
        val plan = forPlan ?: return null
        val a = _active.value ?: return null
        if (a.runId != plan.runId) return null
        return PocketRunTag(runId = a.runId, momentKey = a.momentKey ?: "", rowCollectionId = plan.collectionId, slot = plan.slot)
    }

    /** The History tag for a Mix deck play of [songId] during a W7 run. */
    fun mixTag(songId: String, label: String?): PocketRunTag? {
        val a = _active.value ?: return null
        if (!a.viaMix || label != a.label) return null
        val slot = a.mixSlots[songId] ?: return null
        return PocketRunTag(runId = a.runId, momentKey = a.momentKey ?: "", rowCollectionId = a.mixCollections[songId], slot = slot)
    }

    // ---- observe -----------------------------------------------------------------------------

    /** After a relaunch: reload the candidate cache, re-derive the tuning and resume the ticker. */
    fun resumeTrackingIfNeeded() {
        val a = _active.value ?: return
        if (a.finished) return
        if (cachedCandidates.isEmpty()) {
            scope.launch {
                cachedCandidates = withContext(compute) { candidates() }
                relearn()
                startTicker()
            }
        } else {
            startTicker()
        }
    }

    /** Rebuild the prior (every OTHER run) and this run's tuning from History after a relaunch. */
    private fun relearn() {
        val a = _active.value ?: return
        val events = historyEvents()
        val moment = a.momentKey?.let { PocketMomentKey.fromToken(it) }
        priorEvidence = PocketTuning.fold(
            PocketTuning.verdicts(events, excludingRun = a.runId).map { it.second }, moment, nowMs,
        ) { cachedCandidates[it]?.features }
        runTuning = PocketTuning.multipliers(priorEvidence, allowBans = false)
        val mine = runVerdicts(a, events, currentEventId())
        if (mine.isNotEmpty()) _active.value = applyLearning(a, mine)
    }

    private fun startTicker() {
        if (!tickerEnabled || tickerJob != null) return
        val job = scope.launch(start = CoroutineStart.LAZY) {
            try {
                while (isActive && isRunning) {
                    evaluate()
                    delay(TICK_MS)
                }
            } finally {
                if (tickerJob === coroutineContext[Job]) tickerJob = null
            }
        }
        tickerJob = job
        job.start()
    }

    /** This run's verdicts: ONE bounded tail walk back to the run's start (never a full-history scan). */
    private fun runVerdicts(a: RunState, events: List<PlayEvent>, current: String?): List<Pair<String, PocketTuning.Verdict>> {
        val mine = installId()
        val out = ArrayList<Pair<String, PocketTuning.Verdict>>()
        for (i in events.indices.reversed()) {
            val e = events[i]
            if (e.playedAt < a.startedAtMs - TAIL_SLACK_MS) break
            val tag = e.pocketRun ?: continue
            if (tag.runId != a.runId || e.id == current) continue
            if (e.originInstallId != null && e.originInstallId != mine) continue
            out += e.id to PocketTuning.Verdict(
                songId = SongVariant.baseId(e.songId), skipped = e.wasSkipped == true, fraction = e.listenedFraction,
                atMs = e.playedAt, momentKey = tag.momentKey, rowCollectionId = tag.rowCollectionId,
            )
        }
        return out
    }

    /** Evidence = prior (own x1, related x0.5, rest x0.15) + this run; bans come from THIS run's evidence only (W5). */
    private fun applyLearning(a: RunState, verdicts: List<Pair<String, PocketTuning.Verdict>>): RunState {
        val features: (String) -> PocketTuning.Features? = { cachedCandidates[it]?.features }
        val vs = verdicts.map { it.second }
        val evidence = PocketTuning.Evidence(
            LinkedHashMap(priorEvidence.pos), LinkedHashMap(priorEvidence.neg), ArrayList(priorEvidence.skippedVectors),
        )
        evidence.merge(PocketTuning.runEvidence(vs, features), 1.0)
        val runOnly = PocketTuning.multipliers(PocketTuning.runEvidence(vs, features), allowBans = true)
        runTuning = PocketTuning.multipliers(evidence, allowBans = false).copy(bannedArtists = runOnly.bannedArtists)
        return a.copy(banned = runTuning.bannedArtists.sorted())
    }

    /**
     * One evaluation - the ticker's body and the test seam: count new verdicts, learn, keep the 100-play-through
     * invariant, schedule a re-plan, end on ownership loss.
     */
    fun evaluate() {
        var a = _active.value ?: return
        if (a.finished) return
        val t = nowMs
        val st = player?.state()
        val owns = if (a.viaMix) mixOwnsRun(a.label) else (st != null && st.isRunning && st.sourceSetlistId == a.tag)
        if (owns) ownershipLostAtMs = null else if (ownershipLostAtMs == null) ownershipLostAtMs = t

        // A restored-but-held run is not sounding: nothing to learn or edit until play.
        if (!a.viaMix && st?.isHeldForResume == true) return

        val verdicts = runVerdicts(a, historyEvents(), currentEventId())
        val processed = a.processed.toHashSet()
        var newSkip = false
        var changed = false
        var processedList = a.processed
        var skips = a.skips
        var through = a.playedThrough
        var sinceRescore = a.completedSinceRescore
        for ((id, v) in verdicts) {
            if (id in processed) continue
            processedList = processedList + id
            changed = true
            if (v.skipped) {
                skips++
                newSkip = true
            } else {
                through++
                sinceRescore++
            }
        }
        a = a.copy(processed = processedList, skips = skips, playedThrough = through, completedSinceRescore = sinceRescore)
        if (changed) a = applyLearning(a, verdicts)
        _active.value = a
        if (changed) {
            bump()
            persist()
        }

        val ownsQueue = ownsSequencer(a) || a.viaMix
        if (a.playedThrough >= TARGET) {
            if (ownsQueue) trimToInvariant()
            // The 100th play-through is in: the run is over once the queue has run out.
            val runRowsLeft = player?.state()?.upcoming?.any { it.plan?.runId == a.runId } ?: false
            if (!owns || !runRowsLeft) {
                endRun(finished = true)
                return
            }
        }
        val lost = ownershipLostAtMs
        if (!owns && lost != null && t - lost >= OWNERSHIP_GRACE_MS) {
            endRun(finished = a.playedThrough >= TARGET)
            return
        }
        // Lost the sequencer (inside the grace window): learn, but never touch its queue.
        if (!ownsQueue) return
        if (newSkip) {
            scheduleReplan()
        } else if (a.completedSinceRescore >= RESCORE_EVERY) {
            _active.value = _active.value?.copy(completedSinceRescore = 0)
            scheduleReplan(delayMs = 0)
        }
        trimToInvariant()
    }

    /**
     * W2: keep queued run rows == 100 - played-through - (1 if a run row is sounding with its verdict pending). Excess
     * run rows leave the TAIL; a shortfall is topped up from the bench. The SOUNDING run row counts as done once it is
     * >= 90 % played (a listen past half can no longer become a skip), so the queue empties right after the 100th
     * play-through instead of starting a 101st; until then one SPARE row stays queued in case it gets skipped.
     */
    fun trimToInvariant() {
        val a = _active.value ?: return
        val pl = player ?: return
        if (a.finished || a.viaMix || !ownsSequencer(a)) return
        val st = pl.state()
        val cur = st.queue.getOrNull(st.index)
        val currentIsRun = st.isRunning && cur?.plan?.runId == a.runId
        val fraction = currentEventId()?.let { id -> historyEvents().lastOrNull { it.id == id }?.listenedFraction }
        val needed = rowsNeeded(TARGET, a.playedThrough, currentIsRun, fraction)
        // Pinned (listener-moved) run rows still COUNT toward the 100; only unpinned ones leave.
        val upcomingRun = st.upcoming.filter { it.plan?.runId == a.runId }
        val removable = upcomingRun.filter { it.plan?.pinned != true }
        if (upcomingRun.size > needed) {
            val excess = removable.takeLast(minOf(removable.size, upcomingRun.size - needed)).map { it.uid }
            if (excess.isNotEmpty()) pl.replaceUpcoming(emptyMap(), excess.toSet())
        } else if (upcomingRun.size < needed && st.isRunning && !st.isHeldForResume) {
            topUp(needed - upcomingRun.size)
        }
    }

    /** Score the pool OFF-main, append if the run still owns the sequencer, and back off 30 s when nothing qualifies. */
    private fun topUp(count: Int) {
        val a = _active.value ?: return
        val pl = player ?: return
        if (topUpJob != null || nowMs < topUpBackoffUntilMs) return
        val st = pl.state()
        val inRun = st.queue.mapTo(HashSet()) { it.id }
        val tail = st.queue.takeLast(3).map { it.id }
        val pool = cachedCandidates
        val tuning = runTuning
        val profile = a.profile
        val thumbs = thumbsDown()
        val recency = recencyNow()
        val job = scope.launch(start = CoroutineStart.LAZY) {
            try {
                val picks = withContext(compute) {
                    PocketRunPlanner.topUp(
                        count = count, profile = profile, candidates = pool, tuning = tuning, familiarity = emptyMap(),
                        recency = recency, inRun = inRun, tail = tail, excluded = thumbs,
                    )
                }
                var cur = _active.value ?: return@launch
                if (cur.runId != a.runId || cur.finished || !ownsSequencer(cur)) return@launch
                if (picks.isEmpty()) {
                    topUpBackoffUntilMs = nowMs + TOP_UP_BACKOFF_MS
                    return@launch
                }
                val queued = pl.state().queue.mapTo(HashSet()) { it.id }
                val fresh = picks.filter { it.songId !in queued }
                val items = ArrayList<QueueItem>()
                var slot = cur.nextSlot
                for (p in fresh) {
                    val row = PocketRunPlanner.Row(p.songId, slot, pool[p.songId]?.let { PocketRunPlanner.bucket(it, profile) }, p.score)
                    slot++
                    item(row, cur.runId)?.let { items += it }
                }
                val used = fresh.mapTo(HashSet()) { it.songId }
                cur = cur.copy(nextSlot = slot, bench = cur.bench.filter { it.songId !in used })
                _active.value = cur
                pl.appendRunRows(items)
                persist()
                log("topup run=${cur.runId.take(8)} n=${items.size} playedThrough=${cur.playedThrough} skips=${cur.skips}")
            } finally {
                if (topUpJob === coroutineContext[Job]) topUpJob = null
            }
        }
        topUpJob = job
        job.start()
    }

    /** Test seam: wait for an in-flight top-up. */
    suspend fun awaitTopUp() { topUpJob?.join() }

    // ---- re-plan -----------------------------------------------------------------------------

    fun scheduleReplan(delayMs: Long = REPLAN_DEBOUNCE_MS) {
        replanJob?.cancel()
        replanJob = scope.launch {
            if (delayMs > 0) delay(delayMs)
            replanNow()
        }
    }

    /** Compute (off-main) and apply (protection re-checked at apply time by the sequencer) a re-plan. */
    suspend fun replanNow() {
        val a = _active.value ?: return
        val pl = player ?: return
        if (a.finished || a.viaMix || !ownsSequencer(a)) return
        val started = nowMs
        val rows = pl.replaceableUpcomingRows(a.runId)
        if (rows.isEmpty()) return
        val live = rows.map { PocketRunPlanner.LiveRow(it.uid, it.songId, it.slot, it.collectionId, it.requiresInstant) }
        val neighbours = rows.associate { it.uid to PocketRunPlanner.Neighbours(it.prevSongId, it.nextSongId) }
        val inRun = pl.state().queue.mapTo(HashSet()) { it.id }
        val pool = cachedCandidates
        val tuning = runTuning
        val profile = a.profile
        val thumbs = thumbsDown()
        val recency = recencyNow()
        val result = withContext(compute) {
            PocketRunPlanner.replan(
                profile = profile, candidates = pool, tuning = tuning, familiarity = emptyMap(), recency = recency,
                live = live, inRun = inRun, neighbours = neighbours, excluded = thumbs,
            )
        }
        val cur = _active.value ?: return
        if (cur.runId != a.runId || !ownsSequencer(cur)) return
        val items = LinkedHashMap<String, QueueItem>()
        for (r in result.replacements) {
            item(PocketRunPlanner.Row(r.songId, r.slot, r.collectionId, r.score), a.runId)?.let { items[r.uid] = it }
        }
        val applied = pl.replaceUpcoming(items, result.removals.toSet())
        flashRetuned(items.values.mapTo(HashSet()) { it.uid })
        bump()
        val ms = (nowMs - started).toLong()
        log(
            "replan run=${a.runId.take(8)} skips=${a.skips} replaced=${result.replacements.size} removed=${result.removals.size} " +
                "applied=$applied banned=[${result.banned.joinToString(",")}] ms=$ms",
        )
        trimToInvariant()
    }

    /** Whether the Up Next row with this queue uid shows the "Re-tuned" badge. */
    fun isRetuned(uid: String): Boolean = uid in _retuned.value

    /**
     * Light the badge on the swapped rows still in the queue, then clear it after [retunedBadgeMs] - unless a newer
     * swap re-lit it meanwhile (its own timer clears it; an older timer must not cut the newer badge short).
     */
    internal fun flashRetuned(uids: Set<String>) {
        val queued = player?.state()?.queue?.mapTo(HashSet()) { it.uid } ?: emptySet<String>()
        val live = uids.intersect(queued)
        if (live.isEmpty()) return // nothing landed: keep the previous swap's badge and its timer
        retunedGeneration++
        _retuned.value = live
        val gen = retunedGeneration
        val ms = retunedBadgeMs
        scope.launch {
            delay(maxOf(0L, ms))
            if (retunedGeneration == gen) _retuned.value = emptySet()
        }
    }

    /** Re-plan every replaceable upcoming row from [profile] (slot order kept) - the activity re-target path (P2-POC-12). */
    suspend fun retarget(profile: PocketProfile, mode: PocketMode) {
        var a = _active.value ?: return
        val pl = player ?: return
        if (a.finished || !ownsSequencer(a)) return
        val rows = pl.replaceableUpcomingRows(a.runId)
        if (rows.isEmpty()) return
        val st = pl.state()
        val inRun = st.queue.take(st.index + 1).mapTo(HashSet()) { it.id }
        val pool = cachedCandidates
        val tuning = runTuning
        val thumbs = thumbsDown()
        val seed = a.seed.toULongOrNull() ?: 1uL
        val recency = recencyNow()
        val (plan, runProfile) = withContext(compute) {
            val expanded = PocketRunPlanner.derived(profile, pool)
            PocketRunPlanner.plan(
                PocketRunPlanner.Input(
                    profile = expanded, candidates = pool, excluded = inRun + thumbs, recency = recency, tuning = tuning,
                    seed = seed + 1uL, slots = rows.size,
                ),
            ) to expanded
        }
        val cur = _active.value ?: return
        if (cur.runId != a.runId || !ownsSequencer(cur)) return
        a = cur
        val items = LinkedHashMap<String, QueueItem>()
        for ((row, planned) in rows.sortedBy { it.slot }.zip(plan.rows)) {
            item(PocketRunPlanner.Row(planned.songId, row.slot, planned.collectionId, planned.score), a.runId)?.let { items[row.uid] = it }
        }
        val applied = pl.replaceUpcoming(items, emptySet())
        _active.value = a.copy(retargetedMode = mode, profile = runProfile, bench = plan.bench)
        flashRetuned(items.values.mapTo(HashSet()) { it.uid })
        bump()
        persist()
        log("retarget run=${a.runId.take(8)} mode=${mode.token} applied=$applied")
    }

    // ---- end ---------------------------------------------------------------------------------

    /** Clear this pocket: stop the queue (if it is still this run's) and file the run into past runs. */
    fun stop() {
        val a = _active.value ?: return
        if (!a.viaMix && player?.state()?.sourceSetlistId == a.tag) player.stop()
        endOrClearActive()
    }

    /** End a live run; a run that already finished (card not dismissed) is only cleared, never summarised twice. */
    private fun endOrClearActive() {
        val a = _active.value ?: return
        if (a.finished) dismissFinished() else endRun(finished = false)
    }

    private fun endRun(finished: Boolean) {
        val a = _active.value ?: return
        tickerJob?.cancel(); tickerJob = null
        replanJob?.cancel(); replanJob = null
        topUpJob?.cancel(); topUpJob = null
        retunedGeneration++
        _retuned.value = emptySet()
        val ended = a.copy(finished = true, endedAtMs = nowMs)
        val summary = RunSummary(a.runId, a.momentKey, a.label, a.startedAtMs, a.playedThrough, a.skips, finished)
        _past.value = (_past.value + summary).takeLast(PAST_CAP)
        _active.value = if (finished) ended else null
        runNames.remove(a.tag)
        bump()
        persist()
        log("end run=${a.runId.take(8)} finished=$finished playedThrough=${a.playedThrough} skips=${a.skips}")
        onRunEnded?.invoke(summary)
    }

    /** Dismiss the "Pocket finished" card. */
    fun dismissFinished() {
        if (_active.value?.finished != true) return
        _active.value = null
        bump()
        persist()
    }

    /** "Past runs" for a moment, newest first, at most 5. */
    fun runHistory(key: PocketMomentKey): List<PocketRunHistoryRow> =
        _past.value.filter { it.momentKey == key.token }.asReversed().take(5).map {
            val n = it.playedThrough + it.skips
            PocketRunHistoryRow(it.id, it.startedAtMs, it.playedThrough, if (n > 0) it.skips.toDouble() / n else 0.0)
        }

    /** Delete-history / account-deletion wipe (registered with `PocketsGraph.registerWheelClear`). */
    fun clearLocal() {
        tickerJob?.cancel(); tickerJob = null
        replanJob?.cancel(); replanJob = null
        topUpJob?.cancel(); topUpJob = null
        _active.value?.let { runNames.remove(it.tag) }
        _active.value = null
        _past.value = emptyList()
        _retuned.value = emptySet()
        bump()
        runCatching { file.delete() }
    }

    private fun bump() { _revision.value = _revision.value + 1 }

    private fun persist() {
        runCatching {
            val text = json.encodeToString(Document.serializer(), Document(active = _active.value, past = _past.value))
            val tmp = File(file.parentFile, file.name + ".tmp")
            tmp.writeText(text)
            if (!tmp.renameTo(file)) { file.writeText(text); tmp.delete() }
        }
    }

    /** One "Past runs" row (iOS `PocketRunHistoryRow`). */
    data class PocketRunHistoryRow(val id: String, val startedAtMs: Double, val playedThrough: Int, val skipRate: Double)

    companion object {
        const val FILE_NAME = "pocketdj-pocket-run.json"
        const val TARGET = 100
        const val REPLAN_DEBOUNCE_MS = 1_500L
        const val RESCORE_EVERY = 5
        const val OWNERSHIP_GRACE_MS = 10_000.0
        const val TOP_UP_BACKOFF_MS = 30_000.0
        const val RETUNED_BADGE_MS = 4_000L
        const val TICK_MS = 1_000L
        const val PAST_CAP = 50
        const val MIX_MIN_LOADABLE = 10
        private const val TAIL_SLACK_MS = 60_000.0
        const val NOT_ENOUGH_SONGS =
            "Not enough playable songs fit your pocket right now. Download some, or connect Apple Music."

        /** Display names of live run tags ("Pocket · Tue 8 AM CarPlay") for History's context lookup. */
        val runNames: MutableMap<String, String> = java.util.concurrent.ConcurrentHashMap()

        val json = Json { ignoreUnknownKeys = true; encodeDefaults = true; explicitNulls = false }

        /** Last play of every song in History (base ids), for the planner's freshness. */
        fun lastPlayed(events: List<PlayEvent>): Map<String, Double> {
            val out = HashMap<String, Double>()
            for (e in events) {
                val id = SongVariant.baseId(e.songId)
                if (e.playedAt > (out[id] ?: 0.0)) out[id] = e.playedAt
            }
            return out
        }

        /**
         * The pure W2 invariant (see [trimToInvariant]): how many run rows must stay queued. The sounding row counts as
         * done at >= 90 %; otherwise it is pending and one spare row stays (until the 100th is in).
         */
        fun rowsNeeded(target: Int, playedThrough: Int, currentIsRun: Boolean, currentFraction: Double?): Int {
            val nearlyDone = currentIsRun && (currentFraction ?: 0.0) >= 0.9
            val done = playedThrough + if (nearlyDone) 1 else 0
            val pending = if (currentIsRun && !nearlyDone) 1 else 0
            val base = target - done - pending
            if (base <= 0) return if (pending == 1 && done < target) 1 else 0 // the spare
            return base
        }
    }
}

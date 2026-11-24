package com.levi.pocketdj.playback.dj

import com.levi.pocketdj.playback.sequencer.QueueItem
import com.levi.pocketdj.playback.sequencer.SequencerListener
import com.levi.pocketdj.playback.sequencer.SequencerState
import com.levi.pocketdj.playback.sequencer.SessionEndReason
import com.levi.pocketdj.playback.sequencer.TrackStart
import kotlinx.coroutines.CancellationException
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.CoroutineStart
import kotlinx.coroutines.Job
import kotlinx.coroutines.delay
import kotlinx.coroutines.launch
import java.util.UUID

/**
 * The PocketDJ selector's session side (iOS `SetlistPlayer.djReplan` / `applyDJOrder` / `scheduleDJReplan` /
 * `loadDJMembership`): with DJ Mode on, the upcoming [DjCandidates.PLAN_WINDOW] rows are re-ordered into tempo waves and
 * pockets by [DjSetPlanner] while the listener's own next-up pick (`QueueItem.djUserNext`) stays sacred.
 *
 *  - Triggers: DJ turned on / resumed ([onApply]), every track start, a membership landing, a queue edit (1 s debounce),
 *    an analysis landing that changed a row's tempo / key. NOT while a Remote session is attached; our own re-order never
 *    re-triggers (it is recognized by its queue generation).
 *  - One uid-verified re-order of the next 40 rows ([Host.applyOrder]); duplicate uids bail.
 *  - Fixed rows ([DjCandidates.rowFixed]) keep their slot.
 *  - The planner position lives in `djMode.planner` ([Host.setPlannerState]).
 *
 * Main thread only, like the sequencer.
 */
class DjPlannerDriver(
    private val host: Host,
    private val scope: CoroutineScope,
    /** Queue edits re-plan after this quiet period (np-dj-mode section 4: 1 s). */
    var debounceMs: Long = DEBOUNCE_MS,
) : SequencerListener {

    interface Host {
        /** DJ Mode is switched on (even if suspended). */
        val enabled: Boolean

        /** DJ Mode is on AND allowed to act (not held, Mix tab idle, no Remote session). */
        val djActive: Boolean
        val remoteActive: Boolean
        fun state(): SequencerState
        fun settings(): DJModeSettings
        fun plannerState(): DjPlannerState?
        fun setPlannerState(st: DjPlannerState)
        fun facts(item: QueueItem): DjCandidates.Facts?

        /** Rip / lane / buffer / local signals of one upcoming row (album linkage is [albumLinkedRows]'s). */
        fun signals(item: QueueItem): DjCandidates.RowSignals
        /** Absolute queue positions inside `index..hi` that belong to an album-run block. */
        fun albumLinkedRows(hi: Int): Set<Int>
        val transitioning: Boolean
        fun runwaySeconds(): Double?

        /** song -> collection ids, computed OFF the main thread. An empty answer is an answer. */
        suspend fun loadMembership(): Map<String, Set<String>>

        /** The sequencer's uid-verified re-order of `[lo, lo + expected.size)`; the queue generation it wrote, or null. */
        fun applyOrder(lo: Int, expected: List<String>, order: List<String>, fixed: List<Boolean>, countDeferrals: Boolean): Long?

        /** A listener-chosen next row landed: make it as smooth as possible (buffer lane, rip window, analysis first). */
        fun userNextPlaced(item: QueueItem) {}
        fun persist() {}
        fun log(line: String) {}
    }

    enum class Reason(val raw: String) { TRACK("track"), EDIT("edit"), MEMBERSHIP("membership"), ANALYSIS("analysis"), ON("on") }

    private data class PlannedFacts(val bpm: Double?, val camelot: String?)

    private var replanTask: Job? = null
    private var pendingReason: Reason? = null
    private var membership: Map<String, Set<String>> = emptyMap()
    private var membershipTask: Job? = null
    /** The membership provider ran for this DJ-on (an EMPTY result isn't asked for again at every track start). */
    private var membershipLoaded = false
    private var wasEnabled = false
    private var applying = false
    private var ownGeneration = -1L
    /** The listener's pick, remembered: the sequencer spends the hold when the row STARTS, before the track-start re-plan. */
    private var lastPickUid: String? = null
    private val plannedFacts = HashMap<String, PlannedFacts>()

    /** Re-orders applied (diagnostics + tests). */
    var replanCount = 0; private set

    /** Analysis re-plans requested so far (tests). */
    var analysisReplanCount = 0; private set

    val replanPending: Boolean get() = replanTask != null

    // ---- entry points ----------------------------------------------------------------------------------------------

    /** DJ turned ON or resumed (engine hook `applyOnTrackStart`): membership off-main, then the first plan now. */
    fun onApply() {
        if (!syncEnabled()) return
        loadMembership()
        replan(Reason.ON)
    }

    /** DJ OFF / suspended (engine hook `disarm`): no re-plan is waiting. */
    fun disarm() {
        cancelReplan()
    }

    /** Every start path: every advance re-plans what comes next. */
    override fun onTrackStarted(start: TrackStart) {
        if (!syncEnabled() || !host.djActive) return
        loadMembership()
        replan(Reason.TRACK)
    }

    /** A queue edit: re-plan once things settle - never for our own re-order. */
    override fun onQueueChanged(generation: Long) {
        if (applying || generation == ownGeneration) return
        scheduleReplan(Reason.EDIT)
    }

    /** The sequencer set the pick; remember it and prepare the row. */
    override fun onRowLandedNext(uid: String) {
        if (!host.enabled) return
        lastPickUid = uid
        host.state().queue.firstOrNull { it.uid == uid }?.let {
            host.log("user next song=${it.id} uid=$uid - held next, buffering first")
            host.userNextPlaced(it)
        }
    }

    override fun onSessionStarted(sessionId: String, source: com.levi.pocketdj.playback.sequencer.SourceRef) = reset()
    override fun onSessionEnded(reason: SessionEndReason) = reset()

    /** New session / stop: everything forgotten. */
    fun reset() {
        cancelReplan()
        membershipTask?.cancel(); membershipTask = null
        membership = emptyMap()
        membershipLoaded = false
        wasEnabled = false
        lastPickUid = null
        plannedFacts.clear()
    }

    /** A tempo / key analysis landed for [songId]: re-plan only if a planner fact of a windowed row actually changed. */
    fun onAnalysisLanded(songId: String) {
        if (!host.djActive) return
        val st = host.state()
        if (!st.isRunning || st.index >= st.queue.size) return
        val hi = minOf(st.queue.size, st.index + 1 + DjCandidates.PLAN_WINDOW)
        val changed = (st.index + 1 until hi).any { i ->
            val it = st.queue[i]
            if (!it.matches(songId)) return@any false
            val f = host.facts(it)
            plannedFacts[it.uid] != PlannedFacts(f?.bpm, f?.camelot)
        }
        if (changed) scheduleReplan(Reason.ANALYSIS)
    }

    // ---- membership ------------------------------------------------------------------------------------------------

    /** A fresh DJ-on asks for the membership again; returns whether DJ is on. */
    private fun syncEnabled(): Boolean {
        val on = host.enabled
        if (on && !wasEnabled) { membershipLoaded = false; membership = emptyMap() }
        if (!on) { cancelReplan(); membershipTask?.cancel(); membershipTask = null }
        wasEnabled = on
        return on
    }

    private fun loadMembership() {
        if (membershipTask != null || membershipLoaded) return
        membershipTask = scope.launch {
            val m = try { host.loadMembership() } catch (e: CancellationException) { throw e } catch (e: Exception) {
                host.log("membership failed: ${e.javaClass.simpleName}")
                emptyMap()
            }
            membershipTask = null
            membershipLoaded = true
            membership = m
            if (host.enabled && m.isNotEmpty()) replan(Reason.MEMBERSHIP)
        }
    }

    // ---- scheduling ------------------------------------------------------------------------------------------------

    private fun cancelReplan() {
        replanTask?.cancel(); replanTask = null
        pendingReason = null
    }

    private fun scheduleReplan(reason: Reason) {
        if (!host.enabled || applying || host.remoteActive) return
        if (!host.state().isRunning) return
        replanTask?.cancel()
        // An EDIT counts deferrals (aging); an ANALYSIS re-plan never does. An edit pending alongside wins.
        pendingReason = if (pendingReason == Reason.EDIT) Reason.EDIT else reason
        val wait = debounceMs
        lateinit var self: Job
        self = scope.launch(start = CoroutineStart.LAZY) {
            delay(maxOf(0L, wait))
            if (replanTask === self) replanTask = null
            val r = pendingReason ?: Reason.EDIT
            pendingReason = null
            replan(r)
        }
        replanTask = self
        self.start()
    }

    // ---- the re-plan -----------------------------------------------------------------------------------------------

    /** Re-plan the upcoming window now: one uid-verified, pin-respecting re-order. */
    fun replan(reason: Reason) {
        cancelReplan()
        if (reason == Reason.ANALYSIS) analysisReplanCount++
        val st = host.state()
        if (!host.djActive || !st.isRunning || st.isHeldForResume || st.index >= st.queue.size) return
        val queue = st.queue
        val index = st.index
        val lo = index + 1
        val hi = minOf(queue.size, lo + DjCandidates.PLAN_WINDOW)
        val planner = host.plannerState()
            ?: DjPlannerState(AutoTransition.fxSeed(queue.firstOrNull()?.id, queue.size))

        queue.getOrNull(lo)?.takeIf { it.djUserNext }?.let { lastPickUid = it.uid }
        val cur = queue[index]
        // The listener's pick re-anchors the set - while it waits next, and when it plays.
        val currentAnchor = cur.djUserNext || cur.uid == lastPickUid
        val current = candidate(cur, fixed = true, anchor = currentAnchor)

        val rows = if (lo < hi) queue.subList(lo, hi).toList() else emptyList()
        val linked = if (rows.isEmpty()) emptySet() else host.albumLinkedRows(hi)
        val runway = host.runwaySeconds()
        val transitioning = host.transitioning
        val fixed = rows.mapIndexed { k, row ->
            val pos = lo + k
            val sig = host.signals(row).copy(albumLinked = pos in linked)
            DjCandidates.rowFixed(row, isNext = pos == lo, signals = sig, transitioning = transitioning, runwaySeconds = runway)
        }
        val candidates = rows.mapIndexed { k, row -> candidate(row, fixed[k], anchor = k == 0 && row.djUserNext) }
        val before = candidates.map { it.uid }
        val tag = "replan reason=${reason.raw} song=${cur.id} rows=${rows.size}"

        if (before.toSet().size != before.size) {
            host.log("$tag moved=0 - duplicate uids, order kept")
            return
        }
        val opts = host.settings().plannerOptions.let {
            DjSetPlanner.Options(tempoWaves = it.tempoWaves, pockets = it.pockets, key = it.key)
        }
        val result = DjSetPlanner.plan(current, candidates, planner, opts)
        host.setPlannerState(result.state)
        host.persist()

        val pickUid = rows.firstOrNull()?.takeIf { it.djUserNext }?.uid
        val moved = result.order.indices.count { result.order[it] != before[it] }
        val byUuid = HashMap<UUID, String>().also { m -> rows.forEach { m[DjCandidates.uuidOf(it.uid)] = it.uid } }
        val ok = moved > 0 && run {
            val order = result.order.map { byUuid[it] ?: return@run false }
            applying = true
            val gen = try {
                host.applyOrder(lo, rows.map { it.uid }, order, fixed, countDeferrals = reason != Reason.ANALYSIS)
            } finally { applying = false }
            if (gen != null) ownGeneration = gen
            gen != null
        }
        if (!ok) {
            host.log("$tag moved=0 fixed=${fixed.count { it }} pick=${pickUid ?: "-"} - order kept")
            return
        }
        replanCount++
        val now = host.state().queue
        val head = now.subList(lo, minOf(now.size, lo + 6)).joinToString(",") { it.id }
        host.log(
            "$tag moved=$moved fixed=${fixed.count { it }} pick=${pickUid ?: "-"} " +
                "band=${result.state.band ?: "-"} dir=${if (result.state.direction == DjDirection.UP) "up" else "down"} next=$head",
        )
    }

    private fun candidate(item: QueueItem, fixed: Boolean, anchor: Boolean): DjSetPlanner.Candidate {
        val f = host.facts(item)
        plannedFacts[item.uid] = PlannedFacts(f?.bpm, f?.camelot)
        return DjCandidates.candidate(item, f, membership, fixed, anchor)
    }

    companion object {
        const val DEBOUNCE_MS = 1_000L
    }
}

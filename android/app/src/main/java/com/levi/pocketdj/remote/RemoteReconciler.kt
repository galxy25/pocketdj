package com.levi.pocketdj.remote

import com.levi.pocketdj.diag.NPLog
import com.levi.pocketdj.playback.sequencer.QueueItem
import kotlin.math.abs

/** Reconcile / drift tunables (iOS `RemoteSessionController` statics). */
object ReconcileTuning {
    const val DRIFT_THRESHOLD_MS = 750L

    /** Apple Music's position clock is coarse: a tighter threshold chases its own jitter. */
    const val COARSE_DRIFT_THRESHOLD_MS = 2_000L

    /** Plain drift must be seen on this many consecutive ticks before it's corrected. */
    const val DRIFT_STRIKES_NEEDED = 2
    const val DRIFT_COOLDOWN_MS = 5_000.0

    /** A ▶/⏸ the reconciler applied that hasn't taken is re-issued no sooner than this. */
    const val PLAY_RETRY_MS = 2_000.0

    /** A state received this recently is "fresh off the wire" (a session seek applies without a synced clock). */
    const val FRESH_STATE_MS = 1_000.0

    /** A row the session is on that ended here this much early stays held until the session moves past it. */
    const val HELD_RESTART_SLACK_MS = 5_000L

    /** A start cue at or below this is "from the top". */
    const val CUE_MIN_MS = 1_500L
}

/**
 * Process-wide "Auto-DJ is unavailable" reason: a multiplayer Mix session owns the decks (iOS
 * `MixEngine.autoDJBlockedReason`). Mix Together (P2-REM-11) sets it; the Auto-DJ, the Assistant link and the Auto Mix
 * tab refuse a start with [REASON] while it is non-null.
 */
object MixTogetherBlock {
    const val REASON = "Auto DJ is off while you mix together."

    @Volatile var reason: String? = null
        private set
    val blocked: Boolean get() = reason != null

    /** Told after every change of [reason] (the graph ends a running Auto-DJ). */
    @Volatile var onChanged: (() -> Unit)? = null

    fun set(why: String?) {
        if (reason == why) return
        reason = why
        onChanged?.invoke()
    }
}

/**
 * The speaker half of a Remote session (iOS `reconcileLocal` and friends), bound as the controller's [RemoteSpeakerHooks]:
 * make THIS device's player play the session's current row at the session's position, with the session's upcoming
 * tail, and keep it there.
 *
 * Cheapest move first: a tail edit when only the upcoming rows changed, `jumpToUpcoming(uid, atMs)` when the session
 * moved onto a row we already hold, a fresh `play(startIndex, atMs, startPaused)` otherwise. Drift (750 ms; 2000 ms on a
 * coarse Apple Music clock) is corrected after 2 consecutive strikes with a 5 s cooldown, never while buffering; a
 * position change that arrives with a NEW revision is a session seek, applied at once. A system pause sets
 * `pausedHere`: the speaker follows the session SILENTLY and is never resumed by the app, only by ▶ or Rejoin.
 *
 * The listener's own actions on the local player are read first ([RemoteLocalChanges]) so reconciling never reverts them.
 * Single-threaded (Main), re-entrancy guarded: a command sent from inside a pass can reach this on the host.
 */
class RemoteReconciler(
    private val controller: RemoteSessionController,
    private val target: RemotePlaybackTarget,
    private val clock: SharedClock,
    private val resolutionCache: RemoteResolutionCache = RemoteResolutionCache(controller.resolver),
    private val now: () -> Double = { clock.localNow() },
    private val log: (String) -> Unit = { NPLog.lane(NPLog.REMOTE, it) },
) : RemoteSpeakerHooks {
    val local = RemoteLocalChanges(controller, target, clock, now, log)

    private var lastDriftFixAt = Double.NEGATIVE_INFINITY
    private var driftStrikes = 0

    /** A new revision arrived: a position difference past the threshold is a session SEEK, applied at once. */
    private var seekOwed = false
    private var stateReceivedAt = Double.NEGATIVE_INFINITY
    private var lastPlayApply: Pair<Boolean, Double>? = null
    private var reportedUnavailable: Set<String>? = null
    private var isReconciling = false

    /** `rejoin` is driving the reconcile: the system hold is lifted for this pass. */
    private var rejoining = false

    // ---- RemoteSpeakerHooks ----

    override fun onAttach() { reset() }
    override fun onEnd() { reset() }

    override fun onRoleChanged(role: RemoteDeviceRole) {
        local.expected = null
        local.heldAfterEnd = null
        if (role == RemoteDeviceRole.SPEAKER) local.locallyFailed.clear()
        reportedUnavailable = null
    }

    override fun onWindowChanged() {
        // Keep the cache bounded to the live window (rows leave it as the set advances).
        val s = controller.state.value ?: return
        val live = s.rowIds.toHashSet()
        resolutionCache.retainOnly(live)
        if (local.locallyFailed.size > 500) local.locallyFailed.retainAll(live)
        pruneRidMapIfLarge()
    }

    override fun onStructuralState() {
        seekOwed = true
        stateReceivedAt = now()
    }

    override fun rejoin() {
        rejoining = true
        try {
            lastPlayApply = null
            reconcile()
        } finally {
            rejoining = false
        }
    }

    private fun reset() {
        local.reset()
        resolutionCache.clear()
        lastDriftFixAt = Double.NEGATIVE_INFINITY
        driftStrikes = 0
        seekOwed = false
        stateReceivedAt = Double.NEGATIVE_INFINITY
        lastPlayApply = null
        reportedUnavailable = null
        rejoining = false
    }

    /** `ridByUid` only grows (replaced rows leave stale uids): rebuild it from the rows still near the playhead. */
    private fun pruneRidMapIfLarge() {
        val map = controller.ridByUid
        if (map.size <= RemoteTuning.TAIL_LIMIT * 10) return
        val lo = maxOf(0, target.currentIndex - RemoteQueueModel.WINDOW_BEHIND * 2)
        val hi = minOf(target.queueCount, target.currentIndex + 1 + RemoteTuning.TAIL_LIMIT * 2)
        val kept = HashMap<String, String>()
        for (i in lo until hi) { val u = target.item(i).uid; map[u]?.let { kept[u] = it } }
        if (controller.isHost) for (r in controller.model.rows) if (map[r.rid] != null) kept[r.rid] = r.rid
        map.clear()
        map.putAll(kept)
    }

    // ---- Reconcile ----

    override fun reconcile() {
        if (isReconciling) return
        isReconciling = true
        try { reconcileLocked() } finally { isReconciling = false }
    }

    private fun active() = controller.isActive.value && controller.localRole.value == RemoteDeviceRole.SPEAKER

    private fun reconcileLocked() {
        if (!active() || controller.state.value == null) return
        // The listener's own action FIRST: reconciling before reading it would revert it.
        if (local.expected != null) local.observeAndSend()
        if (!active()) return
        val s = controller.state.value ?: return
        val t = now()
        // A local edit this participant just sent is in flight: don't revert it before the host's answer lands.
        if (local.holdsReconcile(t, s.revision)) return

        val ridByUid = controller.ridByUid
        val rows = s.rows
        val curRel = s.snapshot.index
        val resolutions = resolutionCache.resolve(rows, curRel)
        val available = ArrayList<Pair<String, QueueItem>>()
        val availIdx = HashMap<String, Int>()
        val unavailable = HashSet<String>()
        for ((i, r) in rows.withIndex()) {
            if (r.rid in local.locallyFailed) { unavailable += r.rid; continue }
            val res = resolutions.getOrNull(i) ?: continue // undecided
            val item = res.item
            if (item != null) { availIdx[r.rid] = available.size; available += r.rid to item } else unavailable += r.rid
        }
        reportAvailability(unavailable)

        if (curRel < 0 || curRel >= rows.size) { local.expected = local.observe(); return }
        val sessionRid = rows[curRel].rid
        val sessionPos = s.positionMs(clock.sharedNow ?: s.anchorSharedTime)
        // A row that ended HERE early: hold silent until the session moves (or restarts it).
        local.heldAfterEnd?.let { h ->
            if (sessionRid != h.sessionRid || sessionPos + ReconcileTuning.HELD_RESTART_SLACK_MS < h.sessionPos) local.heldAfterEnd = null
        }
        if (local.heldAfterEnd != null) {
            if (target.isPlaying && !target.isTransitioning) target.setPlaying(false)
            local.expected = local.observe()
            return
        }
        // The row to sound here: the session's current row, or the next one this device can play.
        val desiredRid = (curRel until rows.size).map { rows[it].rid }.firstOrNull { it in availIdx }
        val dIdx = desiredRid?.let { availIdx[it] }
        if (desiredRid == null || dIdx == null) {
            if (target.isPlaying && !target.isTransitioning) target.setPlaying(false)
            local.expected = local.observe()
            return
        }
        val onSessionCurrent = desiredRid == sessionRid
        val desiredPos = if (onSessionCurrent) sessionPos else 0L
        val threshold = if (target.hasCoarsePosition) ReconcileTuning.COARSE_DRIFT_THRESHOLD_MS else ReconcileTuning.DRIFT_THRESHOLD_MS
        // THIS device's system paused it (a call, an unplugged route): never resumed by the app. The speaker follows the
        // session SILENTLY (moves load paused) until the listener's own ▶ / Rejoin.
        val systemHeld = !rejoining && target.isSystemPaused && !target.isPlaying
        val wantPausedHere = systemHeld && s.isPlaying
        if (controller.pausedHere.value != wantPausedHere) controller.setPausedHere(wantPausedHere)

        var moved = false
        val localCurRid = target.currentItem?.let { ridByUid[it.uid] }
        if (localCurRid != desiredRid) {
            val startAt = if (onSessionCurrent && desiredPos > ReconcileTuning.CUE_MIN_MS) desiredPos else 0L
            // A PAUSED session (or a system-held speaker) loads paused: a jump would sound first.
            val hit = if (s.isPlaying && !systemHeld) target.upcomingItems(RemoteTuning.TAIL_LIMIT).firstOrNull { ridByUid[it.uid] == desiredRid } else null
            if (hit != null) {
                target.jumpToUpcoming(hit.uid, startAt)
            } else {
                val items = available.map { it.second.freshInstance() }
                target.play(items, dIdx, startAt, startPaused = !s.isPlaying || systemHeld)
                remap(available.map { it.first }, 0, items)
            }
            moved = true
            seekOwed = false // the start cue carries the position
            driftStrikes = 0
            local.pendingSeekMs = null
        }
        if (target.repeatMode != s.repeatMode) target.setRepeatMode(s.repeatMode)
        // Shuffle: the host re-orders; a participant mirrors the flag (its order follows from the tail sync below).
        // The host's own long local set is never re-shuffled underneath it.
        if (!controller.isHost && target.isRunning && target.shuffleEnabled != s.shuffleEnabled) target.setShuffle(s.shuffleEnabled)
        syncTail(available.subList(dIdx + 1, available.size))

        // ▶/⏸: not while a start / buffering is still settling; an apply that hasn't taken yet is re-issued only after PLAY_RETRY_MS.
        if (!moved && !target.isTransitioning && target.isRunning && target.isPlaying != s.isPlaying && !(s.isPlaying && systemHeld)) {
            val last = lastPlayApply
            val due = last == null || last.first != s.isPlaying || t - last.second >= ReconcileTuning.PLAY_RETRY_MS
            if (due) {
                if (s.isPlaying && onSessionCurrent && abs(target.positionMs - desiredPos) > threshold) {
                    target.seek(desiredPos) // resume AT the session position
                    local.pendingSeekMs = desiredPos
                }
                target.setPlaying(s.isPlaying)
                lastPlayApply = s.isPlaying to t
            }
        }
        // Drift / session seeks: never while buffering, only on the session's own row.
        if (!moved && onSessionCurrent && s.isPlaying && target.isPlaying && !target.isTransitioning) {
            val off = abs(target.positionMs - desiredPos)
            val synced = clock.isSynced && clock.hostId == s.hostId
            if (off > threshold) {
                // A NEW revision (a session seek, a resume) is applied at once, on a synced clock or fresh off the wire;
                // plain drift must persist and respects a cooldown.
                val owed = seekOwed && (synced || t - stateReceivedAt < ReconcileTuning.FRESH_STATE_MS)
                if (synced) driftStrikes += 1
                if (owed || (synced && driftStrikes >= ReconcileTuning.DRIFT_STRIKES_NEEDED && t - lastDriftFixAt >= ReconcileTuning.DRIFT_COOLDOWN_MS)) {
                    target.seek(desiredPos)
                    local.pendingSeekMs = desiredPos
                    lastDriftFixAt = t
                    driftStrikes = 0
                }
            } else {
                driftStrikes = 0
            }
            seekOwed = false
        }
        local.expected = local.observe()
    }

    /**
     * Make the local upcoming tail match [desired]. The local rows that belong to the session are the SEGMENT up to the
     * last rid-mapped one; rows after it (the host's own set beyond the window) are kept: only the segment is edited.
     */
    private fun syncTail(desired: List<Pair<String, QueueItem>>) {
        if (!target.isRunning) return
        val ridByUid = controller.ridByUid
        val localUp = target.upcomingItems(RemoteTuning.TAIL_LIMIT)
        val mappedCount = (localUp.indexOfLast { ridByUid[it.uid] != null }) + 1
        val segment = localUp.take(mappedCount).map { ridByUid[it.uid] }
        val want = desired.map { it.first }
        if (segment == want) return
        if (mappedCount < want.size && want.take(mappedCount) == segment) {
            // The session grew: the new rows go right after the segment.
            val extra = desired.drop(mappedCount).map { it.second.freshInstance() }
            val at = target.currentIndex + 1 + mappedCount
            if (mappedCount < localUp.size) target.insertUpcoming(extra, localUp[mappedCount].uid) else target.appendToQueue(extra)
            remap(want.drop(mappedCount), at, extra)
        } else {
            val items = desired.map { it.second.freshInstance() }
            target.replaceUpcoming(mappedCount, items)
            remap(want, target.currentIndex + 1, items)
        }
    }

    /**
     * Bind session rids to the rows the local player now holds, by POSITION (a player may copy rows while stamping
     * editions; position is what it can't change in a synchronous apply).
     */
    private fun remap(rids: List<String>, start: Int, expecting: List<QueueItem>) {
        val map = controller.ridByUid
        for ((k, rid) in rids.withIndex()) {
            val i = start + k
            if (i in 0 until target.queueCount) map[target.item(i).uid] = rid
            else if (k < expecting.size) map[expecting[k].uid] = rid
        }
    }

    private fun reportAvailability(set: Set<String>) {
        controller.setLocalUnavailable(set)
        if (set == reportedUnavailable) return
        reportedUnavailable = set
        controller.post(
            RemoteMessageKind.AVAILABILITY, RemoteAvailability.serializer(),
            RemoteAvailability(set.sorted()), RemoteRecipient.All,
        )
        if (set.isNotEmpty()) log("unavailable on this device: ${set.size} row(s)")
    }

    companion object {
        /** Bind a reconciler to [controller] over [target] (production: RemoteGraph.wire). */
        fun bind(controller: RemoteSessionController, target: RemotePlaybackTarget, clock: SharedClock): RemoteReconciler =
            RemoteReconciler(controller, target, clock).also { controller.speaker = it }
    }
}

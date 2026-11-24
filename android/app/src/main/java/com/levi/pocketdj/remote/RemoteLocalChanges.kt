package com.levi.pocketdj.remote

import com.levi.pocketdj.playback.sequencer.QueueItem
import com.levi.pocketdj.playback.sequencer.RepeatMode
import com.levi.pocketdj.playback.sequencer.TransitionCause

/** One reading of the local player (iOS `LocalObservation`), compared tick to tick to find the LISTENER's own actions. */
data class LocalObservation(
    val isRunning: Boolean,
    val generation: Long,
    val currentUid: String?,
    val upcomingUids: List<String>,
    val isPlaying: Boolean,
    val positionMs: Long,
    val at: Double,
    val repeatMode: RepeatMode,
    val shuffle: Boolean,
    val transitionSeq: Long,
    val userTransitionSeq: Long,
    val lastCause: TransitionCause,
    val playIntentSeq: Long,
    val playIntent: Boolean,
) {
    companion object {
        fun of(target: RemotePlaybackTarget, now: Double, tailLimit: Int = RemoteTuning.TAIL_LIMIT): LocalObservation = LocalObservation(
            isRunning = target.isRunning,
            generation = target.queueGeneration,
            currentUid = target.currentItem?.uid,
            upcomingUids = target.upcomingItems(tailLimit).map { it.uid },
            isPlaying = target.isPlaying,
            positionMs = target.positionMs,
            at = now,
            repeatMode = target.repeatMode,
            shuffle = target.shuffleEnabled,
            transitionSeq = target.transitionSeq,
            userTransitionSeq = target.lastUserTransitionSeq,
            lastCause = target.lastTransitionCause,
            playIntentSeq = target.userPlayIntentSeq,
            playIntent = target.lastUserPlayIntent,
        )
    }
}

object LocalChangeTuning {
    /** A position jump bigger than this between ticks is a user scrub. */
    const val SEEK_DETECT_MS = 3_000L

    /** A local natural end counts as the SESSION's track end only this close to its length. */
    const val NATURAL_END_TOLERANCE_MS = 10_000L

    /** A local edit a participant sent holds reconcile until a newer state (or this timeout). */
    const val PENDING_HOLD_MS = 3_000.0
}

/** A row that ENDED here while the session is still on it (or on the unavailable row it stood in for). */
data class HeldAfterEnd(val rid: String, val sessionRid: String?, val sessionPos: Long)

/**
 * Speaker side, part 2 (iOS `observeLocalChanges` / `automaticTransition` / `queueEditCommands`): only the listener's
 * OWN actions on this device's player become session commands. A cause-tagged transition decides which:
 *
 *  - USER -> a command (skip / jump / restart / a brand-new set);
 *  - NATURAL_END -> `advanced(fromRid)`, but only within 10 s of the session row's end (a shorter local copy holds silent);
 *  - AUTO_SKIP / STALL_HOP / UNPLAYABLE -> "unplayable HERE" (never echoed, the reconciler mirrors AROUND the row);
 *  - REMOTE -> never echoed.
 *
 * A local stop / system pause produces no command ("a local stop never pauses everyone"): only a ▶/⏸ the listener
 * pressed ([RemotePlaybackTarget.userPlayIntentSeq]) does, and only when it disagrees with the session.
 *
 * Owns the observation state the reconciler shares ([expected], [pendingSeekMs], [heldAfterEnd], [locallyFailed], the
 * pending-edit hold). Single-threaded (Main).
 */
class RemoteLocalChanges(
    private val controller: RemoteSessionController,
    private val target: RemotePlaybackTarget,
    private val clock: SharedClock,
    private val now: () -> Double = { clock.localNow() },
    private val log: (String) -> Unit = {},
) {
    /** What the last reconcile left the player looking like; the next observation is diffed against it. */
    var expected: LocalObservation? = null

    /** The position our last seek aimed at: its (possibly late) landing is not a user scrub. */
    var pendingSeekMs: Long? = null
    var heldAfterEnd: HeldAfterEnd? = null

    /** Rows this device's player could not play: treated as unavailable here, never looped back onto. */
    val locallyFailed = HashSet<String>()

    /** A local edit this participant sent is in flight: reconcile waits until a newer state (or [pendingUntil]). */
    var pendingUntil = 0.0; private set
    var pendingBaseRevision = -1; private set
    private var observing = false

    fun reset() {
        expected = null; pendingSeekMs = null; heldAfterEnd = null; locallyFailed.clear()
        pendingUntil = 0.0; pendingBaseRevision = -1
    }

    fun observe(): LocalObservation = LocalObservation.of(target, now())

    /** True while a participant's own edit still shields the player from the (older) session state. */
    fun holdsReconcile(t: Double, stateRevision: Int): Boolean = t < pendingUntil && stateRevision <= pendingBaseRevision

    /** A local row as a command row: the local uid is its rid until the host assigns otherwise. */
    fun localRow(item: QueueItem): RemoteRow {
        controller.ridByUid[item.uid] = item.uid
        return RemoteRow(item.uid, controller.resolver.outboundRow(item))
    }

    /** Diff the player against [expected] and send what the listener did. */
    fun observeAndSend() {
        if (observing) return
        val obs = observe()
        observing = true
        try {
            val exp = expected
            expected = obs
            if (exp == null) return
            val cmds = diff(exp, obs)
            if (cmds.isEmpty()) return
            log("local change -> ${cmds.size} command(s)")
            if (!controller.isHost) {
                pendingUntil = obs.at + LocalChangeTuning.PENDING_HOLD_MS
                pendingBaseRevision = controller.lastRevision
            }
            for (c in cmds) controller.send(c)
        } finally {
            observing = false
        }
    }

    /** The commands one tick's change from [exp] to [obs] means (no sends; mutates the shared hold state). */
    fun diff(exp: LocalObservation, obs: LocalObservation): List<RemoteCommand> {
        val ridByUid = controller.ridByUid
        val cmds = ArrayList<RemoteCommand>()
        val userMoved = obs.userTransitionSeq != exp.userTransitionSeq
        val autoMoved = !userMoved && obs.transitionSeq != exp.transitionSeq
        val expRid = exp.currentUid?.let { ridByUid[it] }
        val cur = obs.currentUid
        val state = controller.state.value

        if (autoMoved) {
            // The player moved BY ITSELF: never the listener's intent.
            cmds += automaticTransition(obs.lastCause, expRid)
        } else if (userMoved && obs.isRunning && cur != null) {
            pendingSeekMs = null
            if (ridByUid[cur] == null) {
                // A brand-new set the listener started here SINCE joining -> the session's set. (A set already playing
                // when we joined never is.)
                val lo = maxOf(0, target.currentIndex - RemoteQueueModel.WINDOW_BEHIND)
                val hi = minOf(target.queueCount, target.currentIndex + 1 + RemoteQueueModel.WINDOW_AHEAD)
                val rows = (lo until hi).map { localRow(target.item(it)) }
                cmds += RemoteCommand.Play(rows, target.currentIndex - lo)
            } else if (cur != exp.currentUid) {
                if (expRid != null && exp.upcomingUids.firstOrNull() == cur) {
                    cmds += RemoteCommand.Advanced(expRid) // a skip (applied once, while still current)
                } else {
                    ridByUid[cur]?.let { cmds += RemoteCommand.JumpTo(it) }
                }
            } else {
                cmds += RemoteCommand.Seek(obs.positionMs) // a restart of the same row
            }
        } else if (obs.isRunning && exp.isRunning && cur != null && cur == exp.currentUid) {
            if (obs.shuffle != exp.shuffle) {
                cmds += RemoteCommand.SetShuffle(obs.shuffle) // the host re-orders; we mirror it
            } else if (obs.generation != exp.generation) {
                cmds += queueEditCommands(exp, obs, target.upcomingItems(RemoteTuning.TAIL_LIMIT))
            }
            if (!target.isTransitioning) {
                val predicted = if (exp.isPlaying) exp.positionMs + (obs.at - exp.at).toLong() else exp.positionMs
                if (kotlin.math.abs(obs.positionMs - predicted) > LocalChangeTuning.SEEK_DETECT_MS) {
                    val ps = pendingSeekMs
                    if (ps != null && kotlin.math.abs(obs.positionMs - ps) <= LocalChangeTuning.SEEK_DETECT_MS) {
                        pendingSeekMs = null // OUR seek landing late
                    } else {
                        cmds += RemoteCommand.Seek(obs.positionMs)
                    }
                }
            }
        }
        // ▶/⏸ the listener pressed (a cascade halt / interruption / stall never counts).
        if (obs.playIntentSeq != exp.playIntentSeq && obs.isRunning && state != null && obs.playIntent != state.isPlaying) {
            cmds += RemoteCommand.SetPlaying(obs.playIntent)
        }
        if (obs.isRunning && obs.repeatMode != exp.repeatMode && obs.repeatMode != state?.repeatMode) {
            cmds += RemoteCommand.SetRepeat(obs.repeatMode)
        }
        return cmds
    }

    /** The local player changed rows on its own ([cause]) away from session row [fromRid]. */
    fun automaticTransition(cause: TransitionCause, fromRid: String?): List<RemoteCommand> {
        pendingSeekMs = null
        when (cause) {
            TransitionCause.USER, TransitionCause.REMOTE -> return emptyList()
            TransitionCause.NATURAL_END -> {
                val s = controller.state.value
                if (fromRid == null || s == null) return emptyList()
                val pos = s.positionMs(clock.sharedNow ?: s.anchorSharedTime)
                val curRow = s.currentRow
                val len = curRow?.row?.lengthMs
                if (curRow?.rid == fromRid && (len == null || pos >= len - LocalChangeTuning.NATURAL_END_TOLERANCE_MS)) {
                    return listOf(RemoteCommand.Advanced(fromRid)) // the row really ended: for everyone
                }
                // Our copy ended early (shorter), or the row we played in place of one we can't play ended: wait
                // silently for the session, never re-mirror the row we just finished.
                heldAfterEnd = HeldAfterEnd(fromRid, curRow?.rid, pos)
                log("local copy ended before the session - holding silent")
                return emptyList()
            }
            TransitionCause.AUTO_SKIP, TransitionCause.STALL_HOP, TransitionCause.UNPLAYABLE -> {
                // This device can't play that row right now: mirror the session AROUND it.
                if (fromRid != null) locallyFailed += fromRid
                return emptyList()
            }
        }
    }

    /** Same current row, queue moved: removals, additions (next / end), and re-orders. */
    fun queueEditCommands(exp: LocalObservation, obs: LocalObservation, upcoming: List<QueueItem>): List<RemoteCommand> {
        val ridByUid = controller.ridByUid
        val cmds = ArrayList<RemoteCommand>()
        val expRids = exp.upcomingUids.mapNotNull { ridByUid[it] }
        val obsKnown = obs.upcomingUids.mapNotNull { ridByUid[it] }
        val obsKnownSet = obsKnown.toSet()
        for (rid in expRids) if (rid !in obsKnownSet) cmds += RemoteCommand.Remove(rid)
        // New local rows (no rid yet): a leading run is "play next", the rest are appends.
        val leading = ArrayList<QueueItem>()
        val trailing = ArrayList<QueueItem>()
        var seenKnown = false
        for (it in upcoming) {
            if (ridByUid[it.uid] != null) { seenKnown = true; continue }
            if (seenKnown) trailing += it else leading += it
        }
        if (expRids.isNotEmpty() && leading.isNotEmpty()) cmds += RemoteCommand.EnqueueNext(leading.map(::localRow))
        else if (leading.isNotEmpty()) trailing.addAll(0, leading)
        if (trailing.isNotEmpty()) cmds += RemoteCommand.Append(trailing.map(::localRow))
        val expSet = expRids.toSet()
        val kept = expRids.filter { it in obsKnownSet }
        if (kept != obsKnown.filter { it in expSet }) cmds += RemoteCommand.Reorder(obsKnown)
        return cmds
    }
}

package com.levi.pocketdj.remote

import kotlin.math.min
import kotlin.math.pow

/**
 * The session's pure decision rules (iOS `RemoteSessionController` statics): who yields when two devices think they
 * host, who takes over when the host leaves, when a joiner re-hellos or self-hosts, how a missed revision is
 * re-requested, and how a state is trimmed to fit the transport. No transport, no clock, no player: unit-testable.
 */
object RemoteTuning {
    const val TICK_INTERVAL_MS = 500L
    const val HEARTBEAT_MS = 2_000.0

    /** No state from any host this long after joining => re-hello (or, alone, host it). */
    const val ELECTION_TIMEOUT_MS = 8_000.0

    /** The host advances on its own when no speaker reported a track end this long past it. */
    const val HOST_ADVANCE_SLACK_MS = 8_000L

    /** A state request that got no answer is re-sent after this, doubling per attempt up to [STATE_REQUEST_MAX_BACKOFF_MS]. */
    const val STATE_REQUEST_RETRY_MS = 2_000.0
    const val STATE_REQUEST_MAX_BACKOFF_MS = 16_000.0

    /** Encoded-state budget (the messenger's payload limit, with headroom). */
    const val MAX_STATE_BYTES = 60_000
    const val MIN_WINDOW_AHEAD = RemoteQueueModel.MIN_WINDOW_AHEAD

    /** The host refills its model from its own local set when the upcoming tail runs this low. */
    const val HOST_REFILL_BELOW = 100
    const val HOST_REFILL_CHUNK = 200

    /** How many local upcoming rows a speaker inspects (>= the session window). */
    const val TAIL_LIMIT = RemoteQueueModel.WINDOW_AHEAD * 2
}

/** What one device claims when it believes it hosts. */
data class HostClaim(val active: Boolean, val revision: Int, val id: String)

object RemoteElection {
    /**
     * Two hosts (a hand-over race / an election that ran while the real host was slow): who yields. Deterministic and
     * SYMMETRIC (exactly one side yields): an ACTIVE session beats an empty one, then the newer revision, then the
     * LOWER id. An empty self-elected host can never wipe a real one.
     */
    fun shouldYield(theirs: HostClaim, mine: HostClaim): Boolean {
        if (theirs.active != mine.active) return theirs.active
        if (theirs.revision != mine.revision) return theirs.revision > mine.revision
        return theirs.id < mine.id
    }

    /** The host left: the lowest remaining id takes over. */
    fun winner(roster: Set<String>): String? = roster.minOrNull()

    enum class JoinerAction { NONE, SELF_HOST, REHELLO }

    /**
     * A joiner with no state yet. Never elects a host over a peer that may simply be slow: it self-hosts only when
     * alone, otherwise re-hellos (a live host answers with its state), no more often than every timeout.
     */
    fun joinerAction(
        hasState: Boolean, now: Double, attachedAt: Double, lastHelloAt: Double,
        roster: Set<String>, localId: String,
    ): JoinerAction {
        if (hasState || now - attachedAt < RemoteTuning.ELECTION_TIMEOUT_MS) return JoinerAction.NONE
        if (roster == setOf(localId)) return JoinerAction.SELF_HOST
        return if (now - lastHelloAt >= RemoteTuning.ELECTION_TIMEOUT_MS) JoinerAction.REHELLO else JoinerAction.NONE
    }

    /** Encoded envelope size on the wire (UTF-8 bytes of the JSON text). */
    fun encodedSize(env: RemoteEnvelope): Int = env.encode().toByteArray(Charsets.UTF_8).size

    /** The state window the wire copy ended up with. */
    class Fitted(val envelope: RemoteEnvelope, val ahead: Int, val behind: Int, val bytes: Int)

    /**
     * Encode a state within [budget] bytes: [build] makes the state for a (behind, ahead) window; the window halves
     * (ahead down to [RemoteTuning.MIN_WINDOW_AHEAD], behind <= ahead / 4) until it fits. A state that still doesn't
     * fit at the minimum window is sent anyway, like iOS (the transport decides).
     */
    fun fitState(budget: Int, build: (behind: Int, ahead: Int) -> RemotePlaybackState): Fitted {
        var ahead = RemoteQueueModel.WINDOW_AHEAD
        var behind = RemoteQueueModel.WINDOW_BEHIND
        fun make(): RemoteEnvelope =
            RemoteEnvelope.make(RemoteMessageKind.STATE, RemotePlaybackState.serializer(), build(behind, ahead))
        var env = make()
        var size = encodedSize(env)
        while (size > budget && ahead > RemoteTuning.MIN_WINDOW_AHEAD) {
            ahead = maxOf(RemoteTuning.MIN_WINDOW_AHEAD, ahead / 2)
            behind = min(behind, maxOf(1, ahead / 4))
            env = make()
            size = encodedSize(env)
        }
        return Fitted(env, ahead, behind, size)
    }
}

/**
 * "I asked this host for its state": an unanswered request is retried with backoff (2 s doubling to 16 s) so a lost
 * request or answer never strands a participant, and a flood of heartbeats never floods requests.
 */
class StateRequestTracker {
    private data class Entry(val revision: Int, val at: Double, val attempt: Int)

    private val entries = HashMap<String, Entry>()

    /** True when a request to [host] for [revision] should go out now (and records it). */
    fun shouldSend(host: String, revision: Int, now: Double): Boolean {
        val r = entries[host]
        if (r != null && r.revision >= revision) {
            val wait = min(RemoteTuning.STATE_REQUEST_MAX_BACKOFF_MS, RemoteTuning.STATE_REQUEST_RETRY_MS * 2.0.pow(r.attempt))
            if (now - r.at < wait) return false
            entries[host] = Entry(r.revision, now, r.attempt + 1)
        } else {
            entries[host] = Entry(revision, now, 0)
        }
        return true
    }

    /** The host's state arrived: stop retrying. */
    fun answered(host: String) { entries.remove(host) }

    fun clear() = entries.clear()
}

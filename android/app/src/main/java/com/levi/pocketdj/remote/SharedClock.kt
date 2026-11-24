package com.levi.pocketdj.remote

import java.util.UUID

/**
 * The session's shared timeline: the HOST's clock (iOS `SharedClock`). Every participant estimates its offset
 * to the host NTP-style (ping -> pong) and keeps the best, i.e. LOWEST round-trip, of the last [SAMPLE_CAP]
 * samples (never the average): an asymmetric path's error is bounded by rtt / 2, so the quickest exchange has
 * the tightest bound.
 *
 * One exchange (participant clock P, host clock H): t0 = P at ping send, t1 = H at receipt, t2 = H at pong
 * send, t3 = P at pong receipt. offset = ((t1 - t0) + (t2 - t3)) / 2 (H is about P + offset),
 * rtt = (t3 - t0) - (t2 - t1). The host's own offset is 0 by definition. A host hand-over [reset]s the
 * samples; until a fresh one lands [isSynced] is false (receivers then skip drift corrections, never guess).
 *
 * Not thread-safe: confine to one thread (Main, like the session controller).
 */
class SharedClock(
    /** Local wall clock in epoch ms (injectable: tests skew it per device). */
    val localNow: () -> Double = { System.currentTimeMillis().toDouble() },
) {
    data class Sample(val offsetMs: Double, val rttMs: Double)

    private val _samples = ArrayList<Sample>()
    val samples: List<Sample> get() = _samples

    var isHost: Boolean = false
        private set

    /** The host this clock's samples were measured against. */
    var hostId: String? = null
        private set

    /** Re-base onto a (new) host. The host's own clock IS the shared clock. */
    fun reset(hostId: String?, isHost: Boolean) {
        this.hostId = hostId
        this.isHost = isHost
        _samples.clear()
    }

    /** The best (lowest-RTT; the earliest wins a tie) of the retained samples. */
    val best: Sample? get() = _samples.minByOrNull { it.rttMs }

    val isSynced: Boolean get() = isHost || _samples.isNotEmpty()

    /** Local -> shared offset (ms), null before the first sample. */
    val offsetMs: Double? get() = if (isHost) 0.0 else best?.offsetMs

    /** Shared (host) time now, null until synced. */
    val sharedNow: Double? get() = offsetMs?.let { localNow() + it }

    /** A shared-clock instant -> this device's local clock. */
    fun localTime(forShared: Double): Double? = offsetMs?.let { forShared - it }

    fun makePing(): RemotePing = RemotePing(UUID.randomUUID().toString(), localNow())

    /** Host side: answer a ping (t1 = receipt, t2 = send). */
    fun pong(ping: RemotePing): RemotePong {
        val t = localNow()
        return RemotePong(ping.id, ping.t0, t, localNow())
    }

    /** Participant side: fold a pong in, only against the host we're measuring. */
    fun ingest(pong: RemotePong, sender: String) {
        if (isHost || sender != hostId) return
        ingest(sample(pong.t0, pong.t1, pong.t2, localNow()))
    }

    fun ingest(s: Sample) {
        _samples.add(s)
        while (_samples.size > SAMPLE_CAP) _samples.removeAt(0)
    }

    companion object {
        const val SAMPLE_CAP = 8

        /** The offset math for one exchange (pure). */
        fun sample(t0: Double, t1: Double, t2: Double, t3: Double) =
            Sample(offsetMs = ((t1 - t0) + (t2 - t3)) / 2, rttMs = maxOf(0.0, (t3 - t0) - (t2 - t1)))
    }
}

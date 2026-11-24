package com.levi.pocketdj.remote

import kotlinx.coroutines.flow.Flow
import kotlinx.coroutines.flow.StateFlow

/** Who a message goes to. [Participant] carries a transport participant id. (iOS `RemoteRecipient`.) */
sealed interface RemoteRecipient {
    data object All : RemoteRecipient
    data class Participant(val id: String) : RemoteRecipient
}

/** One received message: the envelope plus the SENDER's participant id. */
data class RemoteInbound(val envelope: RemoteEnvelope, val from: String)

/**
 * The session transport, abstracted so the controller never touches Nearby/etc. directly. Real
 * transports and [LoopbackTransport] (unit tests + the showcase seed) implement it. Messages never loop back
 * to the sender.
 *
 * Threading: call [send]/[leave] from the one thread that owns the session (Main in the app).
 */
interface RemoteTransport {
    /** This device's participant id: stable for the session, comparable across devices (hand-over elects the LOWEST id). */
    val localParticipantId: String

    /** Every message other participants send to us (or to all). Completes when the session ends or we leave. */
    /** Single-collector contract: each message goes to exactly one collector (a second collector steals messages rather than seeing a copy). */
    val inbound: Flow<RemoteInbound>

    /** The ACTIVE participant set (including the local one); a new value on every join/leave, empty once ended. */
    val participants: StateFlow<Set<String>>

    /** Largest encoded envelope a `state` message may occupy on this transport, so the host can trim its window. */
    val maxStateBytes: Int

    /** `reliable = false` is best-effort delivery (clock pings: a stale ping is worse than none). */
    fun send(envelope: RemoteEnvelope, to: RemoteRecipient, reliable: Boolean)

    /** Leave the session (other participants carry on). */
    fun leave()
}

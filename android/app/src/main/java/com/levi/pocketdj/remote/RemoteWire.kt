package com.levi.pocketdj.remote

import com.levi.pocketdj.data.PdjJson
import com.levi.pocketdj.playback.durable.SessionRow
import com.levi.pocketdj.playback.durable.SessionSnapshot
import com.levi.pocketdj.playback.sequencer.RepeatMode
import kotlinx.serialization.KSerializer
import kotlinx.serialization.SerialName
import kotlinx.serialization.Serializable
import java.util.Base64
import java.util.UUID

/**
 * The Remote (Listen Together / Backseat) wire format, byte-compatible with iOS `RemoteWire.swift`.
 *
 * Every message rides ONE versioned envelope `{"v":1,"kind":"<kind>","payload":"<base64 of the body JSON>"}`.
 * `kind` is an open string: a receiver that doesn't know a kind, or sees `v` above [RemoteWire.VERSION],
 * IGNORES the message; a body that fails to decode is dropped, never fatal. Song identity crosses devices as
 * ids + title/artist (+ the Apple Music store id); never a rip URL, presigned link or token.
 *
 * Numbers: times are epoch-ms Doubles. Swift prints `5000000.0` as `5000000`; Kotlin prints `5000000.0`.
 * Both decoders read either, so the formats interoperate, but the text is not character-identical.
 */
object RemoteWire {
    /** The envelope version this build speaks. */
    const val VERSION = 1

    internal val json get() = PdjJson.lenient
}

/** The two flavours of session; rides every state broadcast. */
@Serializable
enum class RemoteSessionMode(val title: String) {
    @SerialName("listenTogether") LISTEN_TOGETHER("Listen Together"),

    /** The starter's phone is a remote control (no local audio); the joiner is the speaker. */
    @SerialName("backseat") BACKSEAT("Backseat"),
}

/** What THIS device does in the session. */
@Serializable
enum class RemoteDeviceRole {
    @SerialName("speaker") SPEAKER,
    @SerialName("controller") CONTROLLER,
}

/** Known message kinds; the wire carries [wire]. */
enum class RemoteMessageKind(val wire: String) {
    HELLO("hello"),
    STATE("state"),
    HEARTBEAT("heartbeat"),
    STATE_REQUEST("stateRequest"),
    COMMAND("command"),
    PING("ping"),
    PONG("pong"),
    AVAILABILITY("availability");

    companion object {
        fun fromWire(s: String): RemoteMessageKind? = entries.firstOrNull { it.wire == s }
    }
}

/** The versioned envelope. [payload] is standard (padded) base64 of the body JSON, Swift's default `Data` strategy. */
@Serializable
data class RemoteEnvelope(val v: Int, val kind: String, val payload: String) {
    /** The known kind, or null (unknown kind / newer envelope), in which case the receiver ignores it. */
    val knownKind: RemoteMessageKind?
        get() = if (v > RemoteWire.VERSION) null else RemoteMessageKind.fromWire(kind)

    /** Decode the body, or null when the base64 or the JSON is bad (the message is dropped). */
    fun <T> decode(serializer: KSerializer<T>): T? = try {
        val bytes = Base64.getDecoder().decode(payload)
        RemoteWire.json.decodeFromString(serializer, String(bytes, Charsets.UTF_8))
    } catch (_: Exception) {
        null
    }

    /** The JSON text of this envelope, as it goes on the wire. */
    fun encode(): String = RemoteWire.json.encodeToString(serializer(), this)

    companion object {
        fun <T> make(kind: RemoteMessageKind, serializer: KSerializer<T>, body: T): RemoteEnvelope =
            RemoteEnvelope(
                RemoteWire.VERSION, kind.wire,
                Base64.getEncoder().encodeToString(
                    RemoteWire.json.encodeToString(serializer, body).toByteArray(Charsets.UTF_8),
                ),
            )

        /** Parse a wire envelope; null for garbage. */
        fun parse(text: String): RemoteEnvelope? = try {
            RemoteWire.json.decodeFromString(serializer(), text)
        } catch (_: Exception) {
            null
        }
    }
}

/**
 * One queue row on the wire: the durable-session row plus a HOST-ASSIGNED per-instance id ([rid]); commands
 * address rows by rid, never by songId or a racy index.
 */
@Serializable
data class RemoteRow(val rid: String = UUID.randomUUID().toString(), val row: SessionRow) {
    val songId: String get() = row.songId
    val title: String get() = row.title
    val artist: String get() = row.artist
}

/**
 * The host's authoritative state. [snapshot] is the durable snapshot verbatim, but its queue is a WINDOW:
 * [windowStart] is the absolute index of `snapshot.queue[0]`, `snapshot.index` is RELATIVE to the window and
 * `rowIds[i]` is `snapshot.queue[i]`'s rid.
 */
@Serializable
data class RemotePlaybackState(
    /** Monotonic, host-assigned. Receivers apply structure only from a NEWER revision. */
    val revision: Int,
    val hostId: String,
    val mode: RemoteSessionMode,
    val snapshot: SessionSnapshot,
    val rowIds: List<String>,
    val windowStart: Int,
    val totalCount: Int,
    /** `snapshot.positionMs` was true at THIS shared-clock time (ms on the host's clock). */
    val anchorSharedTime: Double,
    /** Absent (an older build) means derived from the rows. */
    val sessionActive: Boolean? = null,
) {
    val isActiveSession: Boolean get() = sessionActive ?: rowIds.isNotEmpty()

    val rows: List<RemoteRow> get() = rowIds.zip(snapshot.queue).map { (rid, row) -> RemoteRow(rid, row) }

    val currentRow: RemoteRow?
        get() {
            val i = snapshot.index
            if (i < 0 || i >= snapshot.queue.size || i >= rowIds.size) return null
            return RemoteRow(rowIds[i], snapshot.queue[i])
        }

    val isPlaying: Boolean get() = snapshot.isPlaying
    val repeatMode: RepeatMode get() = RepeatMode.fromToken(snapshot.repeatMode)
    val shuffleEnabled: Boolean get() = snapshot.shuffleEnabled ?: false

    /** Song-relative position at shared time [sharedNow]. */
    fun positionMs(sharedNow: Double): Long {
        if (!snapshot.isPlaying) return snapshot.positionMs
        return maxOf(0L, snapshot.positionMs + roundAway(sharedNow - anchorSharedTime))
    }
}

/** Swift `Double.rounded()` (half away from zero) to a Long. */
internal fun roundAway(x: Double): Long = if (x < 0) -Math.round(-x) else Math.round(x)

/** The host's small periodic beat: enough to keep the position anchor fresh and notice a MISSED revision. */
@Serializable
data class RemoteHeartbeat(
    val revision: Int,
    val hostId: String,
    val currentRid: String? = null,
    val positionMs: Long,
    val isPlaying: Boolean,
    val anchorSharedTime: Double,
    val sessionActive: Boolean,
)

/** "Send me your full state"; the revision the requester holds (-1 means none). */
@Serializable
data class RemoteStateRequest(val haveRevision: Int)

@Serializable
data class RemoteCommandMessage(
    val id: String = UUID.randomUUID().toString(),
    @Serializable(with = RemoteCommandSerializer::class) val command: RemoteCommand,
)

@Serializable
data class RemoteHello(
    val name: String,
    val role: RemoteDeviceRole,
    val platform: String,
    /** What this build can do beyond Phase 1 (`"mix"` marks a deck-owner build). */
    val caps: List<String>? = null,
)

/** "These rows can't play on this device". */
@Serializable
data class RemoteAvailability(val unavailableRids: List<String>)

@Serializable
data class RemotePing(val id: String, val t0: Double)

@Serializable
data class RemotePong(val id: String, val t0: Double, val t1: Double, val t2: Double)

/** A transport/queue command. Participants send these to the host. */
sealed interface RemoteCommand {
    data class Play(val rows: List<RemoteRow>, val startIndex: Int) : RemoteCommand
    data class PlayNow(val rows: List<RemoteRow>) : RemoteCommand
    data object PlayPause : RemoteCommand
    data class SetPlaying(val on: Boolean) : RemoteCommand
    data class Seek(val ms: Long) : RemoteCommand
    data object SkipNext : RemoteCommand
    data object SkipPrevious : RemoteCommand
    data class JumpTo(val rid: String) : RemoteCommand
    data class EnqueueNext(val rows: List<RemoteRow>) : RemoteCommand
    data class Append(val rows: List<RemoteRow>) : RemoteCommand
    data class Remove(val rid: String) : RemoteCommand
    data class Move(val rid: String, val toUpcomingOffset: Int) : RemoteCommand
    data class Reorder(val rids: List<String>) : RemoteCommand
    data class SetRepeat(val mode: RepeatMode) : RemoteCommand
    data class SetShuffle(val on: Boolean) : RemoteCommand
    data class Advanced(val fromRid: String) : RemoteCommand
}

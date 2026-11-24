package com.levi.pocketdj.playback.durable

import com.levi.pocketdj.data.PdjJson
import com.levi.pocketdj.playback.PlayContext
import com.levi.pocketdj.playback.sequencer.PlanTag
import com.levi.pocketdj.playback.sequencer.QueueItem
import com.levi.pocketdj.playback.sequencer.RepeatMode
import kotlinx.serialization.Serializable
import kotlinx.serialization.Transient
import kotlinx.serialization.json.JsonObject
import kotlinx.serialization.json.jsonObject

/** Version stamp on the persisted snapshot. A mismatched file simply does not restore (never migrated). */
const val PLAYBACK_SESSION_SCHEMA_VERSION = 1

/** File name under `filesDir` (iOS: Application Support `pocketdj-playback-session.json`). */
const val PLAYBACK_SESSION_FILE = "pocketdj-playback-session.json"

/** The run's origin collection (`kind` is a PlayContext source token; `originKind/originId` the navigable origin). */
@Serializable
data class SessionSourceRef(
    val kind: String,
    val id: String? = null,
    val name: String? = null,
    val originKind: String? = null,
    val originId: String? = null,
    @Transient val unknownKeys: JsonObject = JsonObject(emptyMap()),
)

/** One queue row: self-contained (title/artist/length ride the file) so a restore needs no catalog. */
@Serializable
data class SessionRow(
    val songId: String,
    val title: String,
    val artist: String = "",
    val lengthMs: Long? = null,
    val repeatCount: Int? = null,
    val variant: String? = null,
    val editionLocked: Boolean? = null,
    /**
     * Android-only (Q29): the storage id the row was actually playing (an edition id). iOS Codable ignores
     * the key; absent in old / iOS files -> the restorer re-runs the edition decider.
     */
    val resolveId: String? = null,
    /** Android-only (Q94): clean-only explicit row with no clean cut; iOS ignores it. */
    val cleanOnlySkip: Boolean? = null,
    /** iOS Pocket Wheel run provenance (`Row.plan`); carried, not yet applied (P2-POC). */
    val plan: SessionPlanTag? = null,
    /** iOS: the Apple Music store id on REMOTE rows only; never written by the session. */
    val appleMusicId: String? = null,
    /** iOS DJ Mode: the listener's next-up pick. */
    val djUserNext: Boolean? = null,
    /** iOS LEGACY (1.0.5 betas), read-only: maps to the pick only on the row after current. Never newly written. */
    val djPlaced: Boolean? = null,
    /** Row keys this build does not model (a newer iOS build's); re-emitted verbatim on encode. */
    @Transient val unknownKeys: JsonObject = JsonObject(emptyMap()),
)

/** iOS `StemLockState` (`stemLock` omitted when the lock is off). */
@Serializable
data class SessionStemLock(
    val enabled: Boolean = false,
    val stemsOn: Boolean = false,
    val muted: List<String> = emptyList(),
    val volumes: Map<String, Double> = emptyMap(),
    @Transient val unknownKeys: JsonObject = JsonObject(emptyMap()),
)

/** The iOS `PlaybackSessionStore.Snapshot` JSON shape. */
@Serializable
data class SessionSnapshot(
    val schemaVersion: Int = PLAYBACK_SESSION_SCHEMA_VERSION,
    val sessionId: String,
    val source: SessionSourceRef,
    val queue: List<SessionRow>,
    val index: Int,
    /** Position within the CURRENT song, ms from the song's own 0:00. */
    val positionMs: Long = 0,
    val isPlaying: Boolean = false,
    val repeatMode: String? = null,
    val shuffleEnabled: Boolean? = null,
    val stemLock: SessionStemLock? = null,
    /** Epoch ms of the last write (informational). */
    val updatedAt: Double = 0.0,
    /** iOS 1.0.4+: Now Playing Mix Mode flag (absent = off). Restored HELD. */
    val npMixMode: SessionNpMixMode? = null,
    /** iOS 1.0.4+: FX Lock + the effects it carries (absent = lock off). */
    val fxLock: SessionFxLock? = null,
    /** iOS 1.0.5+: DJ Mode + the selector's raw planner state (absent = off). Restored HELD. */
    val djMode: SessionDjMode? = null,
    /** Top-level keys this build does not model (a newer iOS build's); re-emitted verbatim on encode. */
    @Transient val unknownKeys: JsonObject = JsonObject(emptyMap()),
) {
    /** The restorable queue with FRESH uids (a uid is per-instance identity, never durable). */
    fun toQueueItems(redecide: ((QueueItem) -> QueueItem)? = null): List<QueueItem> = queue.mapIndexed { i, it ->
        val locked = it.editionLocked ?: false
        val item = QueueItem(
            id = it.songId,
            title = it.title,
            artist = it.artist.ifEmpty { null },
            lengthMs = it.lengthMs,
            repeatCount = it.repeatCount,
            variant = it.variant,
            editionLocked = locked,
            // The persisted id wins (the exact edition that was playing). Absent: a locked row (the decider
            // never touches it) keeps the iOS id convention; any other row is re-decided below.
            resolveId = it.resolveId ?: if (it.variant != null && (locked || redecide == null)) variantStorageId(it.songId, it.variant) else it.songId,
            cleanOnlySkip = it.cleanOnlySkip ?: false,
            plan = it.plan?.let { p -> PlanTag(p.runId, p.slot, p.collectionId, p.score, p.pinned) },
            // iOS parity: the next-up pick is only ever the row right after the current one (the legacy djPlaced maps the same way).
            djUserNext = i == index + 1 && (it.djUserNext ?: it.djPlaced ?: false),
        )
        if (it.resolveId == null && !locked && redecide != null) {
            // Old / iOS file: forget the (unreliable) variant and let the decider say what plays now.
            redecide(item.copy(variant = null))
        } else {
            item
        }
    }

    fun toContext(): PlayContext =
        PlayContext(source.kind, contextId = source.id, contextName = source.name)

    fun toOrigin(): Pair<String, String>? {
        val k = source.originKind ?: return null
        val i = source.originId ?: return null
        return k to i
    }

    fun repeat(): RepeatMode = RepeatMode.fromToken(repeatMode)

    companion object {
        /** iOS edition id convention: `sng_x` + variant -> `sng_x_clean`. */
        fun variantStorageId(songId: String, variant: String): String =
            com.levi.pocketdj.data.edition.SongVariant.entries.firstOrNull { it.raw == variant }
                ?.let { com.levi.pocketdj.data.edition.SongVariant.variantId(songId, it) } ?: songId

        fun row(q: QueueItem) = SessionRow(
            songId = q.id,
            title = q.title,
            artist = q.artist ?: "",
            lengthMs = q.lengthMs,
            repeatCount = q.repeatCount,
            variant = q.variant,
            editionLocked = if (q.editionLocked) true else null,
            resolveId = q.resolveId,
            cleanOnlySkip = if (q.cleanOnlySkip) true else null,
            plan = q.plan?.let { SessionPlanTag(it.runId, it.slot, it.collectionId, it.score, it.pinned) },
            djUserNext = if (q.djUserNext) true else null,
        )

        fun encode(s: SessionSnapshot): String {
            val typed = PdjJson.lenient.encodeToJsonElement(serializer(), s).jsonObject
            return PdjJson.lenient.encodeToString(JsonObject.serializer(), SnapshotCodec.merge(s, typed))
        }

        /**
         * LENIENT: any decode failure, a schema-version mismatch or an empty queue -> null. Never throws,
         * never blocks launch.
         */
        fun decode(text: String): SessionSnapshot? {
            val snap = try {
                val root = PdjJson.lenient.parseToJsonElement(text).jsonObject
                SnapshotCodec.attach(PdjJson.lenient.decodeFromJsonElement(serializer(), root), root)
            } catch (_: Exception) {
                return null
            }
            if (snap.schemaVersion != PLAYBACK_SESSION_SCHEMA_VERSION || snap.queue.isEmpty()) return null
            return snap
        }
    }
}

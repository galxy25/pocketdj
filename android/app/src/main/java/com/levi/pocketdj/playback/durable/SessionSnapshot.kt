package com.levi.pocketdj.playback.durable

import com.levi.pocketdj.data.PdjJson
import com.levi.pocketdj.playback.PlayContext
import com.levi.pocketdj.playback.sequencer.QueueItem
import com.levi.pocketdj.playback.sequencer.RepeatMode
import kotlinx.serialization.Serializable

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
)

/** iOS `StemLockState` (`stemLock` omitted when the lock is off). */
@Serializable
data class SessionStemLock(
    val enabled: Boolean = false,
    val stemsOn: Boolean = false,
    val muted: List<String> = emptyList(),
    val volumes: Map<String, Double> = emptyMap(),
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
) {
    /** The restorable queue with FRESH uids (a uid is per-instance identity, never durable). */
    fun toQueueItems(): List<QueueItem> = queue.map {
        QueueItem(
            id = it.songId,
            title = it.title,
            artist = it.artist.ifEmpty { null },
            lengthMs = it.lengthMs,
            repeatCount = it.repeatCount,
            variant = it.variant,
            editionLocked = it.editionLocked ?: false,
            resolveId = if (it.variant != null) variantStorageId(it.songId, it.variant) else it.songId,
        )
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
        )

        fun encode(s: SessionSnapshot): String = PdjJson.lenient.encodeToString(serializer(), s)

        /**
         * LENIENT: any decode failure, a schema-version mismatch or an empty queue -> null. Never throws,
         * never blocks launch.
         */
        fun decode(text: String): SessionSnapshot? {
            val snap = try {
                PdjJson.lenient.decodeFromString(serializer(), text)
            } catch (_: Exception) {
                return null
            }
            if (snap.schemaVersion != PLAYBACK_SESSION_SCHEMA_VERSION || snap.queue.isEmpty()) return null
            return snap
        }
    }
}

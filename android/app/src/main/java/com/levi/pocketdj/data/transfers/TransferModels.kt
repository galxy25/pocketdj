package com.levi.pocketdj.data.transfers

import kotlinx.serialization.SerialName
import kotlinx.serialization.Serializable

/** iOS `TransferCoordinator.Kind` (raw strings match). */
@Serializable
enum class TransferKind {
    @SerialName("burn") BURN,
    @SerialName("download") DOWNLOAD,
}

/**
 * One persisted in-flight transfer (iOS `TransferRecord`, same field names so a doc written by
 * either platform decodes on the other). Everything the worker needs to finish after a cold
 * relaunch rides here — destination, pre-rendered sidecar, file names — because a worker must
 * read NOTHING from live stores (ARCHITECTURE-APPLE item 18).
 *
 * Additive vs iOS: [workId] (the WorkManager request UUID). [taskIdentifier] is kept as a
 * stable Int hash of the song id for compat.
 */
@Serializable
data class TransferRecord(
    val taskIdentifier: Int = 0,
    val songId: String,
    val kind: TransferKind = TransferKind.BURN,
    val audioFileName: String,
    val sidecarFileName: String = "",
    val sidecarText: String = "",
    /** True => app-private `burns/`; false => a user-picked folder (SAF, later). */
    val wasAppStorage: Boolean = true,
    /** iOS security-scoped bookmark (base64). Unused on Android; kept for doc compat. */
    val burnFolderBookmark: String? = null,
    val expectedBytes: Long? = null,
    val manifestKey: String = "",
    val source: String = "digital",
    val bpm: Double? = null,
    val musicalKey: String? = null,
    val camelot: String? = null,
    val durationMs: Long? = null,
    val startMs: Long? = null,
    val rippedAt: Double? = null,
    val title: String = "",
    val artist: String = "",
    val createdAt: Double = 0.0,
    /** ADDITIVE: WorkManager request id. */
    val workId: String? = null,
)

/** The persisted document (`pocketdj-transfers.json`). */
@Serializable
data class TransferDoc(
    val schemaVersion: Int = 1,
    val tasks: List<TransferRecord> = emptyList(),
)

/** Run-scoped progress (resets on beginRun). */
data class TransferProgress(val enqueued: Int = 0, val finished: Int = 0) {
    val active: Boolean get() = enqueued > 0 && finished < enqueued
}

/** Everything WorkManager needs for one unique burn request. */
data class BurnWorkSpec(
    val uniqueName: String,
    val workId: String,
    val songId: String,
    val url: String,
    val attachBearer: Boolean,
)

/** Collapsed WorkInfo.State. A name missing from the states map means "no such work". */
enum class WorkStateKind {
    ENQUEUED, RUNNING, BLOCKED, SUCCEEDED, FAILED, CANCELLED;

    val live: Boolean get() = this == ENQUEUED || this == RUNNING || this == BLOCKED
}

fun burnUniqueName(songId: String) = "burn:$songId"

/** Stable non-negative Int hash standing in for the iOS URLSession task identifier. */
fun stableTaskId(songId: String): Int = songId.hashCode() and 0x7fffffff

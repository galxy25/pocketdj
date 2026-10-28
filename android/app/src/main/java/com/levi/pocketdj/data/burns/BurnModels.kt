package com.levi.pocketdj.data.burns

import kotlinx.serialization.SerialName
import kotlinx.serialization.Serializable

/** iOS `burnSchemaVersion`. */
const val BURN_SCHEMA_VERSION = 1

/** Per-item lifecycle state; raw values match the iOS `BurnStore.State` strings. */
@Serializable
enum class BurnState {
    @SerialName("queued") QUEUED,
    @SerialName("downloading") DOWNLOADING,
    @SerialName("ready") READY,
    @SerialName("error") ERROR,
}

/**
 * One burned (or attempted) track — the MACHINE-READABLE record (iOS `BurnStore.BurnItem`, same
 * field names so a ledger written by either platform decodes on the other).
 */
@Serializable
data class BurnItem(
    val songId: String,
    val title: String,
    val artist: String,
    /** `<descriptive>-<songId>.mp3` (digital) or `<descriptive>-<albumId>.mp3` (analog, shared). */
    val audioFileName: String,
    val sidecarFileName: String,
    /** "analog" | "digital". */
    val source: String,
    val bpm: Double? = null,
    val musicalKey: String? = null,
    val camelot: String? = null,
    val durationMs: Long? = null,
    /** Analog: the seek offset within the shared album mp3 (null for digital). */
    val startMs: Long? = null,
    val bytes: Long = 0,
    val rippedAt: Double? = null,
    val downloadedAt: Double = 0.0,
    val state: BurnState = BurnState.ERROR,
    val error: String? = null,
    /** Whether the files live in the app-managed root (true/absent) vs a user-picked folder. */
    val wasAppStorage: Boolean? = null,
    /** ANALOG per-song cut export file name (null => none). */
    val cutFileName: String? = null,
    /** S3 Last-Modified epoch-ms of the cut at download (drives the auto-repull). */
    val cutDownloadedAt: Double? = null,
) {
    val isReady: Boolean get() = state == BurnState.READY
}

/** The persisted, versioned ledger document (iOS `BurnStore.Document`). */
@Serializable
data class BurnDocument(
    val schemaVersion: Int = BURN_SCHEMA_VERSION,
    val items: List<BurnItem> = emptyList(),
    val pendingAfterRip: List<PendingBurn>? = null,
)

/** A download requested before the song existed as a file (survives restarts). */
@Serializable
data class PendingBurn(
    val songId: String,
    val title: String,
    val artist: String,
    val requestedAtMs: Double,
)

/** Input to a burn run (iOS `(id:, title:, artist:)` tuple). */
data class BurnSong(val id: String, val title: String, val artist: String)

/** Bulk progress for the collection UI. */
data class BurnProgress(val done: Int, val total: Int, val label: String)

/** Outcome of a [BurnStore.burn] run, for the partial-success summary. */
data class BurnResult(
    val burned: Int = 0,
    val notRipped: Int = 0,
    val failed: Int = 0,
    val total: Int = 0,
    val outOfSpace: Boolean = false,
    val folderUnavailable: Boolean = false,
    val stopped: Boolean = false,
    val stemmedSongs: Int = 0,
    val beatGridded: Int = 0,
)

data class ArtistUsage(val artist: String, val songIds: List<String>, val bytes: Long)

/** Soft-cap prune plan (iOS `EvictionPlan`). */
data class EvictionPlan(val usageBytes: Long, val projectedBytes: Long, val evict: List<String>)

/** A resolved playback file; [isCut] means the standalone per-song cut (do NOT apply startMs). */
data class CutResolved(val file: java.io.File, val isCut: Boolean)

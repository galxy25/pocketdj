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
    /** SAF tree the user-folder copy was mirrored into at finalize (null => app storage / unknown). */
    val treeUri: String? = null,
) {
    val isReady: Boolean get() = state == BurnState.READY
}

/** The persisted, versioned ledger document (iOS `BurnStore.Document`). */
@Serializable
data class BurnDocument(
    val schemaVersion: Int = BURN_SCHEMA_VERSION,
    val items: List<BurnItem> = emptyList(),
    val pendingAfterRip: List<PendingBurn>? = null,
    /**
     * Assets the BUFFER lane created (iOS `Document.temporaryHolds`). ADDITIVE-OPTIONAL, per device,
     * never synced: absent/null decodes with NO holds, i.e. everything on the device stays pinned.
     */
    val temporaryHolds: List<TemporaryHold>? = null,
)

/**
 * TEMPORARY HOLD (iOS `BurnStore.TemporaryHold`): the assets of ONE song id the buffer lane
 * downloaded on its own. Only what the lane CREATED is listed; the expiry sweep deletes exactly
 * these. ABSENCE OF A HOLD = PINNED. Same field names as iOS.
 */
@Serializable
data class TemporaryHold(
    val songId: String,
    /** The burned audio (ledger row + sidecar) was created by the buffer lane. */
    val audio: Boolean = false,
    val stemParts: List<String> = emptyList(),
    /** Reserved: a cache analog cut played via the prefetched-cut seam. */
    val cutFile: String? = null,
    val createdAtMs: Double,
    /** FIXED at landing: createdAtMs + TTL; a later asset for the same song only moves it LATER. */
    val expiresAtMs: Double,
    val audioBytes: Long? = null,
    val stemBytes: Map<String, Long>? = null,
    /** Stem parts written to the user-picked folder (the rest live in app storage). */
    val stemPartsInUserFolder: List<String>? = null,
    /** The user-picked folder the user-folder assets were written to. */
    val userFolderPath: String? = null,
    /** File name -> modification time (epoch ms) when the buffer lane wrote it. */
    val userFolderFiles: Map<String, Double>? = null,
) {
    /** Bytes this hold accounts for (cap planning reads the ledger, never the disk). */
    val bytes: Long
        get() = (if (audio) audioBytes ?: 0L else 0L) + stemParts.sumOf { stemBytes?.get(it) ?: 0L }
    val isEmpty: Boolean get() = !audio && stemParts.isEmpty() && cutFile == null
}

/** Who is asking for an asset (iOS `BurnStore.AssetOrigin`). */
sealed class AssetOrigin {
    /** An EXPLICIT Download / Mix / stem action; [reason] is the log label. Pins what it touches. */
    data class Explicit(val reason: String) : AssetOrigin()
    /** The buffer lane (speculative prefetch): creates a temporary hold for what it creates. */
    data object Buffer : AssetOrigin()
    /** Neither: legacy permanent behaviour, no pin, no hold. */
    data object Incidental : AssetOrigin()

    val isExplicit: Boolean get() = this is Explicit

    /** Join rule: explicit wins; incidental (permanent) beats buffer (temporary). */
    fun merged(other: AssetOrigin): AssetOrigin = when {
        this is Explicit -> this
        other is Explicit -> other
        this == Incidental || other == Incidental -> Incidental
        else -> Buffer
    }

    companion object {
        fun explicit(reason: String): AssetOrigin = Explicit(reason)
    }
}

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
    /** SVC-14: a chosen user folder was unreachable, so this run wrote to app storage. */
    val fellBack: Boolean = false,
    val stopped: Boolean = false,
    val stemmedSongs: Int = 0,
    val beatGridded: Int = 0,
    /** SVC-3: songs handed to background transfers (also counted in [burned]). */
    val queued: Int = 0,
)

data class ArtistUsage(val artist: String, val songIds: List<String>, val bytes: Long)

/** Soft-cap prune plan (iOS `EvictionPlan`). */
data class EvictionPlan(
    val usageBytes: Long,
    val projectedBytes: Long,
    val evict: List<String>,
    /** Bytes of orphan stem/grid files swept BEFORE planning (usageBytes is measured after the sweep). */
    val sweptBytes: Long = 0L,
    /** Bytes each planned eviction frees (sidecar, cut, shared-aware audio, stems, grid). */
    val freedById: Map<String, Long> = emptyMap(),
)

/** A resolved playback file; [isCut] means the standalone per-song cut (do NOT apply startMs). */
data class CutResolved(val file: java.io.File, val isCut: Boolean)

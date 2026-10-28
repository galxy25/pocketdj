package com.levi.pocketdj.data.rips

import com.levi.pocketdj.data.config.Endpoints
import kotlinx.serialization.Serializable

/**
 * One rips-manifest entry (specs/playback.md §2.2).
 *
 * Iron law: the server adds fields continually (stems, beat grids, lyrics all
 * arrived later) — every field except `key` is optional-with-default and unknown
 * fields are ignored, or the next server deploy breaks playback.
 */
@Serializable
data class RipManifestEntry(
    /** REQUIRED — S3 object key ("rips/<albumId or songId>.mp3"), consumed verbatim. */
    val key: String,
    val ext: String? = null,
    /** "analog" | "digital". */
    val source: String? = null,
    val albumId: String? = null,
    /** ANALOG only: the song's offset inside the shared ALBUM mp3. */
    val startMs: Long? = null,
    /** Song length; null possible (older analog rips have no end boundary). */
    val durationMs: Long? = null,
    val bpm: Double? = null,
    val musicalKey: String? = null,
    val camelot: String? = null,
    /** Waveform PNG, key relative to the rips base. */
    val waveform: String? = null,
    val analyzed: Boolean? = null,
    /** Epoch-ms; optional on older entries. */
    val rippedAt: Double? = null,
    /** ANALOG burn-export sidecar — NOT for playback. */
    val cutKey: String? = null,
    val cutBytes: Long? = null,
    val cutRippedAt: Double? = null,
    // Beat-grid analysis (mix-analysis indexer). Measured on the burned file the deck opens, so
    // firstDownbeatMs is relative to the song's 0:00; beatGridBpm beats the catalog BPM.
    val firstBeatMs: Long? = null,
    val firstDownbeatMs: Long? = null,
    val beatGridBpm: Double? = null,
    val beatsPerBar: Int? = null,
    val tempoConfidence: Double? = null,
    val tempoVar: Double? = null,
    /** Gates whether single-ratio sync holds. */
    val steady: Boolean? = null,
    /** Lazy per-beat sidecar key (rips/analysis/<id>.json). */
    val beatgrid: String? = null,
    val analysisVersion: Int? = null,
    // Demucs stems. Presence of [stemVersion] (SINGULAR, the canonical writer spelling) => stemmed.
    val stems: RipStems? = null,
    val stemModel: String? = null,
    val stemVersion: Int? = null,
    val stemFormat: String? = null,
    val stemmedAt: Double? = null,
    val stemBytes: Long? = null,
    // Cloud timed lyrics: sidecar KEY (rips/lyrics/<songId>.json); presence => transcribed.
    val lyrics: String? = null,
    val lyricsModel: String? = null,
    val lyricsVersion: Int? = null,
) {
    val isStemmed: Boolean get() = stemVersion != null

    /** Non-blank beat-grid sidecar key, or null. */
    val beatgridKey: String? get() = beatgrid?.takeIf { it.isNotBlank() }

    /** Non-blank lyrics sidecar key, or null. */
    val lyricsKey: String? get() = lyrics?.takeIf { it.isNotBlank() }

    /**
     * Public stem URLs (vocals/drums/bass/other) built off [ripsBase]; null when not stemmed.
     * Keys are stored explicitly, so the URL is format-correct (mp3 vs flac) with no derivation.
     */
    fun stemUrls(ripsBase: String = Endpoints.RIPS_BASE): Map<String, String>? {
        val s = stems?.takeIf { it.isComplete } ?: return null
        fun u(key: String) = "${ripsBase.trimEnd('/')}/${key.removePrefix("/")}"
        return linkedMapOf(
            "vocals" to u(s.vocals), "drums" to u(s.drums), "bass" to u(s.bass), "other" to u(s.other),
        )
    }

    fun beatgridUrl(ripsBase: String = Endpoints.RIPS_BASE): String? =
        beatgridKey?.let { "${ripsBase.trimEnd('/')}/${it.removePrefix("/")}" }

    fun lyricsUrl(ripsBase: String = Endpoints.RIPS_BASE): String? =
        lyricsKey?.let { "${ripsBase.trimEnd('/')}/${it.removePrefix("/")}" }
}

/** The 4 Demucs stem S3 keys. */
@Serializable
data class RipStems(
    val vocals: String = "",
    val drums: String = "",
    val bass: String = "",
    val other: String = "",
) {
    /** A partial stems object must not poison the whole-manifest decode; it just isn't usable. */
    val isComplete: Boolean get() = vocals.isNotBlank() && drums.isNotBlank() && bass.isNotBlank() && other.isNotBlank()
}

/** The manifest document: a JSON object keyed by songId. */
typealias RipsManifest = Map<String, RipManifestEntry>

/**
 * A rip job view (specs/playback.md §4.3) — every field except `phase` optional.
 * `/rip` 200 responses decode to this too (`jobId` null + phase "ready" + `url`
 * means already ripped).
 */
@Serializable
data class RipJob(
    val phase: String,
    val jobId: String? = null,
    val songId: String? = null,
    val message: String? = null,
    /** Durable S3 mp3 — set when phase == "ready". */
    val url: String? = null,
    val error: String? = null,
    /** Relative live-HLS path, present once live streaming is available. */
    val streamUrl: String? = null,
    val progress: RipProgress? = null,
) {
    val isReady: Boolean get() = phase == PHASE_READY && url != null

    companion object {
        const val PHASE_READY = "ready"
        const val PHASE_ERROR = "error"
    }
}

@Serializable
data class RipProgress(
    val elapsedMs: Long? = null,
    val totalMs: Long? = null,
    val pct: Double? = null,
    val indeterminate: Boolean? = null,
)

/** `GET /health` response (specs/playback.md §4.2) — all optional, lenient. */
@Serializable
data class RipServerHealth(
    val ok: Boolean = false,
    val host: String? = null,
    val version: Int? = null,
    val hls: Boolean? = null,
    val stems: Boolean? = null,
    val bucket: String? = null,
    val catalog: RipServerCatalogCounts? = null,
    val cached: Int? = null,
    val auth: Boolean? = null,
    val public: Boolean? = null,
)

@Serializable
data class RipServerCatalogCounts(
    val songs: Int? = null,
    val albums: Int? = null,
)

/** One song's outcome from a batch rip (`/rip-collection` result or the per-song fallback). */
@Serializable
data class BatchRipItem(
    val songId: String,
    /** "ready" | "queued" | "inflight" | "unknown". */
    val status: String,
    val jobId: String? = null,
    val url: String? = null,
)

/** Aggregate batch-rip result: per-song outcomes + counts for the partial-success UI. */
data class BatchRipResult(
    val results: List<BatchRipItem> = emptyList(),
    val ready: Int = 0,
    val queued: Int = 0,
    val inflight: Int = 0,
    val unknown: Int = 0,
    val total: Int = 0,
)

/** One song's outcome from `/rip-cancel`: "canceled" | "notFound" | "alreadyDone". */
@Serializable
data class CancelItem(val songId: String, val status: String)

@Serializable
internal data class BatchRipResponse(
    val results: List<BatchRipItem> = emptyList(),
    val counts: BatchCounts = BatchCounts(),
) {
    @Serializable
    data class BatchCounts(
        val ready: Int = 0,
        val queued: Int = 0,
        val inflight: Int = 0,
        val unknown: Int = 0,
        val total: Int = 0,
    )
}

@Serializable
internal data class CancelResponse(val results: List<CancelItem> = emptyList())

/** Outcome of the bounded interactive wait for a rip job. */
sealed interface RipWaitOutcome {
    data class Ready(val url: String) : RipWaitOutcome

    /** The wait expired with the job still working: not a failure, keep tracking it. */
    data class StillRipping(val jobId: String) : RipWaitOutcome
}

object RipPhases {
    private val IN_FLIGHT = setOf("searching", "ripping", "streaming", "uploading")

    /** Map a job phase to the batch bucket: ready / queued / inflight / unknown (null = unknown). */
    fun batchStatus(phase: String?): String = when {
        phase == RipJob.PHASE_READY -> "ready"
        phase == "queued" -> "queued"
        phase != null && phase in IN_FLIGHT -> "inflight"
        else -> "unknown"
    }
}

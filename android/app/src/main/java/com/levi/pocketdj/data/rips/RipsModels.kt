package com.levi.pocketdj.data.rips

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
)

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

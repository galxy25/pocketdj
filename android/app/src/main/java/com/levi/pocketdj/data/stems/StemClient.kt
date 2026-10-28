package com.levi.pocketdj.data.stems

import com.levi.pocketdj.data.rips.PlayResolver
import kotlinx.serialization.SerialName
import kotlinx.serialization.Serializable

/**
 * A Stemify job's phase (iOS `RipsStore.StemPhase`). Its own lifecycle (rip/cut first if needed,
 * then separate), distinct from the rip phase string because the server emits `stemming` and
 * `ineligible`.
 */
@Serializable
enum class StemPhase {
    @SerialName("queued") QUEUED,
    @SerialName("ripping") RIPPING,
    @SerialName("stemming") STEMMING,
    @SerialName("ready") READY,
    @SerialName("error") ERROR,
    @SerialName("ineligible") INELIGIBLE,
}

/** `/stemify` + `/jobs/<id>` response for a stem job. Unknown fields are ignored. */
@Serializable
data class StemJob(
    val phase: StemPhase,
    val jobId: String? = null,
    val songId: String? = null,
    val error: String? = null,
    /** Only CUSTOM (uploaded-audio) jobs carry their keys here. */
    val stems: Map<String, String>? = null,
    val stemFormat: String? = null,
)

/** One song's outcome from `/stemify-collection`. */
@Serializable
data class BatchStemItem(val songId: String, val status: String, val jobId: String? = null)

/** Aggregate collection-stemify result. [needsConfirm] = the server's over-cap envelope. */
data class BatchStemResult(
    val results: List<BatchStemItem> = emptyList(),
    val ready: Int = 0,
    val queued: Int = 0,
    val inflight: Int = 0,
    val ripping: Int = 0,
    val needsCut: Int = 0,
    val ineligible: Int = 0,
    val unknown: Int = 0,
    val total: Int = 0,
    val needsConfirm: Boolean = false,
    val count: Int = 0,
    val cap: Int = 0,
    /** True only when /stemify-collection itself answered (not the per-song fallback). */
    val viaBatch: Boolean = false,
) {
    /** Songs still going (queued/inflight/ripping/needing a cut). */
    val pending: Int get() = queued + inflight + ripping + needsCut
}

@Serializable
internal data class BatchStemResponse(
    val results: List<BatchStemItem> = emptyList(),
    val counts: Counts = Counts(),
    val needsConfirm: Boolean? = null,
    val count: Int? = null,
    val cap: Int? = null,
) {
    @Serializable
    data class Counts(
        val ready: Int = 0,
        val queued: Int = 0,
        val inflight: Int = 0,
        val ripping: Int = 0,
        val needsCut: Int = 0,
        val ineligible: Int = 0,
        val unknown: Int = 0,
        val total: Int = 0,
    )
}

/** Pure Stemify rules (the network lives in RipServerClient, the polling in RipJobTracker). */
object StemClient {
    /** Phases that mean a stem job is already working. */
    val IN_FLIGHT: Set<StemPhase> = setOf(StemPhase.QUEUED, StemPhase.RIPPING, StemPhase.STEMMING)

    /** Terminal for the poll: stops on ready (after a manifest refresh), error, ineligible. */
    fun isTerminal(phase: StemPhase): Boolean =
        phase == StemPhase.READY || phase == StemPhase.ERROR || phase == StemPhase.INELIGIBLE

    /** Studio ids (and "Pocket DJ" pdj_ ids) NEVER stem: the server would rip-first a garbage title. */
    fun isFenced(songId: String): Boolean = PlayResolver.isStudioId(songId) || songId.startsWith("pdj_")

    /**
     * The three idempotency layers + fence + server gate: should a single-song stemify hit the
     * network at all?
     */
    fun shouldRequest(
        songId: String,
        isStemmed: Boolean,
        currentPhase: StemPhase?,
        requesting: Boolean,
        hasServer: Boolean,
    ): Boolean = !isFenced(songId) && !isStemmed && (currentPhase == null || currentPhase !in IN_FLIGHT) &&
        !requesting && hasServer

    /** Row label while a stem job works; null when idle/terminal (iOS stemPhaseLabel). */
    fun phaseLabel(phase: StemPhase?): String? = when (phase) {
        StemPhase.QUEUED -> "Queued…"
        StemPhase.RIPPING -> "Ripping first…"
        StemPhase.STEMMING -> "Stemming…"
        else -> null
    }

    /** Fallback count synthesis: a job phase -> the collection status vocabulary. */
    fun batchStatus(phase: StemPhase?): String = when (phase) {
        StemPhase.READY -> "ready"
        StemPhase.QUEUED, StemPhase.STEMMING -> "queued"
        StemPhase.RIPPING -> "ripping"
        StemPhase.INELIGIBLE -> "ineligible"
        else -> "unknown"
    }

    /** Collection summary line (iOS runStemify). */
    fun summary(r: BatchStemResult): String {
        val pending = r.pending
        val parts = buildList {
            if (r.ready > 0) add("${r.ready} already stemmed")
            if (r.ripping > 0) add("${r.ripping} ripping first")
            if (pending - r.ripping > 0) add("${pending - r.ripping} stemming — completes over time")
            if (r.ineligible > 0) add("${r.ineligible} can’t be stemmed")
            if (r.unknown > 0) add("${r.unknown} unknown")
        }
        return if (parts.isEmpty()) "Nothing to stemify." else parts.joinToString(" · ")
    }

    fun progressLabel(done: Int, total: Int): String? =
        if (total - done > 0) "stemming — $done of $total done" else null

    fun progressSummary(done: Int, total: Int): String =
        if (total - done > 0) "Stemming $done of $total — completes over time" else "Stemmed $total of $total"

    fun batchResult(counts: Map<String, Int>, items: List<BatchStemItem>): BatchStemResult = BatchStemResult(
        results = items,
        ready = counts["ready"] ?: 0, queued = counts["queued"] ?: 0,
        ripping = counts["ripping"] ?: 0, ineligible = counts["ineligible"] ?: 0,
        unknown = counts["unknown"] ?: 0, total = items.size,
    )
}

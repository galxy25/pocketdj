package com.levi.pocketdj.mix.download

/**
 * Why the Mix's rip/burn lanes can't make progress (iOS `CollectionMixDownloader.LaneIssue`). The
 * "K ripping" count alone was a lie in the 2026-10-30 iPad session: every `/rip-collection` and
 * presign answered 401 (the device had no token) yet the bar sat on "404 of 418 ... 4 ripping"
 * forever. Surfaces read this to say what is actually wrong; the lanes keep retrying on a backoff
 * underneath.
 */
sealed interface LaneIssue {
    /** 401/403 - this device's import-server token is missing or wrong. */
    data object TokenRejected : LaneIssue

    /** Songs need a rip but no import server is configured on this device. */
    data object NoServer : LaneIssue

    /** The server refused the rip batch with a non-auth status (5xx, ...); [status] is [TRANSPORT_FAILURE] when unreachable. */
    data class RipServerRefused(val status: Int) : LaneIssue

    /** The batch was accepted but nothing flipped ready for the stall window; re-requested. */
    data object RipsStalled : LaneIssue

    /** The "Play in Now Playing" fallback is offered when the lanes can NEVER fetch audio without user action. */
    val offersNowPlayingFallback: Boolean get() = this == TokenRejected || this == NoServer

    companion object {
        /** `refusedStatus` for a batch that never got an HTTP answer (matches P2-LIB-1's `RipAuthState.TRANSPORT_FAILURE`). */
        const val TRANSPORT_FAILURE = -1

        /** The import-server copy shared with the Rip/Burn bar (P2-LIB-1). */
        const val TOKEN_REJECTED_COPY = "The import server rejected this device’s token (Settings ▸ Import server)"

        /** Classify a refused batch: 401/403 is a credential fault, anything else a server refusal. */
        fun ofRefusal(status: Int): LaneIssue =
            if (status == 401 || status == 403) TokenRejected else RipServerRefused(status)

        /**
         * Honest bar copy for the rip-pending count (pure): "- 4 ripping" only when the server
         * actually has them; otherwise what is really in the way.
         */
        fun rippingLabel(count: Int, issue: LaneIssue?): String? {
            if (count <= 0) return if (issue == TokenRejected) "· import server rejected this device’s token" else null
            return when (issue) {
                TokenRejected -> "· $count can’t rip — import server rejected this device’s token"
                NoServer -> "· $count need an import server to rip"
                is RipServerRefused ->
                    if (issue.status == TRANSPORT_FAILURE) "· $count waiting — can’t reach the import server, retrying"
                    else "· $count waiting — import server error ${issue.status}, retrying"
                RipsStalled -> "· $count ripping (stalled — re-requested)"
                null -> "· $count ripping"
            }
        }

        /** Honest shortfall copy (pure): "still loading" only while the catalog actually is. */
        fun shortfallCaption(declared: Int, total: Int, stillLoading: Boolean): String =
            if (stillLoading) "Only $total of $declared songs available on this device — catalog still loading"
            else "${declared - total} of $declared crate songs aren’t in this device’s catalog — a source may be missing or disabled"

        /** Refused-batch retry backoff in poll ticks: base * 2^(attempt-1), capped. */
        fun ripRetryDelayTicks(attempt: Int, base: Int, cap: Int): Int {
            val a = attempt.coerceIn(1, 16)
            return minOf(cap.toLong(), base.toLong() shl (a - 1)).toInt()
        }
    }
}

/** What a rip-collection request came back with (the downloader's view of `BatchRipResult.refusedStatus`). */
data class RipBatchOutcome(val refusedStatus: Int? = null) {
    val refused: Boolean get() = refusedStatus != null
    val unauthorized: Boolean get() = refusedStatus == 401 || refusedStatus == 403
}

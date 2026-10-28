package com.levi.pocketdj.data.rips

/** Tunables for the rip client, mirroring the iOS RipsStore constants. */
object RipSettings {
    /** Interactive ▶ wait: a queued rip must surface StillRipping, never park the UI. */
    const val INTERACTIVE_WAIT_MS = 20_000L

    /** Poll cadence of the interactive wait. */
    const val INTERACTIVE_POLL_MS = 1_000L

    /** Per-request timeout for one /jobs/<id> poll. */
    const val JOB_POLL_TIMEOUT_MS = 10_000L

    /** Background pollToReady cadence and cap (2 s x 1800 = 1 h). */
    const val TRACKER_POLL_MS = 2_000L
    const val TRACKER_MAX_TRIES = 1_800

    /** Prefetched presigned URLs are minted with a 6 h TTL and trusted for 5 h. */
    const val PREFETCH_TTL_SECONDS = 21_600
    const val PREFETCH_USABLE_MS = 5L * 3600 * 1000

    /** Consecutive poll failures that abort the interactive wait. */
    const val MAX_POLL_FAILURES = 10
}

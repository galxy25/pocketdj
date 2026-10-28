package com.levi.pocketdj.data.rips

/**
 * The play-time interactive wait for an un-ripped song (iOS `RipsStore` interactive wait):
 * bounded wait, then either play the ready URL or hand the job to [RipJobTracker]
 * ("Still ripping…"). [isCurrent] is the ownership guard: if the user started something else
 * meanwhile, a landed rip only refreshes the manifest and never replaces what is playing.
 */
class RipPlayWait(
    private val awaitReady: suspend (jobId: String) -> RipWaitOutcome,
    private val refreshManifest: suspend () -> Unit,
    private val presignedUrl: suspend (songId: String) -> String?,
    private val tracker: RipJobTracker?,
) {
    sealed interface Result {
        data class Play(val url: String) : Result
        data object StillRipping : Result
        data object Superseded : Result
    }

    suspend fun run(songId: String, jobId: String, isCurrent: () -> Boolean): Result =
        when (val outcome = awaitReady(jobId)) {
            is RipWaitOutcome.Ready -> {
                runCatching { refreshManifest() }
                if (isCurrent()) Result.Play(presignedUrl(songId) ?: outcome.url) else Result.Superseded
            }
            is RipWaitOutcome.StillRipping -> {
                tracker?.pollToReady(songId, outcome.jobId)
                Result.StillRipping
            }
        }
}

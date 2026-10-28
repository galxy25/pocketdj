package com.levi.pocketdj.data.rips

/**
 * iOS `RipsStore.ripCollection` / `cancelCollection` side effects on top of the raw
 * [RipServerClient] calls: a user-requested rip is protected from the playback rip window,
 * queued/inflight results show a phase label (adopted into the tracker) and keep polling to
 * ready; a cancel drops the rows, the protection and the polls.
 */
class RipCollectionCoordinator(
    private val tracker: RipJobTracker,
    private val ripCollectionCall: suspend (List<String>, (String) -> Boolean) -> BatchRipResult,
    private val cancelCall: suspend (List<String>) -> List<CancelItem>,
) {
    constructor(client: RipServerClient, tracker: RipJobTracker) :
        this(tracker, { ids, isRipped -> client.ripCollection(ids, isRipped) }, { client.cancelRips(it) })

    suspend fun ripCollection(songIds: List<String>, isRipped: (String) -> Boolean = { false }): BatchRipResult {
        val ids = songIds.distinct()
        tracker.markUserRequested(ids)
        val result = ripCollectionCall(ids, isRipped)
        for (item in result.results) {
            if (item.status != "queued" && item.status != "inflight") continue
            val jobId = item.jobId ?: continue
            tracker.adopt(item.songId, RipJob(phase = if (item.status == "queued") "queued" else "ripping", jobId = jobId, songId = item.songId))
            tracker.pollToReady(item.songId, jobId)
        }
        return result
    }

    suspend fun cancelRips(songIds: List<String>): List<CancelItem> {
        val results = cancelCall(songIds)
        tracker.cancel(results.filter { it.status == "canceled" }.map { it.songId })
        return results
    }
}

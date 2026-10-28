package com.levi.pocketdj.playback.sequencer

/** A burned / studio file on this device that can play instead of a stream. */
data class LocalFile(
    val url: String,
    /** Song window inside a shared file; null = whole file. */
    val startMs: Long? = null,
    val endMs: Long? = null,
)

/**
 * Seam for the local-file rung (iOS `BurnStore.localURLForPlayback`). The burn store (SVC-4)
 * supplies the real one; until then [None] keeps device mode honest (nothing resolves).
 */
fun interface LocalFileResolver {
    fun localUrlForPlayback(item: QueueItem): LocalFile?

    companion object {
        val None = LocalFileResolver { null }
    }
}

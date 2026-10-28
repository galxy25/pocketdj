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

/**
 * Maps a burn-store hit to a playable [LocalFile]: a per-song cut plays from 0:00 (no window);
 * a shared analog album file plays the song's `[startMs, startMs + durationMs)` window.
 */
fun burnedLocalFile(
    file: java.io.File,
    isCut: Boolean,
    startMs: Long?,
    durationMs: Long?,
    // Production passes android.net.Uri.fromFile(..).toString(): the hand-rolled form left ExoPlayer
    // never signalling STATE_ENDED on the emulator, so the set stalled after the first burned row.
    toUri: (java.io.File) -> String = { "file://" + it.toURI().rawPath },
): LocalFile {
    val start = if (isCut) null else startMs
    val end = if (start != null && durationMs != null) start + durationMs else null
    return LocalFile(toUri(file), start, end)
}

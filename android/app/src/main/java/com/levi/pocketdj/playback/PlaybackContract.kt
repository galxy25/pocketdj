package com.levi.pocketdj.playback

/**
 * Keys for the `MediaItem.RequestMetadata.extras` bundle that travels from the
 * [PlaybackController] to the [PlaybackService].
 *
 * Media3 does not guarantee `localConfiguration` (the URI) or clipping survive
 * the controller → session hop, so the controller encodes everything needed to
 * (re)build a playable item into request-metadata extras and the service's
 * `onAddMediaItems` rebuilds URI + ClippingConfiguration from them.
 */
object PlaybackContract {
    /** Resolved stream URL (public rips-bucket mp3, or a live HLS playlist). */
    const val EXTRA_URL = "pdj.url"

    /** Clip window (analog songs inside a shared album mp3); -1 = unset. */
    const val EXTRA_CLIP_START_MS = "pdj.clipStartMs"
    const val EXTRA_CLIP_END_MS = "pdj.clipEndMs"

    /** History context (specs/history.md §4): source token + optional context. */
    const val EXTRA_SOURCE = "pdj.playSource"
    const val EXTRA_CONTEXT_ID = "pdj.contextId"
    const val EXTRA_CONTEXT_NAME = "pdj.contextName"

    /** Owning album id, for Now Playing surfaces. */
    const val EXTRA_ALBUM_ID = "pdj.albumId"

    /** Marker for the "/hls/" live path (unseekable — disable the scrubber). */
    const val EXTRA_IS_LIVE = "pdj.isLive"

    /** Marker for a 30-second Apple Music preview (badge it; cap the scrubber). */
    const val EXTRA_IS_PREVIEW = "pdj.isPreview"
}

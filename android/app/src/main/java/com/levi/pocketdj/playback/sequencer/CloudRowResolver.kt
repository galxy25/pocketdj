package com.levi.pocketdj.playback.sequencer

import com.levi.pocketdj.data.rips.PlayResolver

/**
 * A row with no manifest rip and no device file in a CLOUD run: it is loaded straight away as a
 * `pdj-resolve://song/<id>` item (metadata on the card, honestly BUFFERING) and the service-side
 * [com.levi.pocketdj.playback.session.ResolvingSongDataSource] does the `POST /rip`: the live HLS stream when the
 * server offers one, else the durable mp3 once it lands. iOS: the `RipRequired` rung inside `playCurrent`.
 */
data class RipOnDemandSource(val songId: String) : RowSource {
    /** Backend label for `[playback] track start` / the dead-air pair; the live swap relabels it `hls`. */
    override val backend: String get() = "rip"

    companion object {
        const val SCHEME = "pdj-resolve"
        const val HOST = "song"

        /** `pdj-resolve://song/<id>` (the id is path-encoded). */
        fun uriFor(songId: String): String = "$SCHEME://$HOST/${java.net.URLEncoder.encode(songId, "UTF-8").replace("+", "%20")}"

        /** Inverse of [uriFor]; null for any other uri. */
        fun songIdFrom(uri: String): String? {
            val prefix = "$SCHEME://$HOST/"
            if (!uri.startsWith(prefix)) return null
            return java.net.URLDecoder.decode(uri.removePrefix(prefix), "UTF-8").takeIf { it.isNotEmpty() }
        }
    }
}

/**
 * Last rung of the cloud ladder (PB-3): a rip-required row. Only when the run is CLOUD, a rip server is
 * configured, and the id is not a device-local studio id (never sent to /rip). Earlier rungs (local file,
 * manifest) already declined, so a hit here means the song genuinely needs ripping.
 */
class CloudRowResolver : RowSourceResolver {
    override val id: String = "cloud-rip-on-demand"
    override val rung: Rung = Rung.RIP_ON_DEMAND

    override suspend fun resolve(item: QueueItem, ctx: ResolveContext): RowSource? {
        if (!ctx.ripServerConfigured) return null
        // Game rows never queue a /rip (a 30 s preview rides the game rung; ripping fills the Mac queue).
        if (item.runTag != null) return null
        if (PlayResolver.isStudioId(item.id) || PlayResolver.isStudioId(item.resolveId)) return null
        return RipOnDemandSource(item.resolveId)
    }
}

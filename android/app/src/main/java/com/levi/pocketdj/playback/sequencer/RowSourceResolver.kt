package com.levi.pocketdj.playback.sequencer

import com.levi.pocketdj.data.rips.PlayAction
import com.levi.pocketdj.data.rips.PlayResolver
import com.levi.pocketdj.data.rips.RipManifestEntry
import com.levi.pocketdj.playback.PlaybackMode

/** Where one queue row's audio comes from. Open interface: later packages add implementers. */
interface RowSource {
    /** Short backend label for the `[playback] track start ... backend=` line. */
    val backend: String
}

/** A burned / studio file on this device. */
data class LocalFileSource(val file: LocalFile) : RowSource {
    override val backend: String get() = "burned"
}

/** A manifest rip stream (public mp3 + optional analog clip window). */
data class StreamSource(val action: PlayAction.Stream) : RowSource {
    override val backend: String get() = "rip"
}

/** Nothing can play this row here; the sequencer advances ([AdvanceCause.UNPLAYABLE_HERE]). */
data class UnplayableSource(val reason: Reason) : RowSource {
    enum class Reason { STUDIO_LOCAL, METADATA_ONLY, NOT_ON_DEVICE }
    override val backend: String get() = "none"
}

/** Ladder ordering. Lower runs first. */
enum class Rung(val order: Int) {
    LOCAL_FILE(0),
    STUDIO_LOCAL(10),
    MANIFEST(20),
    APPLE_MUSIC(30),
    RIP_ON_DEMAND(40),
    FALLBACK(100),
}

/**
 * What a resolver may consult. [ripStartsNow] = a manifest rip exists for the row so streaming
 * starts instantly (iOS `ripStartsNow`): an Apple Music rung should then defer unless the row is
 * Apple-Music-sourced.
 */
data class ResolveContext(
    val mode: PlaybackMode,
    val ripServerConfigured: Boolean,
    val ripStartsNow: Boolean,
)

/**
 * One rung of the per-row resolve ladder. Return null to pass the row to the next rung. Resolution
 * happens FRESH at the row's turn (a rip may have landed, a burn purged, since the queue was built).
 */
interface RowSourceResolver {
    val id: String
    val rung: Rung
    suspend fun resolve(item: QueueItem, ctx: ResolveContext): RowSource?
}

/** Rung 1: the burned / local file seam. */
class LocalFileRowResolver(private val files: LocalFileResolver) : RowSourceResolver {
    override val id: String = "local-file"
    override val rung: Rung = Rung.LOCAL_FILE
    override suspend fun resolve(item: QueueItem, ctx: ResolveContext): RowSource? =
        files.localUrlForPlayback(item)?.let(::LocalFileSource)
}

/**
 * Default rung: the rips manifest (public mp3 + analog clip window; instant). Studio ids are fenced
 * (never sent to /rip, never streamed): they resolve only through a registered STUDIO_LOCAL rung.
 */
class ManifestRowResolver(private val entry: (String) -> RipManifestEntry?) : RowSourceResolver {
    override val id: String = "manifest"
    override val rung: Rung = Rung.MANIFEST
    override suspend fun resolve(item: QueueItem, ctx: ResolveContext): RowSource? {
        if (PlayResolver.isStudioId(item.id)) {
            return UnplayableSource(UnplayableSource.Reason.STUDIO_LOCAL)
        }
        val action = PlayResolver.resolve(item.resolveId, entry(item.resolveId), ripServerConfigured = false)
        return (action as? PlayAction.Stream)?.let(::StreamSource)
    }
}

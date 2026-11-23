package com.levi.pocketdj.playback.sequencer

import java.io.File
import kotlinx.coroutines.CoroutineDispatcher
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.withContext

/**
 * What the burn store can say about one song, decoupled from [com.levi.pocketdj.data.burns.BurnStore]
 * so the burned-first policy is a pure function (and JVM-testable without a ledger on disk).
 */
data class BurnedHit(
    val file: File,
    /** Standalone per-song cut (plays from 0:00; the album window must NOT be applied). */
    val isCut: Boolean,
    val startMs: Long?,
    val durationMs: Long?,
)

/** The burn store's view for one storage id; null = not burned (or the file vanished). */
fun interface BurnLookup {
    fun burned(songId: String): BurnedHit?
}

/**
 * Burned-first rung (iOS `BurnStore.localURLForPlayback` consulted before any stream): a READY burn
 * wins on every song-start path, with or without a manifest entry or rip server. Implements the
 * [LocalFileResolver] seam (so `PlaybackController` and the sequencer's LOCAL_FILE rung share it)
 * and is also a registrable [RowSourceResolver].
 *
 * Resolves by the row's STORAGE id ([QueueItem.resolveId]) so an edition variant finds its own cut.
 */
class BurnedRowResolver(
    /** The ladder rung resolves here; the synchronous [localUrlForPlayback] seam stays caller-threaded. */
    private val io: CoroutineDispatcher = Dispatchers.IO,
    private val lookup: BurnLookup,
) : LocalFileResolver, RowSourceResolver {
    override val id: String = "burned-first"
    override val rung: Rung = Rung.LOCAL_FILE

    override fun localUrlForPlayback(item: QueueItem): LocalFile? {
        val hit = lookup.burned(item.resolveId) ?: return null
        return burnedLocalFile(hit.file, hit.isCut, hit.startMs, hit.durationMs)
    }

    override suspend fun resolve(item: QueueItem, ctx: ResolveContext): RowSource? =
        withContext(io) { localUrlForPlayback(item) }?.let(::LocalFileSource)

    companion object {
        /**
         * Adapter for a `BurnStore`-shaped source. [playbackFile] is `BurnStore.localUrlForPlayback`: the SHARED side
         * file plus the song's window (never the per-song cut, which is a burn-export sidecar and, being cut at the
         * catalog length, ends analog songs early). The cut-preferring lookup stays for Mix/Studio only.
         */
        fun from(
            playbackFile: (String) -> File?,
            startMs: (String) -> Long?,
            durationMs: (String) -> Long?,
        ): BurnedRowResolver = BurnedRowResolver { id ->
            playbackFile(id)?.let { BurnedHit(it, isCut = false, startMs = startMs(id), durationMs = durationMs(id)) }
        }
    }
}

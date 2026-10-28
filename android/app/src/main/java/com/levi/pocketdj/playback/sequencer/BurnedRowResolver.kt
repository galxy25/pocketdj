package com.levi.pocketdj.playback.sequencer

import com.levi.pocketdj.data.burns.CutResolved
import java.io.File

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
class BurnedRowResolver(private val lookup: BurnLookup) : LocalFileResolver, RowSourceResolver {
    override val id: String = "burned-first"
    override val rung: Rung = Rung.LOCAL_FILE

    override fun localUrlForPlayback(item: QueueItem): LocalFile? {
        val hit = lookup.burned(item.resolveId) ?: return null
        return burnedLocalFile(hit.file, hit.isCut, hit.startMs, hit.durationMs)
    }

    override suspend fun resolve(item: QueueItem, ctx: ResolveContext): RowSource? =
        localUrlForPlayback(item)?.let(::LocalFileSource)

    companion object {
        /** Adapter for a `BurnStore`-shaped source. */
        fun from(
            preferringCut: (String) -> CutResolved?,
            startMs: (String) -> Long?,
            durationMs: (String) -> Long?,
        ): BurnedRowResolver = BurnedRowResolver { id ->
            preferringCut(id)?.let { BurnedHit(it.file, it.isCut, startMs(id), durationMs(id)) }
        }
    }
}

/**
 * Pure device-mode queue plan (the sequencer applies the same rule row by row at its turn): which
 * rows would play, and whether the run is dead on arrival (the one-shot banner case).
 */
object DeviceQueuePlan {
    sealed interface Outcome {
        /** [playable] keeps queue order; [skipped] are the un-burned rows device mode passes over. */
        data class Plays(val playable: List<QueueItem>, val skipped: List<QueueItem>) : Outcome

        /** Nothing in the queue is on this device: raise the banner ONCE and play nothing. */
        data object AllUnplayable : Outcome
    }

    fun plan(queue: List<QueueItem>, isBurned: (QueueItem) -> Boolean): Outcome {
        val (ok, skipped) = queue.partition(isBurned)
        return if (ok.isEmpty()) Outcome.AllUnplayable else Outcome.Plays(ok, skipped)
    }
}

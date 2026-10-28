package com.levi.pocketdj.playback.sequencer

import com.levi.pocketdj.playback.PlaybackMode
import java.util.concurrent.CopyOnWriteArrayList
import kotlin.coroutines.cancellation.CancellationException

/**
 * Aggregates the per-row [RowSourceResolver]s and walks them in [Rung] order (ties keep
 * registration order). Packages register their rung from their own sidecar graph: burned-first
 * (SVC-4), studio-local (STU-7), Apple Music (PB-8), cloud / rip-on-demand (PB-3). The default
 * ladder is local-file seam -> manifest.
 *
 * Device mode consults ONLY the local rungs (`LOCAL_FILE`, `STUDIO_LOCAL`): a row with no on-device
 * file is [UnplayableSource.Reason.NOT_ON_DEVICE].
 *
 * Deliberately NO 30 s preview rung: inside a run a preview would advance the set every 30 s.
 */
class RowResolverRegistry(
    initial: List<RowSourceResolver> = emptyList(),
    /** True when a manifest rip exists for the id (the `ripStartsNow` input). */
    private val manifestHit: (String) -> Boolean = { false },
    private val ripServerConfigured: () -> Boolean = { false },
) {
    private val resolvers = CopyOnWriteArrayList<RowSourceResolver>()

    init {
        initial.forEach(::register)
    }

    fun register(resolver: RowSourceResolver) {
        require(resolvers.none { it.id == resolver.id }) { "Duplicate row resolver id ${resolver.id}" }
        resolvers.add(resolver)
    }

    /** The ladder in the order it is walked. */
    fun ladder(): List<RowSourceResolver> = resolvers.sortedBy { it.rung.order }

    suspend fun resolve(item: QueueItem, mode: PlaybackMode): RowSource {
        val ctx = ResolveContext(
            mode = mode,
            ripServerConfigured = ripServerConfigured(),
            ripStartsNow = manifestHit(item.resolveId),
        )
        for (r in ladder()) {
            if (mode == PlaybackMode.DEVICE && r.rung != Rung.LOCAL_FILE && r.rung != Rung.STUDIO_LOCAL) continue
            val hit = try {
                r.resolve(item, ctx)
            } catch (e: CancellationException) {
                throw e
            } catch (_: Exception) {
                null // a broken rung passes the row down the ladder, never crashes the set
            }
            if (hit != null) return hit
        }
        return UnplayableSource(
            if (mode == PlaybackMode.DEVICE) UnplayableSource.Reason.NOT_ON_DEVICE
            else UnplayableSource.Reason.METADATA_ONLY,
        )
    }
}

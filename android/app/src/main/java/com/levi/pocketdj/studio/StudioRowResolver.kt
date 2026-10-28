package com.levi.pocketdj.studio

import com.levi.pocketdj.data.rips.PlayResolver
import com.levi.pocketdj.playback.sequencer.LocalFile
import com.levi.pocketdj.playback.sequencer.LocalFileSource
import com.levi.pocketdj.playback.sequencer.QueueItem
import com.levi.pocketdj.playback.sequencer.ResolveContext
import com.levi.pocketdj.playback.sequencer.RowSource
import com.levi.pocketdj.playback.sequencer.RowSourceResolver
import com.levi.pocketdj.playback.sequencer.Rung
import com.levi.pocketdj.studio.store.StudioPlayable

/**
 * The STUDIO_LOCAL rung (iOS `studioResolve`): plays `smp_`/`lp_`/`ptn_`/`tk_` ids as LOCAL files.
 *
 * - Non-studio rows pass (null) to the next rung; a studio row that cannot play here also returns null
 *   so the manifest rung's fence yields the honest `UnplayableSource(STUDIO_LOCAL)` (never a /rip call).
 * - [prepare] runs on demand (bounce a dirty pattern, render a stale sample/take) so the row plays
 *   the moment it is in a collection; device mode consults this rung too (it is local-only).
 */
class StudioRowResolver(
    private val prepare: suspend (String) -> StudioPlayable?,
    private val toUri: (StudioPlayable) -> String = { it.ref.uri },
) : RowSourceResolver {
    override val id: String = "studio-local"
    override val rung: Rung = Rung.STUDIO_LOCAL

    override suspend fun resolve(item: QueueItem, ctx: ResolveContext): RowSource? {
        val sid = studioIdOf(item) ?: return null
        val playable = prepare(sid) ?: return null
        // A studio file plays whole: no clip window (that is an analog-album concept).
        return LocalFileSource(LocalFile(toUri(playable), startMs = null, endMs = null))
    }

    companion object {
        /** The studio id a row carries (id first, then the substituted storage id), or null. */
        fun studioIdOf(item: QueueItem): String? = when {
            PlayResolver.isStudioId(item.id) -> item.id
            PlayResolver.isStudioId(item.resolveId) -> item.resolveId
            else -> null
        }
    }
}

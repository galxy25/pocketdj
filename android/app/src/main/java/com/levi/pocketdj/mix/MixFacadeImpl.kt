package com.levi.pocketdj.mix

import com.levi.pocketdj.mix.model.MixSource as EngineSource
import com.levi.pocketdj.screens.mix.MixAutoStarter
import com.levi.pocketdj.screens.mix.MixSourceNotFoundException
import com.levi.pocketdj.screens.mix.NoLoadableSongsException
import com.levi.pocketdj.shell.MixFacade
import com.levi.pocketdj.shell.MixSource
import com.levi.pocketdj.shell.MixStartResult
import com.levi.pocketdj.shell.ShellActionException
import kotlin.coroutines.CoroutineContext
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.withContext

/**
 * The [MixFacade] the Assistant / shortcuts / deep links drive (iOS `IntentServices.mix` +
 * `MixResolver` + `CollectionMixDownloader`). Delegates to the SAME [MixAutoStarter] the Mix tab uses,
 * so the invariants live once: the collection download run is kicked BEFORE the empty-loadables guard
 * (an unburned crate starts pulling and the mix begins on the first landing), the four Mix settings
 * are pushed before a headless start, and loadables are burned/streamable files only.
 *
 * Pause/resume go through the LOCK-SCREEN seam (`AutoDj.remotePause/remotePlay`) - the only pause that
 * freezes the transition clock. The engine is Main-confined, so every call hops to [engineContext].
 */
class MixFacadeImpl(
    /** Lazy: building the starter builds the engine; a facade that is never used must not. */
    private val starter: () -> MixAutoStarter,
    private val settings: suspend () -> MixSettings,
    private val isAutoMixing: () -> Boolean,
    private val isAutoPaused: () -> Boolean,
    private val remotePause: () -> Unit,
    private val remotePlay: () -> Unit,
    private val engineContext: CoroutineContext = Dispatchers.Main.immediate,
) : MixFacade {
    override val autoMixing: Boolean get() = isAutoMixing()
    override val autoPaused: Boolean get() = isAutoPaused()

    override suspend fun startAutoMix(source: MixSource, shuffle: Boolean, allowPendingStart: Boolean): MixStartResult =
        start(source.toEngine(), null, shuffle, allowPendingStart)

    override suspend fun startAutoMix(
        deckA: MixSource, deckB: MixSource, shuffle: Boolean, allowPendingStart: Boolean,
    ): MixStartResult = start(deckA.toEngine(), deckB.toEngine(), shuffle, allowPendingStart)

    private suspend fun start(a: EngineSource, b: EngineSource?, shuffle: Boolean, allowPendingStart: Boolean): MixStartResult {
        val s = settings()
        return try {
            withContext(engineContext) {
                val out = starter().start(a, b, shuffle, allowPendingStart, s)
                MixStartResult(out.name, out.count)
            }
        } catch (e: NoLoadableSongsException) {
            throw ShellActionException.NoBurnedSongs(e.crateName)
        } catch (e: MixSourceNotFoundException) {
            throw ShellActionException.MixSourceNotFound
        }
    }

    override fun pauseAutoMix() = remotePause()
    override fun resumeAutoMix() = remotePlay()

    companion object {
        fun MixSource.toEngine(): EngineSource = when (this) {
            is MixSource.Pocket -> EngineSource.Pocket(id)
            is MixSource.Playlist -> EngineSource.Playlist(id)
            is MixSource.Setlist -> EngineSource.Setlist(id)
        }
    }
}

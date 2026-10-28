package com.levi.pocketdj.mix.engine

import com.levi.pocketdj.data.burns.BeatGridSidecar
import com.levi.pocketdj.mix.model.Deck
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Job
import kotlinx.coroutines.launch

/**
 * Attaches a song's full per-beat grid to the deck's [com.levi.pocketdj.mix.model.LoadedTrack] so the
 * beat pulse can phase-lock to the real beats and a beat loop walks the real lattice (iOS
 * `hydrateBeatGrid` / `setBeatPulseEnabled`).
 *
 *  - A LOCAL (burned) sidecar attaches synchronously, with no network and regardless of the pulse flag.
 *  - Otherwise the sidecar is downloaded in the background ONLY when the pulse is enabled (or [force]:
 *    engaging a loop needs real beats now) - pulse OFF + no sidecar => no download, ever.
 *  - The patch is songId-guarded: a deck that moved on while the download ran is left alone.
 *  - [onHydrated] fires after an async patch so a loop armed on synthesized beats can re-resolve.
 */
class BeatGridHydrator(
    private val core: EngineCore,
    private val localGrid: (String) -> BeatGridSidecar?,
    private val download: suspend (String) -> BeatGridSidecar?,
    private val scope: CoroutineScope,
) {
    /** Mirrors the Mix beat-pulse setting (pushed from the view). */
    var beatPulseEnabled = false; private set

    /** After an ASYNC patch landed (the loop controller re-resolves its window). */
    var onHydrated: ((Deck) -> Unit)? = null

    private val inFlight = HashMap<Deck, Job>()

    /** Turning the pulse ON hydrates whatever is already loaded; OFF only stops fetching on load. */
    fun setBeatPulseEnabled(on: Boolean) {
        beatPulseEnabled = on
        if (!on) return
        for (d in Deck.entries) core.deckState(d).loaded?.let { hydrate(d, it.songId) }
    }

    /** Cancel a deck's pending download (a new track / eject). */
    fun cancel(deck: Deck) { inFlight.remove(deck)?.cancel() }

    fun hydrate(deck: Deck, songId: String, force: Boolean = false) {
        if (core.deckState(deck).loaded?.beatsMs != null) return   // already hydrated
        val local = localGrid(songId)
        if (local != null && local.beatsMs.isNotEmpty()) {
            patch(deck, songId, local)
            core.diag("beatgrid hydrate ${deck.label} $songId local beats=${local.beatsMs.size}")
            return
        }
        if (!beatPulseEnabled && !force) return                   // OFF => never download on load
        if (inFlight[deck]?.isActive == true) return
        inFlight[deck] = scope.launch {
            val sc = runCatching { download(songId) }.getOrNull()
            if (sc == null || sc.beatsMs.isEmpty()) return@launch
            if (core.deckState(deck).loaded?.songId != songId) return@launch   // deck moved on -> drop it
            patch(deck, songId, sc)
            core.diag("beatgrid hydrate ${deck.label} $songId downloaded beats=${sc.beatsMs.size}")
            onHydrated?.invoke(deck)
        }
    }

    private fun patch(deck: Deck, songId: String, sc: BeatGridSidecar) {
        core.updateDeck(deck) { s ->
            val l = s.loaded
            if (l == null || l.songId != songId) s
            else s.copy(loaded = l.copy(beatsMs = sc.beatsMs, downbeatsMs = sc.downbeatsMs))
        }
    }
}

package com.levi.pocketdj.screens.discover

import com.levi.pocketdj.data.applemusic.AmResult
import com.levi.pocketdj.data.applemusic.AmSearchType
import com.levi.pocketdj.data.applemusic.AppleMusicApi
import com.levi.pocketdj.data.rips.RipServerClient
import java.io.IOException
import kotlinx.coroutines.CancellationException
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Job
import kotlinx.coroutines.async
import kotlinx.coroutines.coroutineScope
import kotlinx.coroutines.delay
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.launch

/** Outcome of the catalog REST source: [available] false = no dev token / API failure (not "zero hits"). */
data class DiscoverRestResult<T>(val hits: List<T>, val available: Boolean)

sealed interface DiscoverState {
    data object Idle : DiscoverState
    data object Loading : DiscoverState
    data object Loaded : DiscoverState
    /** Neither a rip server nor a catalog token: explanatory empty state. */
    data object NoSources : DiscoverState
    /** The rip-server search failed and nothing else produced hits ("Discover unavailable"). */
    data class Unavailable(val message: String) : DiscoverState
}

data class DiscoverUi<T>(
    val state: DiscoverState = DiscoverState.Idle,
    val hits: List<T> = emptyList(),
    /** Inline notice (server rejected / unreachable) — shown even while REST hits render. */
    val notice: String? = null,
)

/**
 * Debounced two-source driver (iOS `DiscoverSearchModel` / `DiscoverAlbumSearchModel`): Apple Music
 * REST search and the rip-server `/search` proxy run in PARALLEL, merge (REST leads, server rows win
 * ties), dedupe by store id, then the artist refine narrows client-side. A retrigger cancels the
 * pending run; an all-empty query clears to idle. The state flips to Loading SYNCHRONOUSLY, before
 * the debounce sleep, so the surface never shows a stale list as a finished "no matches".
 */
class DiscoverQueryRunner<T>(
    private val scope: CoroutineScope,
    private val rest: suspend (term: String) -> DiscoverRestResult<T>,
    private val server: suspend (term: String) -> List<T>,
    private val serverConfigured: suspend () -> Boolean,
    private val merge: (rest: List<T>, server: List<T>) -> List<T>,
    private val refine: (hits: List<T>, artist: String) -> List<T>,
    private val debounceMs: Long = DEBOUNCE_MS,
) {
    private val _ui = MutableStateFlow(DiscoverUi<T>())
    val ui: StateFlow<DiscoverUi<T>> = _ui
    private var job: Job? = null

    /** [immediate] (return key / Search button) skips the debounce. */
    fun searchDebounced(query: String, artist: String = "", immediate: Boolean = false) {
        job?.cancel()
        val term = DiscoverMerge.term(query, artist)
        if (term == null) {
            _ui.value = DiscoverUi()
            return
        }
        _ui.value = _ui.value.copy(state = DiscoverState.Loading)
        job = scope.launch {
            if (!immediate && debounceMs > 0) delay(debounceMs)
            run(term, artist)
        }
    }

    /** Non-debounced run (deterministic for tests). */
    suspend fun run(term: String, artist: String) {
        val result = coroutineScope {
            val restJob = async { runCatchingNonCancel { rest(term) } ?: DiscoverRestResult(emptyList(), false) }
            val configured = serverConfigured()
            val serverJob = async {
                if (!configured) ServerOutcome(emptyList(), null)
                else try {
                    ServerOutcome(server(term), null)
                } catch (e: CancellationException) {
                    throw e
                } catch (e: Exception) {
                    ServerOutcome(emptyList(), failureMessage(e))
                }
            }
            Triple(restJob.await(), serverJob.await(), configured)
        }
        val (restRes, serverRes, configured) = result
        val hits = refine(merge(restRes.hits, serverRes.hits), artist.trim())
        val state = when {
            !configured && !restRes.available -> DiscoverState.NoSources
            serverRes.error != null && hits.isEmpty() && restRes.hits.isEmpty() -> DiscoverState.Unavailable(serverRes.error)
            else -> DiscoverState.Loaded
        }
        _ui.value = DiscoverUi(state, hits, serverRes.error)
    }

    fun cancel() {
        job?.cancel()
        job = null
        _ui.value = DiscoverUi()
    }

    private class ServerOutcome<T>(val hits: List<T>, val error: String?)

    private suspend fun <R> runCatchingNonCancel(block: suspend () -> R): R? = try {
        block()
    } catch (e: CancellationException) {
        throw e
    } catch (e: Exception) {
        null
    }

    companion object {
        const val DEBOUNCE_MS = 400L
        const val DEFAULT_LIMIT = 25
        const val UNAVAILABLE = "Discover unavailable"

        /** iOS `discoverError` strings. */
        fun failureMessage(e: Exception): String = when {
            e is RipServerClient.RipServerException && (e.code == 401 || e.code == 403) ->
                "The import server rejected the request — check Settings ▸ Import server token."
            e is RipServerClient.RipServerException && e.code != null -> "Search failed (${e.code})."
            e is RipServerClient.RipServerException -> e.message ?: "Search failed."
            e is IOException -> "Import server unreachable (Settings ▸ Import server)."
            else -> "Search failed."
        }
    }
}

object DiscoverSearchModel {
    /** Songs driver over the live clients. [ripUrl] answers the local manifest for an `amrec_` id. */
    fun songs(
        scope: CoroutineScope,
        api: AppleMusicApi,
        rips: RipServerClient,
        ripUrl: (songId: String) -> String? = { null },
    ) = DiscoverQueryRunner<DiscoverHit>(
        scope = scope,
        rest = { term ->
            when (val r = api.searchCatalog(term, setOf(AmSearchType.SONGS), DiscoverQueryRunner.DEFAULT_LIMIT)) {
                is AmResult.Ok -> DiscoverRestResult(
                    r.value.songs.items.map { DiscoverMerge.hit(it, ripUrl("amrec_${it.id}")) }, true,
                )
                else -> DiscoverRestResult(emptyList(), false)
            }
        },
        server = { rips.searchSongs(it, DiscoverQueryRunner.DEFAULT_LIMIT) },
        serverConfigured = { rips.isConfigured() },
        merge = DiscoverMerge::mergeSongs,
        refine = DiscoverMerge::refineSongs,
    )

    fun albums(
        scope: CoroutineScope,
        api: AppleMusicApi,
        rips: RipServerClient,
    ) = DiscoverQueryRunner<DiscoverAlbumHit>(
        scope = scope,
        rest = { term ->
            when (val r = api.searchCatalog(term, setOf(AmSearchType.ALBUMS), DiscoverQueryRunner.DEFAULT_LIMIT)) {
                is AmResult.Ok -> DiscoverRestResult(r.value.albums.items.map(DiscoverMerge::hit), true)
                else -> DiscoverRestResult(emptyList(), false)
            }
        },
        server = { rips.searchAlbums(it, DiscoverQueryRunner.DEFAULT_LIMIT) },
        serverConfigured = { rips.isConfigured() },
        merge = DiscoverMerge::mergeAlbums,
        refine = DiscoverMerge::refineAlbums,
    )
}

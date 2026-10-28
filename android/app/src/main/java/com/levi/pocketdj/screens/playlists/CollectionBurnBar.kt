package com.levi.pocketdj.screens.playlists

import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.padding
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.filled.ArrowCircleDown
import androidx.compose.material.icons.filled.LocalFireDepartment
import androidx.compose.material.icons.filled.Menu
import androidx.compose.material.icons.filled.StopCircle
import androidx.compose.material3.AlertDialog
import androidx.compose.material3.Icon
import androidx.compose.material3.LinearProgressIndicator
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.OutlinedButton
import androidx.compose.material3.Text
import androidx.compose.material3.TextButton
import androidx.compose.runtime.Composable
import androidx.compose.runtime.DisposableEffect
import androidx.compose.runtime.collectAsState
import androidx.compose.runtime.getValue
import androidx.compose.runtime.remember
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.unit.dp
import com.levi.pocketdj.data.burns.BurnItem
import com.levi.pocketdj.data.burns.BurnProgress
import com.levi.pocketdj.data.burns.BurnResult
import com.levi.pocketdj.data.burns.BurnSettings
import com.levi.pocketdj.data.burns.BurnSong
import com.levi.pocketdj.data.burns.BurnState
import com.levi.pocketdj.data.rips.BatchRipResult
import com.levi.pocketdj.data.rips.RipJob
import com.levi.pocketdj.data.stems.BatchStemResult
import com.levi.pocketdj.data.stems.StemClient
import com.levi.pocketdj.di.AppGraph
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Job
import kotlinx.coroutines.delay
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.asStateFlow
import kotlinx.coroutines.flow.distinctUntilChanged
import kotlinx.coroutines.flow.map
import kotlinx.coroutines.flow.update
import kotlinx.coroutines.launch

/** Which long-running op the bar is driving (so one Stop routes to the right cancel path). */
enum class CollectionOp { RIP, BURN, STEM }

/** Immutable UI state of the collection Rip/Burn bar (iOS `CollectionRipBurnController` fields). */
data class CollectionBurnBarState(
    val working: Boolean = false,
    val inFlightOp: CollectionOp? = null,
    val summary: String? = null,
    val showSummary: Boolean = false,
    val canRefresh: Boolean = false,
    val ripInProgress: Boolean = false,
    val ripProgress: String? = null,
    val stemInProgress: Boolean = false,
    val stemProgress: String? = null,
    /** Over-cap envelope: the UI asks "N songs — long job, proceed?" before re-calling. */
    val stemConfirm: StemConfirm? = null,
) {
    data class StemConfirm(val count: Int, val cap: Int)

    /** Stop is offered while anything is in flight (a rip keeps going server-side after enqueue). */
    val showStop: Boolean get() = working || ripInProgress || stemInProgress
}

/** Pure result -> user-string rules, ported from the iOS controller verbatim. */
object CollectionBurnReducer {
    fun ripSummary(r: BatchRipResult): String {
        val pending = r.queued + r.inflight
        val parts = buildList {
            if (r.ready > 0) add("${r.ready} already ripped")
            if (pending > 0) add("$pending enqueued — completes over time")
            if (r.unknown > 0) add("${r.unknown} unrippable")
            if (pending > 0) add("prepared one at a time")
        }
        return if (parts.isEmpty()) "Nothing to rip." else parts.joinToString(" · ")
    }

    fun burnSummary(r: BurnResult, hasServer: Boolean): String {
        if (r.folderUnavailable) return BurnSettings.FOLDER_UNAVAILABLE
        val parts = buildList {
            add("Burned ${r.burned} of ${r.total}")
            if (r.stemmedSongs > 0) add("${r.stemmedSongs} with stems")
            if (r.beatGridded > 0) add("${r.beatGridded} with beat grids")
            if (r.notRipped > 0) add("${r.notRipped} not yet ripped")
            if (r.failed > 0) add("${r.failed} failed")
            if (r.outOfSpace) add("out of space — stopped early")
            if (r.stopped) add("stopped")
            if (!r.stopped && r.notRipped > 0 && hasServer) add("prepared one at a time")
        }
        return parts.joinToString(" · ")
    }

    /** Burn auto-enqueues the missing rips only when not stopped and a server exists. */
    fun shouldRipMissing(r: BurnResult, hasServer: Boolean): Boolean =
        !r.stopped && r.notRipped > 0 && hasServer

    fun canRefreshAfterBurn(r: BurnResult): Boolean = !r.stopped && !r.folderUnavailable && r.notRipped > 0

    fun ripProgressLabel(done: Int, total: Int): String? =
        if (total - done > 0) "ripping — $done of $total done" else null

    fun ripProgressSummary(done: Int, total: Int): String =
        if (total - done > 0) "Ripping $done of $total — completes over time" else "Ripped $total of $total"

    /** 0..1 for the single progress pill; null when there is no burn. */
    fun pillFraction(p: BurnProgress?): Float? =
        p?.takeIf { it.total > 0 }?.let { (it.done.toFloat() / it.total).coerceIn(0f, 1f) }

    fun pillText(p: BurnProgress?): String? = p?.let { "${it.label} ${it.done}/${it.total}".trim() }

    /** iOS RowTransport.phaseLabel equivalent for the raw tracker phase string. */
    fun phaseLabel(phase: String): String = when (phase.lowercase()) {
        "queued", "pending" -> "Queued\u2026"
        "searching", "search" -> "Searching\u2026"
        "ripping", "recording" -> "Ripping\u2026"
        "uploading", "upload" -> "Uploading\u2026"
        else -> phase.replaceFirstChar { it.uppercase() } + "\u2026"
    }

    /**
     * One-line row note for a collection song: the burn ledger's not-ripped error wins (unless the
     * song has since landed in the manifest), else the live rip phase while a rip is running.
     */
    fun rowNote(
        burn: BurnItem?,
        job: RipJob?,
        manifestHit: Boolean = false,
        stemJob: com.levi.pocketdj.data.stems.StemJob? = null,
        stemmed: Boolean = false,
    ): String? {
        if (!manifestHit && burn != null && burn.state == BurnState.ERROR) {
            val e = burn.error.orEmpty()
            if (e.startsWith("not ripped")) return e
        }
        if (job != null && !job.isReady && job.phase.isNotEmpty() && job.phase != "ready" && job.phase != "error") {
            return phaseLabel(job.phase)
        }
        // Already stemmed per the manifest => not busy, even with a stale collection-stemify job.
        if (!stemmed) StemClient.phaseLabel(stemJob?.phase)?.let { return it }
        return null
    }
}

/**
 * Drives Rip / Burn / Stop for one collection screen. Dependencies are lambdas so the whole state
 * machine runs on the JVM (see CollectionBurnBarStateTest).
 */
class CollectionBurnController(
    private val scope: CoroutineScope,
    private val burn: suspend (List<BurnSong>) -> BurnResult,
    private val requestStopBurn: () -> Unit,
    private val ripCollection: suspend (List<String>) -> BatchRipResult,
    private val cancelRips: suspend (List<String>) -> Unit,
    private val isRipped: (String) -> Boolean,
    private val refreshManifest: suspend () -> Unit,
    private val hasServer: suspend () -> Boolean,
    private val tuples: (List<String>) -> List<BurnSong>,
    private val pollIntervalMs: Long = BurnSettings.RIP_POLL_INTERVAL_MS,
    private val maxTicks: Int = BurnSettings.RIP_POLL_MAX_TICKS,
    /** Stemify (SVC-11); defaults keep older call sites compiling. */
    private val stemifyCollection: suspend (ids: List<String>, confirmLarge: Boolean) -> BatchStemResult =
        { _, _ -> BatchStemResult() },
    private val isStemmed: (String) -> Boolean = { false },
    private val cancelStems: (List<String>) -> Unit = {},
) {
    private val _state = MutableStateFlow(CollectionBurnBarState())
    val state: StateFlow<CollectionBurnBarState> = _state.asStateFlow()

    private var burnJob: Job? = null
    private var pollJob: Job? = null
    private var lastRipIds: List<String> = emptyList()
    private var stemPollJob: Job? = null
    private var lastStemIds: List<String> = emptyList()
    private var pendingStemIds: List<String> = emptyList()

    /** Kick a collection Stemify; the server rips/cuts missing songs first. Over-cap => confirm. */
    fun stemify(ids: List<String>, confirmLarge: Boolean = false): Job? {
        if (_state.value.working) return null
        _state.update { it.copy(working = true, inFlightOp = CollectionOp.STEM) }
        lastStemIds = ids
        return scope.launch {
            val r = stemifyCollection(ids, confirmLarge)
            if (r.needsConfirm) {
                pendingStemIds = ids
                _state.update {
                    it.copy(working = false, inFlightOp = null, stemConfirm = CollectionBurnBarState.StemConfirm(r.count, r.cap))
                }
                return@launch
            }
            val pending = r.pending
            _state.update {
                it.copy(
                    summary = StemClient.summary(r),
                    canRefresh = pending > 0 || r.ready > 0,
                    working = false, inFlightOp = null, showSummary = true, stemConfirm = null,
                )
            }
            if (pending > 0) startStemPoll(ids)
        }
    }

    fun confirmStemify(): Job? {
        val ids = pendingStemIds
        pendingStemIds = emptyList()
        _state.update { it.copy(stemConfirm = null) }
        return stemify(ids, confirmLarge = true)
    }

    fun dismissStemConfirm() {
        pendingStemIds = emptyList()
        _state.update { it.copy(stemConfirm = null) }
    }

    private fun startStemPoll(ids: List<String>) {
        stemPollJob?.cancel()
        val total = ids.size
        if (total == 0) return
        _state.update { it.copy(stemInProgress = true) }
        updateStemProgress(ids, total)
        stemPollJob = scope.launch {
            repeat(maxTicks) {
                delay(pollIntervalMs)
                runCatching { refreshManifest() }
                if (updateStemProgress(ids, total) == 0) {
                    _state.update { it.copy(stemInProgress = false, stemProgress = null, canRefresh = true) }
                    stemPollJob = null
                    return@launch
                }
            }
            clearStemProgress()
        }
    }

    private fun updateStemProgress(ids: List<String>, total: Int): Int {
        val done = ids.count(isStemmed)
        _state.update {
            it.copy(
                stemProgress = StemClient.progressLabel(done, total),
                summary = StemClient.progressSummary(done, total),
            )
        }
        return (total - done).coerceAtLeast(0)
    }

    private fun clearStemProgress() {
        stemPollJob?.cancel(); stemPollJob = null
        _state.update { it.copy(stemInProgress = false, stemProgress = null) }
    }

    fun rip(ids: List<String>): Job? {
        if (_state.value.working) return null
        _state.update { it.copy(working = true, inFlightOp = CollectionOp.RIP) }
        lastRipIds = ids
        return scope.launch {
            val r = ripCollection(ids)
            val pending = r.queued + r.inflight
            _state.update {
                it.copy(
                    summary = CollectionBurnReducer.ripSummary(r),
                    canRefresh = pending > 0 || r.ready > 0,
                    working = false, inFlightOp = null, showSummary = true,
                )
            }
            if (pending > 0) startRipPoll(ids)
        }
    }

    private fun startRipPoll(ids: List<String>) {
        pollJob?.cancel()
        val total = ids.size
        if (total == 0) return
        _state.update { it.copy(ripInProgress = true) }
        updateRipProgress(ids, total)
        pollJob = scope.launch {
            repeat(maxTicks) {
                delay(pollIntervalMs)
                runCatching { refreshManifest() }
                if (updateRipProgress(ids, total) == 0) {
                    _state.update { it.copy(ripInProgress = false, ripProgress = null, canRefresh = true) }
                    pollJob = null
                    return@launch
                }
            }
            clearRipProgress()
        }
    }

    private fun updateRipProgress(ids: List<String>, total: Int): Int {
        val done = ids.count(isRipped)
        _state.update {
            it.copy(
                ripProgress = CollectionBurnReducer.ripProgressLabel(done, total),
                summary = CollectionBurnReducer.ripProgressSummary(done, total),
            )
        }
        return (total - done).coerceAtLeast(0)
    }

    private fun clearRipProgress() {
        pollJob?.cancel(); pollJob = null
        _state.update { it.copy(ripInProgress = false, ripProgress = null) }
    }

    fun burn(ids: List<String>): Job? {
        if (_state.value.working) return null
        _state.update { it.copy(working = true, inFlightOp = CollectionOp.BURN) }
        val job = scope.launch {
            var finished = false
            try {
                val songs = tuples(ids)
                // No hard cancel on Stop: requestStop() makes the store break at the next item and
                // return a partial result (stopped = true), so the summary still reports counts.
                val r = burn(songs)
                val server = hasServer()
                if (CollectionBurnReducer.shouldRipMissing(r, server)) {
                    val missing = songs.map { it.id }.filterNot(isRipped)
                    if (missing.isNotEmpty()) runCatching { ripCollection(missing) }
                }
                _state.update {
                    it.copy(
                        summary = CollectionBurnReducer.burnSummary(r, server),
                        canRefresh = CollectionBurnReducer.canRefreshAfterBurn(r),
                        working = false, inFlightOp = null, showSummary = true,
                    )
                }
                finished = true
            } finally {
                if (!finished) _state.update { it.copy(working = false, inFlightOp = null) }
            }
        }
        burnJob = job
        return job
    }

    /** Stop whatever is in flight: halt the burn loop, or cancel the server rips + their poll. */
    fun stop(): Job? {
        val s = _state.value
        requestStopBurn() // idempotent; also covers a background burn whose job already returned
        if (s.inFlightOp == CollectionOp.BURN) {
            return null
        }
        if (s.inFlightOp == CollectionOp.STEM || s.stemInProgress) {
            val stemIds = lastStemIds
            clearStemProgress()
            _state.update { it.copy(working = false, inFlightOp = null) }
            cancelStems(stemIds)
            if (!s.ripInProgress && s.inFlightOp != CollectionOp.RIP) return null
        }
        val ids = lastRipIds
        clearRipProgress()
        _state.update { it.copy(working = false, inFlightOp = null) }
        if (ids.isEmpty()) return null
        return scope.launch { runCatching { cancelRips(ids) } }
    }

    fun dismissSummary() = _state.update { it.copy(showSummary = false) }

    fun refresh(): Job = scope.launch { runCatching { refreshManifest() } }

    fun dispose() {
        pollJob?.cancel(); pollJob = null
        stemPollJob?.cancel(); stemPollJob = null
    }
}

/** Builds the controller from the app graph for one collection screen. */
@Composable
fun rememberCollectionBurnController(key: Any? = null): CollectionBurnController {
    val context = LocalContext.current
    val controller = remember(key) {
        val graph = AppGraph.get(context)
        val services = graph.servicesGraph
        val store = services.burnStore
        val coordinator = services.ripCoordinator
        CollectionBurnController(
            scope = graph.appScope, // a burn outlives the screen (iOS stores the Task on the controller)
            burn = { store.burn(it) },
            requestStopBurn = store::requestStop,
            ripCollection = { ids -> coordinator.ripCollection(ids) { graph.ripsRepository.entry(it) != null } },
            cancelRips = { coordinator.cancelRips(it) },
            isRipped = { graph.ripsRepository.entry(it) != null },
            refreshManifest = { graph.ripsRepository.refresh() },
            hasServer = { graph.ripServerClient.isConfigured() },
            stemifyCollection = { ids, confirm ->
                graph.ripServerClient.stemifyCollection(
                    ids, confirmLarge = confirm,
                    isStemmed = { graph.ripsRepository.entry(it)?.isStemmed == true },
                    fallbackOne = { id ->
                        graph.ripJobTracker.stemify(id)
                        graph.ripJobTracker.stemJobs.value[id]
                    },
                ).also { r ->
                    for (item in r.results) {
                        val jobId = item.jobId ?: continue
                        if (item.status in setOf("queued", "inflight", "ripping", "needsCut")) {
                            graph.ripJobTracker.seedStemJob(item.songId, jobId)
                            graph.ripJobTracker.pollStemReady(item.songId, jobId)
                        }
                    }
                }
            },
            isStemmed = { graph.ripsRepository.entry(it)?.isStemmed == true },
            cancelStems = { graph.ripJobTracker.cancelStems(it) },
            tuples = { ids ->
                val cat = graph.catalogRepository.state.value.catalog
                ids.map { id ->
                    val song = cat?.songsById?.get(id)
                    BurnSong(id, song?.name.orEmpty(), song?.artist.orEmpty())
                }
            },
        )
    }
    DisposableEffect(controller) { onDispose { controller.dispose() } }
    return controller
}

/**
 * Rip / Burn / Stop row + the single progress pill + the result dialog + the device/cloud toggle.
 * [songIds] resolves the collection's (deduped, studio-stripped) ids at action time.
 */
@Composable
fun CollectionBurnBar(
    controller: CollectionBurnController,
    songIds: () -> List<String>,
    modifier: Modifier = Modifier,
    noun: String = "collection",
) {
    val graph = AppGraph.get(LocalContext.current)
    val state by controller.state.collectAsState()
    val progress by graph.servicesGraph.burnStore.progress.collectAsState()
    val currentSongIds by androidx.compose.runtime.rememberUpdatedState(songIds)
    val hasSongs by remember { androidx.compose.runtime.derivedStateOf { currentSongIds().isNotEmpty() } }
    val serverConfigured by androidx.compose.runtime.produceState(false) { value = graph.ripServerClient.isConfigured() }

    Column(modifier = modifier.fillMaxWidth().padding(horizontal = 16.dp, vertical = 4.dp)) {
        Row(horizontalArrangement = Arrangement.spacedBy(8.dp), verticalAlignment = Alignment.CenterVertically) {
            OutlinedButton(
                onClick = { controller.rip(songIds()) },
                enabled = hasSongs && !state.working && serverConfigured,
            ) {
                Icon(Icons.Filled.ArrowCircleDown, contentDescription = null)
                Text("Rip")
            }
            OutlinedButton(
                onClick = { controller.burn(songIds()) },
                enabled = hasSongs && !state.working,
            ) {
                Icon(Icons.Filled.LocalFireDepartment, contentDescription = null)
                Text("Burn")
            }
            OutlinedButton(
                onClick = { controller.stemify(songIds()) },
                enabled = hasSongs && !state.working && serverConfigured,
            ) {
                Icon(Icons.Filled.Menu, contentDescription = null)
                Text("Stemify")
            }
            if (state.showStop || progress != null) {
                OutlinedButton(onClick = { controller.stop() }) {
                    Icon(Icons.Filled.StopCircle, contentDescription = "Stop $noun")
                    Text("Stop")
                }
            }
            PlaybackModeToggle()
        }
        // The single progress pill: burn progress wins, else the live rip line.
        val fraction = CollectionBurnReducer.pillFraction(progress)
        val pill = CollectionBurnReducer.pillText(progress) ?: state.ripProgress ?: state.stemProgress
        if (pill != null) {
            Text(pill, style = MaterialTheme.typography.labelMedium, color = MaterialTheme.colorScheme.onSurfaceVariant)
            if (fraction != null) LinearProgressIndicator(progress = { fraction }, modifier = Modifier.fillMaxWidth())
        }
    }

    state.stemConfirm?.let { c ->
        AlertDialog(
            onDismissRequest = controller::dismissStemConfirm,
            title = { Text("Stemify $noun?") },
            text = { Text("${c.count} songs \u2014 long job (server cap ${c.cap}). Proceed?") },
            confirmButton = { TextButton(onClick = { controller.confirmStemify() }) { Text("Proceed") } },
            dismissButton = { TextButton(onClick = controller::dismissStemConfirm) { Text("Cancel") } },
        )
    }

    if (state.showSummary && state.summary != null) {
        AlertDialog(
            onDismissRequest = controller::dismissSummary,
            title = { Text("Rip / Burn") },
            text = { Text(state.summary.orEmpty()) },
            confirmButton = { TextButton(onClick = controller::dismissSummary) { Text("OK") } },
            dismissButton = if (state.canRefresh) {
                { TextButton(onClick = { controller.refresh(); controller.dismissSummary() }) { Text("Refresh") } }
            } else null,
        )
    }
}

/** Per-row note: collects only this song's ledger/job entries so other rows' changes don't recompose it. */
@Composable
fun rememberRowNote(songId: String?, manifestHit: Boolean): String? {
    if (songId == null) return null
    val graph = AppGraph.get(LocalContext.current)
    val burn by remember(songId) {
        graph.servicesGraph.burnStore.items.map { it[songId] }.distinctUntilChanged()
    }.collectAsState(null)
    val job by remember(songId) {
        graph.ripJobTracker.jobs.map { it[songId] }.distinctUntilChanged()
    }.collectAsState(null)
    val stemJob by remember(songId) {
        graph.ripJobTracker.stemJobs.map { it[songId] }.distinctUntilChanged()
    }.collectAsState(null)
    val stemmed = graph.ripsRepository.entry(songId)?.isStemmed == true
    return CollectionBurnReducer.rowNote(burn, job, manifestHit, stemJob, stemmed)
}

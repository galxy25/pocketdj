package com.levi.pocketdj.screens.nowplaying

import android.content.res.Configuration
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.verticalScroll
import androidx.compose.material3.SnackbarHostState
import androidx.compose.runtime.Composable
import androidx.compose.runtime.DisposableEffect
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.collectAsState
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.rememberCoroutineScope
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.platform.LocalConfiguration
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.unit.dp
import com.levi.pocketdj.di.AppGraph
import com.levi.pocketdj.screens.browse.MinimalSong
import com.levi.pocketdj.screens.browse.SongDetailSheet
import com.levi.pocketdj.data.collections.NOW_PLAYING_SETLIST_ID
import com.levi.pocketdj.playback.QueuePlan
import com.levi.pocketdj.playback.sequencer.QueueItem
import kotlinx.coroutines.launch
import com.levi.pocketdj.shell.NavRequestBus
import com.levi.pocketdj.shell.ShellRoute
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.delay
import kotlinx.coroutines.withContext

/** The home Now Playing deck: gold record, transport, modes, notice. */
@Composable
fun NowPlayingScreen(modifier: Modifier = Modifier) {
    val context = LocalContext.current
    val graph = remember { AppGraph.get(context) }
    val scope = rememberCoroutineScope()
    val vm = remember { NowPlayingViewModel(graph, scope) }
    DisposableEffect(vm) { vm.startPolling(); onDispose { vm.stopPolling() } }

    val seq by graph.playbackGraph.sequencer.state.collectAsState()
    val np by graph.playbackController.nowPlaying.collectAsState()
    val catalogState by graph.catalogRepository.state.collectAsState()
    val manifest by graph.ripsRepository.manifest.collectAsState()
    val position by vm.positionMs.collectAsState()
    val showPlayed by vm.showPlayed.collectAsState()

    val songKey = seq.current?.id ?: np?.songId
    // catalogState/manifest are read so facts recompute when either loads.
    val facts = remember(songKey, catalogState, manifest) { vm.facts(songKey) }
    val state = NowPlayingModel.build(
        seq = seq,
        audible = np?.toAudible(),
        facts = facts,
        startPending = vm.inputsStartPending(),
        appleMusicActive = vm.appleMusicActive(),
        currentNeverSounded = vm.currentNeverSounded(),
    )
    val progress = RecordMath.progressFraction(position, state.lengthMs)

    val cfg = LocalConfiguration.current
    val landscape = cfg.orientation == Configuration.ORIENTATION_LANDSCAPE
    val landscapePhone = landscape && cfg.screenHeightDp < 480
    val expanded = QueueReorder.useExpandedLayout(cfg.screenWidthDp, landscape)
    var detail by remember { mutableStateOf<Pair<String, MinimalSong?>?>(null) }
    val snackbar = remember { SnackbarHostState() }
    val sequencer = graph.playbackGraph.sequencer
    val collections = graph.collections

    // Debounced (200 ms), off-main add-search over the catalog snapshot.
    var query by remember { mutableStateOf("") }
    var results by remember { mutableStateOf(NowPlayingSearch.Results()) }
    LaunchedEffect(query, catalogState) {
        if (query.isBlank()) { results = NowPlayingSearch.Results(); return@LaunchedEffect }
        delay(NowPlayingSearch.DEBOUNCE_MS)
        val merged = catalogState.catalog
        results = if (merged == null) NowPlayingSearch.Results()
        else withContext(Dispatchers.Default) { NowPlayingSearch.search(query, merged) }
    }
    val searching = query.isNotBlank()

    fun showDetail(item: QueueItem) {
        val inCatalog = catalogState.catalog?.songsById?.containsKey(item.id) == true
        detail = item.id to if (inCatalog) null else MinimalSong(item.title, item.artist.orEmpty(), item.lengthMs)
    }
    /**
     * Add rows next/last. Sequencer idle: fold whatever is sounding (album, browse single, AM) into a
     * run first so the add lands behind it; nothing sounding: start a run with the rows.
     */
    fun addRows(items: List<QueueItem>, next: Boolean) {
        if (items.isEmpty()) return
        if (!sequencer.isRunning) {
            val playing = np
            if (playing != null && playing.songId.isNotEmpty()) {
                scope.launch {
                    val pos = runCatching { graph.playbackController.currentPositionMs() }.getOrDefault(0L)
                    sequencer.adoptForeign(
                        QueueItem(playing.songId, playing.title ?: playing.songId, playing.artist, playing.durationMs),
                        pos, null,
                    )
                    if (next) sequencer.insertNextInQueue(items) else sequencer.appendToQueue(items)
                }
            } else {
                scope.launch {
                    graph.playbackController.playQueue(
                        items.map { QueuePlan.QueueEntry(it.id, it.repeatCount, it.title, it.artist, it.lengthMs) },
                    )
                }
            }
            return
        }
        if (next) sequencer.insertNextInQueue(items) else sequencer.appendToQueue(items)
    }
    fun openSetlist() {
        val sid = seq.sourceSetlistId
        if (!QueueReorder.needsMaterialize(sid) { collections.setlist(it) != null }) {
            NavRequestBus.post(ShellRoute.Setlist(sid!!))
        } else if (seq.queue.isNotEmpty()) {
            // Re-materialize the reserved set from the LIVE queue (all rows, repeats kept).
            collections.materializeNowPlayingSetlist(
                seq.capturedContext?.contextName ?: "Now Playing",
                seq.queue,
            )
            NavRequestBus.post(ShellRoute.Setlist(NOW_PLAYING_SETLIST_ID))
        }
    }
    val originRoute = QueueReorder.originRoute(seq.capturedOrigin)

    val deck: @Composable () -> Unit = {
        NowPlayingTitleBlock(state)
        if (!landscapePhone) {
            Spacer(Modifier.height(12.dp))
            NowPlayingRecord(
                state = state,
                progress = progress,
                onLongPress = { state.songId?.let { detail = it to if (state.inCatalog) null else MinimalSong(state.title, state.artist, state.lengthMs) } },
                modifier = Modifier.padding(horizontal = 24.dp),
            )
        }
        NowPlayingProgress(progress, Modifier.padding(vertical = 8.dp))
        NowPlayingTransportRow(
            state = state,
            showPlayedActive = showPlayed,
            onPrevious = vm::previous,
            onPlayPause = { vm.togglePlayPause(vm.currentInputs()) },
            onNext = vm::next,
            onShuffle = vm::toggleShuffle,
            onRepeat = vm::cycleRepeat,
            onTogglePlayed = vm::togglePlayed,
        )
        NowPlayingNotice(state.notice, Modifier.padding(top = 8.dp))
        NowPlayingSeams.dspSlot?.invoke()
    }
    val playedPane: @Composable () -> Unit = {
        PlayedList(seq.played, sequencer, ::showDetail)
    }
    val upNextPane: @Composable () -> Unit = {
        if (searching) {
            val merged = catalogState.catalog
            NowPlayingSearchResults(
                results = results,
                onAddNextSong = { addRows(listOf(NowPlayingSearch.queueItem(it)), true) },
                onAddEndSong = { addRows(listOf(NowPlayingSearch.queueItem(it)), false) },
                onAddNextAlbum = { a -> merged?.let { addRows(NowPlayingSearch.queueItems(a, it), true) } },
                onAddEndAlbum = { a -> merged?.let { addRows(NowPlayingSearch.queueItems(a, it), false) } },
            )
        } else if (seq.isRunning) {
            UpNextList(
                upcoming = seq.upcoming,
                sequencer = sequencer,
                onSongDetail = ::showDetail,
                onOpenSetlist = ::openSetlist,
                onOpenOrigin = originRoute?.let { r -> { NavRequestBus.post(r) } },
            )
        }
    }

    if (expanded) {
        Column(modifier.fillMaxSize()) {
            NowPlayingSearchBar(query, { query = it }, Modifier.padding(horizontal = 12.dp, vertical = 4.dp))
            NowPlayingExpandedLayout(played = playedPane, center = deck, upNext = upNextPane, modifier = Modifier.weight(1f))
        }
    } else {
        Column(
            modifier
                .fillMaxSize()
                .verticalScroll(rememberScrollState())
                .padding(horizontal = 16.dp, vertical = 8.dp),
            horizontalAlignment = Alignment.CenterHorizontally,
        ) {
            NowPlayingSearchBar(query, { query = it })
            Spacer(Modifier.height(8.dp))
            deck()
            if (showPlayed) playedPane()
            upNextPane()
        }
    }

    detail?.let { (id, fb) ->
        SongDetailSheet(songId = id, onDismiss = { detail = null }, snackbar = snackbar, fallback = fb)
    }
}

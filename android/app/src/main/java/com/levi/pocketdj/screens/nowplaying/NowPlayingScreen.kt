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
    val landscapePhone = cfg.orientation == Configuration.ORIENTATION_LANDSCAPE && cfg.screenHeightDp < 480
    var detailFor by remember { mutableStateOf<String?>(null) }
    val snackbar = remember { SnackbarHostState() }

    Column(
        modifier
            .fillMaxSize()
            .verticalScroll(rememberScrollState())
            .padding(horizontal = 16.dp, vertical = 8.dp),
        horizontalAlignment = Alignment.CenterHorizontally,
    ) {
        NowPlayingTitleBlock(state)
        if (!landscapePhone) {
            Spacer(Modifier.height(12.dp))
            NowPlayingRecord(
                state = state,
                progress = progress,
                onLongPress = { state.songId?.let { detailFor = it } },
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
        if (showPlayed) NowPlayingSeams.playedList?.invoke()
        NowPlayingSeams.dspSlot?.invoke()
    }

    detailFor?.let { id ->
        SongDetailSheet(
            songId = id,
            onDismiss = { detailFor = null },
            snackbar = snackbar,
            fallback = if (state.inCatalog) null else MinimalSong(state.title, state.artist, state.lengthMs),
        )
    }
}

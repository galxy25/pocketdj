package com.levi.pocketdj.screens.mix

import android.app.Activity
import android.content.res.Configuration
import androidx.compose.foundation.background
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.widthIn
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.verticalScroll
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.filled.Close
import androidx.compose.material.icons.filled.History
import androidx.compose.material.icons.filled.Layers
import androidx.compose.material3.FilterChip
import androidx.compose.material3.Icon
import androidx.compose.material3.IconButton
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.runtime.DisposableEffect
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.collectAsState
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.produceState
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.platform.LocalConfiguration
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.platform.testTag
import androidx.compose.ui.semantics.contentDescription
import androidx.compose.ui.semantics.semantics
import androidx.compose.ui.unit.dp
import com.levi.pocketdj.di.AppGraph
import com.levi.pocketdj.screens.browse.AlbumArt
import com.levi.pocketdj.mix.engine.onAirBuffering
import com.levi.pocketdj.mix.model.Deck
import kotlinx.coroutines.delay
import kotlinx.coroutines.flow.distinctUntilChanged
import kotlinx.coroutines.flow.map

/**
 * The Mix tab (iOS `MixView`): session header, optional recording slot, Auto setup bar / banner,
 * the decks, crossfader, master transport, Auto-only Skip, and the bottom-pinned download bar.
 *
 * Leaving the tab does NOT pause or tear down the engine (load-bearing; pause/pauseBoth would end
 * an Auto-DJ); only the download run is cancelled, and only when no mix is live.
 *
 * [recordingIndicator] / [recordAction] are the MIX-12 slots (the "● Recording m:ss + Stop" row and
 * the top-bar Record button).
 */
@Composable
fun MixScreen(
    graph: AppGraph,
    onOpenSessions: () -> Unit,
    modifier: Modifier = Modifier,
    recordingIndicator: @Composable () -> Unit = {},
    recordAction: @Composable () -> Unit = {},
) {
    val mix = graph.mixGraph
    val vm = mix.mixViewModel
    val engine = mix.mixEngine
    val sessions = mix.mixSessions
    val st by vm.state.collectAsState()
    val settings by vm.settings.collectAsState()
    val auto by vm.autoUi.collectAsState()
    val sessionName by sessions.currentNameFlow.collectAsState()
    var confirmingReset by remember { mutableStateOf(false) }
    // MIX-17: the slot whose modulation sheet is open (deck, slot index).
    var modTarget by remember { mutableStateOf<Pair<com.levi.pocketdj.mix.model.Deck, Int>?>(null) }

    // First composition: warm the graph, push the four settings, THEN materialize a parked restore;
    // afterwards each changed setting is pushed immediately. Lives as long as the screen.
    LaunchedEffect(vm) { vm.run() }

    // handleMixLeave ONLY on dispose (a tab switch), never on rotation.
    val activity = LocalContext.current as? Activity
    DisposableEffect(vm) {
        onDispose { if (activity?.isChangingConfigurations != true) vm.handleMixLeave() }
    }

    // Crate menu entries are remembered by the collections REVISION: nothing the download bar
    // ticks can rebuild them, so an open menu keeps its scroll position.
    val revision by remember { graph.collections.state.map { it.revision }.distinctUntilChanged() }
        .collectAsState(graph.collections.state.value.revision)
    val entries = remember(revision) {
        MixCrateEntries(MixCrateMenuState.entries(graph.collections.pockets, graph.collections.playlists, graph.collections.setlists))
    }
    val pickA = remember(vm) { { s: com.levi.pocketdj.mix.model.MixSource? -> vm.setAutoSource(s) } }
    val pickB = remember(vm) { { s: com.levi.pocketdj.mix.model.MixSource? -> vm.setAutoSourceB(s) } }

    val host = remember(engine) {
        val burns = graph.servicesGraph.burnStore
        DeckHost(
            engine = engine, stems = mix.mixDeckExtras.stems, loops = mix.mixDeckExtras.loops,
            streams = mix.mixStreamDecks, cues = graph.studioGraph.cuePoints,
            onMod = { d, i -> modTarget = d to i },
            isStemmed = { id -> burns.stemsBurned(id) || burns.stemsRemote(id) },
            peaksFor = { t -> MixWaveform.peaksForSong(t.songId, null, burns) },
            art = { albumId, m ->
                AlbumArt(albumId?.let { graph.catalogRepository.state.value.catalog?.albumsById?.get(it) }, m)
            },
        )
    }
    val landscape = LocalConfiguration.current.orientation == Configuration.ORIENTATION_LANDSCAPE

    // "Buffering…" on the banner: a cheap 4 Hz poll scoped to this one flag (and only while mixing).
    val buffering by produceState(false, auto.mixing) {
        if (!auto.mixing) { value = false; return@produceState }
        while (true) { value = mix.autoDj.onAirBuffering; delay(250) }
    }

    Column(modifier.fillMaxSize().background(androidx.compose.material3.MaterialTheme.colorScheme.background).testTag("mix-tab")) {
        Row(Modifier.fillMaxWidth().padding(horizontal = 8.dp), verticalAlignment = Alignment.CenterVertically) {
            IconButton(onClick = onOpenSessions, modifier = Modifier.testTag("mix-sessions")) {
                Icon(Icons.Filled.History, "Mix sessions — replay & history", tint = DeckColors.fg)
            }
            IconButton(onClick = { confirmingReset = true }, modifier = Modifier.testTag("mix-reset")) {
                Icon(Icons.Filled.Close, "Start a new session", tint = DeckColors.fg)
            }
            Box(Modifier.weight(1f)) {
                Text("Mix", color = DeckColors.fg, style = androidx.compose.material3.MaterialTheme.typography.titleMedium, modifier = Modifier.padding(start = 6.dp))
            }
            FilterChip(
                selected = st.autoEnabled, onClick = { vm.setAutoEnabled(!st.autoEnabled) },
                label = { Text(if (st.autoEnabled) "Auto" else "Manual") },
                modifier = Modifier.testTag("mix-auto-toggle").semantics { contentDescription = "Auto mode" },
            )
            recordAction()
        }
        Column(Modifier.weight(1f).fillMaxWidth().verticalScroll(rememberScrollState()), horizontalAlignment = Alignment.CenterHorizontally) {
            Column(
                Modifier.widthIn(max = 900.dp).fillMaxWidth().padding(16.dp),
                verticalArrangement = Arrangement.spacedBy(18.dp),
            ) {
                Box(Modifier.fillMaxWidth(), contentAlignment = Alignment.Center) {
                    SessionHeader(
                        name = sessionName,
                        onRename = { sessions.rename(sessions.currentId, it) },
                        onNewSession = { confirmingReset = true },
                        onAllSessions = onOpenSessions,
                    )
                }
                MixRecordingControls(mix.mixRecorder)
                recordingIndicator()
                if (st.autoEnabled && !auto.mixing) {
                    AutoSetupBar(
                        entries = entries,
                        crateAName = vm.crateName(st.autoSource),
                        crateBName = vm.crateName(st.autoSourceB),
                        liveSourceLabel = auto.sourceLabel,
                        canPlay = st.autoSource != null,
                        error = st.autoStartError,
                        fxGlide = auto.fxGlide, mixGlide = auto.mixGlide,
                        onPickA = pickA, onPickB = pickB,
                        onPlay = { vm.startAuto(false) }, onShuffle = { vm.startAuto(true) },
                        onFxGlide = vm::setFXGlide, onMixGlide = vm::setMixGlide,
                    )
                }
                if (auto.mixing) {
                    AutoMixBanner(
                        auto = auto, buffering = buffering,
                        onPause = vm::pauseAuto, onResume = vm::resumeAuto, onStop = vm::stopAuto,
                        onFxGlide = vm::setFXGlide, onMixGlide = vm::setMixGlide,
                    )
                }
                DeckArea(
                    host = host, layout = settings.mixDeckLayout, landscape = landscape,
                    onLoad = { vm.openLoader(it) },
                    beatPulseEnabled = settings.beatPulseEnabled,
                    sourceMenu = { d ->
                        val src = if (d == Deck.A) st.sourceA else st.sourceB
                        MixCrateMenu(
                            entries = entries,
                            labelText = vm.crateName(src) ?: "Pick a source",
                            icon = Icons.Filled.Layers,
                            onPick = { s -> if (s != null) vm.setSource(d, s) },
                            tag = "mix-deck-source-${d.label}",
                        )
                    },
                )
                CrossfaderView(engine)
                MasterTransport(engine)
                if (auto.mixing) SkipButton(onSkip = vm::skip)
            }
        }
        // Bottom-pinned; the ONLY collector of the downloader's progress.
        DownloadBar(state = mix.collectionMixDownloader.state, onCancel = { mix.collectionMixDownloader.cancel() })
    }

    st.loaderDeck?.let { deck ->
        val hide = settings.mixAutoHidePlayed
        val env = remember(entries, hide) {
            TrackLoaderEnv(
                entries = entries,
                crateName = vm::crateName,
                loadables = vm::loadables,
                album = { id -> id?.let { graph.catalogRepository.state.value.catalog?.albumsById?.get(it) } },
                hasPlayed = sessions::hasPlayed,
                playedRevision = sessions.playedRevisionFlow,
                autoHidePlayed = hide,
            )
        }
        TrackLoaderSheet(
            deck = deck,
            source = if (deck == Deck.A) st.sourceA else st.sourceB,
            env = env,
            onPickSource = { vm.setSource(deck, it) },
            onLoad = { engine.load(it, deck) },
            onDismiss = vm::closeLoader,
        )
    }
    modTarget?.let { (d, i) ->
        SlotModSheet(engine, d, i, "mix-deck-${d.label.lowercase()}-fx-slot-$i", onDismiss = { modTarget = null })
    }

    if (confirmingReset) ResetSessionDialog(
        onConfirm = { sessions.reset(); confirmingReset = false },
        onDismiss = { confirmingReset = false },
    )
}

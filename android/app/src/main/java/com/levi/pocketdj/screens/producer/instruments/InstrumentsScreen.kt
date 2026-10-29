package com.levi.pocketdj.screens.producer.instruments

import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.lazy.LazyRow
import androidx.compose.foundation.lazy.items
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.verticalScroll
import androidx.compose.material3.Button
import androidx.compose.material3.ButtonDefaults
import androidx.compose.material3.FilterChip
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.OutlinedButton
import androidx.compose.material3.SegmentedButton
import androidx.compose.material3.SegmentedButtonDefaults
import androidx.compose.material3.SingleChoiceSegmentedButtonRow
import androidx.compose.material3.Switch
import androidx.compose.material3.Text
import androidx.compose.material3.TextButton
import androidx.compose.runtime.Composable
import androidx.compose.runtime.DisposableEffect
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.collectAsState
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableIntStateOf
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.rememberCoroutineScope
import androidx.compose.runtime.saveable.rememberSaveable
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.platform.testTag
import androidx.compose.ui.unit.dp
import com.levi.pocketdj.di.AppGraph
import com.levi.pocketdj.studio.engine.ClickTrack
import com.levi.pocketdj.studio.engine.InstrumentEngine
import com.levi.pocketdj.studio.engine.TakeFileException
import com.levi.pocketdj.studio.model.InstrumentKey
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.launch
import kotlinx.coroutines.withContext

private enum class InstrumentsSection(val label: String) { Play("Play"), Takes("Takes"), Packs("Packs") }

/**
 * The Instruments tab: pick an instrument (loaded off-main from its downloaded bank), play the on-screen keys, record
 * a take (optional click + one-bar count-in, neither recorded), and manage takes / sound packs.
 */
@Composable
fun InstrumentsScreen(graph: AppGraph, modifier: Modifier = Modifier) {
    var section by rememberSaveable { mutableStateOf(InstrumentsSection.Play.name) }
    val current = InstrumentsSection.valueOf(section)
    val ctx = LocalContext.current
    var scoreTakeId by rememberSaveable { mutableStateOf<String?>(null) }
    LaunchedEffect(Unit) {
        InstrumentEngine.DEBUG_THREADS = (ctx.applicationInfo.flags and android.content.pm.ApplicationInfo.FLAG_DEBUGGABLE) != 0
    }
    androidx.activity.compose.BackHandler(enabled = scoreTakeId != null) { scoreTakeId = null }
    scoreTakeId?.let { id ->
        ScoreScreen(graph, id, onBack = { scoreTakeId = null }, onNeedPacks = { scoreTakeId = null; section = InstrumentsSection.Packs.name }, modifier = modifier)
        return
    }
    Column(modifier.fillMaxSize().testTag("instruments-screen")) {
        SingleChoiceSegmentedButtonRow(Modifier.fillMaxWidth().padding(horizontal = 8.dp, vertical = 4.dp)) {
            InstrumentsSection.entries.forEachIndexed { i, s ->
                SegmentedButton(
                    selected = current == s, onClick = { section = s.name },
                    shape = SegmentedButtonDefaults.itemShape(i, InstrumentsSection.entries.size), icon = {},
                    modifier = Modifier.testTag("instruments-section-${s.name.lowercase()}"),
                ) { Text(s.label) }
            }
        }
        when (current) {
            InstrumentsSection.Play -> PlaySection(graph, onNeedPacks = { section = InstrumentsSection.Packs.name })
            InstrumentsSection.Takes -> TakesScreen(graph, onNeedPacks = { section = InstrumentsSection.Packs.name }, onOpenScore = { scoreTakeId = it })
            InstrumentsSection.Packs -> Column(Modifier.verticalScroll(rememberScrollState())) { PacksSection(graph) }
        }
    }
}

@Composable
private fun PlaySection(graph: AppGraph, onNeedPacks: () -> Unit) {
    val studio = graph.studioGraph
    val engine = studio.instrumentEngine
    val packs = studio.instrumentPacks
    val st by engine.state.collectAsState()
    val packState by packs.state.collectAsState()
    val odState by engine.overdub.state.collectAsState()
    val scope = rememberCoroutineScope()
    var message by remember { mutableStateOf<String?>(null) }
    var bpm by rememberSaveable { mutableIntStateOf(120) }
    // The two take switches persist (iOS studioClickEnabled / studioCountInEnabled, both ON by default).
    val (clickState, setClickOn) = rememberPrefState(graph, com.levi.pocketdj.studio.midi.MidiSettings.CLICK_ENABLED, true)
    val (countInState, setCountIn) = rememberPrefState(graph, com.levi.pocketdj.studio.midi.MidiSettings.COUNT_IN_ENABLED, true)
    val clickOn = clickState.value
    val countIn = countInState.value
    var octave by rememberSaveable { mutableIntStateOf(4) }       // first C of the 2-octave board
    var filing by remember { mutableStateOf(false) }

    suspend fun select(key: InstrumentKey): Boolean {
        val pack = packs.pack(key)
        val bank = packs.localBankFile(key)
        if (pack == null || bank == null) { message = "Download the ${key.displayName} pack to play it."; onNeedPacks(); return false }
        if (!engine.loadInstrument(key, bank)) { message = "Couldn't load the ${key.displayName} sound bank."; return false }
        message = null
        return true
    }

    // Open on the piano when its bank is already installed.
    LaunchedEffect(packState.downloadedSlugs, packState.index) {
        if (engine.state.value.currentInstrument == null && !engine.state.value.isLoadingInstrument && packs.localBankFile(InstrumentKey.PIANO) != null) select(InstrumentKey.PIANO)
    }
    DisposableEffect(Unit) {
        onDispose {
            engine.arp.stop()
            // Leaving Play finishes an armed overdub (iOS onDisappear): the backing must not keep looping behind another tab.
            engine.finishOverdub(engine.state.value.currentInstrument ?: InstrumentKey.PIANO)
            engine.allNotesOff()
        }
    }

    Column(Modifier.fillMaxSize().verticalScroll(rememberScrollState()).padding(12.dp), verticalArrangement = Arrangement.spacedBy(12.dp)) {
        LazyRow(horizontalArrangement = Arrangement.spacedBy(8.dp)) {
            items(InstrumentKey.entries.toList(), key = { it.raw }) { k ->
                val installed = packState.packs.firstOrNull { it.instrument == k }?.let { packState.isDownloaded(it) } == true
                FilterChip(
                    selected = st.currentInstrument == k,
                    onClick = { scope.launch { select(k) } },
                    label = { Text(if (installed || packState.packs.isEmpty()) k.displayName else k.displayName + " ↓") },
                    modifier = Modifier.testTag("instrument-${k.raw}"),
                )
            }
        }
        when {
            st.isLoadingInstrument -> Text("Loading instrument…", Modifier.testTag("instrument-loading"), color = MaterialTheme.colorScheme.onSurfaceVariant)
            st.loadError != null -> Text(st.loadError!!, color = MaterialTheme.colorScheme.error, modifier = Modifier.testTag("instrument-error"))
            st.currentInstrument == null -> Text("Pick an instrument. Sound packs are a one-time download.", color = MaterialTheme.colorScheme.onSurfaceVariant)
        }

        val (first, last) = PianoLayout.clampRange(12 * (octave + 1), 12 * (octave + 1) + 24)
        PianoKeyboard(first, last, st.pressedNotes, onNoteOn = { n, v -> engine.noteOn(n, v) }, onNoteOff = { engine.noteOff(it) })
        Row(Modifier.fillMaxWidth(), horizontalArrangement = Arrangement.SpaceBetween, verticalAlignment = Alignment.CenterVertically) {
            OutlinedButton(onClick = { octave = (octave - 1).coerceAtLeast(0) }, enabled = octave > 0, modifier = Modifier.testTag("octave-down")) { Text("Octave −") }
            Text("${PianoLayout.name(first)} – ${PianoLayout.name(last)}", style = MaterialTheme.typography.labelLarge)
            OutlinedButton(onClick = { octave = (octave + 1).coerceAtMost(8) }, enabled = octave < 8, modifier = Modifier.testTag("octave-up")) { Text("Octave +") }
        }

        // Take controls
        Row(verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(8.dp)) {
            OutlinedButton(onClick = { bpm = (bpm - 1).coerceAtLeast(ClickTrack.MIN_BPM.toInt()) }, enabled = !st.isRecordingTake) { Text("−") }
            Text("$bpm BPM", Modifier.testTag("take-bpm"), style = MaterialTheme.typography.titleMedium)
            OutlinedButton(onClick = { bpm = (bpm + 1).coerceAtMost(ClickTrack.MAX_BPM.toInt()) }, enabled = !st.isRecordingTake) { Text("+") }
        }
        Row(verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(8.dp)) {
            Text("Click"); Switch(clickOn, { setClickOn(it); if (st.isRecordingTake || st.clickEnabled) engine.setClickEnabled(it, bpm.toDouble()) }, modifier = Modifier.testTag("click-switch"))
            Text("Count-in"); Switch(countIn, { setCountIn(it) }, enabled = !st.isRecordingTake, modifier = Modifier.testTag("countin-switch"))
        }
        Row(verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(12.dp)) {
            if (!st.isRecordingTake) {
                Button(
                    onClick = {
                        if (!engine.startTake(bpm.toDouble(), clickOn, countIn)) message = "Pick an instrument first."
                        else message = null
                    },
                    enabled = st.currentInstrument != null && !st.isLoadingInstrument && !filing,
                    modifier = Modifier.testTag("take-record"),
                ) { Text("Record") }
                OutlinedButton(onClick = { engine.setClickEnabled(!st.clickEnabled, bpm.toDouble()) }, modifier = Modifier.testTag("click-toggle")) { Text(if (st.clickEnabled) "Click off" else "Click on") }
            } else {
                Button(
                    onClick = {
                        val r = engine.stopTake()
                        if (r == null) message = "Take cancelled."
                        else {
                            filing = true
                            // Final review: filing outlives this screen (leaving it mid-render used to cancel it and lose the take).
                            graph.appScope.launch {
                                try {
                                    val name = "Take ${studio.studioStore.takes(null).size + 1}"
                                    val bank = packs.localBankFile(r.instrument)
                                    withContext(Dispatchers.IO) { studio.takeFiler.file(r, name, bank) }
                                    message = "Saved “$name” — find it under Takes."
                                } catch (e: TakeFileException) { message = e.failure.message } finally { filing = false }
                            }
                        }
                    },
                    colors = ButtonDefaults.buttonColors(containerColor = MaterialTheme.colorScheme.error),
                    modifier = Modifier.testTag("take-stop"),
                ) { Text(if (st.isCountingIn) "Counting in… (cancel)" else "Stop") }
            }
            if (filing) Text("Saving…", color = MaterialTheme.colorScheme.onSurfaceVariant)
        }
        if (st.liveEvents.isNotEmpty() || odState.staffs.isNotEmpty() || odState.active) {
            Row(verticalAlignment = Alignment.CenterVertically) {
                Text("${st.liveEvents.size} notes played", Modifier.weight(1f).testTag("live-count"), color = MaterialTheme.colorScheme.onSurfaceVariant)
                if (st.liveCaptureFull) Text("Capture full  ", color = MaterialTheme.colorScheme.error)
                TextButton(onClick = { engine.clearLiveScore() }, modifier = Modifier.testTag("live-clear")) { Text("Clear") }
            }
        }
        ArpPanel(graph, engine, bpm, onMessage = { message = it })
        MidiDevicesSection(graph)
        MidiImportButton(graph, onMessage = { message = it }, onNeedPacks = onNeedPacks, tag = "instruments-import-midi")
        LiveStaff(graph, onMessage = { message = it })
        OverdubControls(graph, engine, bpm, onMessage = { message = it })
        message?.let { Text(it, Modifier.testTag("instruments-message"), color = MaterialTheme.colorScheme.onSurfaceVariant) }
    }
}

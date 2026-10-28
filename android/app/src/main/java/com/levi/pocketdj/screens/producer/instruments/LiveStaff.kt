package com.levi.pocketdj.screens.producer.instruments

import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.OutlinedButton
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.runtime.collectAsState
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.rememberCoroutineScope
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.platform.testTag
import androidx.compose.ui.unit.dp
import com.levi.pocketdj.di.AppGraph
import com.levi.pocketdj.studio.engine.TakeFileException
import com.levi.pocketdj.studio.engine.TakeResult
import com.levi.pocketdj.studio.model.InstrumentKey
import com.levi.pocketdj.studio.model.StudioFactory
import com.levi.pocketdj.studio.model.StudioNoteEvent
import com.levi.pocketdj.studio.store.StudioFamily
import com.levi.pocketdj.studio.store.StudioFolders
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.launch
import kotlinx.coroutines.withContext

/** Pure "Save as take" shaping for the live staff (iOS `saveLiveAsTake`). */
object LiveStaffSave {
    /** The live score's click tempo (iOS files it at 120). */
    const val LIVE_BPM = 120.0
    /** Floor for the take length so a one-tap capture still has a sane duration. */
    const val MIN_DURATION_MS = 500

    /** The [TakeResult] to file for [events], or null when there is nothing to save. [newId] mints the take id. */
    fun result(events: List<StudioNoteEvent>, instrument: InstrumentKey, newId: () -> String = StudioFactory::newTakeId): TakeResult? {
        if (events.isEmpty()) return null
        val id = newId()
        val dur = maxOf(MIN_DURATION_MS, events.maxOf { it.offMs })
        return TakeResult(id, StudioFolders.fileName(StudioFamily.TAKES, id), dur, events, LIVE_BPM, instrument)
    }
}

/**
 * The always-on LIVE staff (iOS `LiveStaffView` + the live score section): notes played on the keys appear as notation WHILE you play,
 * editable in place, and "Save" files them as a take (its audio is rendered from the events, so launch reconcile keeps the file).
 */
@Composable
fun LiveStaff(graph: AppGraph, onMessage: (String) -> Unit, modifier: Modifier = Modifier) {
    val studio = graph.studioGraph
    val engine = studio.instrumentEngine
    val es by engine.state.collectAsState()
    val scope = rememberCoroutineScope()
    var editing by remember { mutableStateOf(false) }
    var saving by remember { mutableStateOf(false) }
    val instrument = es.currentInstrument ?: InstrumentKey.PIANO

    Column(modifier.fillMaxWidth().testTag("live-staff"), verticalArrangement = Arrangement.spacedBy(8.dp)) {
        Row(Modifier.fillMaxWidth(), horizontalArrangement = Arrangement.spacedBy(8.dp), verticalAlignment = Alignment.CenterVertically) {
            Text("Live score", style = MaterialTheme.typography.titleSmall, modifier = Modifier.weight(1f))
            if (es.liveEvents.isNotEmpty()) {
                OutlinedButton({ editing = !editing }, modifier = Modifier.testTag("live-edit")) { Text(if (editing) "Done" else "Edit") }
                OutlinedButton(
                    onClick = {
                        val r = LiveStaffSave.result(es.liveEvents, instrument) ?: return@OutlinedButton
                        saving = true
                        scope.launch {
                            try {
                                val name = "Take ${studio.studioStore.takes(null).size + 1}"
                                val bank = studio.instrumentPacks.localBankFile(instrument)
                                withContext(Dispatchers.IO) { studio.takeFiler.file(r, name, bank) }
                                engine.clearLive(); editing = false
                                onMessage("Saved “$name” — find it under Takes.")
                            } catch (e: TakeFileException) { onMessage(e.failure.message) } finally { saving = false }
                        }
                    },
                    enabled = !saving, modifier = Modifier.testTag("live-save"),
                ) { Text(if (saving) "Saving…" else "Save as take") }
            }
        }
        if (es.liveEvents.isEmpty() && !editing) {
            Text("Play the keys — your notes appear here as a score you can edit and save as a take.", style = MaterialTheme.typography.bodySmall, color = MaterialTheme.colorScheme.onSurfaceVariant)
        } else {
            ScoreEditor(
                events = es.liveEvents, bpm = LiveStaffSave.LIVE_BPM, instrument = instrument, title = "Live", editing = editing,
                onEdit = { engine.setLiveEvents(it) }, tagPrefix = "live-score",
            )
        }
    }
}

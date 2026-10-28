package com.levi.pocketdj.screens.producer.instruments

import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.material3.Button
import androidx.compose.material3.ButtonDefaults
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.OutlinedButton
import androidx.compose.material3.Switch
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.collectAsState
import androidx.compose.runtime.getValue
import androidx.compose.runtime.rememberCoroutineScope
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.platform.testTag
import androidx.compose.ui.unit.dp
import com.levi.pocketdj.di.AppGraph
import com.levi.pocketdj.studio.engine.InstrumentEngine
import com.levi.pocketdj.studio.engine.LiveExtraStaff
import com.levi.pocketdj.studio.engine.OverdubMath
import com.levi.pocketdj.studio.engine.SynthVoice
import com.levi.pocketdj.studio.midi.MidiSettings
import com.levi.pocketdj.studio.model.InstrumentKey
import kotlinx.coroutines.Dispatchers
import com.levi.pocketdj.studio.engine.OverdubFinish
import kotlinx.coroutines.launch
import kotlinx.coroutines.withContext

/**
 * Overdub controls for the free-play LIVE score (iOS live overdub): up to 4 staffs, a confined region
 * [0, scoreEnd), Loop toggle (wrap/layer), and the monitoring click switch. Played notes — hand, MIDI or arp —
 * capture into the NEW staff only; the existing score plays back as the backing.
 */
@Composable
fun OverdubControls(graph: AppGraph, engine: InstrumentEngine, bpm: Int, onMessage: (String?) -> Unit, modifier: Modifier = Modifier) {
    val od = engine.overdub
    val st by od.state.collectAsState()
    val es by engine.state.collectAsState()
    val scope = rememberCoroutineScope()
    val packs = graph.studioGraph.instrumentPacks
    val (loop, setLoop) = rememberPrefState(graph, MidiSettings.OVERDUB_LOOP, false)
    val (monitor, setMonitor) = rememberPrefState(graph, MidiSettings.OVERDUB_CLICK_ENABLED, false)
    val instrument = es.currentInstrument ?: InstrumentKey.PIANO

    fun finish() {
        when (engine.finishOverdub(instrument)) {
            OverdubFinish.NOTHING -> onMessage("Nothing was played, so no staff was added.")
            OverdubFinish.CAP -> onMessage("A score holds at most ${OverdubMath.MAX_STAFFS} staffs.")
            else -> onMessage(null)
        }
    }

    // Loop OFF: the confined region ran out; the 30 Hz pump flagged it — finalize cleanly.
    LaunchedEffect(st.reachedEnd) { if (st.active && st.reachedEnd) finish() }

    fun start() {
        if (es.currentInstrument == null) { onMessage("Pick an instrument first."); return }
        val staffs = listOf(es.liveEvents) + st.staffs.map { it.events }
        val end = OverdubMath.scoreEndMs(staffs)
        if (!OverdubMath.hasOverdubRoom(0, end)) { onMessage(OverdubMath.NO_ROOM_MESSAGE); return }
        val region = if (end == 0) Int.MAX_VALUE else end
        if (!od.start(0, region, loop.value, midTake = es.isRecordingTake)) { onMessage(OverdubMath.NO_ROOM_MESSAGE); return }
        onMessage(null)
        engine.overdubMonitorClick = monitor.value
        if (monitor.value) engine.setClickEnabled(true, bpm.toDouble())
        if (end == 0) return                                   // overdub from silence: no backing
        od.setBackingPreparing(true)
        scope.launch {
            val extras = ArrayList<Pair<SynthVoice, List<com.levi.pocketdj.studio.model.StudioNoteEvent>>>()
            var primaryEvents = es.liveEvents
            // Each voice is a full float copy of the SF2 (tens of MB native): ANY exit that did not hand them to replay()
            // (cancellation while preparing included) must close them.
            var handedOff = false
            try {
            withContext(Dispatchers.Default) {
                // Staff 1 plays through its OWN voice: the engine's live voice is the user's overdub voice and must stay free (iOS).
                val bank1 = packs.localBankFile(instrument)
                val v1 = if (bank1 != null && es.liveEvents.isNotEmpty()) runCatching { engine.createVoice() }.getOrNull() else null
                if (v1 != null) {
                    if (runCatching { v1.load(bank1!!.path) && v1.setPreset(0, instrument.gmProgram) }.getOrDefault(false)) { extras.add(v1 to es.liveEvents); primaryEvents = emptyList() }
                    else runCatching { v1.close() }
                }
                for (s in st.staffs) {
                    val bank = packs.localBankFile(s.instrument) ?: continue
                    val v = runCatching { engine.createVoice() }.getOrNull() ?: continue
                    if (runCatching { v.load(bank.path) && v.setPreset(0, s.instrument.gmProgram) }.getOrDefault(false)) extras.add(v to s.events) else runCatching { v.close() }
                }
            }
            if (!od.isActive) { extras.forEach { runCatching { it.first.close() } }; return@launch }
            val ok = engine.replay(primaryEvents, 0, extras, if (loop.value) 0 to end else null)
            if (ok) { handedOff = true; od.setBackingReady(true); od.reanchorIfEmpty() }
            else { od.setBackingPreparing(false); od.reanchorIfEmpty(); extras.forEach { runCatching { it.first.close() } } }
            } finally {
                if (!handedOff) extras.forEach { runCatching { it.first.close() } }
            }
        }
    }

    Column(modifier.fillMaxWidth().testTag("overdub-controls"), verticalArrangement = Arrangement.spacedBy(6.dp)) {
        Text("Overdub", style = MaterialTheme.typography.titleSmall)
        Row(verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(8.dp)) {
            Text("Loop"); Switch(loop.value, { setLoop(it) }, enabled = !st.active, modifier = Modifier.testTag("overdub-loop"))
            Text("Click"); Switch(monitor.value, { setMonitor(it); if (st.active || es.clickEnabled) engine.setClickEnabled(it, bpm.toDouble()) }, modifier = Modifier.testTag("overdub-click"))
        }
        Row(verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(8.dp)) {
            if (!st.active) {
                Button(
                    onClick = { start() },
                    enabled = !es.isRecordingTake && 1 + st.staffs.size < OverdubMath.MAX_STAFFS,
                    modifier = Modifier.testTag("overdub-start"),
                ) { Text("Overdub") }
            } else {
                Button({ finish() }, colors = ButtonDefaults.buttonColors(containerColor = MaterialTheme.colorScheme.error), modifier = Modifier.testTag("overdub-end")) { Text("End overdub") }
                Text(if (st.loop) "Looping — layering" else if (st.backingPreparing) "Preparing backing…" else "Recording a new staff", color = MaterialTheme.colorScheme.onSurfaceVariant)
            }
        }
        if (st.active && st.events.isNotEmpty()) {
            ScoreEditor(events = st.events, bpm = 120.0, instrument = instrument, title = "Recording", editing = false, onEdit = {}, tagPrefix = "overdub-live")
        }
        st.staffs.forEachIndexed { i, s -> ExtraStaff(i + 2, s, onEdit = { od.setStaffEvents(s.id, it) }, onDelete = { od.deleteStaff(s.id) }) }
    }
}

@Composable
private fun ExtraStaff(number: Int, s: LiveExtraStaff, onEdit: (List<com.levi.pocketdj.studio.model.StudioNoteEvent>) -> Unit, onDelete: () -> Unit) {
    Column(verticalArrangement = Arrangement.spacedBy(4.dp)) {
        Row(verticalAlignment = Alignment.CenterVertically) {
            Text("Staff $number · ${s.instrument.displayName}", Modifier.weight(1f).testTag("overdub-staff-title-$number"), style = MaterialTheme.typography.labelLarge)
            OutlinedButton(onDelete, modifier = Modifier.testTag("overdub-staff-delete-$number")) { Text("Remove") }
        }
        ScoreEditor(events = s.events, bpm = 120.0, instrument = s.instrument, title = "Staff $number", editing = false, onEdit = onEdit, tagPrefix = "overdub-staff-$number")
    }
}

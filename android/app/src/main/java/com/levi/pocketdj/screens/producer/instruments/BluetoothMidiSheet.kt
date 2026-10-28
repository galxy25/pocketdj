package com.levi.pocketdj.screens.producer.instruments

import android.media.midi.MidiManager
import androidx.activity.compose.rememberLauncherForActivityResult
import androidx.activity.result.contract.ActivityResultContracts
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.verticalScroll
import androidx.compose.material3.ExperimentalMaterial3Api
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.ModalBottomSheet
import androidx.compose.material3.OutlinedButton
import androidx.compose.material3.Text
import androidx.compose.material3.rememberModalBottomSheetState
import androidx.compose.runtime.Composable
import androidx.compose.runtime.DisposableEffect
import androidx.compose.runtime.collectAsState
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.platform.testTag
import androidx.compose.ui.unit.dp
import com.levi.pocketdj.studio.engine.InstrumentEngine
import com.levi.pocketdj.studio.midi.BleMidiScanner
import com.levi.pocketdj.studio.midi.EngineMidiSink
import com.levi.pocketdj.studio.midi.MidiInput

/**
 * The MIDI section of the Play tab: the USB/connected device list (an explicit empty state when nothing is
 * attached — the emulator has no MIDI devices) plus the "Bluetooth MIDI…" connect sheet.
 */
@Composable
fun MidiDevicesSection(graph: com.levi.pocketdj.di.AppGraph, modifier: Modifier = Modifier) {
    // App-scoped (StudioGraph): leaving this screen stops the scan but never drops a connected keyboard.
    val input = graph.studioGraph.midiInput
    val scanner = graph.studioGraph.bleMidiScanner
    DisposableEffect(input) { input.start(); onDispose { scanner.stopScan() } }
    val st by input.state.collectAsState()
    var sheet by remember { mutableStateOf(false) }

    Column(modifier.fillMaxWidth().testTag("midi-section"), verticalArrangement = Arrangement.spacedBy(6.dp)) {
        Row(verticalAlignment = Alignment.CenterVertically) {
            Text("MIDI input", style = MaterialTheme.typography.titleSmall, modifier = Modifier.weight(1f))
            OutlinedButton({ sheet = true }, enabled = st.supported, modifier = Modifier.testTag("midi-bluetooth")) { Text("Bluetooth MIDI…") }
        }
        when {
            !st.supported -> Text("This device doesn't support MIDI.", color = MaterialTheme.colorScheme.onSurfaceVariant, modifier = Modifier.testTag("midi-empty"))
            st.devices.isEmpty() -> Text("No MIDI keyboards connected. Plug one in over USB, or connect a Bluetooth keyboard.", style = MaterialTheme.typography.bodySmall, color = MaterialTheme.colorScheme.onSurfaceVariant, modifier = Modifier.testTag("midi-empty"))
            else -> st.devices.forEach { d ->
                Row(verticalAlignment = Alignment.CenterVertically, modifier = Modifier.testTag("midi-device")) {
                    Text("${d.name} · ${d.transport.name.lowercase()}", Modifier.weight(1f))
                    OutlinedButton({ if (d.connected) input.disconnect(d.id) else input.connect(d.id) }) { Text(if (d.connected) "Connected" else "Connect") }
                }
            }
        }
        st.lastError?.let { Text(it, color = MaterialTheme.colorScheme.error) }
    }
    if (sheet) BluetoothMidiSheet(scanner, input) { sheet = false }
}

/** The Connect-Bluetooth-MIDI sheet: a live scan list with Connect / Connected per keyboard. */
@OptIn(ExperimentalMaterial3Api::class)
@Composable
fun BluetoothMidiSheet(scanner: BleMidiScanner, input: MidiInput, onDismiss: () -> Unit) {
    val st by scanner.state.collectAsState()
    val midi by input.state.collectAsState()
    val perms = rememberLauncherForActivityResult(ActivityResultContracts.RequestMultiplePermissions()) { scanner.start() }
    DisposableEffect(scanner) {
        if (scanner.hasPermission()) scanner.start() else perms.launch(scanner.requiredPermissions())
        onDispose { scanner.stopScan() }
    }
    ModalBottomSheet(onDismissRequest = onDismiss, sheetState = rememberModalBottomSheetState(skipPartiallyExpanded = true), modifier = Modifier.testTag("ble-midi-sheet")) {
        Column(Modifier.verticalScroll(rememberScrollState()).padding(horizontal = 16.dp).padding(bottom = 24.dp), verticalArrangement = Arrangement.spacedBy(8.dp)) {
            Text("Bluetooth MIDI", style = MaterialTheme.typography.titleMedium)
            if (st.devices.isEmpty()) {
                Text(
                    when {
                        st.needsPermission -> "Allow Bluetooth access to find MIDI keyboards."
                        st.error != null -> st.error!!
                        !st.poweredOn -> "Turn on Bluetooth to find MIDI keyboards."
                        else -> "Scanning for Bluetooth MIDI keyboards… put yours in pairing mode."
                    },
                    style = MaterialTheme.typography.bodySmall, color = MaterialTheme.colorScheme.onSurfaceVariant, modifier = Modifier.testTag("ble-midi-status"),
                )
            }
            st.devices.forEach { d ->
                Row(verticalAlignment = Alignment.CenterVertically, modifier = Modifier.testTag("ble-midi-device")) {
                    Text(d.name, Modifier.weight(1f))
                    OutlinedButton(
                        onClick = { if (d.connected) scanner.disconnect(d.address) else scanner.connect(d.address) },
                        enabled = !d.connecting,
                    ) { Text(if (d.connected) "Connected" else if (d.connecting) "Connecting…" else "Connect") }
                }
            }
            Text("Pair a keyboard here, then play — its notes drive the current instrument exactly like the on-screen keys, and record into a take when you're recording.", style = MaterialTheme.typography.bodySmall, color = MaterialTheme.colorScheme.onSurfaceVariant)
        }
    }
}

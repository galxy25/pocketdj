package com.levi.pocketdj.screens.producer.instruments

import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.lazy.LazyRow
import androidx.compose.foundation.lazy.items
import androidx.compose.material3.FilterChip
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.OutlinedButton
import androidx.compose.material3.Slider
import androidx.compose.material3.Switch
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.MutableState
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
import com.levi.pocketdj.data.settings.PrefKey
import com.levi.pocketdj.di.AppGraph
import com.levi.pocketdj.studio.engine.ArpOrder
import com.levi.pocketdj.studio.engine.ArpSettings
import com.levi.pocketdj.studio.engine.ArpStepLength
import com.levi.pocketdj.studio.engine.InstrumentEngine
import com.levi.pocketdj.studio.midi.MidiSettings
import kotlinx.coroutines.launch

/** A persisted pref as Compose state: loads once, writes through on every set (the iOS "every write persists" rule). */
@Composable
internal fun <T> rememberPrefState(graph: AppGraph, key: PrefKey<T>, default: T, onLoaded: (T) -> Unit = {}): Pair<MutableState<T>, (T) -> Unit> {
    val state = remember { mutableStateOf(default) }
    val scope = rememberCoroutineScope()
    LaunchedEffect(key) {
        val v = runCatching { graph.settings.get(key) }.getOrDefault(default)
        state.value = v; onLoaded(v)
    }
    return state to { v: T -> state.value = v; scope.launch { runCatching { graph.settings.set(key, v) } }; Unit }
}

/**
 * The arpeggiator panel (iOS Instruments-tab arp section): master switch, PROGRAM mode (keys toggle membership and
 * write nothing to any score), transport ▶/⏸, order/length/octaves/swing/latch knobs — all persisted.
 */
@Composable
fun ArpPanel(graph: AppGraph, engine: InstrumentEngine, bpm: Int, onMessage: (String?) -> Unit, modifier: Modifier = Modifier) {
    val arp = engine.arp
    val st by arp.state.collectAsState()
    val s = st.settings
    var loaded by remember { mutableStateOf(false) }
    val (_, setOrder) = rememberPrefState(graph, MidiSettings.ARP_ORDER, "up")
    val (_, setLength) = rememberPrefState(graph, MidiSettings.ARP_LENGTH, 16)
    val (_, setOctaves) = rememberPrefState(graph, MidiSettings.ARP_OCTAVES, 1)
    val (_, setSwing) = rememberPrefState(graph, MidiSettings.ARP_SWING, 50.0)
    val (_, setLatch) = rememberPrefState(graph, MidiSettings.ARP_LATCH, true)
    LaunchedEffect(Unit) {
        if (!loaded) {
            loaded = true
            val g = graph.settings
            val persisted = runCatching {
                ArpSettings.fromPersisted(g.get(MidiSettings.ARP_ORDER), g.get(MidiSettings.ARP_LENGTH), g.get(MidiSettings.ARP_OCTAVES), g.get(MidiSettings.ARP_SWING), g.get(MidiSettings.ARP_LATCH))
            }.getOrNull()
            if (persisted != null) arp.setSettings(persisted)
        }
    }

    Column(modifier.fillMaxWidth().testTag("arp-panel"), verticalArrangement = Arrangement.spacedBy(6.dp)) {
        Row(verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(8.dp)) {
            Text("Arpeggiator", style = MaterialTheme.typography.titleSmall, modifier = Modifier.weight(1f))
            Switch(st.enabled, { arp.setEnabled(it) }, modifier = Modifier.testTag("arp-enabled"))
        }
        if (st.enabled) {
            Row(horizontalArrangement = Arrangement.spacedBy(8.dp), verticalAlignment = Alignment.CenterVertically) {
                FilterChip(st.programming, { arp.setProgramming(!st.programming) }, label = { Text("Program") }, modifier = Modifier.testTag("arp-program"))
                OutlinedButton(
                    onClick = { if (st.playing) arp.stop() else if (!engine.startArp(bpm.toDouble())) onMessage(if (st.selected.isEmpty()) "Tap Program, then press keys to build a pattern." else "Pick an instrument first.") },
                    modifier = Modifier.testTag("arp-transport"),
                ) { Text(if (st.playing) "Pause" else "Play") }
                OutlinedButton({ arp.clearSelection() }, enabled = st.selected.isNotEmpty(), modifier = Modifier.testTag("arp-clear")) { Text("Clear") }
            }
            Text(
                when {
                    st.programming -> "Programming — press keys to add or remove them (nothing is recorded). ${st.selected.size} in pattern."
                    st.selected.isEmpty() -> "No notes yet. Turn on Program and press keys."
                    else -> "${st.selected.size} notes in pattern."
                },
                style = MaterialTheme.typography.bodySmall, color = MaterialTheme.colorScheme.onSurfaceVariant, modifier = Modifier.testTag("arp-status"),
            )
            LazyRow(horizontalArrangement = Arrangement.spacedBy(6.dp)) {
                items(ArpOrder.entries.toList(), key = { it.raw }) { o ->
                    FilterChip(s.order == o, { arp.setSettings(s.copy(order = o)); setOrder(o.raw) }, label = { Text(o.raw.replaceFirstChar { it.uppercase() }) }, modifier = Modifier.testTag("arp-order-${o.raw}"))
                }
            }
            LazyRow(horizontalArrangement = Arrangement.spacedBy(6.dp)) {
                items(ArpStepLength.entries.sortedBy { it.denominator }.reversed(), key = { it.denominator }) { l ->
                    FilterChip(s.length == l, { arp.setSettings(s.copy(length = l)); setLength(l.denominator) }, label = { Text("1/${l.denominator}") }, modifier = Modifier.testTag("arp-length-${l.denominator}"))
                }
            }
            Row(verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(8.dp)) {
                Text("Octaves")
                OutlinedButton({ val v = (s.octaves - 1).coerceAtLeast(1); arp.setSettings(s.copy(octaves = v)); setOctaves(v) }, enabled = s.octaves > 1, modifier = Modifier.testTag("arp-oct-down")) { Text("−") }
                Text("${s.octaves}", Modifier.testTag("arp-octaves"))
                OutlinedButton({ val v = (s.octaves + 1).coerceAtMost(4); arp.setSettings(s.copy(octaves = v)); setOctaves(v) }, enabled = s.octaves < 4, modifier = Modifier.testTag("arp-oct-up")) { Text("+") }
                Text("Latch"); Switch(s.latch, { arp.setSettings(s.copy(latch = it)); setLatch(it) }, modifier = Modifier.testTag("arp-latch"))
            }
            Row(verticalAlignment = Alignment.CenterVertically) {
                Text("Swing ${s.swingPct.toInt()}%", Modifier.testTag("arp-swing-label"))
                Slider(
                    value = s.swingPct.toFloat(), onValueChange = { arp.setSettings(s.copy(swingPct = it.toDouble().coerceIn(50.0, 75.0))) },
                    onValueChangeFinished = { setSwing(arp.state.value.settings.swingPct) },
                    valueRange = 50f..75f, modifier = Modifier.weight(1f).testTag("arp-swing"),
                )
            }
        }
    }
}

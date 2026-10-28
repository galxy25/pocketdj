package com.levi.pocketdj.screens.mix

import android.content.res.Configuration
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.verticalScroll
import androidx.compose.material3.OutlinedButton
import androidx.compose.material3.Surface
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
import androidx.compose.ui.Modifier
import androidx.compose.ui.platform.LocalConfiguration
import androidx.compose.ui.unit.dp
import androidx.compose.ui.window.Dialog
import androidx.compose.ui.window.DialogProperties
import com.levi.pocketdj.di.AppGraph

/**
 * Debug-only host for the MIX-13 deck UI until MIX-14 routes the Mix tab: the real [DeckArea],
 * [CrossfaderView] and [MasterTransport] over the app-scoped engine. Opened from Settings > Debug.
 */
@Composable
fun DebugDeckHarness(graph: AppGraph, onDismiss: () -> Unit) {
    val mix = graph.mixGraph
    val host = remember {
        DeckHost(engine = mix.mixEngine, stems = mix.mixDeckExtras.stems, loops = mix.mixDeckExtras.loops, streams = mix.mixStreamDecks)
    }
    var layout by remember { mutableStateOf(DeckLayout.STACKED) }
    val landscape = LocalConfiguration.current.orientation == Configuration.ORIENTATION_LANDSCAPE
    Dialog(onDismissRequest = onDismiss, properties = DialogProperties(usePlatformDefaultWidth = false)) {
        Surface(Modifier.fillMaxSize()) {
            Column(Modifier.verticalScroll(rememberScrollState()).padding(12.dp), verticalArrangement = Arrangement.spacedBy(10.dp)) {
                Row(horizontalArrangement = Arrangement.spacedBy(6.dp)) {
                    DeckLayout.entries.forEach { l -> OutlinedButton(onClick = { layout = l }) { Text(l.raw) } }
                    OutlinedButton(onClick = onDismiss) { Text("Close") }
                }
                DeckArea(host = host, layout = layout, landscape = landscape, onLoad = {}, beatPulseEnabled = true)
                CrossfaderView(engine = host.engine)
                MasterTransport(engine = host.engine)
            }
        }
    }
}

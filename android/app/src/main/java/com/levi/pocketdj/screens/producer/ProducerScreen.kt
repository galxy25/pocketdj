package com.levi.pocketdj.screens.producer

import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.padding
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.filled.AccountTree
import androidx.compose.material.icons.filled.Bookmarks
import androidx.compose.material.icons.filled.GraphicEq
import androidx.compose.material.icons.filled.Piano
import androidx.compose.material.icons.filled.Repeat
import androidx.compose.material.icons.filled.ViewTimeline
import androidx.compose.material.icons.filled.Grid4x4
import androidx.compose.material3.Icon
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.SegmentedButton
import androidx.compose.material3.SegmentedButtonDefaults
import androidx.compose.material3.SingleChoiceSegmentedButtonRow
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.rememberCoroutineScope
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.platform.LocalConfiguration
import androidx.compose.ui.platform.testTag
import androidx.compose.ui.semantics.contentDescription
import androidx.compose.ui.semantics.semantics
import androidx.compose.ui.unit.dp
import com.levi.pocketdj.di.AppGraph
import com.levi.pocketdj.screens.producer.loops.LoopsScreen
import com.levi.pocketdj.screens.producer.samples.SamplesScreen
import com.levi.pocketdj.screens.producer.sequencer.SequencerScreen
import com.levi.pocketdj.studio.StudioSettings
import kotlinx.coroutines.launch

private fun StudioSubTab.icon() = when (this) {
    StudioSubTab.Samples -> Icons.Filled.GraphicEq
    StudioSubTab.Loops -> Icons.Filled.Repeat
    StudioSubTab.Sequencer -> Icons.Filled.Grid4x4
    StudioSubTab.Instruments -> Icons.Filled.Piano
    StudioSubTab.Cues -> Icons.Filled.Bookmarks
    StudioSubTab.Demuxer -> Icons.Filled.AccountTree
    StudioSubTab.Tracks -> Icons.Filled.ViewTimeline
}

/**
 * The Producer tab: a 7-segment sub-tab row (icon-only under 600 dp of width), the last sub-tab persisted
 * in AppSettings (`studioTab`, same raw values as iOS). Samples is live; the other sub-tabs are owned by
 * later Studio packages and show a placeholder until they land.
 */
@Composable
fun ProducerScreen(graph: AppGraph, modifier: Modifier = Modifier, hideTabs: Boolean = false) {
    val settings = graph.settings
    val scope = rememberCoroutineScope()
    var tab by remember { mutableStateOf(StudioSubTab.Samples) }
    var restored by remember { mutableStateOf(false) }
    LaunchedEffect(Unit) {
        tab = StudioSubTab.fromRaw(runCatching { settings.get(StudioSettings.STUDIO_TAB) }.getOrNull())
        restored = true
    }
    val widthDp = LocalConfiguration.current.screenWidthDp
    val iconOnly = StudioSubTab.iconOnly(widthDp)

    Column(modifier.fillMaxSize().testTag("producer-screen")) {
        if (!hideTabs) {
            SingleChoiceSegmentedButtonRow(Modifier.fillMaxWidth().padding(horizontal = 8.dp, vertical = 6.dp)) {
                val all = StudioSubTab.entries
                all.forEachIndexed { i, t ->
                    SegmentedButton(
                        selected = tab == t,
                        onClick = { tab = t; scope.launch { settings.set(StudioSettings.STUDIO_TAB, t.raw) } },
                        shape = SegmentedButtonDefaults.itemShape(i, all.size),
                        icon = {},
                        label = {
                            if (iconOnly) Icon(t.icon(), contentDescription = t.label, modifier = Modifier.semantics { contentDescription = t.label })
                            else Text(t.label, maxLines = 1)
                        },
                        modifier = Modifier.testTag("studio-tab-${t.raw}"),
                    )
                }
            }
        }
        Box(Modifier.fillMaxSize()) {
            if (restored) when (tab) {
                StudioSubTab.Samples -> SamplesScreen(graph)
                StudioSubTab.Loops -> LoopsScreen(graph)
                StudioSubTab.Sequencer -> SequencerScreen(graph)
                else -> ComingSoon(tab)
            }
        }
    }
}

@Composable
private fun ComingSoon(tab: StudioSubTab) {
    Column(Modifier.fillMaxSize().padding(24.dp), verticalArrangement = Arrangement.Center, horizontalAlignment = Alignment.CenterHorizontally) {
        Icon(tab.icon(), null, tint = MaterialTheme.colorScheme.onSurfaceVariant)
        Text(tab.label, style = MaterialTheme.typography.titleMedium, modifier = Modifier.padding(top = 8.dp))
        Text("Coming soon to Android.", color = MaterialTheme.colorScheme.onSurfaceVariant, modifier = Modifier.testTag("studio-coming-soon"))
    }
}

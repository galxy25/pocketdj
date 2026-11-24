package com.levi.pocketdj.screens.browse

import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.Text
import androidx.compose.material3.TextButton
import androidx.compose.runtime.Composable
import androidx.compose.runtime.collectAsState
import androidx.compose.runtime.getValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.platform.testTag
import com.levi.pocketdj.di.AppGraph
import com.levi.pocketdj.screens.settings.storage.MixModeBufferState

/**
 * "Buffered · expires in N h" with Keep (iOS CollectionSongRow's clock + "Keep download"). Renders
 * nothing unless the song's audio is a temporary buffer hold. Keep = explicit `pin` (a download).
 */
@Composable
fun BufferedBadge(songId: String, graph: AppGraph, modifier: Modifier = Modifier) {
    val holds by graph.servicesGraph.burnStore.temporaryHolds.collectAsState()
    val hold = holds[songId]?.takeIf { it.audio } ?: return
    Row(modifier.fillMaxWidth().testTag("buffered-badge"), horizontalArrangement = Arrangement.SpaceBetween,
        verticalAlignment = Alignment.CenterVertically) {
        Text(MixModeBufferState.badgeText(hold.expiresAtMs, System.currentTimeMillis().toDouble()),
            style = MaterialTheme.typography.bodySmall, color = MaterialTheme.colorScheme.onSurfaceVariant)
        TextButton({ graph.servicesGraph.burnStore.pin(listOf(songId), MixModeBufferState.REASON_ROW_KEEP) },
            Modifier.testTag("buffered-keep")) { Text("Keep") }
    }
}

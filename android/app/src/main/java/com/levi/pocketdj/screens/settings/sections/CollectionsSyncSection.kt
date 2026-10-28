package com.levi.pocketdj.screens.settings.sections

import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.Switch
import androidx.compose.material3.Text
import androidx.compose.runtime.collectAsState
import androidx.compose.runtime.getValue
import androidx.compose.runtime.remember
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.platform.testTag
import com.levi.pocketdj.data.collections.SourceSyncSettings
import com.levi.pocketdj.screens.settings.SettingsCaption
import com.levi.pocketdj.screens.settings.SettingsHeader
import com.levi.pocketdj.shell.SettingsSection
import kotlinx.coroutines.launch

/** Settings ▸ "Follow source playlists" (iOS "Converted collections follow their sources"). */
internal fun collectionsSyncSection() = SettingsSection("collectionsSync", 410) { host ->
    val graph = host.graph
    val on by remember(graph) { graph.settings.flow(SourceSyncSettings.SYNC_CONVERTED_POCKETS) }
        .collectAsState(initial = SourceSyncSettings.SYNC_CONVERTED_POCKETS.default)
    val state by graph.collections.state.collectAsState()
    val linked = state.pockets.count { it.hasSource } + state.playlists.count { it.hasSource }

    SettingsHeader("Collections sync")
    Row(verticalAlignment = Alignment.CenterVertically, modifier = Modifier.fillMaxWidth()) {
        Text(
            "Follow source playlists",
            style = MaterialTheme.typography.bodyMedium,
            modifier = Modifier.weight(1f),
        )
        Switch(
            checked = on,
            onCheckedChange = { v ->
                host.scope.launch { graph.settings.set(SourceSyncSettings.SYNC_CONVERTED_POCKETS, v) }
            },
            modifier = Modifier.testTag("collections-source-sync"),
        )
    }
    SettingsCaption(
        "$linked linked item${if (linked == 1) "" else "s"} follow their source playlists on every " +
            "catalog refresh while this is on. Your own edits survive. Freeze a single item from its " +
            "detail-view menu, or use \"Sync from source now\" to pull one on demand.",
    )
}

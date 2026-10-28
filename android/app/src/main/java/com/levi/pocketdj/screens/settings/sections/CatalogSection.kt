package com.levi.pocketdj.screens.settings.sections

import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.width
import androidx.compose.material3.AlertDialog
import androidx.compose.material3.Button
import androidx.compose.material3.CircularProgressIndicator
import androidx.compose.material3.OutlinedButton
import androidx.compose.material3.Text
import androidx.compose.material3.TextButton
import androidx.compose.runtime.collectAsState
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.unit.dp
import com.levi.pocketdj.screens.settings.SectionHeader
import com.levi.pocketdj.screens.settings.SettingsCaption
import com.levi.pocketdj.screens.settings.SettingsSections
import com.levi.pocketdj.shell.SettingsSection
import kotlinx.coroutines.launch

internal fun catalogSection() = SettingsSection(SettingsSections.CATALOG, 200) { host ->
    val graph = host.graph
    val catalogState by graph.catalogRepository.state.collectAsState()
    var confirmClearCache by remember { mutableStateOf(false) }

    SectionHeader("Catalog")
    catalogState.catalog?.let { catalog ->
        SettingsCaption(
            "${catalog.albums.size} albums · ${catalog.songs.size} songs · " +
                "${catalog.availableSources.size} sources",
        )
    }
    catalogState.error?.let { SettingsCaption("Last refresh: $it") }
    Row(verticalAlignment = Alignment.CenterVertically) {
        Button(
            onClick = { graph.catalogRepository.refresh() },
            enabled = !catalogState.isRefreshing,
        ) {
            Text("Reload catalog")
        }
        Spacer(Modifier.width(12.dp))
        OutlinedButton(onClick = { confirmClearCache = true }) {
            Text("Clear cache")
        }
        if (catalogState.isRefreshing) {
            Spacer(Modifier.width(12.dp))
            CircularProgressIndicator(
                modifier = Modifier.width(18.dp).height(18.dp),
                strokeWidth = 2.dp,
            )
        }
    }
    SettingsCaption(
        "Reload refreshes in place and never blanks a loaded catalog. " +
            "Clear cache removes the offline copies, then refetches.",
    )

    if (confirmClearCache) {
        AlertDialog(
            onDismissRequest = { confirmClearCache = false },
            title = { Text("Clear catalog cache?") },
            text = {
                Text(
                    "Removes the offline catalog copies from this device, then " +
                        "refetches from the network. Your sources and settings are kept.",
                )
            },
            confirmButton = {
                TextButton(
                    onClick = {
                        confirmClearCache = false
                        host.scope.launch {
                            graph.catalogService.clearCache()
                            graph.catalogRepository.refresh()
                            host.snackbar.showSnackbar("Catalog cache cleared")
                        }
                    },
                ) {
                    Text("Clear")
                }
            },
            dismissButton = {
                TextButton(onClick = { confirmClearCache = false }) { Text("Cancel") }
            },
        )
    }
}

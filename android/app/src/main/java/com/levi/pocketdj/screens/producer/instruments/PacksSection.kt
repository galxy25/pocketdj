package com.levi.pocketdj.screens.producer.instruments

import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.padding
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.filled.CheckCircle
import androidx.compose.material3.AlertDialog
import androidx.compose.material3.Button
import androidx.compose.material3.HorizontalDivider
import androidx.compose.material3.Icon
import androidx.compose.material3.LinearProgressIndicator
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.OutlinedButton
import androidx.compose.material3.Text
import androidx.compose.material3.TextButton
import androidx.compose.runtime.Composable
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.collectAsState
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.rememberCoroutineScope
import kotlinx.coroutines.launch
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.platform.testTag
import androidx.compose.ui.unit.dp
import com.levi.pocketdj.di.AppGraph
import com.levi.pocketdj.studio.packs.InstrumentBankGroup
import com.levi.pocketdj.studio.packs.InstrumentPackGroups

/**
 * Instrument packs: one row per downloadable BANK (packs sharing a bank are grouped — downloading one enables them
 * all), with progress / cancel / retry / delete and the licence attribution.
 */
@Composable
fun PacksSection(graph: AppGraph, modifier: Modifier = Modifier) {
    val packs = graph.studioGraph.instrumentPacks
    val st by packs.state.collectAsState()
    val scope = rememberCoroutineScope()
    var confirmDelete by remember { mutableStateOf<InstrumentBankGroup?>(null) }
    LaunchedEffect(Unit) { packs.refreshIndex() }
    val groups = InstrumentPackGroups.group(st.packs, st.index?.sharedBanks.orEmpty())

    Column(modifier.fillMaxWidth().padding(16.dp).testTag("packs-section"), verticalArrangement = Arrangement.spacedBy(8.dp)) {
        Text("Sound packs", style = MaterialTheme.typography.titleMedium)
        Text(
            "Instruments play from a SoundFont bank downloaded to this device (works offline once installed).",
            style = MaterialTheme.typography.bodySmall, color = MaterialTheme.colorScheme.onSurfaceVariant,
        )
        if (groups.isEmpty()) {
            Text(if (st.isRefreshing) "Loading packs…" else "No packs available right now. Check your connection.", Modifier.testTag("packs-empty"))
            if (!st.isRefreshing) OutlinedButton(onClick = { scope.launch { packs.refreshIndex() } }, modifier = Modifier.testTag("packs-retry")) { Text("Retry") }
        }
        groups.forEach { g ->
            val first = g.packs.first()
            val downloaded = st.isDownloaded(first)
            val progress = st.progress(first)
            val error = st.error(first) ?: st.errorByBank[g.bankKey]
            Column(Modifier.fillMaxWidth().testTag("bank-${com.levi.pocketdj.studio.packs.InstrumentBankNaming.slug(g.bankKey.ifEmpty { first.id })}")) {
                Row(verticalAlignment = Alignment.CenterVertically) {
                    Column(Modifier.weight(1f)) {
                        Text(g.title, style = MaterialTheme.typography.bodyLarge)
                        Text(
                            listOf(InstrumentPackGroups.sizeLabel(g.bytes), if (downloaded) "Installed" else if (!g.downloadable) "Unavailable" else "Not installed").filter { it.isNotEmpty() }.joinToString(" · "),
                            style = MaterialTheme.typography.bodySmall, color = MaterialTheme.colorScheme.onSurfaceVariant,
                        )
                    }
                    when {
                        progress != null -> TextButton(onClick = { packs.cancelDownload(first) }, modifier = Modifier.testTag("pack-cancel")) { Text("Cancel") }
                        downloaded -> {
                            Icon(Icons.Filled.CheckCircle, "Installed", tint = MaterialTheme.colorScheme.primary)
                            TextButton(onClick = { confirmDelete = g }, modifier = Modifier.testTag("pack-delete")) { Text("Delete") }
                        }
                        g.downloadable -> Button(onClick = { packs.download(first) }, modifier = Modifier.testTag("pack-download")) { Text(if (error != null) "Retry" else "Download") }
                    }
                }
                if (progress != null) {
                    LinearProgressIndicator(progress = { progress.toFloat() }, modifier = Modifier.fillMaxWidth().padding(top = 4.dp).testTag("pack-progress"))
                    Text("${(progress * 100).toInt()}%", style = MaterialTheme.typography.labelSmall)
                }
                if (error != null && progress == null) Text(error, color = MaterialTheme.colorScheme.error, style = MaterialTheme.typography.bodySmall, modifier = Modifier.testTag("pack-error"))
            }
            HorizontalDivider()
        }
        st.attribution?.let { Text(it, style = MaterialTheme.typography.labelSmall, color = MaterialTheme.colorScheme.onSurfaceVariant, modifier = Modifier.testTag("packs-attribution")) }
    }

    confirmDelete?.let { g ->
        AlertDialog(
            onDismissRequest = { confirmDelete = null },
            title = { Text("Delete sound bank?") },
            text = { Text("${g.title} will no longer play until you download it again. Existing takes keep their audio.") },
            confirmButton = { TextButton(onClick = { packs.deleteBank(g.bankKey); confirmDelete = null }, modifier = Modifier.testTag("pack-delete-confirm")) { Text("Delete") } },
            dismissButton = { TextButton(onClick = { confirmDelete = null }) { Text("Cancel") } },
        )
    }
}

package com.levi.pocketdj.screens.settings

import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.OutlinedButton
import androidx.compose.material3.Text
import androidx.compose.material3.TextButton
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
import androidx.compose.runtime.collectAsState
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.platform.testTag
import androidx.compose.ui.unit.dp
import com.levi.pocketdj.data.applemusic.WriteBackSettings
import com.levi.pocketdj.data.applemusic.WriteBackStatus
import com.levi.pocketdj.shell.SettingsSection
import kotlinx.coroutines.launch

/**
 * Settings > "Apple Music playlists" (COL-8, iOS AppleMusicSettingsView write-back half): the
 * look-back knob, "Send my adds" backfill, and the durable queue made visible (waiting / failed /
 * guessed-playlist warning / retry). The queue block hides when the queue is empty - on a healthy
 * install adds land in seconds and a permanent "0 pending" row would be noise.
 */
fun appleMusicWriteBackSection() = SettingsSection("appleMusicWriteBack", 405) { host ->
    val graph = host.graph
    val writeBack = graph.collectionsGraph.writeBack
    val queue by writeBack.state.collectAsState()
    val days by remember(graph) { graph.settings.flow(WriteBackSettings.BACKFILL_DAYS) }
        .collectAsState(initial = WriteBackSettings.BACKFILL_DEFAULT_DAYS)
    val clamped = WriteBackSettings.clampDays(days)
    var status by remember { mutableStateOf<List<String>>(emptyList()) }
    val catalog = graph.catalogRepository.state.collectAsState().value.catalog

    SettingsHeader("Apple Music playlists")
    Row(
        verticalAlignment = Alignment.CenterVertically,
        horizontalArrangement = Arrangement.spacedBy(8.dp),
        modifier = Modifier.fillMaxWidth(),
    ) {
        Text(
            "Send look-back: ${WriteBackStatus.lookbackLabel(clamped)}",
            style = MaterialTheme.typography.bodyMedium,
            modifier = Modifier.weight(1f).testTag("writeback-backfill-days"),
        )
        TextButton(
            enabled = clamped > 1,
            onClick = { host.scope.launch { graph.settings.set(WriteBackSettings.BACKFILL_DAYS, WriteBackSettings.clampDays(clamped - 1)) } },
            modifier = Modifier.testTag("writeback-days-minus"),
        ) { Text("−") }
        TextButton(
            enabled = clamped < WriteBackSettings.BACKFILL_MAX_DAYS,
            onClick = { host.scope.launch { graph.settings.set(WriteBackSettings.BACKFILL_DAYS, WriteBackSettings.clampDays(clamped + 1)) } },
            modifier = Modifier.testTag("writeback-days-plus"),
        ) { Text("+") }
    }
    Row(horizontalArrangement = Arrangement.spacedBy(8.dp)) {
        OutlinedButton(
            onClick = {
                val n = graph.collections.backfillSourceWriteBacks(
                    events = graph.collectionActivity.state.value.events,
                    days = clamped,
                    localInstallId = graph.collectionActivity.installId,
                )
                if (n > 0) writeBack.runSoon()
                status = listOf(WriteBackStatus.sendLine(writeBack.canWriteBack, n))
            },
            modifier = Modifier.testTag("writeback-send"),
        ) { Text("Send my adds") }
        OutlinedButton(
            enabled = catalog != null,
            onClick = {
                val changed = graph.collections.syncConvertedCollections(catalog?.playlists.orEmpty())
                status = listOf(
                    if (changed == 0) "Converted collections: all in sync"
                    else "Converted collections: updated $changed item${if (changed == 1) "" else "s"}",
                )
            },
            modifier = Modifier.testTag("writeback-get"),
        ) { Text("Get from Apple Music") }
    }
    status.forEach { SettingsCaption(it) }

    if (queue.jobs.isNotEmpty()) {
        Column(modifier = Modifier.testTag("writeback-queue")) {
            Text("Waiting to send: ${queue.pending.size}", style = MaterialTheme.typography.bodyMedium, modifier = Modifier.testTag("writeback-pending"))
            val failed = queue.failed
            Text(
                "Failed: ${failed.size}",
                style = MaterialTheme.typography.bodyMedium,
                color = if (failed.isEmpty()) MaterialTheme.colorScheme.onSurface else MaterialTheme.colorScheme.error,
                modifier = Modifier.testTag("writeback-failed"),
            )
            failed.forEach { job ->
                val title = catalog?.songsById?.get(job.songId)?.name ?: job.title.ifEmpty { job.songId }
                Text("$title → ${job.playlistName}", style = MaterialTheme.typography.bodySmall, modifier = Modifier.testTag("writeback-failed-job"))
                job.lastError?.let { Text(it, style = MaterialTheme.typography.bodySmall, color = MaterialTheme.colorScheme.error) }
            }
            // A GUESSED playlist match is a successful delivery that may have gone to the wrong place.
            queue.resolutionWarning?.let {
                Text(it, style = MaterialTheme.typography.bodySmall, color = MaterialTheme.colorScheme.onSurfaceVariant, modifier = Modifier.testTag("writeback-warning"))
            }
            queue.lastError?.takeIf { failed.isEmpty() }?.let { SettingsCaption(it) }
            Row(horizontalArrangement = Arrangement.spacedBy(8.dp)) {
                if (queue.pending.isNotEmpty()) {
                    OutlinedButton(onClick = { writeBack.runSoon() }, modifier = Modifier.testTag("writeback-run")) { Text("Send now") }
                }
                if (failed.isNotEmpty()) {
                    OutlinedButton(
                        onClick = { writeBack.retryFailed(); writeBack.runSoon() },
                        modifier = Modifier.testTag("writeback-retry"),
                    ) { Text("Retry failed") }
                }
            }
        }
    }
    SettingsCaption(
        "Songs you add to a linked Apple Music playlist from inside PocketDJ are written to your real " +
            "Apple Music library once you’re signed in. PocketDJ’s own view of that playlist catches " +
            "up on the next catalog sync, so a song can be in Apple Music and not yet listed here.",
    )
}

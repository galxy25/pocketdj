package com.levi.pocketdj.screens.settings

import kotlinx.coroutines.withContext
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.widthIn
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.OutlinedButton
import androidx.compose.material3.Text
import androidx.compose.material3.TextButton
import androidx.compose.runtime.getValue
import androidx.compose.runtime.produceState
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
import androidx.compose.runtime.collectAsState
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.platform.testTag
import androidx.compose.ui.unit.dp
import androidx.compose.material3.Switch
import androidx.compose.material3.Button
import androidx.compose.material3.CircularProgressIndicator
import androidx.compose.ui.platform.LocalContext
import com.levi.pocketdj.data.applemusic.AmSyncSettings
import com.levi.pocketdj.data.applemusic.AmSyncStep
import com.levi.pocketdj.data.applemusic.AmSyncReport
import com.levi.pocketdj.data.applemusic.PlaylistAppleMusicSync
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
                host.scope.launch {
                    // Off-main: the store walk + queue writes must not run on the UI thread.
                    val n = withContext(kotlinx.coroutines.Dispatchers.IO) {
                        graph.collections.backfillSourceWriteBacks(
                            events = graph.collectionActivity.state.value.events,
                            days = clamped,
                            localInstallId = graph.collectionActivity.installId,
                        ).also { if (it > 0) writeBack.runSoon() }
                    }
                    status = listOf(WriteBackStatus.sendLine(writeBack.canWriteBack, n))
                }
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

/**
 * Settings > "Apple Music syncing" (COL-9, iOS AppleMusicSettingsView sync half): the three verbs
 * (⇅ Sync / ↑ Send / ↓ Get), the LIVE step list, the interrupted-run hint, the audit history and
 * the Automatic block (daily time, import-new toggle). Reconcile (removals/reorders) is omitted.
 */
fun appleMusicSyncSection() = SettingsSection("appleMusicSync", 404) { host ->
    val graph = host.graph
    val cg = graph.collectionsGraph
    val syncState by produceState<PlaylistAppleMusicSync?>(null, cg) {
        value = kotlinx.coroutines.withContext(kotlinx.coroutines.Dispatchers.IO) { cg.playlistAmSync }
    }
    val ui by remember(syncState) { syncState?.ui ?: kotlinx.coroutines.flow.MutableStateFlow(com.levi.pocketdj.data.applemusic.AmSyncUi()) }.collectAsState()
    val autoEnabled by remember(graph) { graph.settings.flow(AmSyncSettings.AUTO_ENABLED) }.collectAsState(initial = true)
    val minutes by remember(graph) { graph.settings.flow(AmSyncSettings.AUTO_MINUTES) }
        .collectAsState(initial = com.levi.pocketdj.data.applemusic.AppleMusicAutoSync.DEFAULT_MINUTES)
    val lastAuto by remember(graph) { graph.settings.flow(AmSyncSettings.LAST_AUTO_MS) }.collectAsState(initial = 0.0)
    val importNew by remember(graph) { graph.settings.flow(AmSyncSettings.IMPORT_NEW) }.collectAsState(initial = false)
    val context = LocalContext.current
    var historyOpen by remember { mutableStateOf(false) }

    fun run(direction: PlaylistAppleMusicSync.Direction) {
        cg.startManualSync(direction)
    }
    fun fmt(ms: Double): String =
        java.text.DateFormat.getDateTimeInstance(java.text.DateFormat.MEDIUM, java.text.DateFormat.SHORT).format(java.util.Date(ms.toLong()))

    SettingsHeader("Apple Music syncing")
    Row(horizontalArrangement = Arrangement.spacedBy(8.dp), modifier = Modifier.fillMaxWidth()) {
        Button(onClick = { run(PlaylistAppleMusicSync.Direction.BOTH) }, enabled = !ui.isSyncing && syncState != null, modifier = Modifier.testTag("am-sync-both")) {
            Text("\u21C5 Sync")
        }
        OutlinedButton(onClick = { run(PlaylistAppleMusicSync.Direction.PUSH) }, enabled = !ui.isSyncing && syncState != null, modifier = Modifier.testTag("am-sync-push")) {
            Text("\u2191 Send")
        }
        OutlinedButton(onClick = { run(PlaylistAppleMusicSync.Direction.PULL) }, enabled = !ui.isSyncing && syncState != null, modifier = Modifier.testTag("am-sync-pull")) {
            Text("\u2193 Get")
        }
    }

    ui.currentRunStartedMs?.takeIf { ui.steps.isNotEmpty() }?.let { started ->
        Row(modifier = Modifier.fillMaxWidth().testTag("am-sync-run-header"), horizontalArrangement = Arrangement.SpaceBetween) {
            Text(
                if (ui.isSyncing) "Syncing now" else if (ui.currentRunCompleted) "Last sync" else "Interrupted sync",
                style = MaterialTheme.typography.labelLarge,
            )
            Text(fmt(started), style = MaterialTheme.typography.bodySmall, color = MaterialTheme.colorScheme.onSurfaceVariant)
        }
    }
    ui.steps.forEach { step ->
        Row(verticalAlignment = Alignment.Top, horizontalArrangement = Arrangement.spacedBy(8.dp), modifier = Modifier.testTag("am-sync-step")) {
            when (step.state) {
                AmSyncStep.State.RUNNING -> CircularProgressIndicator(strokeWidth = 2.dp, modifier = Modifier.padding(top = 2.dp).then(Modifier.height(16.dp).widthIn(max = 16.dp)))
                AmSyncStep.State.DONE -> Text("\u2713", color = MaterialTheme.colorScheme.primary)
                AmSyncStep.State.FAILED -> Text("\u2717", color = MaterialTheme.colorScheme.error)
                AmSyncStep.State.INTERRUPTED -> Text("\u23F8", color = MaterialTheme.colorScheme.tertiary)
            }
            Column {
                Text(step.label, style = MaterialTheme.typography.bodyMedium)
                step.detail?.let { Text(it, style = MaterialTheme.typography.bodySmall, color = MaterialTheme.colorScheme.onSurfaceVariant) }
            }
        }
    }
    if (!ui.isSyncing && !ui.currentRunCompleted && ui.steps.isNotEmpty()) {
        Text(
            "This sync was interrupted \u2014 tap Sync to resume where it left off.",
            style = MaterialTheme.typography.bodySmall, color = MaterialTheme.colorScheme.tertiary,
            modifier = Modifier.testTag("am-sync-resume-hint"),
        )
    }
    if (!ui.isSyncing && ui.steps.isEmpty()) {
        ui.lastResult?.let { SettingsCaption(it) }
    }

    if (ui.auditTrail.isNotEmpty()) {
        TextButton(onClick = { historyOpen = !historyOpen }, modifier = Modifier.testTag("am-sync-history")) {
            Text((if (historyOpen) "\u25BE " else "\u25B8 ") + "Sync history (${ui.auditTrail.size})")
        }
        if (historyOpen) ui.auditTrail.forEach { report -> AuditReportRows(report, ::fmt) }
    }

    SettingsHeader("Automatic")
    Row(verticalAlignment = Alignment.CenterVertically, modifier = Modifier.fillMaxWidth()) {
        Text("Sync daily", modifier = Modifier.weight(1f))
        Switch(
            checked = autoEnabled,
            onCheckedChange = { v -> host.scope.launch { graph.settings.set(AmSyncSettings.AUTO_ENABLED, v) } },
            modifier = Modifier.testTag("am-auto-sync-enabled"),
        )
    }
    if (autoEnabled) {
        Row(verticalAlignment = Alignment.CenterVertically, modifier = Modifier.fillMaxWidth()) {
            Text("At", modifier = Modifier.weight(1f))
            TextButton(
                onClick = {
                    val m = AmSyncSettings.clampMinutes(minutes)
                    android.app.TimePickerDialog(
                        context,
                        { _, h, min -> host.scope.launch { graph.settings.set(AmSyncSettings.AUTO_MINUTES, AmSyncSettings.clampMinutes(h * 60 + min)) } },
                        m / 60, m % 60, false,
                    ).show()
                },
                modifier = Modifier.testTag("am-auto-sync-time"),
            ) { Text(AmSyncSettings.timeLabel(minutes)) }
        }
        if (lastAuto > 0.0) SettingsCaption("Last auto-sync: ${fmt(lastAuto)}")
    }
    Row(verticalAlignment = Alignment.CenterVertically, modifier = Modifier.fillMaxWidth()) {
        Text("Import new Apple Music playlists", modifier = Modifier.weight(1f))
        Switch(
            checked = importNew,
            onCheckedChange = { v -> host.scope.launch { graph.settings.set(AmSyncSettings.IMPORT_NEW, v) } },
            modifier = Modifier.testTag("am-import-new-playlists"),
        )
    }
    SettingsCaption(
        "Daily sync runs the full pass at the chosen time \u2014 when PocketDJ is open, or the next time you return after it. " +
            "Off, sync only touches collections you converted or duplicated yourself; a playlist that lives only in Apple Music is " +
            "left there. On, every Apple Music playlist without a copy here is imported as a PocketDJ playlist.",
    )
}

@androidx.compose.runtime.Composable
private fun AuditReportRows(report: AmSyncReport, fmt: (Double) -> String) {
    Column(modifier = Modifier.padding(vertical = 4.dp).testTag("am-sync-report")) {
        Row(modifier = Modifier.fillMaxWidth(), horizontalArrangement = Arrangement.SpaceBetween) {
            Text(fmt(report.dateMs), style = MaterialTheme.typography.labelMedium)
            Text(report.summary, style = MaterialTheme.typography.bodySmall, color = MaterialTheme.colorScheme.onSurfaceVariant, maxLines = 1)
        }
        report.changes.forEach { c ->
            Row(horizontalArrangement = Arrangement.spacedBy(6.dp)) {
                Text(c.kind, style = MaterialTheme.typography.labelSmall)
                Text(c.name, style = MaterialTheme.typography.bodySmall, modifier = Modifier.weight(1f), maxLines = 1)
                Text(
                    buildString { if (c.added > 0) append("+${c.added}"); if (c.removed > 0) append(" \u2212${c.removed}") }.trim(),
                    style = MaterialTheme.typography.labelSmall,
                )
            }
        }
        report.errors.forEach { Text(it, style = MaterialTheme.typography.bodySmall, color = MaterialTheme.colorScheme.error, maxLines = 2) }
    }
}

/**
 * Settings > "Favorites" (COL-11, iOS AppleMusicSettingsView favorites half): the opt-in
 * two-way sync toggle (default OFF), "Sync favorites now", last-synced / error lines, and the
 * curator-seed opt-in (default OFF, hidden once two-way sync is on). The un-favorite caveat is
 * part of the copy because the ★ cannot be retracted.
 */
fun appleMusicFavoritesSection() = SettingsSection("appleMusicFavorites", 406) { host ->
    val graph = host.graph
    val sync = graph.collectionsGraph.favoritesSync
    val st by sync.state.collectAsState()
    val twoWay by remember(graph) { graph.settings.flow(com.levi.pocketdj.data.favorites.FavoritesSyncSettings.TWO_WAY) }
        .collectAsState(initial = false)
    val seedOpt by remember(graph) { graph.settings.flow(com.levi.pocketdj.data.favorites.FavoritesSyncSettings.APPLY_OWNER_SEED) }
        .collectAsState(initial = false)

    SettingsHeader("Favorites")
    Row(verticalAlignment = Alignment.CenterVertically, modifier = Modifier.fillMaxWidth()) {
        Text("Two-way favorites sync", modifier = Modifier.weight(1f))
        Switch(
            checked = twoWay,
            onCheckedChange = { v ->
                host.scope.launch {
                    graph.settings.set(com.levi.pocketdj.data.favorites.FavoritesSyncSettings.TWO_WAY, v)
                    if (v) sync.run()
                }
            },
            modifier = Modifier.testTag("favorites-sync-gate"),
        )
    }
    st.lastError?.let {
        Text(it, style = MaterialTheme.typography.bodySmall, color = MaterialTheme.colorScheme.error, modifier = Modifier.testTag("favorites-sync-error"))
    }
    st.lastSyncedAtMs?.let {
        SettingsCaption("Last synced " + java.text.DateFormat.getDateTimeInstance(java.text.DateFormat.SHORT, java.text.DateFormat.SHORT).format(java.util.Date(it.toLong())))
    }
    OutlinedButton(
        enabled = twoWay && !st.isSyncing,
        onClick = { host.scope.launch { sync.run() } },
        modifier = Modifier.testTag("favorites-sync-now"),
    ) {
        if (st.isSyncing) CircularProgressIndicator(modifier = Modifier.height(16.dp)) else Text("Sync favorites now")
    }
    if (!twoWay) {
        Row(verticalAlignment = Alignment.CenterVertically, modifier = Modifier.fillMaxWidth()) {
            Text("Start with the curator’s picks", modifier = Modifier.weight(1f))
            Switch(
                checked = seedOpt,
                onCheckedChange = { v -> host.scope.launch { graph.settings.set(com.levi.pocketdj.data.favorites.FavoritesSyncSettings.APPLY_OWNER_SEED, v) } },
                modifier = Modifier.testTag("favorites-seed-optin"),
            )
        }
    }
    SettingsCaption(
        "With favorites sync ON, ♥ on an Apple Music song also loves it in Apple Music, and songs you love " +
            "there appear here. Vinyl, My Digital and Studio favorites stay on this device. Un-favoriting is " +
            "lossy on Apple Music: it removes the love rating, but Apple provides no way to remove the ★ " +
            "from “Favorite Songs”, so remove it there yourself.",
    )
}

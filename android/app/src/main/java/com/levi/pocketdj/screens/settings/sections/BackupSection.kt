package com.levi.pocketdj.screens.settings.sections

import androidx.activity.compose.rememberLauncherForActivityResult
import androidx.activity.result.contract.ActivityResultContracts
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.material3.OutlinedButton
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.runtime.remember
import androidx.compose.ui.Modifier
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.platform.testTag
import androidx.compose.foundation.layout.ColumnScope
import androidx.compose.ui.unit.dp
import com.levi.pocketdj.data.backup.BackupPayload
import com.levi.pocketdj.data.backup.BackupSources
import com.levi.pocketdj.data.backup.BackupZip
import com.levi.pocketdj.data.backup.CollectionShare
import com.levi.pocketdj.screens.settings.SettingsCaption
import com.levi.pocketdj.screens.settings.SettingsHeader
import com.levi.pocketdj.shell.SettingsHost
import com.levi.pocketdj.shell.SettingsSection
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.launch
import kotlinx.coroutines.withContext

/** Settings ▸ Backup: export / restore the full `.pocketdj.zip` (sources, collections, favorites). */
internal fun backupSection() = SettingsSection("backup", 420) { host -> BackupBlock(host) }

internal object BackupCoordinator {
    suspend fun build(host: SettingsHost): ByteArray {
        val g = host.graph
        val store = g.collections
        val s = store.state.value
        val sources = BackupSources.toWire(g.settings.current().sources)
        val fav = runCatching { g.collectionsGraph.favorites.exportData().toByteArray() }.getOrNull()
        return BackupZip.export(
            BackupPayload(
                sourcesJson = sources, pockets = s.pockets, playlists = s.playlists,
                setlists = s.setlists, folders = s.folders, editsData = editsStore(g).exportData(), favoritesData = fav,
            ),
        )
    }

    private fun editsStore(g: com.levi.pocketdj.di.AppGraph) =
        com.levi.pocketdj.data.backup.BackupEditsStore(java.io.File(g.appContext.filesDir, "backup-edits.json"))

    suspend fun restore(host: SettingsHost, data: ByteArray): String = restore(host.graph, data)

    /** Merge a backup: collections (idempotent by id), sources (append unmatched), favorites (union). */
    suspend fun restore(g: com.levi.pocketdj.di.AppGraph, data: ByteArray): String {
        val (payload, skipped) = BackupZip.import(data)
        val summary = g.collections.mergeBackupCollections(payload)
        val local = g.settings.current().sources
        val merged = BackupSources.merge(local, BackupSources.fromWire(payload.sourcesJson))
        val sourcesAdded = (merged.size - local.size).coerceAtLeast(0)
        if (merged.size != local.size) { g.settings.setSources(merged); g.catalogRepository.refresh() }
        val favs = payload.favoritesData?.let { runCatching { g.collectionsGraph.favorites.importMerging(String(it)) }.getOrDefault(0) } ?: 0
        val edits = runCatching { editsStore(g).importMerging(payload.editsData) }.getOrDefault(0)
        return CollectionShare.restoreMessage(summary, sourcesAdded, favs, skipped.items, edits)
    }
}

@Composable
private fun ColumnScope.BackupBlock(host: SettingsHost) {
    val context = LocalContext.current
    val scope = host.scope
    val export = rememberLauncherForActivityResult(ActivityResultContracts.CreateDocument(CollectionShare.ZIP_MIME)) { uri ->
        if (uri != null) scope.launch {
            val ok = withContext(Dispatchers.IO) {
                CollectionShare.writeUri(context.contentResolver, uri, BackupCoordinator.build(host))
            }
            host.snackbar.showSnackbar(if (ok) "Backup saved" else "Couldn't write the backup")
        }
    }
    val import = rememberLauncherForActivityResult(ActivityResultContracts.OpenDocument()) { uri ->
        if (uri != null) scope.launch {
            val msg = withContext(Dispatchers.IO) {
                val bytes = CollectionShare.readUri(context.contentResolver, uri) ?: return@withContext "Couldn't open that file"
                runCatching { BackupCoordinator.restore(host, bytes) }.getOrElse { CollectionShare.failureMessage(it) }
            }
            host.snackbar.showSnackbar(msg)
        }
    }
    val stamp = remember { java.text.SimpleDateFormat("yyyy-MM-dd", java.util.Locale.US).format(java.util.Date()) }
    SettingsHeader("Backup")
    Row(horizontalArrangement = Arrangement.spacedBy(8.dp), modifier = Modifier.fillMaxWidth()) {
        OutlinedButton(onClick = { export.launch(CollectionShare.backupFilename(stamp)) }, modifier = Modifier.testTag("backup-export")) {
            Text("Export backup…")
        }
        OutlinedButton(onClick = { import.launch(arrayOf("*/*")) }, modifier = Modifier.testTag("backup-import")) {
            Text("Restore…")
        }
    }
    SettingsCaption(
        "Saves your sources, playlists, pockets, setlists, folders and favorites to a .pocketdj.zip. " +
            "Restoring merges by id - nothing is overwritten or duplicated.",
    )
}

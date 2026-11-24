package com.levi.pocketdj.screens.settings.sections

import androidx.activity.compose.rememberLauncherForActivityResult
import androidx.activity.result.contract.ActivityResultContracts
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.ColumnScope
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.material3.AlertDialog
import androidx.compose.material3.OutlinedButton
import androidx.compose.material3.Text
import androidx.compose.material3.TextButton
import androidx.compose.runtime.Composable
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableIntStateOf
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
import androidx.compose.ui.Modifier
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.platform.testTag
import androidx.compose.ui.unit.dp
import com.levi.pocketdj.data.backup.BackupEdits
import com.levi.pocketdj.data.backup.BackupEditsStore
import com.levi.pocketdj.data.backup.CollectionShare
import com.levi.pocketdj.data.catalog.EditsStore
import com.levi.pocketdj.screens.settings.SettingsCaption
import com.levi.pocketdj.screens.settings.SettingsHeader
import com.levi.pocketdj.shell.SettingsHost
import com.levi.pocketdj.shell.SettingsSection
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.launch
import kotlinx.coroutines.withContext

/** Settings ▸ Edits (iOS `editsSection`): export / import / clear the metadata edits document. */
internal fun editsSection() = SettingsSection("edits", 430) { host -> EditsBlock(host) }

/** Pure helpers behind the Edits section (JVM-testable). */
internal object EditsTransfer {
    const val FILE_NAME = "pocketdj-edits.json"
    const val MIME = "application/json"
    const val PLATFORM = "android"

    /** iOS footer: "N local metadata edit(s). Export to JSON (schema vN) ...". */
    fun footer(count: Int): String =
        "$count local metadata edit${if (count == 1) "" else "s"}. Export to JSON (schema v${EditsStore.SCHEMA_VERSION}) " +
            "to merge into the PocketDJ catalog; Import merges another export in (the imported edit wins per item)."

    /** Export is disabled when there is nothing to export. */
    fun canExport(count: Int): Boolean = count > 0

    /** The document to write: schemaVersion + a fresh `meta` stamp (platform "android"). */
    fun exportBytes(raw: ByteArray?, appVersion: String, now: java.time.Instant = java.time.Instant.now()): ByteArray? =
        BackupEdits.restamp(raw, appVersion, now, PLATFORM)

    /** Snackbar text for an import: [changed] = edits that were new or different; [incomingCount] = edits in the file. */
    fun importMessage(incomingCount: Int, changed: Int): String = when {
        incomingCount == 0 -> "No edits found in that file"
        changed == 0 -> "Edits already up to date"
        else -> "Imported $changed edit${if (changed == 1) "" else "s"}"
    }
}

@Composable
private fun ColumnScope.EditsBlock(host: SettingsHost) {
    val context = LocalContext.current
    val g = host.graph
    val store = g.collectionsGraph.editsStore
    val scope = host.scope
    var count by remember { mutableIntStateOf(store.count) }
    var confirmClear by remember { mutableStateOf(false) }
    val appVersion = remember {
        runCatching { context.packageManager.getPackageInfo(context.packageName, 0).versionName }.getOrNull().orEmpty()
    }

    val export = rememberLauncherForActivityResult(ActivityResultContracts.CreateDocument(EditsTransfer.MIME)) { uri ->
        if (uri != null) scope.launch {
            val ok = withContext(Dispatchers.IO) {
                val raw = runCatching { g.catalogEdits.file.takeIf { it.exists() }?.readBytes() }.getOrNull()
                val bytes = EditsTransfer.exportBytes(raw, appVersion)
                bytes != null && CollectionShare.writeUri(context.contentResolver, uri, bytes)
            }
            host.snackbar.showSnackbar(if (ok) "Edits exported" else "Couldn't write the edits file")
        }
    }
    val import = rememberLauncherForActivityResult(ActivityResultContracts.OpenDocument()) { uri ->
        if (uri != null) scope.launch {
            val msg = withContext(Dispatchers.IO) {
                val bytes = CollectionShare.readUri(context.contentResolver, uri) ?: return@withContext "Couldn't open that file"
                val incoming = BackupEdits.count(bytes)
                val changed = runCatching {
                    BackupEditsStore(g.catalogEdits.file, write = store::replaceRaw).importMerging(bytes)
                }.getOrElse { return@withContext "Couldn't import that file" }
                EditsTransfer.importMessage(incoming, changed)
            }
            count = store.count
            host.snackbar.showSnackbar(msg)
        }
    }

    SettingsHeader("Edits")
    Row(horizontalArrangement = Arrangement.spacedBy(8.dp), modifier = Modifier.fillMaxWidth()) {
        OutlinedButton(
            onClick = { count = store.count; export.launch(EditsTransfer.FILE_NAME) },
            enabled = EditsTransfer.canExport(count),
            modifier = Modifier.testTag("edits-export"),
        ) { Text("Export edits…") }
        OutlinedButton(onClick = { import.launch(arrayOf("application/json", "*/*")) }, modifier = Modifier.testTag("edits-import")) {
            Text("Import edits…")
        }
        OutlinedButton(
            onClick = { confirmClear = true },
            enabled = EditsTransfer.canExport(count),
            modifier = Modifier.testTag("edits-clear"),
        ) { Text("Clear") }
    }
    SettingsCaption(EditsTransfer.footer(count))

    if (confirmClear) {
        AlertDialog(
            onDismissRequest = { confirmClear = false },
            title = { Text("Clear all edits?") },
            text = { Text("Removes every local album and song metadata edit and restores the original catalog values.") },
            confirmButton = {
                TextButton(onClick = {
                    confirmClear = false
                    scope.launch {
                        store.clearAllIo()
                        count = store.count
                        host.snackbar.showSnackbar("Edits cleared")
                    }
                }) { Text("Clear") }
            },
            dismissButton = { TextButton(onClick = { confirmClear = false }) { Text("Cancel") } },
        )
    }
}

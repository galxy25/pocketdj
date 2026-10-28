package com.levi.pocketdj.screens.settings.sections

import android.content.Intent
import android.net.Uri
import android.text.format.Formatter
import androidx.activity.compose.rememberLauncherForActivityResult
import androidx.activity.result.contract.ActivityResultContracts
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.padding
import androidx.compose.material3.AlertDialog
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.OutlinedButton
import androidx.compose.material3.Text
import androidx.compose.material3.TextButton
import androidx.compose.runtime.Composable
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.unit.dp
import com.levi.pocketdj.screens.settings.SettingsCaption
import com.levi.pocketdj.screens.settings.SettingsHeader
import com.levi.pocketdj.shell.SettingsHost
import com.levi.pocketdj.shell.SettingsSection
import com.levi.pocketdj.studio.store.StudioFamily
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.launch
import kotlinx.coroutines.withContext

/** The user-relocatable families shown in the section, in display order. */
internal val STUDIO_FOLDER_FAMILIES = listOf(StudioFamily.SAMPLES, StudioFamily.LOOPS, StudioFamily.SEQUENCES, StudioFamily.TAKES)

internal fun studioFamilyTitle(f: StudioFamily): String = when (f) {
    StudioFamily.SAMPLES -> "Samples"
    StudioFamily.LOOPS -> "Loops"
    StudioFamily.SEQUENCES -> "Sequences"
    StudioFamily.TAKES -> "Takes"
    StudioFamily.INSTRUMENTS -> "Instruments"
}

/** A readable name for a SAF tree uri ("Music/Studio" from `...:Music%2FStudio`), or null for none. */
internal fun folderLabel(treeUri: String?): String? {
    if (treeUri.isNullOrEmpty()) return null
    val last = treeUri.substringAfterLast("/tree/", treeUri)
    val decoded = try { Uri.decode(last) } catch (_: Exception) { last }
    return decoded.substringAfter(':', decoded).ifEmpty { decoded }
}

/**
 * Settings > Studio storage (STU-7): per-family usage, a folder chooser (SAF tree, persisted permission; new
 * files go there, files already written stay readable from the folder they were written to) and a confirmed
 * delete-all. Instruments are app-private and only show usage. The Storage screen carries the same bytes.
 */
internal fun studioStorageSection(order: Int = 710) = SettingsSection("studioStorage", order) { host ->
    StudioStorageContent(host)
}

@Composable
private fun StudioStorageContent(host: SettingsHost) {
    val context = LocalContext.current
    val sg = remember { host.graph.studioGraph }
    var tick by remember { mutableStateOf(0) }
    val usage = remember { mutableStateOf<Map<StudioFamily, Long>>(emptyMap()) }
    var confirm by remember { mutableStateOf<StudioFamily?>(null) }
    var picking by remember { mutableStateOf<StudioFamily?>(null) }

    LaunchedEffect(tick) {
        usage.value = withContext(Dispatchers.IO) {
            StudioFamily.entries.associateWith { runCatching { sg.studioStore.usageBytes(it) }.getOrDefault(0L) }
        }
    }

    val launcher = rememberLauncherForActivityResult(ActivityResultContracts.OpenDocumentTree()) { uri: Uri? ->
        val family = picking
        picking = null
        if (uri != null && family != null) {
            runCatching {
                context.contentResolver.takePersistableUriPermission(
                    uri, Intent.FLAG_GRANT_READ_URI_PERMISSION or Intent.FLAG_GRANT_WRITE_URI_PERMISSION,
                )
            }
            sg.setUserFolder(family, uri.toString())
            tick++
        }
    }

    SettingsHeader("Studio storage")
    SettingsCaption(
        "Samples, loops, sequences and takes live in the app by default. Pick a folder to keep new ones there " +
            "instead; ones already saved stay where they were written.",
    )
    for (family in STUDIO_FOLDER_FAMILIES + StudioFamily.INSTRUMENTS) {
        val bytes = usage.value[family]
        val folder = folderLabel(sg.userFolderTreeUri(family))
        Column(Modifier.fillMaxWidth().padding(vertical = 6.dp)) {
            Row(Modifier.fillMaxWidth(), horizontalArrangement = Arrangement.SpaceBetween, verticalAlignment = Alignment.CenterVertically) {
                Text(studioFamilyTitle(family), style = MaterialTheme.typography.bodyMedium)
                Text(
                    bytes?.let { Formatter.formatFileSize(context, it) } ?: "-",
                    style = MaterialTheme.typography.bodyMedium, color = MaterialTheme.colorScheme.onSurfaceVariant,
                )
            }
            if (family.supportsUserFolder) {
                Text(
                    folder?.let { "Folder: $it" } ?: "App storage",
                    style = MaterialTheme.typography.bodySmall, color = MaterialTheme.colorScheme.onSurfaceVariant,
                )
            }
            Row(horizontalArrangement = Arrangement.spacedBy(8.dp), modifier = Modifier.padding(top = 4.dp)) {
                if (family.supportsUserFolder) {
                    OutlinedButton(onClick = { picking = family; launcher.launch(null) }) { Text("Choose folder") }
                    if (folder != null) {
                        OutlinedButton(onClick = { sg.setUserFolder(family, null); tick++ }) { Text("Use app storage") }
                    }
                }
                OutlinedButton(onClick = { confirm = family }, enabled = (bytes ?: 0L) > 0L) { Text("Delete all") }
            }
        }
    }

    confirm?.let { family ->
        AlertDialog(
            onDismissRequest = { confirm = null },
            title = { Text("Delete all ${studioFamilyTitle(family).lowercase()}?") },
            text = {
                Text(
                    "Permanently deletes every ${studioFamilyTitle(family).lowercase()} file and its record. " +
                        "Anything in a folder that is unavailable right now is kept. This can't be undone.",
                )
            },
            confirmButton = {
                TextButton(onClick = {
                    confirm = null
                    host.scope.launch {
                        withContext(Dispatchers.IO) { runCatching { sg.studioStore.deleteAll(family); sg.studioStore.flush() } }
                        tick++
                    }
                }) { Text("Delete") }
            },
            dismissButton = { TextButton(onClick = { confirm = null }) { Text("Cancel") } },
        )
    }
}

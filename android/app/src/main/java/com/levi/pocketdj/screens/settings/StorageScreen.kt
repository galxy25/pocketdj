package com.levi.pocketdj.screens.settings

import android.text.format.Formatter
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.width
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.verticalScroll
import androidx.compose.material3.AlertDialog
import androidx.compose.material3.CircularProgressIndicator
import androidx.compose.material3.HorizontalDivider
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.OutlinedButton
import androidx.compose.material3.SnackbarHost
import androidx.compose.material3.SnackbarHostState
import androidx.compose.material3.Text
import androidx.compose.material3.TextButton
import androidx.compose.runtime.Composable
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateMapOf
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.rememberCoroutineScope
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.unit.dp
import com.levi.pocketdj.data.storage.StorageService.Category
import com.levi.pocketdj.di.AppGraph
import kotlinx.coroutines.launch

/**
 * Settings ▸ Storage (specs/storage.md §2–§4): measured on-disk usage per
 * category with human-readable sizes + per-category Clear actions wired to the
 * real stores/caches via [AppGraph.storageService]. Five rows (caches first,
 * then user docs); Collections is display-only (no Clear — irreplaceable user
 * content, §2.3). Every Clear is behind an [AlertDialog]; the store/cache work
 * runs off-main inside [StorageService] and the row re-measures on return.
 *
 * The clear contract is enforced by [StorageService] itself: no clear touches
 * the settings DataStore or regenerates the install id (§3). This screen only
 * measures, formats, and confirms.
 *
 * Entry composable for the integrator; the "Storage" row that opens it lives in
 * [SettingsScreen] (nav param `onOpenStorage`). Wiring needed in MainActivity is
 * reported to the integrator (a `settings/storage` route + title case).
 */
@Composable
fun StorageScreen(modifier: Modifier = Modifier) {
    val context = LocalContext.current
    val graph = remember { AppGraph.get(context) }
    val storage = remember { graph.storageService }
    val scope = rememberCoroutineScope()
    val snackbar = remember { SnackbarHostState() }

    // null == not yet measured → render the "—" placeholder (spec §1, iOS parity).
    val sizes = remember { mutableStateMapOf<Category, Long?>() }
    var measuring by remember { mutableStateOf(true) }
    var pendingClear by remember { mutableStateOf<Category?>(null) }

    LaunchedEffect(Unit) {
        measuring = true
        val measured = storage.measureAll() // off-main inside the service
        sizes.putAll(measured)
        measuring = false
    }

    val total = Category.entries.sumOf { sizes[it] ?: 0L }

    Box(modifier = modifier.fillMaxSize()) {
        Column(
            modifier = Modifier
                .fillMaxSize()
                .verticalScroll(rememberScrollState())
                .padding(16.dp),
        ) {
            SectionHeader("On-device storage")
            Caption(
                "What PocketDJ keeps on this device. Clearing a cache or log frees " +
                    "space and never removes a song from your catalog, a playlist, " +
                    "a pocket, or a set list — those live in the catalog and can be " +
                    "loaded again. Your settings and install identity are never touched.",
            )

            if (measuring && sizes.isEmpty()) {
                Spacer(Modifier.height(12.dp))
                Row(verticalAlignment = Alignment.CenterVertically) {
                    CircularProgressIndicator(
                        modifier = Modifier.width(18.dp).height(18.dp),
                        strokeWidth = 2.dp,
                    )
                    Spacer(Modifier.width(12.dp))
                    Text("Measuring…", style = MaterialTheme.typography.bodySmall)
                }
            }

            Spacer(Modifier.height(8.dp))

            Category.entries.forEach { category ->
                val meta = storageCategoryMeta(category)
                val bytes = sizes[category]
                StorageRow(
                    title = meta.title,
                    description = meta.description,
                    sizeLabel = bytes?.let { Formatter.formatFileSize(context, it) } ?: "—",
                    // Enable a Clear while any bytes remain, even if the logical
                    // count is 0 (reclaim orphaned bytes) — spec §1, iOS parity.
                    clearable = category.clearable && (bytes ?: 0L) > 0L,
                    onClear = if (category.clearable) {
                        { pendingClear = category }
                    } else {
                        null
                    },
                )
                Spacer(Modifier.height(4.dp))
                HorizontalDivider()
                Spacer(Modifier.height(4.dp))
            }

            Spacer(Modifier.height(8.dp))
            Row(
                modifier = Modifier.fillMaxWidth(),
                horizontalArrangement = Arrangement.SpaceBetween,
                verticalAlignment = Alignment.CenterVertically,
            ) {
                Text(
                    "Total on device",
                    style = MaterialTheme.typography.bodyMedium,
                    fontWeight = FontWeight.SemiBold,
                )
                Text(
                    if (sizes.isEmpty()) "—" else Formatter.formatFileSize(context, total),
                    style = MaterialTheme.typography.bodyMedium,
                    fontWeight = FontWeight.SemiBold,
                )
            }

            Spacer(Modifier.height(24.dp))
        }

        SnackbarHost(hostState = snackbar, modifier = Modifier.align(Alignment.BottomCenter))
    }

    pendingClear?.let { category ->
        val meta = storageCategoryMeta(category)
        AlertDialog(
            onDismissRequest = { pendingClear = null },
            title = { Text(meta.clearTitle) },
            text = { Text(meta.clearBody) },
            confirmButton = {
                TextButton(
                    onClick = {
                        pendingClear = null
                        scope.launch {
                            val remaining = storage.clear(category) // off-main + re-measure
                            sizes[category] = remaining
                            snackbar.showSnackbar("${meta.title} cleared")
                        }
                    },
                ) {
                    Text("Clear")
                }
            },
            dismissButton = {
                TextButton(onClick = { pendingClear = null }) { Text("Cancel") }
            },
        )
    }
}

@Composable
private fun StorageRow(
    title: String,
    description: String,
    sizeLabel: String,
    clearable: Boolean,
    onClear: (() -> Unit)?,
) {
    Row(
        modifier = Modifier
            .fillMaxWidth()
            .padding(vertical = 4.dp),
        verticalAlignment = Alignment.CenterVertically,
    ) {
        Column(Modifier.weight(1f)) {
            Row(
                modifier = Modifier.fillMaxWidth(),
                horizontalArrangement = Arrangement.SpaceBetween,
                verticalAlignment = Alignment.CenterVertically,
            ) {
                Text(title, style = MaterialTheme.typography.bodyMedium)
                Text(
                    sizeLabel,
                    style = MaterialTheme.typography.bodyMedium,
                    color = MaterialTheme.colorScheme.onSurfaceVariant,
                )
            }
            Text(
                description,
                style = MaterialTheme.typography.bodySmall,
                color = MaterialTheme.colorScheme.onSurfaceVariant,
                modifier = Modifier.padding(top = 2.dp),
            )
            if (onClear != null) {
                Spacer(Modifier.height(6.dp))
                OutlinedButton(onClick = onClear, enabled = clearable) {
                    Text("Clear")
                }
            }
        }
    }
}

@Composable
private fun SectionHeader(text: String) {
    Text(
        text,
        style = MaterialTheme.typography.titleSmall,
        fontWeight = FontWeight.SemiBold,
        color = MaterialTheme.colorScheme.primary,
        modifier = Modifier.padding(bottom = 6.dp),
    )
}

@Composable
private fun Caption(text: String) {
    Text(
        text,
        style = MaterialTheme.typography.bodySmall,
        color = MaterialTheme.colorScheme.onSurfaceVariant,
        modifier = Modifier.padding(vertical = 4.dp),
    )
}

/**
 * UI copy per category (title, description, and confirm-dialog copy). Pure — no
 * Android/Compose dependency — so the "every category has copy and Collections
 * carries no clear affordance" invariant is a plain JVM unit test.
 */
internal data class StorageCategoryMeta(
    val title: String,
    val description: String,
    val clearTitle: String,
    val clearBody: String,
)

internal fun storageCategoryMeta(category: Category): StorageCategoryMeta = when (category) {
    Category.CATALOG_CACHE -> StorageCategoryMeta(
        title = "Catalog cache",
        description = "Offline copies of your catalog index. Re-fetched on the next load.",
        clearTitle = "Clear catalog cache?",
        clearBody = "Removes the offline catalog copies from this device. The catalog " +
            "re-fetches from the network on its next load. Your sources and settings are kept.",
    )
    Category.ARTWORK -> StorageCategoryMeta(
        title = "Artwork cache",
        description = "Album and song artwork thumbnails. Re-fetched when shown again.",
        clearTitle = "Clear artwork cache?",
        clearBody = "Removes cached album and song artwork from this device. Images " +
            "re-download the next time they appear. Nothing in your library changes.",
    )
    Category.COLLECTIONS -> StorageCategoryMeta(
        // Display-only (§2.3): no clear affordance — the clear-copy fields are
        // never shown for this category.
        title = "Collections",
        description = "Your pockets, playlists, set lists, and folders. Kept — never cleared here.",
        clearTitle = "",
        clearBody = "",
    )
    Category.PLAY_HISTORY -> StorageCategoryMeta(
        title = "Play history",
        description = "Every recorded play on this device. Your install identity is kept.",
        clearTitle = "Clear play history?",
        clearBody = "Every recorded play is removed from this device. Your settings, " +
            "sources, and install identity are kept. This can't be undone.",
    )
    Category.ACTIVITY -> StorageCategoryMeta(
        title = "Activity log",
        description = "The add/remove history behind the Activity tab. Your collections stay.",
        clearTitle = "Clear activity log?",
        clearBody = "Removes the add/remove activity history from this device. The " +
            "collections it references are untouched. This can't be undone.",
    )
}

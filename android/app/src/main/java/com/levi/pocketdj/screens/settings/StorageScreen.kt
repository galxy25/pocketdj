package com.levi.pocketdj.screens.settings

import kotlinx.coroutines.withContext
import kotlinx.coroutines.Dispatchers
import androidx.compose.material3.ButtonDefaults
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
import androidx.compose.material3.OutlinedTextField
import androidx.compose.material3.TextButton
import androidx.compose.foundation.clickable
import androidx.compose.ui.text.input.KeyboardType
import androidx.compose.foundation.text.KeyboardOptions
import com.levi.pocketdj.data.burns.ArtistUsage
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
    val studioCounts = remember { mutableStateMapOf<Category, Int>() }
    var measuring by remember { mutableStateOf(true) }
    var pendingClear by remember { mutableStateOf<Category?>(null) }

    LaunchedEffect(Unit) {
        measuring = true
        val measured = storage.measureAll() // off-main inside the service
        sizes.putAll(measured)
        withContext(Dispatchers.IO) {
            Category.entries.filter { it.studioFamily != null }.forEach { studioCounts[it] = storage.studioRecordCount(it) }
        }
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

            Category.entries.filter { it.studioFamily == null }.forEach { category ->
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

            Spacer(Modifier.height(12.dp))
            SectionHeader("Producer studio")
            Caption(
                "These are things you made (recordings, loops, sequences, takes). PocketDJ never deletes them on its " +
                    "own. Deleting a family is permanent: loops already playing keep playing, but sequencer rows that " +
                    "use a deleted sample or loop fall silent, and any pocket or playlist entry for a deleted item is " +
                    "left unplayable. Instruments are downloaded packs and can be fetched again.",
            )
            Spacer(Modifier.height(8.dp))
            Category.entries.filter { it.studioFamily != null }.forEach { category ->
                val meta = storageCategoryMeta(category)
                val bytes = sizes[category]
                StorageRow(
                    title = meta.title,
                    description = meta.description,
                    sizeLabel = bytes?.let { Formatter.formatFileSize(context, it) } ?: "—",
                    // Enable a Clear while any bytes remain, even if the logical
                    // count is 0 (reclaim orphaned bytes) — spec §1, iOS parity.
                    clearable = (bytes ?: 0L) > 0L || (studioCounts[category] ?: 0) > 0,
                    destructive = true,
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

            DownloadSections(
                graph = graph,
                onChanged = { scope.launch { sizes.putAll(storage.measureAll()) } },
                snackbar = snackbar,
            )

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
                            if (category.studioFamily != null) {
                                studioCounts[category] = withContext(Dispatchers.IO) { storage.studioRecordCount(category) }
                            }
                            snackbar.showSnackbar(if (category.studioFamily != null) "${meta.title} deleted" else "${meta.title} cleared")
                        }
                    },
                ) {
                    Text(if (category.studioFamily != null) "Delete" else "Clear")
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
    destructive: Boolean = false,
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
                OutlinedButton(
                    onClick = onClear, enabled = clearable,
                    colors = if (destructive) ButtonDefaults.outlinedButtonColors(contentColor = MaterialTheme.colorScheme.error)
                    else ButtonDefaults.outlinedButtonColors(),
                ) {
                    Text(if (destructive) "Delete" else "Clear")
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
    Category.BURNS -> StorageCategoryMeta(
        title = "Downloaded songs",
        description = "Songs burned to this device for offline play. Your library is never touched.",
        clearTitle = "Delete downloaded songs?",
        clearBody = "Removes every downloaded song file from this device. The songs stay in " +
            "your library and collections and can be downloaded again any time.",
    )
    Category.STEMS -> StorageCategoryMeta(
        title = "Stems",
        description = "Separated vocal, drum, bass and other parts kept for offline mixing.",
        clearTitle = "Delete stems?",
        clearBody = "Removes the downloaded stem files from this device. Downloaded songs " +
            "and beat grids are kept; stems re-download when needed.",
    )
    Category.COLLECTIONS -> StorageCategoryMeta(
        // Display-only (§2.3): no clear affordance — the clear-copy fields are
        // never shown for this category.
        title = "Collections",
        description = "Your pockets, playlists, set lists, and folders. Kept — never cleared here.",
        clearTitle = "",
        clearBody = "",
    )
    Category.FAVORITES -> StorageCategoryMeta(
        // Display-only like Collections: favorites (and un-favorite tombstones) are user content.
        title = "Favorites",
        description = "Your hearted songs. Kept — never cleared here.",
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
    Category.LYRICS -> StorageCategoryMeta(
        title = "Lyrics cache",
        description = "Song lyrics saved for offline reading. Re-fetched when a song opens.",
        clearTitle = "Clear lyrics cache?",
        clearBody = "Removes saved lyrics text from this device. Lyrics re-download the " +
            "next time you open a song that has them. Nothing else changes.",
    )
    Category.ACTIVITY -> StorageCategoryMeta(
        title = "Activity log",
        description = "The add/remove history behind the Activity tab. Your collections stay.",
        clearTitle = "Clear activity log?",
        clearBody = "Removes the add/remove activity history from this device. The " +
            "collections it references are untouched. This can't be undone.",
    )
    Category.STUDIO_SAMPLES -> studioMeta("Studio samples", "Your recorded and carved samples (and their edited renders).", "samples")
    Category.STUDIO_LOOPS -> studioMeta("Studio loops", "Loops cut from your samples.", "loops")
    Category.STUDIO_SEQUENCES -> studioMeta("Studio sequences", "Bounced sequencer patterns.", "sequences")
    Category.STUDIO_TAKES -> studioMeta("Studio takes", "Instrumental takes and their rendered audio. A take being recorded right now is kept.", "takes")
    Category.STUDIO_INSTRUMENTS -> StorageCategoryMeta(
        title = "Studio instruments",
        description = "Downloaded instrument SoundFonts. Re-downloadable.",
        clearTitle = "Delete instruments?",
        clearBody = "Removes the downloaded instrument packs from this device. They can be downloaded again.",
    )
    Category.MIX_SESSIONS -> StorageCategoryMeta(
        title = "Mix sessions",
        description = "Audio recorded from your mixes. A take being recorded right now is kept.",
        clearTitle = "Delete mix recordings?",
        clearBody = "Permanently deletes every recorded mix take from this device. Session logs are kept.",
    )
}

private fun studioMeta(title: String, description: String, noun: String) = StorageCategoryMeta(
    title = title,
    description = description,
    clearTitle = "Delete all $noun?",
    clearBody = "Permanently deletes every Studio $noun file and its record. Anything stored in a folder " +
        "that is unavailable right now is kept. This can't be undone.",
)


/** What the by-artist / by-collection delete dialog is currently offering. */
private enum class DeleteKind(val label: String, val stems: Boolean) {
    BURN_ARTIST("Delete songs by artist", false),
    BURN_COLLECTION("Delete songs by collection", false),
    STEM_ARTIST("Delete stems by artist", true),
}

private data class DeleteChoice(val label: String, val detail: String, val songIds: List<String>)

/**
 * SVC-6: Settings ▸ Storage cap + prune controls and targeted deletes. Media only — the
 * library, collections, catalog and settings are never touched.
 */
@Composable
private fun DownloadSections(graph: AppGraph, onChanged: () -> Unit, snackbar: SnackbarHostState) {
    val context = LocalContext.current
    val scope = rememberCoroutineScope()
    val services = graph.servicesGraph
    val storage = graph.storageService
    var capGb by remember { mutableStateOf("") }
    var capSongs by remember { mutableStateOf("") }
    var status by remember { mutableStateOf<String?>(null) }
    var pruning by remember { mutableStateOf(false) }
    var kind by remember { mutableStateOf<DeleteKind?>(null) }
    var choices by remember { mutableStateOf<List<DeleteChoice>>(emptyList()) }
    var confirm by remember { mutableStateOf<Pair<DeleteKind, DeleteChoice>?>(null) }

    LaunchedEffect(Unit) {
        val gb = services.storageSettings.capGB()
        val n = services.storageSettings.capSongs()
        capGb = gb?.let { if (it % 1.0 == 0.0) it.toLong().toString() else it.toString() } ?: ""
        capSongs = n?.toString() ?: ""
        services.storageManager.lastResult?.let { status = describe(context, it) }
    }

    Spacer(Modifier.height(16.dp))
    SectionHeader("Automatic cleanup")
    Caption(
        "Optional soft cap on downloaded songs. When set, PocketDJ removes the songs you " +
            "have played least recently (never-played first), at most once a day, until the " +
            "downloads fit. Leave both empty to manage storage yourself.",
    )
    Row(horizontalArrangement = Arrangement.spacedBy(12.dp)) {
        OutlinedTextField(
            value = capGb,
            onValueChange = { v -> capGb = v.filter { it.isDigit() || it == '.' }.take(7) },
            label = { Text("Cap (GB)") },
            singleLine = true,
            keyboardOptions = KeyboardOptions(keyboardType = KeyboardType.Decimal),
            modifier = Modifier.weight(1f),
        )
        OutlinedTextField(
            value = capSongs,
            onValueChange = { v -> capSongs = v.filter { it.isDigit() }.take(7) },
            label = { Text("Cap (songs)") },
            singleLine = true,
            keyboardOptions = KeyboardOptions(keyboardType = KeyboardType.Number),
            modifier = Modifier.weight(1f),
        )
    }
    Spacer(Modifier.height(8.dp))
    Row(horizontalArrangement = Arrangement.spacedBy(8.dp), verticalAlignment = Alignment.CenterVertically) {
        OutlinedButton(onClick = {
            scope.launch {
                if (capGb.isNotBlank() && capGb.toDoubleOrNull() == null) {
                    snackbar.showSnackbar("Enter the GB cap as a number, e.g. 12.5")
                    return@launch
                }
                services.storageSettings.setCapGB(capGb.toDoubleOrNull())
                services.storageSettings.setCapSongs(capSongs.toIntOrNull())
                snackbar.showSnackbar("Cap saved")
            }
        }) { Text("Save cap") }
        OutlinedButton(
            enabled = !pruning,
            onClick = {
                scope.launch {
                    if (capGb.isNotBlank() && capGb.toDoubleOrNull() == null) {
                        status = "Enter the GB cap as a number, e.g. 12.5"
                        return@launch
                    }
                    services.storageSettings.setCapGB(capGb.toDoubleOrNull())
                    services.storageSettings.setCapSongs(capSongs.toIntOrNull())
                    pruning = true
                    val r = services.storageManager.prune()
                    pruning = false
                    status = r?.let { describe(context, it) }
                        ?: if (services.storageManager.isPruning) "A prune is already running - try again shortly."
                        else "No cap set - nothing to prune."
                    onChanged()
                }
            },
        ) { Text(if (pruning) "Pruning…" else "Prune now") }
    }
    status?.let { Caption(it) }

    Spacer(Modifier.height(16.dp))
    SectionHeader("Delete downloads")
    Caption("Removes downloaded files only. Songs stay in your library and collections.")
    @OptIn(androidx.compose.foundation.layout.ExperimentalLayoutApi::class)
    androidx.compose.foundation.layout.FlowRow(horizontalArrangement = Arrangement.spacedBy(8.dp)) {
        for (k in DeleteKind.entries) {
            OutlinedButton(onClick = {
                scope.launch {
                    choices = loadChoices(graph, k)
                    kind = k
                }
            }) { Text(k.label, style = MaterialTheme.typography.labelSmall) }
        }
    }

    kind?.let { k ->
        AlertDialog(
            onDismissRequest = { kind = null },
            title = { Text(k.label) },
            text = {
                if (choices.isEmpty()) Text("Nothing downloaded.")
                else Column(Modifier.verticalScroll(rememberScrollState())) {
                    choices.forEach { c ->
                        Column(
                            Modifier.fillMaxWidth().clickable { confirm = k to c; kind = null }.padding(vertical = 8.dp),
                        ) {
                            Text(c.label, style = MaterialTheme.typography.bodyMedium)
                            Text(c.detail, style = MaterialTheme.typography.bodySmall, color = MaterialTheme.colorScheme.onSurfaceVariant)
                        }
                    }
                }
            },
            confirmButton = { TextButton(onClick = { kind = null }) { Text("Close") } },
        )
    }
    confirm?.let { (k, c) ->
        AlertDialog(
            onDismissRequest = { confirm = null },
            title = { Text("Delete ${c.label}?") },
            text = { Text("Removes ${c.detail} from this device. Your library and collections are kept.") },
            confirmButton = {
                TextButton(onClick = {
                    confirm = null
                    scope.launch {
                        if (k.stems) storage.deleteStems(c.songIds) else storage.deleteBurns(c.songIds)
                        snackbar.showSnackbar("Deleted ${c.label}")
                        onChanged()
                    }
                }) { Text("Delete") }
            },
            dismissButton = { TextButton(onClick = { confirm = null }) { Text("Cancel") } },
        )
    }
}

private suspend fun loadChoices(graph: AppGraph, k: DeleteKind): List<DeleteChoice> {
    val storage = graph.storageService
    fun fmt(a: ArtistUsage) = DeleteChoice(a.artist, "${a.songIds.size} songs, ${a.bytes / 1_000_000} MB", a.songIds)
    return when (k) {
        DeleteKind.BURN_ARTIST -> storage.burnUsageByArtist().map(::fmt)
        DeleteKind.STEM_ARTIST -> storage.stemUsageByArtist().map(::fmt)
        DeleteKind.BURN_COLLECTION -> {
            val col = graph.collections
            val st = col.state.value
            val raw = st.pockets.map { it.name to col.songIdsForPocket(it.id) } +
                st.playlists.map { it.name to col.songIdsForPlaylist(it.id) }
            raw.sortedBy { it.first.lowercase() }.mapNotNull { (name, ids) ->
                val ready = graph.servicesGraph.burnStore.readyBurnedIds(ids)
                if (ready.isEmpty()) null
                else DeleteChoice(name, "${ready.size} downloaded songs, ${storage.approximateBurnBytes(ready) / 1_000_000} MB", ready)
            }
        }
    }
}

private fun describe(context: android.content.Context, r: com.levi.pocketdj.data.storage.StorageManager.PruneResult): String =
    "Pruned ${r.evicted} songs, freed ${Formatter.formatFileSize(context, r.freedBytes)}. " +
        "Now ${r.usageSongs} songs / ${Formatter.formatFileSize(context, r.usageBytes)}."

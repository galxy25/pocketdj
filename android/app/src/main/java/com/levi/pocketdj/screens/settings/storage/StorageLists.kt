package com.levi.pocketdj.screens.settings.storage

import androidx.compose.foundation.clickable
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.lazy.LazyColumn
import androidx.compose.foundation.lazy.items
import androidx.compose.material3.AlertDialog
import androidx.compose.material3.HorizontalDivider
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.SnackbarHost
import androidx.compose.material3.SnackbarHostState
import androidx.compose.material3.Text
import androidx.compose.material3.TextButton
import androidx.compose.runtime.Composable
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.rememberCoroutineScope
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.platform.testTag
import androidx.compose.ui.unit.dp
import com.levi.pocketdj.data.burns.ArtistUsage
import kotlinx.coroutines.launch

/** Pushed Storage list routes (contributed by PlaybackGraph.navEntries). */
object StorageRoutes {
    const val BURNED_ARTISTS = "settings/storage/burned-artists"
    const val BURNED_COLLECTIONS = "settings/storage/burned-collections"
    const val BURNED_STEMS = "settings/storage/burned-stems"
}

/** One deletable row of a burned-music list. */
data class UsageRow(val label: String, val detail: String, val songIds: List<String>)

/** Pure grouping + copy for the three iOS-Storage-parity lists. */
object StorageLists {
    fun detail(songs: Int, bytes: Long, noun: String = "songs"): String =
        "$songs $noun, ${bytes / 1_000_000} MB"

    /** By-artist rows exactly as the service reports them (it already sorts and de-dupes files). */
    fun fromArtists(usage: List<ArtistUsage>, noun: String = "songs"): List<UsageRow> =
        usage.map { UsageRow(it.artist, detail(it.songIds.size, it.bytes, noun), it.songIds) }

    /**
     * Group burned songs under each named collection (pockets + playlists), A-Z case-insensitively; a
     * collection with no READY burn is omitted. [readyOf] filters ids to burned-ready, [bytesOf] sizes them.
     */
    suspend fun fromCollections(
        named: List<Pair<String, List<String>>>,
        readyOf: (List<String>) -> List<String>,
        bytesOf: suspend (List<String>) -> Long,
    ): List<UsageRow> =
        named.sortedBy { it.first.lowercase() }.mapNotNull { (name, ids) ->
            val ready = readyOf(ids)
            if (ready.isEmpty()) null else UsageRow(name, detail(ready.size, bytesOf(ready), "downloaded songs"), ready)
        }

    /** Every song id behind the rows, once each (a song in two collections is deleted once). */
    fun allSongIds(rows: List<UsageRow>): List<String> = rows.flatMap { it.songIds }.distinct()

    const val DELETE_ALL_LABEL = "Delete all burnt music"
    const val DELETE_ALL_BODY =
        "Removes every downloaded file (audio, cuts, stems, beat grids) from this device. " +
            "Your library, collections and catalog are kept."

    /** iOS StorageView: Delete-all stays enabled while ANY ledger entry (incl. stuck) or burned/stem bytes remain. */
    fun deleteAllEnabled(ledgerEntries: Int, burnBytes: Long, stemBytes: Long): Boolean =
        ledgerEntries > 0 || burnBytes > 0L || stemBytes > 0L

    /** The by-artist / by-collection / stems links are dead ends when nothing is downloaded. */
    fun navEnabled(ledgerEntries: Int, burnBytes: Long, stemBytes: Long): Boolean =
        deleteAllEnabled(ledgerEntries, burnBytes, stemBytes)
}

/** Shared scaffold of the three pushed lists: rows, tap -> confirm -> delete, empty state. */
@Composable
internal fun BurnedListScreen(
    title: String,
    caption: String,
    load: suspend () -> List<UsageRow>,
    delete: suspend (UsageRow) -> Unit,
    tag: String,
) {
    val scope = rememberCoroutineScope()
    val snackbar = remember { SnackbarHostState() }
    var rows by remember { mutableStateOf<List<UsageRow>?>(null) }
    var confirm by remember { mutableStateOf<UsageRow?>(null) }
    LaunchedEffect(Unit) { rows = runCatching { load() }.getOrDefault(emptyList()) }

    Box(Modifier.fillMaxSize().testTag(tag)) {
        Column(Modifier.fillMaxSize().padding(horizontal = 16.dp)) {
            Text(title, style = MaterialTheme.typography.titleMedium, modifier = Modifier.padding(top = 16.dp))
            Text(
                caption, style = MaterialTheme.typography.bodySmall,
                color = MaterialTheme.colorScheme.onSurfaceVariant, modifier = Modifier.padding(vertical = 4.dp),
            )
            val list = rows
            when {
                list == null -> Text("Loading…", style = MaterialTheme.typography.bodySmall)
                list.isEmpty() -> Text("Nothing downloaded.", style = MaterialTheme.typography.bodyMedium)
                else -> LazyColumn(Modifier.fillMaxSize()) {
                    items(list) { row ->
                        Column(Modifier.fillMaxWidth().clickable { confirm = row }.padding(vertical = 10.dp)) {
                            Text(row.label, style = MaterialTheme.typography.bodyMedium)
                            Text(
                                row.detail, style = MaterialTheme.typography.bodySmall,
                                color = MaterialTheme.colorScheme.onSurfaceVariant,
                            )
                        }
                        HorizontalDivider()
                    }
                }
            }
        }
        SnackbarHost(snackbar, Modifier.align(Alignment.BottomCenter))
    }

    confirm?.let { row ->
        AlertDialog(
            onDismissRequest = { confirm = null },
            title = { Text("Delete ${row.label}?") },
            text = { Text("Removes ${row.detail} from this device. Your library and collections are kept.") },
            confirmButton = {
                TextButton(onClick = {
                    confirm = null
                    scope.launch {
                        delete(row)
                        // A song sits in many collections: reload so every other row's count/MB is fresh.
                        rows = runCatching { load() }.getOrDefault(emptyList())
                        snackbar.showSnackbar("Deleted ${row.label}")
                    }
                }) { Text("Delete") }
            },
            dismissButton = { TextButton(onClick = { confirm = null }) { Text("Cancel") } },
        )
    }
}

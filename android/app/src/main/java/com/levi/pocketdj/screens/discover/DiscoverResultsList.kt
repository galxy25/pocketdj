package com.levi.pocketdj.screens.discover

import androidx.compose.foundation.background
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.layout.width
import androidx.compose.foundation.lazy.LazyColumn
import androidx.compose.foundation.lazy.items
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.filled.Add
import androidx.compose.material.icons.filled.Album
import androidx.compose.material.icons.filled.Check
import androidx.compose.material3.CircularProgressIndicator
import androidx.compose.material3.Icon
import androidx.compose.material3.IconButton
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.OutlinedTextField
import androidx.compose.material3.SegmentedButton
import androidx.compose.material3.SegmentedButtonDefaults
import androidx.compose.material3.SingleChoiceSegmentedButtonRow
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.collectAsState
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.rememberCoroutineScope
import androidx.compose.runtime.saveable.rememberSaveable
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.layout.ContentScale
import androidx.compose.ui.semantics.contentDescription
import androidx.compose.ui.semantics.semantics
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.unit.dp
import coil.compose.AsyncImage
import com.levi.pocketdj.screens.browse.EmptyState
import com.levi.pocketdj.screens.browse.ExplicitBadge
import com.levi.pocketdj.screens.browse.Fmt
import com.levi.pocketdj.data.edition.EditionSettings
import kotlinx.coroutines.flow.map
import kotlinx.coroutines.launch

/** Square artwork with a neutral placeholder (no catalog album row exists for a Discover hit). */
@Composable
internal fun DiscoverArt(url: String?, size: Int, modifier: Modifier = Modifier) {
    val shaped = modifier.size(size.dp).clip(RoundedCornerShape(6.dp))
    if (url.isNullOrBlank()) {
        Box(shaped.background(MaterialTheme.colorScheme.surfaceVariant), contentAlignment = Alignment.Center) {
            Icon(
                Icons.Filled.Album, null,
                tint = MaterialTheme.colorScheme.onSurfaceVariant, modifier = Modifier.size(24.dp),
            )
        }
    } else {
        AsyncImage(
            model = url, contentDescription = null, contentScale = ContentScale.Crop,
            modifier = shaped.background(MaterialTheme.colorScheme.surfaceVariant),
        )
    }
}

/** Shared loading / empty / error scaffold; calls [content] only when there are hits to render. */
@Composable
internal fun <T> DiscoverStateHost(
    ui: DiscoverUi<T>,
    noun: String,
    content: @Composable () -> Unit,
) {
    Column(Modifier.fillMaxSize()) {
        ui.notice?.let {
            Text(
                it,
                style = MaterialTheme.typography.labelMedium,
                color = MaterialTheme.colorScheme.error,
                modifier = Modifier.fillMaxWidth().padding(horizontal = 16.dp, vertical = 4.dp),
            )
        }
        Box(Modifier.weight(1f).fillMaxWidth()) {
            when (val s = ui.state) {
                DiscoverState.Idle -> EmptyState("Search all of Apple Music — type a title or an artist")
                DiscoverState.Loading -> Box(Modifier.fillMaxSize(), contentAlignment = Alignment.Center) {
                    Row(verticalAlignment = Alignment.CenterVertically) {
                        CircularProgressIndicator(Modifier.size(18.dp), strokeWidth = 2.dp)
                        Spacer(Modifier.width(10.dp))
                        Text("Searching…", color = MaterialTheme.colorScheme.onSurfaceVariant)
                    }
                }
                DiscoverState.NoSources -> EmptyState(
                    "Discover needs a source — add an import server in Settings, " +
                        "or sign in to Apple Music so the catalog can be searched.",
                )
                is DiscoverState.Unavailable -> EmptyState(DiscoverQueryRunner.unavailableCopy(s.message))
                DiscoverState.Loaded ->
                    if (ui.hits.isEmpty()) EmptyState("No $noun matches — adjust the search or the artist refine")
                    else content()
            }
        }
    }
}

/** Discover ▸ Songs results. [onAdd] returns true when the add was accepted (delegates to DISC-2). */
@Composable
fun DiscoverResultsList(
    ui: DiscoverUi<DiscoverHit>,
    canAddToLibrary: Boolean,
    onAdd: suspend (DiscoverHit) -> Boolean,
    modifier: Modifier = Modifier,
) {
    DiscoverStateHost(ui, "song") {
        LazyColumn(modifier.fillMaxSize()) {
            items(ui.hits, key = { it.id }) { hit ->
                DiscoverSongRow(hit, canAddToLibrary, onAdd)
            }
        }
    }
}

@Composable
private fun DiscoverSongRow(hit: DiscoverHit, canAddToLibrary: Boolean, onAdd: suspend (DiscoverHit) -> Boolean) {
    val scope = rememberCoroutineScope()
    var busy by remember(hit.id) { mutableStateOf(false) }
    // Ripped is NOT "added": show a distinct "Ripped" state (play from Discover is PARTIAL, see status).
    val ripped = hit.ripped == true
    var addedLocal by rememberSaveable(hit.id) { mutableStateOf(false) }
    // Derived from the store like iOS (BrowseDiscover.swift:283): an already-added song never offers ＋ again.
    val ctx = androidx.compose.ui.platform.LocalContext.current
    val addsState = remember(ctx) { com.levi.pocketdj.di.AppGraph.get(ctx).browseGraph.discoverAdds.state }
    val adds by addsState.collectAsState()
    val added = addedLocal || adds.entries.any { it.songId == hit.id }
    var failed by remember(hit.id) { mutableStateOf(false) }
    Row(
        verticalAlignment = Alignment.CenterVertically,
        modifier = Modifier.fillMaxWidth().padding(horizontal = 12.dp, vertical = 6.dp),
    ) {
        DiscoverArt(hit.artworkUrl ?: hit.albumArtworkUrl, 48)
        Spacer(Modifier.width(12.dp))
        Column(Modifier.weight(1f)) {
            Row(verticalAlignment = Alignment.CenterVertically) {
                Text(
                    hit.title, style = MaterialTheme.typography.bodyLarge,
                    maxLines = 1, overflow = TextOverflow.Ellipsis, modifier = Modifier.weight(1f, fill = false),
                )
                if (hit.explicit == true) {
                    Spacer(Modifier.width(6.dp))
                    ExplicitBadge()
                }
            }
            Text(
                listOfNotNull(hit.artist.ifBlank { null }, hit.album).joinToString(" · "),
                style = MaterialTheme.typography.bodySmall,
                color = MaterialTheme.colorScheme.onSurfaceVariant,
                maxLines = 1, overflow = TextOverflow.Ellipsis,
            )
        }
        hit.durationMs?.let {
            Text(
                Fmt.duration(it.toLong()), style = MaterialTheme.typography.labelSmall,
                color = MaterialTheme.colorScheme.onSurfaceVariant,
            )
        }
        val help = DiscoverAddWording.addHelp("song", canAddToLibrary, opensInMusic = false)
        when {
            busy -> CircularProgressIndicator(Modifier.padding(12.dp).size(20.dp), strokeWidth = 2.dp)
            ripped -> Icon(
                Icons.Filled.Check, "Ripped", tint = MaterialTheme.colorScheme.primary,
                modifier = Modifier.padding(12.dp),
            )
            added -> Icon(
                Icons.Filled.Check, "Added", tint = MaterialTheme.colorScheme.primary,
                modifier = Modifier.padding(12.dp),
            )
            else -> IconButton(
                onClick = {
                    busy = true
                    failed = false
                    scope.launch {
                        addedLocal = try { onAdd(hit) } finally { busy = false }
                        failed = !addedLocal
                    }
                },
                modifier = Modifier.semantics { contentDescription = help },
            ) { Icon(Icons.Filled.Add, contentDescription = help) }
        }
    }
    if (failed) {
        Text(
            DiscoverAddWording.ADD_FAILED,
            style = MaterialTheme.typography.labelSmall,
            color = MaterialTheme.colorScheme.error,
            modifier = Modifier.padding(start = 72.dp, end = 16.dp),
        )
    }
}

/**
 * The Browse ▸ Discover body: Songs|Albums scope, artist refine, and the results for the Browse
 * search field's [query]. Owns its two debounced models; leaving Discover disposes them.
 */
@Composable
fun DiscoverPane(query: String, modifier: Modifier = Modifier) {
    val context = androidx.compose.ui.platform.LocalContext.current
    val graph = remember { com.levi.pocketdj.di.AppGraph.get(context) }
    val scope = rememberCoroutineScope()
    var discoverScope by rememberSaveable { mutableStateOf(DiscoverScope.SONGS) }
    var refine by rememberSaveable { mutableStateOf("") }
    val songModel = remember { DiscoverSearchModel.songs(scope, graph.appleMusicApi, graph.ripServerClient) }
    val albumModel = remember { DiscoverSearchModel.albums(scope, graph.appleMusicApi, graph.ripServerClient) }
    val songUi by songModel.ui.collectAsState()
    val albumUi by albumModel.ui.collectAsState()
    val canAdd by remember { graph.settings.settings.map { it.hasAppleMusic } }.collectAsState(false)
    val albumStates by remember { graph.browseGraph.discoverAlbumStates }.collectAsState(emptyMap())
    val preferExplicit by remember { EditionSettings.flow(graph.settings) }.collectAsState(null)
    val rankedSongUi = remember(songUi, preferExplicit) {
        songUi.copy(hits = DiscoverExplicitRanking.rank(songUi.hits, preferExplicit ?: false))
    }

    LaunchedEffect(query, refine, discoverScope) {
        when (discoverScope) {
            DiscoverScope.SONGS -> { albumModel.cancel(); songModel.searchDebounced(query, refine) }
            DiscoverScope.ALBUMS -> { songModel.cancel(); albumModel.searchDebounced(query, refine) }
        }
    }
    androidx.compose.runtime.DisposableEffect(Unit) {
        onDispose { songModel.cancel(); albumModel.cancel() }
    }

    Column(modifier.fillMaxSize()) {
        SingleChoiceSegmentedButtonRow(Modifier.fillMaxWidth().padding(horizontal = 12.dp)) {
            DiscoverScope.entries.forEachIndexed { i, entry ->
                SegmentedButton(
                    selected = discoverScope == entry,
                    onClick = { discoverScope = entry },
                    shape = SegmentedButtonDefaults.itemShape(i, DiscoverScope.entries.size),
                ) { Text(if (entry == DiscoverScope.SONGS) "Songs" else "Albums") }
            }
        }
        OutlinedTextField(
            value = refine,
            onValueChange = { refine = it },
            singleLine = true,
            placeholder = { Text("Refine by artist") },
            modifier = Modifier.fillMaxWidth().padding(horizontal = 12.dp, vertical = 4.dp),
        )
        when (discoverScope) {
            DiscoverScope.SONGS -> DiscoverResultsList(
                ui = rankedSongUi, canAddToLibrary = canAdd, onAdd = { graph.browseGraph.discoverAddSong(it) },
            )
            DiscoverScope.ALBUMS -> DiscoverAlbumResultsList(
                ui = albumUi, canAddToLibrary = canAdd,
                loadTracks = { graph.ripServerClient.albumTracks(it) },
                onAdd = { graph.browseGraph.discoverAddAlbum(it) },
                addStates = albumStates,
            )
        }
    }
}

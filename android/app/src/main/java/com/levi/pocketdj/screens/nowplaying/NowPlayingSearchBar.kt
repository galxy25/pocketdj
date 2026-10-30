package com.levi.pocketdj.screens.nowplaying

import androidx.compose.foundation.clickable
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.heightIn
import androidx.compose.foundation.layout.padding
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.filled.Close
import androidx.compose.material.icons.filled.ExpandLess
import androidx.compose.material.icons.filled.ExpandMore
import androidx.compose.material.icons.filled.PlaylistAdd
import androidx.compose.material.icons.filled.Search
import androidx.compose.material3.Icon
import androidx.compose.material3.IconButton
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.OutlinedTextField
import androidx.compose.material3.Text
import androidx.compose.material3.TextButton
import androidx.compose.runtime.Composable
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.saveable.rememberSaveable
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.platform.testTag
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.unit.dp
import com.levi.pocketdj.data.catalog.IndexAlbum
import com.levi.pocketdj.data.catalog.IndexSong

/** The add-search field ("Add songs or albums"). The caller debounces + runs [NowPlayingSearch] off-main. */
@Composable
fun NowPlayingSearchBar(query: String, onQuery: (String) -> Unit, modifier: Modifier = Modifier) {
    OutlinedTextField(
        value = query,
        onValueChange = onQuery,
        singleLine = true,
        placeholder = { Text("Add songs or albums") },
        leadingIcon = { Icon(Icons.Filled.Search, contentDescription = null) },
        trailingIcon = {
            if (query.isNotEmpty()) {
                IconButton(onClick = { onQuery("") }) { Icon(Icons.Filled.Close, contentDescription = "Clear search") }
            }
        },
        modifier = modifier.fillMaxWidth().testTag("np-search"),
    )
}

/** Albums above songs, each section collapsible; every row offers Add next / Add to end. */
@Composable
fun NowPlayingSearchResults(
    results: NowPlayingSearch.Results,
    onAddNextSong: (IndexSong) -> Unit,
    onAddEndSong: (IndexSong) -> Unit,
    onAddNextAlbum: (IndexAlbum) -> Unit,
    onAddEndAlbum: (IndexAlbum) -> Unit,
    modifier: Modifier = Modifier,
) {
    var albumsOpen by rememberSaveable { mutableStateOf(true) }
    var songsOpen by rememberSaveable { mutableStateOf(true) }
    Column(modifier.fillMaxWidth()) {
        SectionHeader("Albums (${results.albums.size})", albumsOpen, "np-albums-header") { albumsOpen = !albumsOpen }
        if (albumsOpen) results.albums.forEach { album ->
            ResultRow(
                title = album.name,
                subtitle = "${album.artist} · ${com.levi.pocketdj.screens.browse.Fmt.count(album.trackList.size, "track")}",
                tag = "np-add-album-${album.id}",
                onNext = { onAddNextAlbum(album) },
                onEnd = { onAddEndAlbum(album) },
            )
        }
        SectionHeader("Songs (${results.songs.size})", songsOpen, "np-songs-header") { songsOpen = !songsOpen }
        if (songsOpen) results.songs.forEach { song ->
            ResultRow(
                title = song.name,
                subtitle = song.artist,
                tag = "np-add-song-${song.id}",
                onNext = { onAddNextSong(song) },
                onEnd = { onAddEndSong(song) },
            )
        }
    }
}

@Composable
private fun SectionHeader(text: String, open: Boolean, tag: String, toggle: () -> Unit) {
    Row(
        Modifier.fillMaxWidth().clickable(onClick = toggle).padding(vertical = 8.dp).testTag(tag),
        verticalAlignment = Alignment.CenterVertically,
    ) {
        Text(text, style = MaterialTheme.typography.labelLarge, color = MaterialTheme.colorScheme.onSurfaceVariant, modifier = Modifier.weight(1f))
        Icon(if (open) Icons.Filled.ExpandLess else Icons.Filled.ExpandMore, contentDescription = if (open) "Collapse" else "Expand")
    }
}

@Composable
private fun ResultRow(title: String, subtitle: String, tag: String, onNext: () -> Unit, onEnd: () -> Unit) {
    Row(
        Modifier.fillMaxWidth().heightIn(min = 52.dp).testTag(tag),
        verticalAlignment = Alignment.CenterVertically,
        horizontalArrangement = Arrangement.spacedBy(4.dp),
    ) {
        Column(Modifier.weight(1f)) {
            Text(title, style = MaterialTheme.typography.bodyMedium, maxLines = 1, overflow = TextOverflow.Ellipsis)
            Text(subtitle, style = MaterialTheme.typography.bodySmall, color = MaterialTheme.colorScheme.onSurfaceVariant, maxLines = 1, overflow = TextOverflow.Ellipsis)
        }
        TextButton(onClick = onNext) { Text("Next") }
        IconButton(onClick = onEnd) { Icon(Icons.Filled.PlaylistAdd, contentDescription = "Add to end") }
    }
}

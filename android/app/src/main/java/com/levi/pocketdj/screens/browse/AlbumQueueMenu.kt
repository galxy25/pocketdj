package com.levi.pocketdj.screens.browse

import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.automirrored.filled.PlaylistAdd
import androidx.compose.material.icons.automirrored.filled.PlaylistPlay
import androidx.compose.material.icons.automirrored.filled.QueueMusic
import androidx.compose.material.icons.filled.MoreHoriz
import androidx.compose.material3.DropdownMenu
import androidx.compose.material3.DropdownMenuItem
import androidx.compose.material3.Icon
import androidx.compose.material3.IconButton
import androidx.compose.runtime.Composable
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
import androidx.compose.ui.Modifier
import androidx.compose.ui.platform.testTag
import androidx.compose.ui.unit.dp
import androidx.compose.foundation.layout.size
import com.levi.pocketdj.data.catalog.IndexSong
import com.levi.pocketdj.playback.sequencer.QueueItem
import com.levi.pocketdj.screens.collections.ContextAction

/** Pure helpers + the menu rows for the album page's queue actions (iOS `QueueMenuItems`). */
internal object AlbumQueueMenu {
    /** Songs -> queue items (id, title, artist, length), in the order given. */
    fun queueItems(songs: List<IndexSong>): List<QueueItem> =
        songs.map { QueueItem(it.id, it.name, it.artist, it.length) }

    /** "Play next" / "Play last" labels; the album variant says what is queued. */
    fun nextLabel(songCount: Int, album: Boolean): String = if (album) "Play next ($songCount)" else "Play next"
    fun lastLabel(songCount: Int, album: Boolean): String = if (album) "Play last ($songCount)" else "Play last"

    /** The queue rows hide themselves when there is nothing to queue (iOS). */
    fun showsQueueRows(songCount: Int): Boolean = songCount > 0

    /** Leading rows for the track long-press dialog. */
    fun trackActions(song: IndexSong, add: (List<QueueItem>, Boolean) -> Unit): List<ContextAction> {
        val items = queueItems(listOf(song))
        return listOf(
            ContextAction("Play next", Icons.AutoMirrored.Filled.QueueMusic, "ctx-play-next") { add(items, true) },
            ContextAction("Play last", Icons.AutoMirrored.Filled.PlaylistPlay, "ctx-play-last") { add(items, false) },
        )
    }
}

/**
 * The whole-album menu beside the track count: Play next / Play last / Add to playlist.
 * [onAdd] is (items, next); [onAddToPlaylist] opens the add-to-playlist flow for the album.
 */
@Composable
internal fun AlbumQueueMenuButton(
    songs: List<IndexSong>,
    onAdd: (List<QueueItem>, Boolean) -> Unit,
    onAddToPlaylist: () -> Unit,
    modifier: Modifier = Modifier,
) {
    var open by remember { mutableStateOf(false) }
    IconButton(onClick = { open = true }, modifier = modifier.size(32.dp).testTag("album-queue-menu")) {
        Icon(Icons.Filled.MoreHoriz, contentDescription = "Album queue menu", modifier = Modifier.size(20.dp))
    }
    DropdownMenu(expanded = open, onDismissRequest = { open = false }) {
        if (AlbumQueueMenu.showsQueueRows(songs.size)) {
            val items = AlbumQueueMenu.queueItems(songs)
            DropdownMenuItem(
                text = { androidx.compose.material3.Text(AlbumQueueMenu.nextLabel(songs.size, album = true)) },
                leadingIcon = { Icon(Icons.AutoMirrored.Filled.QueueMusic, null) },
                onClick = { open = false; onAdd(items, true) },
                modifier = Modifier.testTag("album-play-next"),
            )
            DropdownMenuItem(
                text = { androidx.compose.material3.Text(AlbumQueueMenu.lastLabel(songs.size, album = true)) },
                leadingIcon = { Icon(Icons.AutoMirrored.Filled.PlaylistPlay, null) },
                onClick = { open = false; onAdd(items, false) },
                modifier = Modifier.testTag("album-play-last"),
            )
        }
        DropdownMenuItem(
            text = { androidx.compose.material3.Text("Add to playlist") },
            leadingIcon = { Icon(Icons.AutoMirrored.Filled.PlaylistAdd, null) },
            onClick = { open = false; onAddToPlaylist() },
            modifier = Modifier.testTag("album-add-to-playlist"),
        )
    }
}

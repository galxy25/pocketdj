package com.levi.pocketdj.screens.nowplaying

import androidx.compose.foundation.layout.padding
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.filled.Share
import androidx.compose.material3.Icon
import androidx.compose.material3.Text
import androidx.compose.material3.TextButton
import androidx.compose.runtime.Composable
import androidx.compose.ui.Modifier
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.platform.testTag
import androidx.compose.ui.unit.dp
import com.levi.pocketdj.data.catalog.IndexSong
import com.levi.pocketdj.data.share.ShareText

/** Pure share-text choice for Now Playing (iOS `NowPlayingPanel` share): catalog song block, else title/artist search links. */
object NowPlayingShareText {
    /** Null when nothing is playing (the button is hidden). */
    fun build(hasTrack: Boolean, songId: String?, title: String, artist: String, songsById: Map<String, IndexSong>?): String? {
        if (!hasTrack) return null
        val song = songId?.let { songsById?.get(it) }
        if (song != null) return ShareText.forSong(song)
        if (title.isBlank()) return null
        return ShareText.forTitleArtist(title, artist)
    }
}

/** Share action under the transport row; hidden when nothing plays. */
@Composable
fun NowPlayingShareButton(text: String?, modifier: Modifier = Modifier) {
    if (text == null) return
    val context = LocalContext.current
    TextButton(onClick = { ShareText.send(context, text) }, modifier = modifier.testTag("np-share")) {
        Icon(Icons.Filled.Share, contentDescription = null, modifier = Modifier.padding(end = 6.dp))
        Text("Share")
    }
}

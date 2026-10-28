package com.levi.pocketdj.screens.producer.tracks

import android.content.Context
import android.content.Intent
import android.media.AudioAttributes
import android.media.MediaPlayer
import androidx.compose.foundation.clickable
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.padding
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.filled.MoreVert
import androidx.compose.material.icons.filled.PauseCircle
import androidx.compose.material.icons.filled.PlayCircleOutline
import androidx.compose.material3.DropdownMenu
import androidx.compose.material3.DropdownMenuItem
import androidx.compose.material3.Icon
import androidx.compose.material3.IconButton
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.runtime.DisposableEffect
import androidx.compose.runtime.getValue
import androidx.compose.runtime.rememberCoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.launch
import kotlinx.coroutines.withContext
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.platform.testTag
import androidx.compose.ui.semantics.contentDescription
import androidx.compose.ui.semantics.semantics
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.unit.dp
import androidx.core.content.FileProvider
import com.levi.pocketdj.studio.model.StudioArrangementArtifact
import com.levi.pocketdj.studio.store.ArrangerMath
import java.io.File

/**
 * Row-audition for bounce / recording artifacts (tap a row to hear it, tap again to stop). One artifact at
 * a time; [playingId] drives the row's play/pause glyph and clears when playback ends on its own. Separate
 * from the arranger engine; the caller parks Now Playing first via [beforePlay].
 */
class ArtifactAuditionPlayer(private val beforePlay: () -> Unit = {}) {
    private var player: MediaPlayer? = null
    var playingId by mutableStateOf<String?>(null)
        private set

    fun toggle(file: File?, id: String) {
        if (playingId == id) { stop(); return }
        stop()
        if (file == null) return
        beforePlay()
        val p = MediaPlayer()
        try {
            p.setAudioAttributes(AudioAttributes.Builder().setUsage(AudioAttributes.USAGE_MEDIA).setContentType(AudioAttributes.CONTENT_TYPE_MUSIC).build())
            p.setDataSource(file.path)
            p.setOnCompletionListener { if (playingId == id) stop() }
            p.setOnErrorListener { _, _, _ -> if (playingId == id) stop(); true }
            p.setOnPreparedListener { if (player === p) it.start() }
            player = p; playingId = id
            p.prepareAsync()
        } catch (_: Exception) {
            runCatching { p.release() }
            player = null; playingId = null
        }
    }

    fun stop() {
        player?.let { runCatching { it.stop() }; runCatching { it.release() } }
        player = null; playingId = null
    }
}

/** Share an artifact file through a copy in the cache dir + the app FileProvider. */
suspend fun shareArtifact(ctx: Context, file: File, name: String) {
    val (copy, uri) = withContext(Dispatchers.IO) { copyForShare(ctx, file, name) }
    val send = Intent(Intent.ACTION_SEND).apply {
        type = "audio/*"; putExtra(Intent.EXTRA_STREAM, uri); addFlags(Intent.FLAG_GRANT_READ_URI_PERMISSION)
    }
    ctx.startActivity(Intent.createChooser(send, "Share").addFlags(Intent.FLAG_ACTIVITY_NEW_TASK))
}

private fun copyForShare(ctx: Context, file: File, name: String): Pair<File, android.net.Uri> {
    val dir = File(ctx.cacheDir, "shared-artifacts").also { it.mkdirs() }
    val safe = name.replace(Regex("[^A-Za-z0-9 ._-]"), "_").ifBlank { "artifact" }
    val copy = File(dir, "$safe.${file.extension.ifEmpty { "m4a" }}")
    file.copyTo(copy, overwrite = true)
    return copy to FileProvider.getUriForFile(ctx, "${ctx.packageName}.fileprovider", copy)
}

/**
 * A collapsible group of one arrangement's artifacts of one [kind] (Bounces / Recordings), nested under
 * its home row. Header toggles [expanded]; each row auditions, with a menu to convert to a sample, add as
 * a track, share or delete.
 */
@Composable
fun ArtifactGroup(
    arrangementId: String,
    kind: StudioArrangementArtifact.Kind,
    artifacts: List<StudioArrangementArtifact>,
    expanded: Boolean,
    onToggle: () -> Unit,
    audition: ArtifactAuditionPlayer,
    fileFor: (StudioArrangementArtifact) -> File?,
    onConvert: (StudioArrangementArtifact) -> Unit,
    onAddAsTrack: (StudioArrangementArtifact) -> Unit,
    onDelete: (StudioArrangementArtifact) -> Unit,
    modifier: Modifier = Modifier,
) {
    val title = if (kind == StudioArrangementArtifact.Kind.BOUNCE) "Bounces" else "Recordings"
    val key = "$arrangementId-${kind.raw}"
    val ctx = LocalContext.current
    val shareScope = rememberCoroutineScope()
    Column(modifier.padding(start = 22.dp)) {
        Text(
            "${if (expanded) "v" else ">"}  $title (${artifacts.size})",
            style = MaterialTheme.typography.labelMedium, color = MaterialTheme.colorScheme.onSurfaceVariant,
            modifier = Modifier.fillMaxWidth().clickable(onClick = onToggle).padding(horizontal = 16.dp, vertical = 8.dp).testTag("tracks-artifacts-$key"),
        )
        if (expanded) artifacts.forEach { art ->
            var menu by remember(art.id) { mutableStateOf(false) }
            val playing = audition.playingId == art.id
            Row(
                Modifier.fillMaxWidth().clickable { audition.toggle(fileFor(art), art.id) }.padding(start = 16.dp).testTag("tracks-artifact-row-${art.id}"),
                verticalAlignment = Alignment.CenterVertically,
            ) {
                Icon(
                    if (playing) Icons.Filled.PauseCircle else Icons.Filled.PlayCircleOutline,
                    contentDescription = if (playing) "Pause ${art.name}" else "Play ${art.name}",
                    tint = if (playing) MaterialTheme.colorScheme.primary else MaterialTheme.colorScheme.onSurfaceVariant,
                )
                Column(Modifier.weight(1f).padding(start = 8.dp, top = 6.dp, bottom = 6.dp)) {
                    Text(art.name, style = MaterialTheme.typography.bodySmall, maxLines = 1, overflow = TextOverflow.Ellipsis)
                    Text(ArrangerMath.mmss(art.durationMs / 1000.0), style = MaterialTheme.typography.labelSmall, color = MaterialTheme.colorScheme.onSurfaceVariant)
                }
                Box {
                    IconButton(onClick = { menu = true }, modifier = Modifier.semantics { contentDescription = "Artifact actions" }.testTag("tracks-artifact-menu-${art.id}")) {
                        Icon(Icons.Filled.MoreVert, null)
                    }
                    DropdownMenu(menu, { menu = false }) {
                        DropdownMenuItem(text = { Text("Convert to sample") }, onClick = { menu = false; onConvert(art) }, modifier = Modifier.testTag("tracks-artifact-convert-${art.id}"))
                        DropdownMenuItem(text = { Text("Add as track") }, onClick = { menu = false; onAddAsTrack(art) }, modifier = Modifier.testTag("tracks-artifact-addtrack-${art.id}"))
                        DropdownMenuItem(text = { Text("Share") }, enabled = fileFor(art) != null,
                            onClick = { menu = false; fileFor(art)?.let { f -> shareScope.launch { runCatching { shareArtifact(ctx, f, art.name) } } } })
                        DropdownMenuItem(text = { Text("Delete") }, onClick = { menu = false; onDelete(art) }, modifier = Modifier.testTag("tracks-artifact-delete-${art.id}"))
                    }
                }
            }
        }
    }
}

/** Stop the audition when the host leaves composition. */
@Composable
fun rememberArtifactAudition(beforePlay: () -> Unit): ArtifactAuditionPlayer {
    val p = remember { ArtifactAuditionPlayer(beforePlay) }
    DisposableEffect(p) { onDispose { p.stop() } }
    return p
}

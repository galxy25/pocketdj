package com.levi.pocketdj.screens.producer.demux

import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.filled.Album
import androidx.compose.material.icons.filled.GraphicEq
import androidx.compose.material.icons.filled.Mic
import androidx.compose.material.icons.filled.Pause
import androidx.compose.material.icons.filled.Piano
import androidx.compose.material.icons.filled.PlayArrow
import androidx.compose.material.icons.filled.VolumeOff
import androidx.compose.material.icons.filled.VolumeUp
import androidx.compose.material3.CircularProgressIndicator
import androidx.compose.material3.Icon
import androidx.compose.material3.IconButton
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.Switch
import androidx.compose.material3.Text
import androidx.compose.material3.TextButton
import androidx.compose.runtime.Composable
import androidx.compose.runtime.collectAsState
import androidx.compose.runtime.getValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.platform.testTag
import androidx.compose.ui.unit.dp
import androidx.compose.ui.graphics.vector.ImageVector
import com.levi.pocketdj.studio.demux.DemuxSession
import com.levi.pocketdj.studio.demux.DemuxStemState
import com.levi.pocketdj.studio.demux.DemuxStore

/** Pure copy for the stems panel so the wording is testable (iOS stemsPanel strings). */
object StemsCopy {
    fun creatable(isSong: Boolean) =
        if (isSong) "Not stemmed yet — separate it on the import server."
        else "Uploads this audio to the import server to separate its stems — it stays private to you."

    fun creating(isSong: Boolean) =
        if (isSong) "Separating stems on the import server (this can take a few minutes)…"
        else "Uploading + separating on the import server (this can take a few minutes)…"

    const val DOWNLOADABLE = "This track is stemmed — download to play stems offline."
    const val NONE = "No stems for this one yet — they’re separated on the import server (Settings ▸ Import server)."
    const val STEMS_HINT = "Flip the Stems switch to mute/solo drums, bass, vocals, and the rest live."
}

private fun stemIcon(name: String): ImageVector = when (name) {
    "vocals" -> Icons.Filled.Mic
    "drums" -> Icons.Filled.Album
    "bass" -> Icons.Filled.GraphicEq
    else -> Icons.Filled.Piano
}

@Composable
fun StemsSection(session: DemuxSession, isSong: Boolean) {
    val state by session.stemState.collectAsState()
    val stemMode by session.stemMode.collectAsState()
    val player = session.player
    val version by player.version.collectAsState()
    Column(Modifier.fillMaxWidth().testTag("demux-stems"), verticalArrangement = Arrangement.spacedBy(6.dp)) {
        Text("Stems", style = MaterialTheme.typography.titleSmall)
        when (val s = state) {
            DemuxStemState.Burned -> {
                Row(verticalAlignment = Alignment.CenterVertically) {
                    Text("Stems", Modifier.weight(1f), style = MaterialTheme.typography.bodyMedium)
                    Switch(checked = stemMode, onCheckedChange = { session.setStemMode(it) }, modifier = Modifier.testTag("demux-stems-switch"))
                }
                if (stemMode) {
                    // `version` is passed down so each row recomposes when mute/solo/play state changes
                    // (rows are otherwise skipped: same name + same session instance).
                    DemuxStore.STEM_NAMES.forEach { StemRow(it, session, version) }
                } else Muted(StemsCopy.STEMS_HINT)
            }
            DemuxStemState.Downloadable -> ActionRow(StemsCopy.DOWNLOADABLE, "Download", "demux-stems-download") { session.downloadStems() }
            DemuxStemState.Downloading -> Busy("Downloading stems…", "demux-stems-downloading")
            DemuxStemState.Creatable -> ActionRow(StemsCopy.creatable(isSong), "Create stems", "demux-stems-create") { session.createStems() }
            DemuxStemState.Creating -> Busy(StemsCopy.creating(isSong), "demux-stems-creating")
            is DemuxStemState.Failed -> ActionRow(s.message, "Retry", "demux-stems-retry") { session.createStems() }
            DemuxStemState.None -> Muted(StemsCopy.NONE, "demux-stems-none")
        }
    }
}

@Composable
@Suppress("UNUSED_PARAMETER")
private fun StemRow(name: String, session: DemuxSession, version: Int) {
    val player = session.player
    val soloed = player.soloed == name
    Row(Modifier.fillMaxWidth().padding(vertical = 2.dp), verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(8.dp)) {
        IconButton(onClick = { player.solo(name) }, modifier = Modifier.size(36.dp).testTag("demux-stem-solo-$name")) {
            Icon(if (soloed && player.isPlaying) Icons.Filled.Pause else Icons.Filled.PlayArrow, "Solo $name",
                tint = if (soloed) MaterialTheme.colorScheme.tertiary else MaterialTheme.colorScheme.primary)
        }
        Icon(stemIcon(name), null, Modifier.size(18.dp))
        Text(name.replaceFirstChar { it.uppercase() }, Modifier.weight(1f).testTag("demux-stem-row-$name"))
        val audible = player.isAudible(name)
        IconButton(onClick = { player.toggleMute(name) }, modifier = Modifier.size(36.dp).testTag("demux-stem-mute-$name")) {
            Icon(if (audible) Icons.Filled.VolumeUp else Icons.Filled.VolumeOff, if (audible) "Mute $name" else "Unmute $name",
                tint = if (audible) MaterialTheme.colorScheme.primary else MaterialTheme.colorScheme.onSurfaceVariant)
        }
    }
}

@Composable
private fun Muted(text: String, tag: String? = null) {
    Text(text, style = MaterialTheme.typography.bodySmall, color = MaterialTheme.colorScheme.onSurfaceVariant,
        modifier = if (tag != null) Modifier.testTag(tag) else Modifier)
}

@Composable
private fun Busy(text: String, tag: String) {
    Row(verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(8.dp), modifier = Modifier.testTag(tag)) {
        CircularProgressIndicator(Modifier.size(16.dp), strokeWidth = 2.dp)
        Text(text, style = MaterialTheme.typography.bodySmall, color = MaterialTheme.colorScheme.onSurfaceVariant)
    }
}

@Composable
private fun ActionRow(text: String, button: String, tag: String, onClick: () -> Unit) {
    Row(verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(8.dp)) {
        Text(text, Modifier.weight(1f), style = MaterialTheme.typography.bodySmall, color = MaterialTheme.colorScheme.onSurfaceVariant)
        TextButton(onClick = onClick, modifier = Modifier.testTag(tag)) { Text(button) }
    }
}

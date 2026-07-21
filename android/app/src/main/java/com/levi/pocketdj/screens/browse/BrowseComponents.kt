package com.levi.pocketdj.screens.browse

import androidx.compose.foundation.background
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.filled.Album
import androidx.compose.material3.Icon
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.SnackbarHostState
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableIntStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.layout.ContentScale
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.unit.dp
import coil.compose.AsyncImage
import com.levi.pocketdj.data.catalog.IndexAlbum
import com.levi.pocketdj.data.rips.PlayResolver
import com.levi.pocketdj.data.rips.RipsManifest
import com.levi.pocketdj.playback.PlaybackController
import com.levi.pocketdj.playback.PlayOutcome

/**
 * How honest a ▶ affordance is for a song (specs/playback.md §3): STREAM = a
 * public rip exists; RIP = no rip but a configured server can make one on
 * explicit ▶; NONE = browsable metadata only (never render a play control that
 * can only fail).
 */
enum class Playability { STREAM, RIP, NONE }

fun playability(songId: String, manifest: RipsManifest, hasRipServer: Boolean): Playability =
    when {
        PlayResolver.isStudioId(songId) -> Playability.NONE
        manifest.containsKey(songId) -> Playability.STREAM
        hasRipServer -> Playability.RIP
        else -> Playability.NONE
    }

/**
 * Play through the controller and surface the outcome on a snackbar.
 * [queueAlbumContext] false = a standalone Browser single (history `browser`,
 * one-item queue) — the Browse Songs list, where no album is in view.
 */
suspend fun playAndReport(
    controller: PlaybackController,
    songId: String,
    snackbar: SnackbarHostState,
    queueAlbumContext: Boolean = true,
) {
    when (val outcome = controller.play(songId, queueAlbumContext = queueAlbumContext)) {
        is PlayOutcome.Started -> Unit
        is PlayOutcome.Preparing ->
            snackbar.showSnackbar("Preparing — playback starts automatically when the rip is ready")
        is PlayOutcome.NotPlayable ->
            snackbar.showSnackbar("No import server configured (Settings)")
        is PlayOutcome.Failed ->
            snackbar.showSnackbar(outcome.message)
    }
}

/**
 * Album art with the ordered-candidate fallback chain (specs/catalog.md §1):
 * try each `artCandidates()` URL in order, placeholder when all fail or none exist.
 */
@Composable
fun AlbumArt(
    album: IndexAlbum?,
    modifier: Modifier = Modifier,
    cornerRadius: Int = 6,
) {
    val candidates = remember(album?.id) { album?.artCandidates().orEmpty() }
    var candidateIndex by remember(album?.id) { mutableIntStateOf(0) }
    val url = candidates.getOrNull(candidateIndex)
    val shaped = modifier.clip(RoundedCornerShape(cornerRadius.dp))
    if (url == null) {
        Box(
            modifier = shaped.background(MaterialTheme.colorScheme.surfaceVariant),
            contentAlignment = Alignment.Center,
        ) {
            Icon(
                Icons.Filled.Album,
                contentDescription = null,
                tint = MaterialTheme.colorScheme.onSurfaceVariant,
                modifier = Modifier.size(24.dp),
            )
        }
    } else {
        AsyncImage(
            model = url,
            contentDescription = album?.let { "${it.name} cover art" },
            contentScale = ContentScale.Crop,
            onError = { candidateIndex += 1 }, // advance the chain; ends at placeholder
            modifier = shaped.background(MaterialTheme.colorScheme.surfaceVariant),
        )
    }
}

/**
 * Key chip: key name + camelot code tinted by wheel position
 * (specs/browse.md §5; iOS `Views/KeyChip.swift`). Renders nothing without data.
 */
@Composable
fun KeyChip(key: String?, camelot: String?, modifier: Modifier = Modifier) {
    val label = when {
        !camelot.isNullOrBlank() && !key.isNullOrBlank() -> "$key · $camelot"
        !camelot.isNullOrBlank() -> camelot
        !key.isNullOrBlank() -> key
        else -> return
    }
    val color = Camelot.color(camelot)
    Text(
        text = label,
        style = MaterialTheme.typography.labelSmall,
        fontWeight = FontWeight.SemiBold,
        color = color,
        maxLines = 1,
        modifier = modifier
            .clip(RoundedCornerShape(6.dp))
            .background(color.copy(alpha = 0.16f))
            .padding(horizontal = 6.dp, vertical = 2.dp),
    )
}

/** Small "E" explicit badge (specs/browse.md §3). */
@Composable
fun ExplicitBadge(modifier: Modifier = Modifier) {
    Text(
        text = "E",
        style = MaterialTheme.typography.labelSmall,
        fontWeight = FontWeight.Bold,
        color = MaterialTheme.colorScheme.onSurfaceVariant,
        modifier = modifier
            .clip(RoundedCornerShape(3.dp))
            .background(MaterialTheme.colorScheme.surfaceVariant)
            .padding(horizontal = 4.dp),
    )
}

/** Dim caption tag ("hip-hop · 1994 · My Vinyl" style fragments). */
@Composable
fun MetaTag(text: String, modifier: Modifier = Modifier) {
    Text(
        text = text,
        style = MaterialTheme.typography.labelSmall,
        color = MaterialTheme.colorScheme.onSurfaceVariant,
        maxLines = 1,
        modifier = modifier,
    )
}

package com.levi.pocketdj.screens.settings.sections

import android.content.Intent
import android.net.Uri
import androidx.activity.compose.rememberLauncherForActivityResult
import androidx.activity.result.contract.ActivityResultContracts
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.material3.CircularProgressIndicator
import androidx.compose.material3.HorizontalDivider
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.Text
import androidx.compose.material3.TextButton
import androidx.compose.runtime.Composable
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.collectAsState
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.rememberCoroutineScope
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.unit.dp
import com.levi.pocketdj.data.applemusic.MusicKitAuth
import com.levi.pocketdj.di.AppGraph
import com.levi.pocketdj.screens.shazam.AppleMusicAlbumRef
import com.levi.pocketdj.screens.shazam.AppleMusicRecognition
import com.levi.pocketdj.screens.shazam.AppleMusicRecognitionAction
import com.levi.pocketdj.screens.shazam.AppleMusicResolution
import com.levi.pocketdj.screens.shazam.ShazamHitInfo
import kotlinx.coroutines.CancellationException
import kotlinx.coroutines.launch

/** Label for the post-add rip phase (iOS ripPhaseLabel; "prepare your copy" wording). */
internal fun recognitionPhaseLabel(phase: String?): String = when (phase) {
    "queued", "searching" -> "Preparing — finding your copy…"
    "ripping", "streaming" -> "Preparing your copy…"
    "uploading" -> "Preparing — finishing up…"
    else -> "Saving to this device…"
}

/**
 * The Apple Music block inside the "Heard it" sheet (iOS AppleMusicRecognitionSection): resolves
 * the recognized track against the user's library and offers exactly one primary action - connect,
 * open its album, or add to Apple Music then prepare a copy for this device.
 */
@Composable
fun AppleMusicRecognitionSection(
    info: ShazamHitInfo,
    onOpenAlbum: (albumId: String) -> Unit,
    modifier: Modifier = Modifier,
) {
    val context = LocalContext.current
    val graph = remember { AppGraph.get(context) }
    val port = remember { graph.browseGraph.appleMusicRecognition }
    val scope = rememberCoroutineScope()
    val catalogState by graph.catalogRepository.state.collectAsState()
    val manifest by graph.ripsRepository.manifest.collectAsState()
    val jobs by graph.ripJobTracker.jobs.collectAsState()

    var linked by remember { mutableStateOf(false) }
    var resolving by remember { mutableStateOf(true) }
    var resolution by remember { mutableStateOf<AppleMusicResolution?>(null) }
    var adding by remember { mutableStateOf(false) }
    var added by remember { mutableStateOf(false) }
    var burnSongId by remember { mutableStateOf<String?>(null) }
    var errorText by remember { mutableStateOf<String?>(null) }
    var signingIn by remember { mutableStateOf(false) }

    suspend fun resolve() {
        linked = port.canContribute()
        if (!linked) { resolution = null; resolving = false; return }
        resolving = true
        resolution = port.resolve(info.appleMusicId, info.title, info.artist)
        resolving = false
    }

    LaunchedEffect(info) { resolve() }

    val authLauncher = rememberLauncherForActivityResult(ActivityResultContracts.StartActivityForResult()) { result ->
        scope.launch {
            signingIn = false
            if (graph.musicKitAuth.decodeResult(result.data) is MusicKitAuth.AuthResult.Success) resolve()
        }
    }

    val catalog = catalogState.catalog
    val indexAlbumId = resolution?.album?.let { ref ->
        catalog?.albumsById?.values?.let { AppleMusicRecognition.indexAlbum(ref, it)?.id }
    }
    val action = AppleMusicRecognition.action(
        available = port.available, canContribute = linked, canAdd = port.canAdd,
        resolving = if (adding) false else resolving, resolution = resolution, indexAlbumId = indexAlbumId,
    )
    if (action is AppleMusicRecognitionAction.Unavailable || action is AppleMusicRecognitionAction.NotFound) return

    fun openUrl(url: String?) {
        if (url == null) return
        runCatching { context.startActivity(Intent(Intent.ACTION_VIEW, Uri.parse(url)).addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)) }
    }

    @Composable
    fun BurnStatus() {
        val id = burnSongId ?: return
        val job = jobs[id]
        when {
            manifest.containsKey(id) -> Text("Saved to device", style = MaterialTheme.typography.bodySmall, color = MaterialTheme.colorScheme.primary)
            job?.phase == "error" -> Text(job.error ?: job.message ?: "Couldn’t prepare a copy", style = MaterialTheme.typography.bodySmall, color = MaterialTheme.colorScheme.error)
            job != null -> Row(verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(6.dp)) {
                CircularProgressIndicator(Modifier.size(12.dp), strokeWidth = 2.dp)
                Text(recognitionPhaseLabel(job.phase), style = MaterialTheme.typography.bodySmall)
            }
        }
    }

    @Composable
    fun InLibraryLabel() = Text("In your Apple Music library", style = MaterialTheme.typography.bodyMedium, color = MaterialTheme.colorScheme.primary)

    Column(modifier.padding(top = 4.dp), verticalArrangement = Arrangement.spacedBy(8.dp)) {
        HorizontalDivider()
        Text("Apple Music", style = MaterialTheme.typography.labelMedium, color = MaterialTheme.colorScheme.onSurfaceVariant)
        when (action) {
            AppleMusicRecognitionAction.Connect -> TextButton(
                enabled = !signingIn,
                onClick = {
                    scope.launch {
                        signingIn = true
                        try {
                            authLauncher.launch(graph.musicKitAuth.signInIntent())
                        } catch (e: CancellationException) {
                            signingIn = false; throw e
                        } catch (e: Throwable) {
                            signingIn = false; errorText = e.message ?: "Apple Music sign-in is unavailable"
                        }
                    }
                },
            ) { Text(if (signingIn) "Connecting…" else "Connect Apple Music") }

            AppleMusicRecognitionAction.Checking -> Row(verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(8.dp)) {
                CircularProgressIndicator(Modifier.size(14.dp), strokeWidth = 2.dp)
                Text("Checking your Apple Music library…", style = MaterialTheme.typography.bodyMedium)
            }

            AppleMusicRecognitionAction.InLibrary -> { InLibraryLabel(); BurnStatus() }

            is AppleMusicRecognitionAction.OpenIndexAlbum -> {
                InLibraryLabel()
                TextButton(onClick = { onOpenAlbum(action.albumId) }) { Text("Open album") }
                BurnStatus()
            }

            is AppleMusicRecognitionAction.OpenRecognizedAlbum -> {
                InLibraryLabel()
                // No synthesized album page on Android: hand the album to the Apple Music app.
                TextButton(onClick = { openUrl(action.album.url) }, enabled = action.album.url != null) { Text("Open album") }
                BurnStatus()
            }

            is AppleMusicRecognitionAction.OpenInMusicApp -> {
                Text("Not in your Apple Music library", style = MaterialTheme.typography.bodyMedium)
                TextButton(onClick = { openUrl(action.url) }) { Text("Add in Apple Music") }
            }

            is AppleMusicRecognitionAction.AddToLibrary -> {
                // Latch "added" so library-search latency can't re-offer the add and invite a duplicate.
                if (added) {
                    Text("Added to Apple Music", style = MaterialTheme.typography.bodyMedium, color = MaterialTheme.colorScheme.primary)
                } else {
                    TextButton(
                        enabled = !adding,
                        onClick = {
                            adding = true; errorText = null
                            scope.launch {
                                try {
                                    if (port.addSongToLibrary(action.storeId)) {
                                        added = true
                                        val catalogId = catalog?.songsById?.values?.let {
                                            AppleMusicRecognition.indexSong(action.storeId, action.title, action.artist, it)?.id
                                        }
                                        val id = AppleMusicRecognition.burnSongId(catalogId, action.storeId)
                                        burnSongId = id
                                        port.startRipAndBurn(id, action.title, action.artist, action.storeId)
                                        resolve()
                                    } else {
                                        errorText = "Couldn’t add to Apple Music"
                                    }
                                } catch (e: CancellationException) {
                                    throw e
                                } catch (e: Throwable) {
                                    errorText = e.message ?: "Couldn’t add to Apple Music"
                                } finally {
                                    adding = false
                                }
                            }
                        },
                    ) { Text(if (adding) "Adding…" else "Add to Apple Music") }
                    errorText?.let { Text(it, style = MaterialTheme.typography.bodySmall, color = MaterialTheme.colorScheme.error) }
                }
                BurnStatus()
            }

            else -> Unit
        }
    }
}

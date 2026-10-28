package com.levi.pocketdj.screens.shazam

import android.Manifest
import android.content.Intent
import android.content.pm.PackageManager
import android.net.Uri
import android.provider.Settings
import androidx.activity.compose.rememberLauncherForActivityResult
import androidx.activity.result.contract.ActivityResultContracts
import androidx.compose.animation.core.LinearEasing
import androidx.compose.animation.core.RepeatMode
import androidx.compose.animation.core.animateFloat
import androidx.compose.animation.core.infiniteRepeatable
import androidx.compose.animation.core.rememberInfiniteTransition
import androidx.compose.animation.core.tween
import androidx.compose.foundation.BorderStroke
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.material3.CircularProgressIndicator
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.Surface
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.collectAsState
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.rememberCoroutineScope
import androidx.compose.runtime.setValue
import androidx.compose.foundation.clickable
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.alpha
import androidx.compose.ui.draw.scale
import androidx.compose.ui.graphics.graphicsLayer
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.semantics.contentDescription
import androidx.compose.ui.semantics.semantics
import androidx.compose.ui.semantics.stateDescription
import androidx.compose.ui.unit.dp
import androidx.core.content.ContextCompat
import com.levi.pocketdj.di.AppGraph
import kotlinx.coroutines.CompletableDeferred

/** Accessibility string per phase (iOS accessibilityValue). */
internal fun shazamAccessibilityValue(phase: ShazamPhase, recording: Boolean): String = when {
    recording -> "Unavailable while recording"
    phase is ShazamPhase.Idle -> "Idle"
    phase is ShazamPhase.Listening -> "Listening"
    phase is ShazamPhase.Recognizing -> "Identifying"
    phase is ShazamPhase.Matched -> "Match found"
    phase is ShazamPhase.NoMatch -> "No match"
    phase is ShazamPhase.Denied -> "Microphone access denied"
    phase is ShazamPhase.Failed -> phase.message
    else -> ""
}

/** The glyph in the middle of "?♪?" per phase. */
internal fun shazamCenterGlyph(phase: ShazamPhase): String = when (phase) {
    is ShazamPhase.Matched -> "✓"
    is ShazamPhase.Denied -> "×"
    is ShazamPhase.Failed -> "!"
    else -> "♪"
}

/**
 * The literal "?♪?" capsule at the top of the catalog tabs. Tint + sonar pulse track the phase;
 * second tap while active cancels; denied opens app settings; disabled while a mix recording runs.
 */
@Composable
fun ShazamButton(
    onOpenSong: (songId: String) -> Unit,
    onOpenAlbum: (albumId: String) -> Unit,
    modifier: Modifier = Modifier,
) {
    val context = LocalContext.current
    val graph = remember { AppGraph.get(context) }
    val scope = rememberCoroutineScope()
    val mixRecording by graph.mixGraph.mixRecorder.isRecordingFlow.collectAsState()

    // The permission prompt result is bridged into the recognizer's suspend gate.
    var pending by remember { mutableStateOf<CompletableDeferred<Boolean>?>(null) }
    val launcher = rememberLauncherForActivityResult(ActivityResultContracts.RequestPermission()) { granted ->
        pending?.complete(granted); pending = null
    }
    val recognizer = remember {
        ShazamRecognizer(
            scope = scope,
            backend = graph.browseGraph.shazamBackend,
            permission = object : MicPermission {
                override fun isGrantedNow() =
                    ContextCompat.checkSelfPermission(context, Manifest.permission.RECORD_AUDIO) == PackageManager.PERMISSION_GRANTED

                override suspend fun ensureGranted(): Boolean =
                    if (isGrantedNow()) {
                        true
                    } else {
                        val d = CompletableDeferred<Boolean>()
                        pending = d
                        launcher.launch(Manifest.permission.RECORD_AUDIO)
                        d.await()
                    }
            },
            songs = { graph.catalogRepository.state.value.catalog?.songsById?.values.orEmpty() },
            blocked = { graph.mixGraph.mixRecorder.isRecording },
        )
    }
    val phase by recognizer.phase.collectAsState()

    // Granted in system Settings after a denial: Android does not relaunch the app on a grant, so re-check on resume.
    val lifecycleOwner = androidx.compose.ui.platform.LocalLifecycleOwner.current
    androidx.compose.runtime.DisposableEffect(lifecycleOwner, recognizer) {
        val observer = androidx.lifecycle.LifecycleEventObserver { _, event ->
            if (event == androidx.lifecycle.Lifecycle.Event.ON_RESUME &&
                ContextCompat.checkSelfPermission(context, Manifest.permission.RECORD_AUDIO) == PackageManager.PERMISSION_GRANTED
            ) recognizer.clearDenied()
        }
        lifecycleOwner.lifecycle.addObserver(observer)
        onDispose { lifecycleOwner.lifecycle.removeObserver(observer) }
    }

    // One-shot horizontal shake when the mic is denied (iOS ShakeIfDenied).
    val shake = androidx.compose.runtime.remember { androidx.compose.animation.core.Animatable(0f) }
    LaunchedEffect(phase is ShazamPhase.Denied) {
        if (phase is ShazamPhase.Denied) {
            for (x in floatArrayOf(10f, -10f, 7f, -7f, 3f, 0f)) {
                shake.animateTo(x, tween(60))
            }
        } else shake.snapTo(0f)
    }

    val tint = when (phase) {
        is ShazamPhase.Idle, is ShazamPhase.NoMatch -> MaterialTheme.colorScheme.onSurfaceVariant
        is ShazamPhase.Listening -> MaterialTheme.colorScheme.primary
        is ShazamPhase.Recognizing -> MaterialTheme.colorScheme.tertiary
        is ShazamPhase.Matched -> Color(0xFF34C759)
        is ShazamPhase.Denied, is ShazamPhase.Failed -> MaterialTheme.colorScheme.error
    }
    val markAlpha = when (phase) {
        is ShazamPhase.Listening -> 0.55f
        is ShazamPhase.Denied, is ShazamPhase.Failed -> 0.4f
        else -> 1f
    }
    val pulse = rememberInfiniteTransition(label = "shazam-pulse")
    val ring by pulse.animateFloat(
        initialValue = 0f, targetValue = 1f,
        animationSpec = infiniteRepeatable(tween(1200, easing = LinearEasing), RepeatMode.Restart), label = "ring",
    )
    val active = phase.isActive

    Surface(
        modifier = modifier
            .graphicsLayer { translationX = shake.value.dp.toPx() }
            .alpha(if (mixRecording) 0.4f else 1f)
            .scale(if (active) 1f + 0.05f * ring else 1f)
            .semantics {
                contentDescription = "Identify the song playing"
                stateDescription = shazamAccessibilityValue(phase, mixRecording)
            }
            .clickable(enabled = !mixRecording) {
                when (recognizer.tap()) {
                    ShazamTap.OPEN_SETTINGS -> runCatching {
                        context.startActivity(
                            Intent(Settings.ACTION_APPLICATION_DETAILS_SETTINGS, Uri.fromParts("package", context.packageName, null))
                                .addFlags(Intent.FLAG_ACTIVITY_NEW_TASK),
                        )
                    }
                    else -> Unit
                }
            },
        shape = MaterialTheme.shapes.extraLarge,
        color = MaterialTheme.colorScheme.surfaceVariant,
        border = BorderStroke(1.dp, tint.copy(alpha = if (active) 1f - 0.5f * ring else 0.6f)),
    ) {
        Row(
            modifier = Modifier.padding(horizontal = 14.dp, vertical = 8.dp),
            horizontalArrangement = Arrangement.spacedBy(6.dp),
            verticalAlignment = Alignment.CenterVertically,
        ) {
            Text("?", color = tint, modifier = Modifier.alpha(markAlpha), style = MaterialTheme.typography.titleMedium)
            Text(shazamCenterGlyph(phase), color = tint, style = MaterialTheme.typography.titleMedium)
            Text("?", color = tint, modifier = Modifier.alpha(markAlpha), style = MaterialTheme.typography.titleMedium)
            if (phase is ShazamPhase.Recognizing) CircularProgressIndicator(Modifier.size(12.dp), strokeWidth = 2.dp, color = tint)
        }
    }

    (phase as? ShazamPhase.Matched)?.let { matched ->
        ShazamResultSheet(
            match = matched.match,
            onOpenSong = { recognizer.reset(); onOpenSong(it) },
            onOpenAlbum = { recognizer.reset(); onOpenAlbum(it) },
            onDismiss = { recognizer.reset() },
        )
    }
}

package com.levi.pocketdj.screens.playlists

import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.filled.Cloud
import androidx.compose.material.icons.filled.PhoneAndroid
import androidx.compose.material3.Icon
import androidx.compose.material3.IconButton
import androidx.compose.runtime.Composable
import androidx.compose.runtime.collectAsState
import androidx.compose.runtime.getValue
import androidx.compose.runtime.remember
import androidx.compose.runtime.rememberCoroutineScope
import androidx.compose.ui.platform.LocalContext
import com.levi.pocketdj.di.AppGraph
import com.levi.pocketdj.playback.PlaybackMode
import com.levi.pocketdj.playback.PlaybackPrefKeys
import com.levi.pocketdj.playback.PlaybackSettings
import kotlinx.coroutines.launch

/** Pure flip rule (iOS `PlaybackModeToggle`): device <-> cloud. */
fun PlaybackMode.toggled(): PlaybackMode = if (this == PlaybackMode.DEVICE) PlaybackMode.CLOUD else PlaybackMode.DEVICE

/** Device (phone glyph) / Cloud toggle persisted in the shared playback prefs. */
@Composable
fun PlaybackModeToggle() {
    val graph = AppGraph.get(LocalContext.current)
    val scope = rememberCoroutineScope()
    val settings = remember { PlaybackSettings(graph.settings) }
    val token by remember { graph.settings.flow(PlaybackPrefKeys.PLAYBACK_MODE) }
        .collectAsState(initial = PlaybackMode.CLOUD.token)
    val mode = PlaybackMode.fromToken(token)
    IconButton(onClick = { scope.launch { settings.setMode(mode.toggled()) } }) {
        Icon(
            if (mode == PlaybackMode.DEVICE) Icons.Filled.PhoneAndroid else Icons.Filled.Cloud,
            contentDescription = if (mode == PlaybackMode.DEVICE) "Playing from device" else "Playing from cloud",
        )
    }
}

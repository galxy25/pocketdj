package com.levi.pocketdj.screens.settings.sections

import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.FlowRow
import androidx.compose.foundation.layout.ExperimentalLayoutApi
import androidx.compose.material3.FilterChip
import androidx.compose.material3.Text
import androidx.compose.runtime.getValue
import androidx.compose.runtime.collectAsState
import androidx.compose.runtime.remember
import androidx.compose.ui.platform.testTag
import androidx.compose.ui.unit.dp
import com.levi.pocketdj.playback.PlaybackMode
import com.levi.pocketdj.playback.PlaybackPrefKeys
import com.levi.pocketdj.playback.PlaybackSettings
import com.levi.pocketdj.screens.settings.SettingsCaption
import com.levi.pocketdj.screens.settings.SettingsHeader
import com.levi.pocketdj.shell.SettingsSection
import kotlinx.coroutines.launch

internal const val PLAYBACK_SECTION_ID = "playback"
internal const val PLAYBACK_SECTION_ORDER = 460

/** Pure copy + option table for the Playback mode row (the same pref the per-collection toggle writes). */
object PlaybackSectionModel {
    val options: List<PlaybackMode> = listOf(PlaybackMode.DEVICE, PlaybackMode.CLOUD)

    fun title(mode: PlaybackMode): String = when (mode) {
        PlaybackMode.DEVICE -> "Device"
        PlaybackMode.CLOUD -> "Cloud"
    }

    fun caption(mode: PlaybackMode): String = when (mode) {
        PlaybackMode.DEVICE ->
            "Device: only songs already downloaded to this phone play. Everything else is skipped, so playback never touches the network."
        PlaybackMode.CLOUD ->
            "Cloud: songs play from the device when downloaded and stream from your rip server or Apple Music otherwise."
    }

    /** Persisted token -> mode (unknown/missing => Cloud, the shipped default). */
    fun modeOf(token: String?): PlaybackMode = PlaybackMode.fromToken(token)
}

/** Settings > Playback: Device / Cloud, round-tripping [PlaybackPrefKeys.PLAYBACK_MODE]. */
@OptIn(ExperimentalLayoutApi::class)
internal fun playbackSection() = SettingsSection(PLAYBACK_SECTION_ID, PLAYBACK_SECTION_ORDER) { host ->
    val settings = remember { PlaybackSettings(host.graph.settings) }
    val token by remember { host.graph.settings.flow(PlaybackPrefKeys.PLAYBACK_MODE) }
        .collectAsState(initial = PlaybackMode.CLOUD.token)
    val mode = PlaybackSectionModel.modeOf(token)
    SettingsHeader("Playback")
    FlowRow(horizontalArrangement = Arrangement.spacedBy(8.dp)) {
        PlaybackSectionModel.options.forEach { opt ->
            FilterChip(
                selected = opt == mode,
                onClick = { host.scope.launch { settings.setMode(opt) } },
                label = { Text(PlaybackSectionModel.title(opt)) },
                modifier = androidx.compose.ui.Modifier.testTag("playback-mode-${opt.token}"),
            )
        }
    }
    SettingsCaption(PlaybackSectionModel.caption(mode))
}

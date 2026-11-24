package com.levi.pocketdj.screens.settings.sections

import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.FlowRow
import androidx.compose.foundation.layout.ExperimentalLayoutApi
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.padding
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.Switch
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import com.levi.pocketdj.mix.nowplaying.NpMixCellularPolicy
import com.levi.pocketdj.mix.nowplaying.NpMixSettings
import com.levi.pocketdj.mix.nowplaying.npMixSettingsFlow
import com.levi.pocketdj.mix.nowplaying.setNpMixBufferAhead
import com.levi.pocketdj.mix.nowplaying.setNpMixCellular
import com.levi.pocketdj.mix.nowplaying.setNpMixModeDefaultOn
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

    // ---- Mix Mode buffering rows (iOS Settings ▸ Storage ▸ Mix Mode copy, verbatim) ----
    const val MIX_DEFAULT_TITLE = "Start new sessions in Mix Mode"
    const val MIX_AHEAD_TITLE = "Mix Mode buffers ahead"
    const val MIX_CELLULAR_TITLE = "Mix Mode on cellular"
    val mixAheadOptions: List<Int> = NpMixSettings.AHEAD_OPTIONS
    val mixCellularOptions: List<NpMixCellularPolicy> = NpMixCellularPolicy.entries.toList()

    fun mixAheadLabel(n: Int): String = "$n song${if (n == 1) "" else "s"}"

    fun mixCellularLabel(p: NpMixCellularPolicy): String = when (p) {
        NpMixCellularPolicy.OFF -> "Off"
        NpMixCellularPolicy.NEXT_SONG -> "Next song only"
        NpMixCellularPolicy.FULL -> "Same as Wi-Fi"
    }

    fun mixCellularCaption(p: NpMixCellularPolicy): String = when (p) {
        NpMixCellularPolicy.OFF -> "Off: on mobile data Mix Mode buffers nothing beyond what Stem Lock already fetches."
        NpMixCellularPolicy.NEXT_SONG -> "Next song only: on mobile data Mix Mode buffers the current row and the next song."
        NpMixCellularPolicy.FULL -> "Same as Wi-Fi: on mobile data Mix Mode buffers the whole window, stems included."
    }

    const val MIX_CAPTION =
        "Mix Mode buffers the playing song and the ones after it on this phone so the Mix controls work on any track. " +
            "Buffered files are temporary; Settings ▸ Storage controls how long they are kept."

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
                modifier = Modifier.testTag("playback-mode-${opt.token}"),
            )
        }
    }
    SettingsCaption(PlaybackSectionModel.caption(mode))

    // ---- Mix Mode buffering (the three iOS rows) ----
    val mix by remember { host.graph.settings.npMixSettingsFlow() }.collectAsState(initial = NpMixSettings())
    Spacer(Modifier.height(12.dp))
    SettingsHeader("Mix Mode")
    Row(Modifier.fillMaxWidth(), verticalAlignment = Alignment.CenterVertically) {
        Text(PlaybackSectionModel.MIX_DEFAULT_TITLE, Modifier.weight(1f))
        Switch(
            checked = mix.modeDefaultOn,
            onCheckedChange = { on -> host.scope.launch { host.graph.settings.setNpMixModeDefaultOn(on) } },
            modifier = Modifier.testTag("playback-mixmode-default"),
        )
    }
    Text(PlaybackSectionModel.MIX_AHEAD_TITLE, style = MaterialTheme.typography.bodyMedium)
    FlowRow(horizontalArrangement = Arrangement.spacedBy(8.dp)) {
        PlaybackSectionModel.mixAheadOptions.forEach { n ->
            FilterChip(
                selected = n == mix.bufferAhead,
                onClick = { host.scope.launch { host.graph.settings.setNpMixBufferAhead(n) } },
                label = { Text(PlaybackSectionModel.mixAheadLabel(n)) },
                modifier = Modifier.testTag("playback-mixmode-ahead-$n"),
            )
        }
    }
    Text(PlaybackSectionModel.MIX_CELLULAR_TITLE, style = MaterialTheme.typography.bodyMedium, modifier = Modifier.padding(top = 8.dp))
    FlowRow(horizontalArrangement = Arrangement.spacedBy(8.dp)) {
        PlaybackSectionModel.mixCellularOptions.forEach { p ->
            FilterChip(
                selected = p == mix.cellular,
                onClick = { host.scope.launch { host.graph.settings.setNpMixCellular(p) } },
                label = { Text(PlaybackSectionModel.mixCellularLabel(p)) },
                modifier = Modifier.testTag("playback-mixmode-cellular-${p.raw}"),
            )
        }
    }
    SettingsCaption(PlaybackSectionModel.mixCellularCaption(mix.cellular))
    SettingsCaption(PlaybackSectionModel.MIX_CAPTION)
}

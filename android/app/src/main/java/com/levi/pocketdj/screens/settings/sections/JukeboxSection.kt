package com.levi.pocketdj.screens.settings.sections

import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.material3.Switch
import androidx.compose.material3.Text
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import com.levi.pocketdj.data.jukebox.JukeboxSettings
import com.levi.pocketdj.screens.settings.SettingsCaption
import com.levi.pocketdj.screens.settings.SettingsHeader
import com.levi.pocketdj.shell.SettingsSection
import kotlinx.coroutines.launch

internal const val JUKEBOX_SECTION_ID = "jukebox"

/**
 * Settings ▸ Jukebox: the "Require access tokens by default" seed (default ON) the
 * create view reads on every appearance. Intent only — copy never claims gating (§9).
 * Sits right after the broker block (order 500).
 */
internal fun jukeboxSection() = SettingsSection(JUKEBOX_SECTION_ID, 510) { host ->
    val required = host.settings?.jukeboxTokensRequiredByDefault ?: true
    SettingsHeader("Jukebox")
    Row(
        modifier = Modifier.fillMaxWidth(),
        horizontalArrangement = Arrangement.SpaceBetween,
        verticalAlignment = Alignment.CenterVertically,
    ) {
        Text(JukeboxSettings.REQUIRE_TOKEN_TITLE, modifier = Modifier.weight(1f))
        Switch(
            checked = required,
            enabled = host.settings != null,
            onCheckedChange = { value ->
                host.scope.launch { host.graph.settings.setJukeboxTokensRequiredByDefault(value) }
            },
        )
    }
    SettingsCaption(JukeboxSettings.REQUIRE_TOKEN_CAPTION)
}

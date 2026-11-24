package com.levi.pocketdj.screens.settings.sections

import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.material3.OutlinedButton
import androidx.compose.material3.Text
import androidx.compose.ui.Modifier
import androidx.compose.ui.platform.testTag
import com.levi.pocketdj.screens.settings.SettingsCaption
import com.levi.pocketdj.screens.settings.SettingsHeader
import com.levi.pocketdj.shell.SettingsSection

internal const val MIX_SECTION_ID = "mix"

/**
 * Settings ▸ Mixing entry: one row that opens [com.levi.pocketdj.screens.settings.MixingSettingsScreen]
 * (crossfades, Now Playing DJ Mode toggles, Mix tab options). The controls moved there.
 */
internal fun mixSection() = SettingsSection(MIX_SECTION_ID, 520) { host ->
    SettingsHeader("Mixing")
    OutlinedButton(
        onClick = { host.openMixing() },
        modifier = Modifier.fillMaxWidth().testTag("settings-mixing-row"),
    ) { Text("Mixing") }
    SettingsCaption("Crossfade lengths, Now Playing DJ Mode, and the Mix tab's deck options.")
}

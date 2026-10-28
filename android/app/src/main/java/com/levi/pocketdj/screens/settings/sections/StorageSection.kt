package com.levi.pocketdj.screens.settings.sections

import androidx.compose.material3.OutlinedButton
import androidx.compose.material3.Text
import com.levi.pocketdj.screens.settings.SectionHeader
import com.levi.pocketdj.screens.settings.SettingsCaption
import com.levi.pocketdj.screens.settings.SettingsSections
import com.levi.pocketdj.shell.SettingsSection

internal fun storageSection() = SettingsSection(SettingsSections.STORAGE, 700) { host ->
    SectionHeader("Storage")
    OutlinedButton(onClick = { host.openStorage() }) {
        Text("Manage storage")
    }
    SettingsCaption(
        "See what PocketDJ keeps on this device per category, with sizes, and " +
            "clear the re-derivable caches and logs.",
    )
}

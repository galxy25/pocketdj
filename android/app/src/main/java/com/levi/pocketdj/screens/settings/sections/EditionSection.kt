package com.levi.pocketdj.screens.settings.sections

import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.material3.Switch
import androidx.compose.material3.Text
import androidx.compose.runtime.collectAsState
import androidx.compose.runtime.getValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import com.levi.pocketdj.data.edition.EditionSettings
import com.levi.pocketdj.screens.settings.SettingsCaption
import com.levi.pocketdj.screens.settings.SettingsHeader
import com.levi.pocketdj.shell.SettingsSection
import kotlinx.coroutines.launch

internal const val EDITION_SECTION_ID = "edition"

internal fun editionCaption(raw: Boolean?): String = when (raw) {
    null -> "Never chosen: every song plays its own cut. Flip the switch to start preferring a version."
    true -> "Explicit editions are preferred when a song has one."
    false -> "Clean editions are preferred when a song has one."
}

internal fun editionSection() = SettingsSection(EDITION_SECTION_ID, 450) { host ->
    val store = host.graph.settings
    val raw by EditionSettings.flow(store).collectAsState(initial = null)
    SettingsHeader("Explicit versions")
    Row(
        modifier = Modifier.fillMaxWidth(),
        horizontalArrangement = Arrangement.SpaceBetween,
        verticalAlignment = Alignment.CenterVertically,
    ) {
        Text("Prefer explicit versions")
        Switch(
            checked = raw ?: false,
            onCheckedChange = { v -> host.scope.launch { EditionSettings.set(store, v) } },
        )
    }
    SettingsCaption(editionCaption(raw))
}

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
import com.levi.pocketdj.data.settings.ShellSettings
import com.levi.pocketdj.data.settings.setRipFromCloud
import com.levi.pocketdj.shell.SettingsSection
import kotlinx.coroutines.launch

internal const val RIP_FROM_CLOUD_SECTION_ID = "importServerRipFromCloud"

/**
 * Import-server add-on row: "Rip from cloud source" → `ripFromCloud` in the POST /rip body.
 * Sits right after the Import server block (300). As on iOS (#TOUPDATE) the flag does not gate
 * server-side capture; it is forwarded for parity and stored settings.
 */
internal fun ripFromCloudSection() = SettingsSection(RIP_FROM_CLOUD_SECTION_ID, 305) { host ->
    val graph = host.graph
    val on by graph.settings.flow(ShellSettings.RIP_FROM_CLOUD).collectAsState(initial = false)
    Row(
        modifier = Modifier.fillMaxWidth(),
        horizontalArrangement = Arrangement.SpaceBetween,
        verticalAlignment = Alignment.CenterVertically,
    ) {
        Text("Rip from cloud source", modifier = Modifier.weight(1f))
        Switch(checked = on, onCheckedChange = { v -> host.scope.launch { graph.settings.setRipFromCloud(v) } })
    }
}

package com.levi.pocketdj.screens.settings.sections

import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.text.KeyboardOptions
import androidx.compose.material3.OutlinedTextField
import androidx.compose.material3.Text
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
import androidx.compose.ui.Modifier
import androidx.compose.ui.text.input.KeyboardType
import com.levi.pocketdj.data.settings.ShellSettings
import com.levi.pocketdj.data.settings.defaultRecentlyAddedCount
import com.levi.pocketdj.data.settings.setDefaultRecentlyAddedCount
import com.levi.pocketdj.screens.settings.SettingsCaption
import com.levi.pocketdj.screens.settings.SettingsHeader
import com.levi.pocketdj.shell.SettingsSection
import kotlinx.coroutines.launch

internal const val COLLECTIONS_SECTION_ID = "collections"

/** Settings ▸ Collections: "Default recently added" count (iOS clamp 1…100000, default 3650). */
internal fun collectionsSection() = SettingsSection(COLLECTIONS_SECTION_ID, 250) { host ->
    val graph = host.graph
    var text by remember { mutableStateOf("") }
    LaunchedEffect(Unit) { text = graph.settings.defaultRecentlyAddedCount().toString() }

    SettingsHeader("Collections")
    OutlinedTextField(
        value = text,
        onValueChange = { raw ->
            text = raw.filter { it.isDigit() }
            ShellSettings.parseRecentlyAdded(text)?.let { n ->
                host.scope.launch { graph.settings.setDefaultRecentlyAddedCount(n) }
            }
        },
        label = { Text("Default recently added") },
        singleLine = true,
        keyboardOptions = KeyboardOptions(keyboardType = KeyboardType.Number),
        modifier = Modifier.fillMaxWidth(),
    )
    SettingsCaption(
        "How many items the “Recently added” playlist shows — the last N songs you added to " +
            "your library (Apple Music adds, ＋Add, imports, and custom audio).",
    )
}

package com.levi.pocketdj.screens.settings.sections

import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.material3.OutlinedTextField
import androidx.compose.material3.Text
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
import androidx.compose.ui.Modifier
import com.levi.pocketdj.data.settings.ShellSettings
import com.levi.pocketdj.onboarding.OnboardingPrefs
import com.levi.pocketdj.screens.settings.SettingsCaption
import com.levi.pocketdj.screens.settings.SettingsHeader
import com.levi.pocketdj.shell.SettingsSection
import kotlinx.coroutines.launch

internal const val PROFILE_SECTION_ID = "profile"

/** Settings ▸ Profile: "Your PocketDJ name" (same pref the onboarding stage 1 writes). Order 50: first. */
internal fun profileSection() = SettingsSection(PROFILE_SECTION_ID, 50) { host ->
    val graph = host.graph
    var name by remember { mutableStateOf("") }
    LaunchedEffect(Unit) { name = graph.settings.get(OnboardingPrefs.PROFILE_NAME) }

    SettingsHeader("Profile")
    OutlinedTextField(
        value = name,
        onValueChange = {
            name = it
            host.scope.launch {
                graph.settings.set(OnboardingPrefs.PROFILE_NAME, ShellSettings.normalizeProfileName(it))
            }
        },
        label = { Text("Your PocketDJ name") },
        singleLine = true,
        modifier = Modifier.fillMaxWidth(),
    )
    SettingsCaption(
        "Your PocketDJ name shows as the artist on your samples, loops, sequences, and " +
            "instrumentals (leave blank for “Studio”).",
    )
}

package com.levi.pocketdj.screens.settings.sections

import com.levi.pocketdj.screens.settings.DebugPanel
import com.levi.pocketdj.screens.settings.SettingsSections
import com.levi.pocketdj.shell.SettingsSection

/** Settings ▸ Debug registry row (order 900, after About). Registered only on diag-channel builds. */
fun debugSection() = SettingsSection(SettingsSections.DEBUG, 900) { host -> DebugPanel(host) }

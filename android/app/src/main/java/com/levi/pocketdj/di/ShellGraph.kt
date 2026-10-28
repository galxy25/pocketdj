package com.levi.pocketdj.di

import com.levi.pocketdj.screens.settings.SettingsSections
import com.levi.pocketdj.shell.FeatureModule
import com.levi.pocketdj.shell.SettingsSection

/**
 * Sidecar graph for the shell area (decision D3). Empty today: packages in this area
 * override the FeatureModule members they contribute (nav entries, settings sections,
 * deep-link handlers, flushables, reset hooks, sync entries, row resolvers, play-outcome
 * listeners, periodic work) and add their own lazies here — never in AppGraph.
 */
class ShellGraph(@Suppress("unused") private val app: AppGraph) : FeatureModule {
    override val area: String = "shell"

    /** The pre-existing Settings blocks (Data sources … About), in shipped order. */
    override val periodicWork = com.levi.pocketdj.work.ShellWork.specs

    override val settingsSections: List<SettingsSection> = SettingsSections.builtin()
}

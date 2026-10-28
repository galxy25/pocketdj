package com.levi.pocketdj.di

import com.levi.pocketdj.diag.DiagServices
import com.levi.pocketdj.screens.settings.sections.debugSection
import com.levi.pocketdj.shell.DeepLinkHandler
import com.levi.pocketdj.shell.FeatureModule
import com.levi.pocketdj.shell.Flushable
import com.levi.pocketdj.shell.SettingsSection
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.launch

/**
 * Sidecar graph for the services area (decision D3). Packages in this area override the
 * FeatureModule members they contribute and add their own lazies here — never in AppGraph.
 */
class ServicesGraph(private val app: AppGraph) : FeatureModule {
    override val area: String = "services"

    /** SVC-5 diagnostics stack. Touching [FeatureModule] lists below materializes the log. */
    val diag: DiagServices by lazy { DiagServices.get(app) }

    override val settingsSections: List<SettingsSection> by lazy {
        if (diag.channel) listOf(debugSection()) else emptyList()
    }

    override val deepLinkHandlers: List<DeepLinkHandler> by lazy {
        // Keystore/prefs work must not run on the registry (main) path: start on IO.
        if (diag.channel) app.appScope.launch(Dispatchers.IO) { diag.start() }
        listOf(diag.deepLink)
    }

    override val flushables: List<Flushable> by lazy { listOf(diag.flushable) }
}

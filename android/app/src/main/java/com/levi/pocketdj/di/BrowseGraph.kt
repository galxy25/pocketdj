package com.levi.pocketdj.di

import com.levi.pocketdj.data.search.SearchConfig
import com.levi.pocketdj.data.search.SearchService
import com.levi.pocketdj.data.search.SearchSettings
import com.levi.pocketdj.screens.browse.BrowseSessionFlushable
import com.levi.pocketdj.screens.settings.sections.editionSection
import com.levi.pocketdj.screens.settings.sections.onlineSearchSection
import com.levi.pocketdj.shell.FeatureModule
import com.levi.pocketdj.shell.Flushable
import com.levi.pocketdj.shell.SettingsSection
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.launch

/**
 * Sidecar graph for the browse area (decision D3). Packages in this area override the
 * FeatureModule members they contribute and add their own lazies here, never in AppGraph.
 */
class BrowseGraph(private val app: AppGraph) : FeatureModule {
    override val area: String = "browse"

    override val flushables: List<Flushable> =
        listOf(BrowseSessionFlushable { app.settings.setBrowseSnapshot(it) })

    /** Online-search host resolution (user override -> search-config.json -> baked default). */
    val searchConfig: SearchConfig by lazy {
        SearchConfig(SearchConfig.httpFetcher(app.httpClient)).also { cfg ->
            // Seed the per-user host override from the persisted pref (off-main).
            app.appScope.launch(Dispatchers.IO) {
                runCatching { cfg.setUserHost(SearchSettings.endpoint(app.settings)) }
            }
        }
    }

    val searchService: SearchService by lazy { SearchService(app.httpClient, searchConfig) }

    override val settingsSections: List<SettingsSection> by lazy {
        listOf(editionSection(), onlineSearchSection())
    }
}

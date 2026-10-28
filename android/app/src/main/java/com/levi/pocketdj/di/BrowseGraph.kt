package com.levi.pocketdj.di

import com.levi.pocketdj.screens.browse.BrowseSessionFlushable
import com.levi.pocketdj.shell.FeatureModule
import com.levi.pocketdj.shell.Flushable

/**
 * Sidecar graph for the browse area (decision D3). Packages in this area override the
 * FeatureModule members they contribute and add their own lazies here, never in AppGraph.
 */
class BrowseGraph(private val app: AppGraph) : FeatureModule {
    override val area: String = "browse"

    override val flushables: List<Flushable> =
        listOf(BrowseSessionFlushable { app.settings.setBrowseSnapshot(it) })
}

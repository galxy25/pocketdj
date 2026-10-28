package com.levi.pocketdj.di

import com.levi.pocketdj.shell.FeatureModule

/**
 * Sidecar graph for the mix area (decision D3). Empty today: packages in this area
 * override the FeatureModule members they contribute (nav entries, settings sections,
 * deep-link handlers, flushables, reset hooks, sync entries, row resolvers, play-outcome
 * listeners, periodic work) and add their own lazies here — never in AppGraph.
 */
class MixGraph(@Suppress("unused") private val app: AppGraph) : FeatureModule {
    override val area: String = "mix"
}

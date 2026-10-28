package com.levi.pocketdj.di

import com.levi.pocketdj.onboarding.DataStoreOnboardingMarkerStorage
import com.levi.pocketdj.onboarding.LinkDeviceProbe
import com.levi.pocketdj.onboarding.OnboardingStore
import com.levi.pocketdj.onboarding.StubLinkDeviceProbe
import com.levi.pocketdj.screens.settings.SettingsSections
import com.levi.pocketdj.shell.DeepLinkDispatcher
import com.levi.pocketdj.shell.DeepLinkHandler
import com.levi.pocketdj.shell.DeepLinkSeams
import com.levi.pocketdj.shell.FeatureModule
import com.levi.pocketdj.shell.OnboardingGate
import com.levi.pocketdj.shell.SettingsSection

/**
 * Sidecar graph for the shell area (decision D3). Empty today: packages in this area
 * override the FeatureModule members they contribute (nav entries, settings sections,
 * deep-link handlers, flushables, reset hooks, sync entries, row resolvers, play-outcome
 * listeners, periodic work) and add their own lazies here — never in AppGraph.
 */
class ShellGraph(private val app: AppGraph) : FeatureModule {
    override val area: String = "shell"

    /** The pre-existing Settings blocks (Data sources … About), in shipped order. */
    override val periodicWork = com.levi.pocketdj.work.ShellWork.specs

    override val settingsSections: List<SettingsSection> = SettingsSections.builtin()

    /** Stage-1 "Link a device" probe; SVC-9 swaps in the S3 cloud-doc implementation. */
    @Volatile var linkDeviceProbe: LinkDeviceProbe = StubLinkDeviceProbe

    /**
     * The zero-to-hero first-run state machine. The launch pipeline awaits
     * `onboarding.waitUntilComplete()`; mutating ShellActions calls run `vetoIfIncomplete()`.
     */
    val onboarding: OnboardingStore by lazy {
        OnboardingStore(
            storage = DataStoreOnboardingMarkerStorage(app.settings),
            hadPersistedSettings = app.hadPersistedSettingsAtLaunch,
            scope = app.appScope,
        ).also { store ->
            // Completing triggers the catalog load with the chosen sources.
            store.onComplete = {
                val repo = app.catalogRepository
                if (repo.state.value.catalog == null) repo.loadIfNeeded() else repo.refresh()
            }
        }
    }

    /** Later packages (SURF-5 ShellActions, JBX-2, SET-2, Games) assign these seams. */
    val deepLinkSeams = DeepLinkSeams()

    /** SURF-4: pocketdj:// links, jukebox/MwF App Links and collection file opens. */
    val deepLinks: DeepLinkDispatcher by lazy {
        DeepLinkDispatcher(
            scope = app.appScope,
            gate = object : OnboardingGate {
                override val isComplete: Boolean get() = onboarding.isComplete
                override suspend fun waitUntilComplete() = onboarding.waitUntilComplete()
            },
            seams = deepLinkSeams,
            displayName = DeepLinkDispatcher.contentDisplayName(app.appContext.contentResolver),
        )
    }

    override val deepLinkHandlers: List<DeepLinkHandler> by lazy { listOf(deepLinks.intentHandler) }
}

package com.levi.pocketdj.data.reset

import kotlinx.coroutines.CancellationException

/** One executed reset step: [error] is null when it succeeded. */
data class StepResult(val name: String, val error: Throwable? = null) {
    val ok: Boolean get() = error == null
}

/** What a reset / account deletion did, in execution order. A failed step never stops the rest. */
data class ResetReport(val steps: List<StepResult>) {
    val failures: List<StepResult> get() = steps.filterNot { it.ok }
    val ok: Boolean get() = failures.isEmpty()
    val names: List<String> get() = steps.map { it.name }
}

/**
 * Best-effort step runner shared by [AppResetService] and [AccountDeletionService]: a throwing
 * step is logged and recorded, the remaining steps still run (iOS: "a failure in any single step
 * is logged and the remaining steps still run"). Cancellation is the one thing that propagates.
 */
internal class StepRunner(private val log: (String) -> Unit) {
    private val results = mutableListOf<StepResult>()

    suspend fun run(name: String, block: suspend () -> Unit) {
        try {
            block()
            results += StepResult(name)
        } catch (e: CancellationException) {
            throw e
        } catch (t: Throwable) {
            log("reset step '$name' failed (continuing): ${t.javaClass.simpleName}: ${t.message}")
            results += StepResult(name, t)
        }
    }

    fun report() = ResetReport(results.toList())
}

/**
 * Settings > "Reset all app state" (iOS `SettingsStore.resetEverything` + collections clear):
 * a DEVICE-local reset. Cloud documents, the profile identity, secrets of the sync profile and the
 * per-install id are NOT touched (that is [AccountDeletionService]).
 *
 * Order (load-bearing):
 *  1. hold cloud pushes, so the clears below can never upload empty documents;
 *  2. collections cleared;
 *  3. catalog disk cache, synced-credentials mirror file, artwork caches;
 *  4. connection secrets (rip/jukebox/Music-User/search keys);
 *  5. DataStore settings reset to defaults, the install id preserved;
 *  6. onboarding marker `pending` AFTER step 5 (clearing the DataStore would otherwise erase it —
 *     iOS writes an explicit `pending` marker for the same reason);
 *  7. cloud-sync state + `.pre-cloud` backups.
 * The caller relaunches the process afterwards so the app comes back into onboarding.
 */
class AppResetService(
    private val holdPushes: () -> Unit,
    private val clearCollections: suspend () -> Unit,
    private val deleteCatalogCache: suspend () -> Unit,
    private val deleteCredentialsMirror: suspend () -> Unit,
    private val clearArtwork: suspend () -> Unit,
    private val clearSecrets: suspend () -> Unit,
    /** Reset the preference store to defaults, KEEPING the per-install id. */
    private val resetSettings: suspend () -> Unit,
    private val markOnboardingPending: suspend () -> Unit,
    private val clearSyncState: suspend () -> Unit,
    private val log: (String) -> Unit = {},
) {
    /** Full device reset (Settings > Reset all app state). */
    suspend fun resetEverything(): ResetReport {
        val r = StepRunner(log)
        r.run(STEP_HOLD_PUSHES) { holdPushes() }
        r.run(STEP_COLLECTIONS) { clearCollections() }
        resetSettingsState(r)
        r.run(STEP_SYNC_STATE) { clearSyncState() }
        return r.report()
    }

    /**
     * Steps 3-6 only: used by [AccountDeletionService] AFTER its media deletes (settings reset must
     * follow them) — it runs the sync-state clear and identity reset itself, in its own order.
     */
    suspend fun resetSettingsOnly(): ResetReport {
        val r = StepRunner(log)
        resetSettingsState(r)
        return r.report()
    }

    internal suspend fun resetSettingsState(r: StepRunner) {
        r.run(STEP_CATALOG_CACHE) { deleteCatalogCache() }
        r.run(STEP_CREDENTIALS_MIRROR) { deleteCredentialsMirror() }
        r.run(STEP_ARTWORK) { clearArtwork() }
        r.run(STEP_SECRETS) { clearSecrets() }
        r.run(STEP_SETTINGS) { resetSettings() }
        r.run(STEP_ONBOARDING_PENDING) { markOnboardingPending() }
    }

    companion object {
        const val STEP_HOLD_PUSHES = "hold-pushes"
        const val STEP_COLLECTIONS = "collections"
        const val STEP_CATALOG_CACHE = "catalog-cache"
        const val STEP_CREDENTIALS_MIRROR = "credentials-mirror"
        const val STEP_ARTWORK = "artwork"
        const val STEP_SECRETS = "secrets"
        const val STEP_SETTINGS = "settings"
        const val STEP_ONBOARDING_PENDING = "onboarding-pending"
        const val STEP_SYNC_STATE = "sync-state"
    }
}

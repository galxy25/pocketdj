package com.levi.pocketdj.data.reset

import kotlinx.coroutines.withTimeoutOrNull

/**
 * Settings > Delete account (iOS `AccountDeletionService`, App Store 5.1.1(v)). Removes the cloud
 * copies, then every local store, then media, settings and finally the identity — BEST-EFFORT: a
 * failing step (cloud unreachable, a store throwing) is logged and the rest still run, so the
 * device always ends genuinely clean.
 *
 * Order invariants:
 *  - cloud delete BEFORE the local wipe (and before the profile secret goes — it authorizes it);
 *  - settings reset AFTER the media deletes (media stores read user-picked roots from settings);
 *  - identity (profile id, profile secret, install id) LAST and exactly once.
 */
class AccountDeletionService(
    private val holdPushes: () -> Unit,
    /** Stop playback / eject Mix / end Jukebox / cancel transfers, each its own best-effort step. */
    private val stopLiveActivity: List<Pair<String, suspend () -> Unit>>,
    /** Whether the cloud delete may run at all (false: no backend configured, fixture/test runs). */
    private val cloudDeleteEnabled: () -> Boolean,
    private val deleteCloudDocs: suspend (List<String>) -> Unit,
    /** `DELETE /profile` — wipes the server-side prefix; a no-op port when there is no enrolled profile. */
    private val deleteCloudProfile: suspend () -> Unit,
    /** Every local store + each area's FeatureModule reset hook, named for the log. */
    private val localStores: List<Pair<String, suspend () -> Unit>>,
    /** Burned/stem/lyrics media deletes (run before settings reset). */
    private val mediaDeletes: List<Pair<String, suspend () -> Unit>>,
    private val appReset: AppResetService,
    private val clearSyncState: suspend () -> Unit,
    private val resetProfile: suspend () -> Unit,
    private val clearProfileSecret: suspend () -> Unit,
    private val resetInstallId: suspend () -> Unit,
    private val cloudKeys: List<String> = cloudDocKeys,
    private val cloudTimeoutMs: Long = CLOUD_TIMEOUT_MS,
    private val log: (String) -> Unit = {},
) {
    suspend fun deleteAccountAndAllData(): ResetReport {
        log("account deletion started")
        val r = StepRunner(log)

        // 0) pushes off: nothing cleared below may upload as an "empty" document.
        r.run(STEP_HOLD_PUSHES) { holdPushes() }
        // 1) live activity
        for ((name, block) in stopLiveActivity) r.run("stop:$name") { block() }
        // 2) cloud copies (before the local wipe). Never gates the local wipe.
        if (cloudDeleteEnabled()) {
            r.run(STEP_CLOUD_DOCS) { boundedCloud(STEP_CLOUD_DOCS) { deleteCloudDocs(cloudKeys) } }
            r.run(STEP_CLOUD_PROFILE) { boundedCloud(STEP_CLOUD_PROFILE) { deleteCloudProfile() } }
        } else {
            log("cloud deletion skipped (disabled / not configured)")
        }
        // 3) local stores
        for ((name, block) in localStores) r.run("clear:$name") { block() }
        // 4) media, then 5) settings (strictly after media)
        for ((name, block) in mediaDeletes) r.run("media:$name") { block() }
        appReset.resetSettingsState(r)
        // 6) sync state + .pre-cloud backups
        r.run(STEP_SYNC_STATE) { clearSyncState() }
        // 7) identity, LAST and once
        r.run(STEP_IDENTITY_PROFILE) { resetProfile() }
        r.run(STEP_IDENTITY_SECRET) { clearProfileSecret() }
        r.run(STEP_IDENTITY_INSTALL_ID) { resetInstallId() }
        log("account deletion complete")
        return r.report()
    }

    /** An unreachable cloud must cost a bounded wait, not hang the wipe; timeout counts as a failed step. */
    private suspend fun boundedCloud(what: String, block: suspend () -> Unit) {
        val done = withTimeoutOrNull(cloudTimeoutMs) { block(); true }
        if (done != true) throw java.io.IOException("$what timed out after ${cloudTimeoutMs}ms")
    }

    companion object {
        const val STEP_HOLD_PUSHES = "hold-pushes"
        const val STEP_CLOUD_DOCS = "cloud-docs"
        const val STEP_CLOUD_PROFILE = "cloud-profile"
        const val STEP_SYNC_STATE = "sync-state"
        const val STEP_IDENTITY_PROFILE = "identity:profile"
        const val STEP_IDENTITY_SECRET = "identity:secret"
        const val STEP_IDENTITY_INSTALL_ID = "identity:install-id"

        const val CLOUD_TIMEOUT_MS = 20_000L

        /**
         * The cloud document keys removed on account deletion: EXACTLY the Android registry (every
         * `SyncEntry` contributed by the area graphs). Lockstep is enforced by AccountDeletionTest;
         * a newly synced document must be added here or its cloud copy would survive deletion.
         */
        val cloudDocKeys: List<String> = listOf(
            "profile", "collections", "play-history", "collection-activity", "play-stats",
            "timeline-cues", "settings-credentials", "diag-key",
            "rec-feedback", "foryou-feed", "studio-cues", "game-scores", "puzzle-decisions",
        )
    }
}

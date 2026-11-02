package com.levi.pocketdj.data.sync

import java.util.UUID

/**
 * Q120: what is wrong with this device's sync identity, as Settings shows it. Sync itself already stops on
 * either problem ([S3CloudDocDatabase.accountAvailable] is false while unauthorized) - this only names it.
 */
enum class ProfileSyncProblem {
    /**
     * The server answered 401 for the CURRENT identity: the other device ran Delete account (`DELETE /profile`
     * wipes the profile and its secret hash), so these credentials can never work again.
     */
    DELETED,

    /** Enroll answered 409: the profile exists but holds a different secret (lost / foreign). Relink only. */
    LOCKED,
    ;

    companion object {
        /** null = nothing wrong (or sync isn't configured on this build, where no request is ever made). */
        fun of(configured: Boolean, unauthorized: Boolean, relinkRequired: Boolean): ProfileSyncProblem? = when {
            !configured || !unauthorized -> null
            relinkRequired -> LOCKED
            else -> DELETED
        }
    }
}

/**
 * Q120 recovery from [ProfileSyncProblem.DELETED]. Relink is the existing link-code flow
 * ([com.levi.pocketdj.onboarding.CodeLinkProbe.link], which adopts the other device's identity and clears the
 * flag). "Start fresh" is here: a BRAND-NEW profile identity on this device - fresh id, no secret (a new one is
 * minted at the next enroll) - keeping every local collection and the PocketDJ name. It never turns sync on and
 * makes no request: with sync off nothing is sent; with it on, the next pass enrolls the new id.
 */
class ProfileRecovery(
    private val secrets: ProfileSecretStore,
    /** ProfileStore.adoptIdentity. */
    private val adoptProfileId: (String) -> Unit,
    /** S3CloudDocDatabase.clearUnauthorized (in-memory flag + persisted marker). */
    private val clearUnauthorized: () -> Unit,
    /**
     * Forget the dead identity's push watermarks so this device's local docs upload in full to the new profile
     * (CloudSyncService.holdPushesForIdentityChange then releasePushHold - the new profile holds nothing a push
     * could overwrite, so no pull-first hold is needed).
     */
    private val forgetWatermarks: () -> Unit,
    private val newId: () -> String = { UUID.randomUUID().toString().uppercase() },
) {
    /** Returns the new profile id. */
    @Synchronized fun startFresh(): String {
        val id = newId()
        secrets.clear()
        adoptProfileId(id)
        clearUnauthorized()
        forgetWatermarks()
        return id
    }
}

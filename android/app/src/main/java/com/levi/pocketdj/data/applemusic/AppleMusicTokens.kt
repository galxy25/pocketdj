package com.levi.pocketdj.data.applemusic

import com.levi.pocketdj.data.settings.AppSettingsStore

/**
 * The two credentials the Apple Music Web API needs (decision D12):
 *  - the **developer token** (ES256 JWT minted by the rip server, via
 *    [MusicKitDeveloperTokenClient]) -> `Authorization: Bearer`;
 *  - the **Music-User-Token** (from [MusicKitAuth] sign-in) -> `Music-User-Token`.
 * The user token is OPTIONAL: catalog calls work without it; library/favorites
 * calls report NeedsUserToken when it is absent.
 */
interface AppleMusicTokens {
    /** A valid developer token; throws when none can be minted (no server configured, offline). */
    suspend fun developerToken(): String

    /** The signed-in Music-User-Token, or null when not signed in. */
    suspend fun musicUserToken(): String?

    /** Drop a developer token the API rejected so the next call re-mints. Default no-op. */
    suspend fun invalidateDeveloperToken() {}
}

/** Production wiring over the existing token client + Settings-persisted MUT. */
class DefaultAppleMusicTokens(
    private val devTokenClient: MusicKitDeveloperTokenClient,
    private val settings: AppSettingsStore,
) : AppleMusicTokens {
    override suspend fun developerToken(): String = devTokenClient.developerToken()
    override suspend fun musicUserToken(): String? =
        settings.current().musicUserToken.trim().takeIf { it.isNotEmpty() }
    override suspend fun invalidateDeveloperToken() = devTokenClient.invalidate()
}

/** Fixed tokens, for tests and tooling. */
class StaticAppleMusicTokens(
    private val dev: String,
    private val user: String? = null,
) : AppleMusicTokens {
    override suspend fun developerToken(): String = dev
    override suspend fun musicUserToken(): String? = user?.trim()?.takeIf { it.isNotEmpty() }
}

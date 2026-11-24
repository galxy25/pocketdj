package com.levi.pocketdj.data.applemusic

import com.levi.pocketdj.data.settings.AppSettingsStore
import com.levi.pocketdj.data.settings.PrefKey
import kotlinx.coroutines.flow.Flow
import kotlinx.coroutines.flow.combine
import kotlinx.coroutines.flow.map
import kotlinx.coroutines.sync.Mutex
import kotlinx.coroutines.sync.withLock

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

    /**
     * A sync job failed with `AM <METHOD> <path> -> 401|403`: Apple rejected [usedToken]. Implementations may
     * clear it (once) and ask the user to reconnect. Returns true when the stored token was cleared. Default no-op.
     */
    suspend fun onAppleAuthRejected(usedToken: String?): Boolean = false
}

/**
 * Rejected Music-User-Token handling (iOS commit 67c26bd2, Android equivalent). iOS re-mints a rejected MUT
 * silently with `.ignoreCache`; the Android MusicKit auth activity cannot, so a rejected token is cleared ONCE and
 * Settings > Apple Music shows "Reconnect Apple Music" instead of failing every day on a dead token.
 */
object RejectedMut {
    /** The sync Lambda surfaces Apple's errors verbatim as `AM <METHOD> <path> -> <status>`. */
    private val PATTERN = Regex("""AM [A-Z]+ \S+ -> 40[13]\b""")

    /** Persisted: a rejection cleared the token and the user has not reconnected yet. */
    val NEEDS_RECONNECT = PrefKey.boolean("amMutNeedsReconnect", false)

    /** Persisted fingerprint of the last token we cleared (belt and braces for the once-per-token rule). */
    val LAST_CLEARED_FP = PrefKey.string("amMutLastClearedFp", "")

    const val RECONNECT_TITLE = "Reconnect Apple Music"
    const val RECONNECT_CAPTION = "Apple Music rejected your saved sign-in, so playlist syncing is paused. Reconnect to resume."

    /** Pure: does [message] report Apple (not our own gateway) rejecting the token? */
    fun matches(message: String?): Boolean = message != null && PATTERN.containsMatchIn(message)

    /**
     * Pure: did this failure come from Apple rejecting the MUT? Our OWN gateway's 401 (`{"error":"unauthorized"}`)
     * deliberately does NOT match - a new MUT cannot fix it.
     */
    fun isAppleAuthRejection(e: Throwable): Boolean = when (e) {
        is AmSyncException.Worker -> matches(e.msg)
        is AmSyncException.Http -> matches(e.body)
        else -> false
    }

    fun fingerprint(token: String): String =
        java.security.MessageDigest.getInstance("SHA-256").digest(token.toByteArray())
            .joinToString("") { "%02x".format(it) }.take(16)

    /**
     * Pure decision: clear only when the rejected token IS the one currently stored (a freshly re-minted token must
     * survive a late failure from the old job) and we have not already cleared this very token.
     */
    fun shouldClear(usedToken: String?, currentToken: String?, lastClearedFp: String): Boolean {
        val used = usedToken?.trim().orEmpty()
        val cur = currentToken?.trim().orEmpty()
        if (used.isEmpty() || cur.isEmpty() || used != cur) return false
        return fingerprint(used) != lastClearedFp
    }

    /** "Reconnect" shows only while the flag is set AND no token is stored (a reconnect hides it at once). */
    fun needsReconnect(flag: Boolean, hasToken: Boolean): Boolean = flag && !hasToken
}

/** Storage the rejection handler drives; production = [AppSettingsStore], tests = a fake. */
interface MutStore {
    suspend fun currentToken(): String?
    suspend fun clearToken()
    suspend fun lastClearedFingerprint(): String
    suspend fun markCleared(fingerprint: String)
}

class SettingsMutStore(private val settings: AppSettingsStore) : MutStore {
    override suspend fun currentToken(): String? = settings.current().musicUserToken.trim().takeIf { it.isNotEmpty() }
    override suspend fun clearToken() = settings.clearMusicUserToken()
    override suspend fun lastClearedFingerprint(): String = settings.get(RejectedMut.LAST_CLEARED_FP)
    override suspend fun markCleared(fingerprint: String) {
        settings.set(RejectedMut.LAST_CLEARED_FP, fingerprint)
        settings.set(RejectedMut.NEEDS_RECONNECT, true)
    }
}

/** Serialised once-per-token clearing; concurrent failed jobs cannot clear twice or clear a newer token. */
class MutRejectionHandler(private val store: MutStore) {
    private val lock = Mutex()

    suspend fun onRejected(usedToken: String?): Boolean = lock.withLock {
        val current = store.currentToken()
        if (!RejectedMut.shouldClear(usedToken, current, store.lastClearedFingerprint())) return@withLock false
        store.markCleared(RejectedMut.fingerprint(current!!))
        store.clearToken()
        true
    }
}

/** Live "show Reconnect Apple Music" for Settings. */
fun AppSettingsStore.needsMutReconnect(): Flow<Boolean> =
    combine(flow(RejectedMut.NEEDS_RECONNECT), settings.map { it.hasAppleMusic }) { flag, has ->
        RejectedMut.needsReconnect(flag, has)
    }

/** Production wiring over the existing token client + Settings-persisted MUT. */
class DefaultAppleMusicTokens(
    private val devTokenClient: MusicKitDeveloperTokenClient,
    private val settings: AppSettingsStore,
) : AppleMusicTokens {
    override suspend fun developerToken(): String =
        if (AppleMusicApi.debugBase != null && com.levi.pocketdj.BuildConfig.DEBUG) "debug-dev-token" else devTokenClient.developerToken()
    override suspend fun musicUserToken(): String? =
        settings.current().musicUserToken.trim().takeIf { it.isNotEmpty() }
    override suspend fun invalidateDeveloperToken() = devTokenClient.invalidate()
    private val rejection = MutRejectionHandler(SettingsMutStore(settings))
    override suspend fun onAppleAuthRejected(usedToken: String?): Boolean = rejection.onRejected(usedToken)
}

/** Fixed tokens, for tests and tooling. */
class StaticAppleMusicTokens(
    private val dev: String,
    private val user: String? = null,
) : AppleMusicTokens {
    override suspend fun developerToken(): String = dev
    override suspend fun musicUserToken(): String? = user?.trim()?.takeIf { it.isNotEmpty() }
}

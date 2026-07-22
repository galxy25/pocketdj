package com.levi.pocketdj.data.applemusic

import android.content.Context
import android.content.Intent
import com.apple.android.sdk.authentication.AuthenticationFactory
import com.apple.android.sdk.authentication.TokenError
import com.apple.android.sdk.authentication.TokenResult
import com.levi.pocketdj.data.settings.AppSettingsStore

/**
 * Wraps Apple's Android auth SDK (specs/applemusic.md §3): developer token IN →
 * sign-in Intent OUT → Music-User-Token decoded from the result and persisted.
 *
 * This is the CORE half of the flow — building the intent and decoding the
 * result. The actual `ActivityResultContracts.StartActivityForResult` launch
 * lives on `MainActivity` (the single activity, wired by the UI layer): the
 * Settings button asks this wrapper for the intent, the activity launches it,
 * and the result callback hands the returned `Intent` back to [decodeResult].
 *
 * EVERY SDK touch is guarded (catch `Throwable`, incl. `NoClassDefFoundError` /
 * `UnsatisfiedLinkError`) so the app NEVER crashes when the SDK or the Apple
 * Music app is unavailable — on the emulator sign-in simply cannot complete
 * (specs/applemusic.md §0 fact 8, §3.2 [DEVICE-ONLY]).
 */
class MusicKitAuth(
    context: Context,
    private val settings: AppSettingsStore,
    private val devTokenClient: MusicKitDeveloperTokenClient,
) {
    private val appContext = context.applicationContext

    /** Outcome of decoding a sign-in result (specs/applemusic.md §3.2). */
    sealed interface AuthResult {
        /** Signed in — the Music-User-Token has already been persisted. */
        data class Success(val musicUserToken: String) : AuthResult

        /** The user backed out (`USER_CANCELLED`) — surface nothing. */
        data object Cancelled : AuthResult

        /** A recoverable/inactionable failure with a UI-ready [message]. */
        data class Failed(val kind: Kind, val message: String) : AuthResult

        enum class Kind { NO_SUBSCRIPTION, SUBSCRIPTION_EXPIRED, TOKEN_FETCH_ERROR, UNKNOWN, SDK_UNAVAILABLE }
    }

    /** Thrown when the sign-in intent can't be built (no dev token / SDK gone). */
    class AuthUnavailableException(message: String, cause: Throwable? = null) : Exception(message, cause)

    /**
     * Build the sign-in Intent for the activity to launch
     * (specs/applemusic.md §3.2 step 1). Fetches the developer token FIRST so a
     * server/token failure surfaces before Apple Music is ever opened (§7).
     * Throws [AuthUnavailableException] on any failure — the caller shows a
     * caption instead of launching.
     */
    suspend fun signInIntent(
        startScreenMessage: String = DEFAULT_START_MESSAGE,
    ): Intent {
        val developerToken = try {
            devTokenClient.developerToken()
        } catch (t: Throwable) {
            if (t is kotlinx.coroutines.CancellationException) throw t
            throw AuthUnavailableException(t.message ?: "Could not get an Apple Music token", t)
        }
        return try {
            AuthenticationFactory.createAuthenticationManager(appContext)
                .createIntentBuilder(developerToken)
                .setHideStartScreen(false)
                .setStartScreenMessage(startScreenMessage)
                .build()
        } catch (t: Throwable) {
            if (t is kotlinx.coroutines.CancellationException) throw t
            throw AuthUnavailableException("Apple Music sign-in is unavailable on this device", t)
        }
    }

    /**
     * Decode the activity result (specs/applemusic.md §3.2 step 3) and, on
     * success, PERSIST the Music-User-Token (§3.3). Fully guarded — a null intent
     * or an SDK failure degrades to [AuthResult.Cancelled] /
     * [AuthResult.Failed], never a crash.
     */
    suspend fun decodeResult(data: Intent?): AuthResult {
        if (data == null) return AuthResult.Cancelled
        val result: TokenResult = try {
            AuthenticationFactory.createAuthenticationManager(appContext).handleTokenResult(data)
        } catch (t: Throwable) {
            if (t is kotlinx.coroutines.CancellationException) throw t
            return AuthResult.Failed(AuthResult.Kind.SDK_UNAVAILABLE, "Apple Music sign-in failed to complete")
        }
        if (result.isError) return mapError(result.error)
        val token = result.musicUserToken
        if (token.isNullOrBlank()) {
            return AuthResult.Failed(AuthResult.Kind.UNKNOWN, "Sign-in returned no token — try again.")
        }
        settings.setMusicUserToken(token)
        return AuthResult.Success(token)
    }

    /** Sign out — clears the Music-User-Token only (dev token is app-wide, §3.3). */
    suspend fun signOut() {
        settings.clearMusicUserToken()
    }

    companion object {
        const val DEFAULT_START_MESSAGE =
            "Connect Apple Music to stream your library in PocketDJ"

        /** Pure mapping of an SDK [TokenError] to a UI-ready [AuthResult]. */
        fun mapError(error: TokenError?): AuthResult = when (error) {
            TokenError.USER_CANCELLED -> AuthResult.Cancelled
            TokenError.NO_SUBSCRIPTION ->
                AuthResult.Failed(AuthResult.Kind.NO_SUBSCRIPTION, "No active Apple Music subscription — previews still play.")
            TokenError.SUBSCRIPTION_EXPIRED ->
                AuthResult.Failed(AuthResult.Kind.SUBSCRIPTION_EXPIRED, "Your Apple Music subscription has expired — previews still play.")
            TokenError.TOKEN_FETCH_ERROR ->
                AuthResult.Failed(AuthResult.Kind.TOKEN_FETCH_ERROR, "Sign-in failed, try again.")
            else ->
                AuthResult.Failed(AuthResult.Kind.UNKNOWN, "Sign-in failed, try again.")
        }
    }
}

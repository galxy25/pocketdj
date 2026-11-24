package com.levi.pocketdj.data.rips

import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.asStateFlow

/**
 * Port of the iOS `RipsStore` auth-rejection state (commit 1bad0e9d): a 401/403 from the rip server
 * means THIS device's token is wrong, which is a credential problem, not "server down".
 *
 * [rejectedToken] is the token VALUE the server last rejected. It lives in memory only (never logged,
 * never persisted) so the rejection clears by construction the moment the token changes (re-typed, or
 * healed by credentials sync) without anyone having to reset it. Any authed 2xx also clears it.
 *
 * Automatic callers (presign prefetch, burn lane, rip window, rip-collection) consult [holdoff] and skip
 * a guaranteed 401; user actions still try. After [reprobeMs] one automatic request is let through to see
 * whether the server's token was fixed to match.
 */
class RipAuthState(
    private val clock: () -> Long = System::currentTimeMillis,
    private val reprobeMs: Long = REPROBE_MS,
    private val log: (String) -> Unit = {},
) {
    private val lock = Any()
    private var rejectedToken: String? = null
    private var rejectedAt = 0L

    private val _revision = MutableStateFlow(0)

    /** Bumped on every rejection/clear so UI (the Rip/Burn bar) re-renders. */
    val revision: StateFlow<Int> = _revision.asStateFlow()

    /** The server rejected the CURRENT [token]. Sticky until the token changes or an authed call succeeds. */
    fun isRejected(token: String, hasServer: Boolean = true): Boolean = synchronized(lock) {
        hasServer && rejectedToken != null && rejectedToken == token
    }

    /** Automatic authed traffic should be held back now: rejected, and the re-probe window hasn't elapsed. */
    fun holdoff(token: String, hasServer: Boolean = true): Boolean = synchronized(lock) {
        hasServer && rejectedToken != null && rejectedToken == token && clock() - rejectedAt < reprobeMs
    }

    /** Record an HTTP status from an authed rip-server call (401/403 => rejected, 2xx => ok). */
    fun noteStatus(status: Int, token: String) {
        var changed = false
        var message: String? = null
        synchronized(lock) {
            if (status == 401 || status == 403) {
                rejectedAt = clock()
                if (rejectedToken != token) {
                    rejectedToken = token
                    changed = true
                    // Presence only, never the token itself.
                    message = "ripauth rejected status=$status tokenPresent=${token.isNotEmpty()} - presign/rip will fail until the token changes"
                }
            } else if (status in 200..299 && rejectedToken != null) {
                rejectedToken = null
                rejectedAt = 0L
                changed = true
                message = "ripauth accepted again status=$status"
            }
        }
        if (changed) _revision.value = _revision.value + 1
        message?.let(log)
    }

    companion object {
        /** After a rejection, automatic callers wait this long before one more authed request. */
        const val REPROBE_MS = 120_000L

        /** User-facing copy; says the server rejected the token, never "server down". */
        const val REJECTED_COPY = "The import server rejected this device's token (Settings ▸ Import server)"

        /** `BatchRipResult.refusedStatus` for a batch that never got an HTTP answer. */
        const val TRANSPORT_FAILURE = -1
    }
}

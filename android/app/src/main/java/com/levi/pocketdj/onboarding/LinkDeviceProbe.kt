package com.levi.pocketdj.onboarding

/** Outcome of probing for an existing PocketDJ profile to link (stage 1, "Link a device"). */
sealed interface LinkProbeResult {
    /** A profile already exists for this account — offer "Welcome back" / restore. */
    data class Existing(val name: String) : LinkProbeResult

    /** Reachable, nothing to restore — fall through to name entry. */
    data object Fresh : LinkProbeResult

    /** Cannot probe (not built yet / unreachable). Never offers name entry (LWW-clobber hazard). */
    data class Unavailable(val reason: String) : LinkProbeResult
}

/** The seam SVC-9 replaces with the S3 cloud-doc probe + code entry. */
fun interface LinkDeviceProbe {
    suspend fun probe(): LinkProbeResult
}

/** Default until SVC-9 lands: linking is not available yet, the user continues on-device. */
object StubLinkDeviceProbe : LinkDeviceProbe {
    const val REASON = "Linking another device isn't available yet. You can keep going on this device and link later in Settings."
    override suspend fun probe(): LinkProbeResult = LinkProbeResult.Unavailable(REASON)
}

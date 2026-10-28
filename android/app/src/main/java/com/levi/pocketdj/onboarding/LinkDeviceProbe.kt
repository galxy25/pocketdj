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

/** A probe that links by CODE (SVC-9): onboarding shows code entry instead of an immediate probe. */
interface CodeLinkProbe : LinkDeviceProbe {
    /**
     * Decode [code] (checksum verified BEFORE any network), adopt its profileId + secret, then probe the
     * cloud. On anything but [LinkProbeResult.Existing]/[LinkProbeResult.Fresh] the previous identity is
     * restored (a failed link never leaves a half-adopted profile).
     */
    suspend fun link(code: String): LinkProbeResult

    /** "Restore my stuff": force-pull every synced document. true = the pass ran. */
    suspend fun restore(): Boolean
}

/**
 * Production probe (SVC-9). Seams are lambdas so JVM tests drive it without the sync engine:
 * [probeCloud] = `CloudSyncService.probeCloudProfile`, [restoreCloud] = `restoreForOnboarding`.
 */
class S3LinkDeviceProbe(
    private val secrets: com.levi.pocketdj.data.sync.ProfileSecretStore,
    private val profileId: () -> String,
    private val adoptProfileId: (String) -> Unit,
    private val clearUnauthorized: () -> Unit,
    private val isUnauthorized: () -> Boolean,
    private val syncConfigured: () -> Boolean,
    private val probeCloud: suspend () -> com.levi.pocketdj.data.sync.CloudSyncService.ProfileProbe,
    private val restoreCloud: suspend () -> List<String>?,
) : CodeLinkProbe {
    private fun mapProbe(p: com.levi.pocketdj.data.sync.CloudSyncService.ProfileProbe): LinkProbeResult {
        if (isUnauthorized()) return LinkProbeResult.Unavailable(NOT_AUTHORIZED)
        return when (p) {
            is com.levi.pocketdj.data.sync.CloudSyncService.ProfileProbe.Existing -> LinkProbeResult.Existing(p.name)
            com.levi.pocketdj.data.sync.CloudSyncService.ProfileProbe.Fresh -> LinkProbeResult.Fresh
            com.levi.pocketdj.data.sync.CloudSyncService.ProfileProbe.Disabled ->
                LinkProbeResult.Unavailable("Sync across devices is turned off.")
            com.levi.pocketdj.data.sync.CloudSyncService.ProfileProbe.NoAccount ->
                LinkProbeResult.Unavailable("This device isn't set up to sync yet. You can keep going and link later in Settings.")
            com.levi.pocketdj.data.sync.CloudSyncService.ProfileProbe.Unknown ->
                LinkProbeResult.Unavailable("Couldn't reach PocketDJ sync. Check your connection and try again.")
        }
    }

    override suspend fun probe(): LinkProbeResult {
        if (!syncConfigured()) return LinkProbeResult.Unavailable(NOT_CONFIGURED)
        return mapProbe(probeCloud())
    }

    override suspend fun link(code: String): LinkProbeResult {
        if (!syncConfigured()) return LinkProbeResult.Unavailable(NOT_CONFIGURED)
        val ok = when (val d = com.levi.pocketdj.data.sync.LinkCode.decode(code)) {
            is com.levi.pocketdj.data.sync.LinkCode.Decoded.Ok -> d
            com.levi.pocketdj.data.sync.LinkCode.Decoded.BadChecksum ->
                return LinkProbeResult.Unavailable("That code doesn't look right. Check it for typos and try again.")
            com.levi.pocketdj.data.sync.LinkCode.Decoded.UnsupportedVersion ->
                return LinkProbeResult.Unavailable("That code is from a newer version of PocketDJ. Update this app and try again.")
            com.levi.pocketdj.data.sync.LinkCode.Decoded.BadFormat ->
                return LinkProbeResult.Unavailable("That isn't a PocketDJ link code.")
        }
        val prevSecrets = secrets.snapshot()
        val prevId = profileId()
        secrets.adopt(ok.profileId, ok.secret)
        adoptProfileId(ok.profileId)
        clearUnauthorized()
        val result = mapProbe(probeCloud())
        if (result !is LinkProbeResult.Existing && result !is LinkProbeResult.Fresh) {
            secrets.restore(prevSecrets)
            adoptProfileId(prevId)
            clearUnauthorized()
        }
        return result
    }

    override suspend fun restore(): Boolean = restoreCloud() != null

    companion object {
        const val NOT_CONFIGURED = "Sync across devices isn't set up for this build yet. You can keep going on this device."
        const val NOT_AUTHORIZED = "Profile not authorized — relink with a fresh code from your other device."
    }
}

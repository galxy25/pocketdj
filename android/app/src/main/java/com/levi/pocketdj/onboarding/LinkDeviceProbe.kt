package com.levi.pocketdj.onboarding

import kotlinx.coroutines.sync.withLock

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

    /**
     * Undo the last successful [link] (user chose "Start fresh" / Back / a restore failed and they
     * left the restore path): put the pre-link id + secret back so this device never keeps — and
     * later pushes into — the other device's profile. No-op when nothing is linked.
     */
    suspend fun unlink()
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
    /** Adopting a new identity: forget old watermarks and block pushes until the first pull (CloudSyncService). */
    private val holdPushes: () -> Unit = {},
    /** Link rolled back / nothing to restore: pushes follow their normal gate again. */
    private val releasePushes: () -> Unit = {},
    /**
     * Wave 7: sync is opt-in (default OFF), so a fresh install's probe answered "turned off" and first-run
     * linking could never work. Entering a link code IS the opt-in: [link] turns sync on (via
     * [setSyncEnabled]) when it was off, and turns it back off if the link fails or is undone.
     */
    private val syncEnabled: () -> Boolean = { true },
    private val setSyncEnabled: (Boolean) -> Unit = {},
) : CodeLinkProbe {
    @Volatile private var enabledByLink = false
    private class PreLink(val secrets: com.levi.pocketdj.data.sync.ProfileSecretStore.Snapshot, val id: String)

    /** Identity to go back to if the user leaves the restore path after a successful link. */
    @Volatile private var preLink: PreLink? = null
    private val identityLock = kotlinx.coroutines.sync.Mutex()

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
        return identityLock.withLock {
            val prev = PreLink(secrets.snapshot(), profileId())
            // Keep the ORIGINAL identity across a re-link: unlink() must go back to the device's own.
            val original = preLink ?: prev
            if (!syncEnabled()) { setSyncEnabled(true); enabledByLink = true }
            holdPushes()
            secrets.adopt(ok.profileId, ok.secret)
            adoptProfileId(ok.profileId)
            clearUnauthorized()
            val result = mapProbe(probeCloud())
            if (result !is LinkProbeResult.Existing && result !is LinkProbeResult.Fresh) {
                secrets.restore(prev.secrets)
                adoptProfileId(prev.id)
                clearUnauthorized()
                // The rollback re-applies the previous identity; a previous link (if any) stays unlinkable.
                if (preLink == null) releasePushes()
                if (enabledByLink && preLink == null) { setSyncEnabled(false); enabledByLink = false }
            } else {
                preLink = original
                // Nothing in the cloud to pull first, so there is nothing a push could overwrite.
                if (result == LinkProbeResult.Fresh) releasePushes()
            }
            result
        }
    }

    override suspend fun restore(): Boolean {
        val ok = restoreCloud() != null
        if (ok) { preLink = null; enabledByLink = false } // restored: this device now IS the linked profile; nothing to undo
        return ok
    }

    override suspend fun unlink() {
        identityLock.withLock {
            val p = preLink ?: return
            secrets.restore(p.secrets)
            adoptProfileId(p.id)
            clearUnauthorized()
            releasePushes()
            preLink = null
            if (enabledByLink) { setSyncEnabled(false); enabledByLink = false }
        }
    }

    companion object {
        const val NOT_CONFIGURED = "Sync across devices isn't set up for this build yet. You can keep going on this device."
        const val NOT_AUTHORIZED = "Profile not authorized — relink with a fresh code from your other device."
    }
}

package com.levi.pocketdj.data.sync

import com.levi.pocketdj.data.credentials.SecretStore
import java.security.MessageDigest
import java.security.SecureRandom

/**
 * The profile's sync SECRET (SVC-9) - 32 random bytes minted once on the originating device and
 * shared to linked devices by link code. Lives ONLY in the Keystore-backed [SecretStore] (decision
 * D6): never DataStore, never JSON, never logs ([toString] is redacted). The server stores just
 * SHA-256(secret) (see docs/design/profile-sync-s3.md).
 *
 * Wire form of the secret is 64 lowercase hex chars; the bearer token is that string and the
 * enroll body carries `sha256hex(thatString)`.
 */
class ProfileSecretStore(
    private val store: SecretStore,
    private val random: SecureRandom = SecureRandom(),
) {
    @Synchronized fun secret(): String = store.get(SECRET)

    @Synchronized fun hasSecret(): Boolean = secret().isNotEmpty()

    /** The existing secret, or a freshly minted one persisted first. */
    @Synchronized fun secretOrMint(): String {
        secret().takeIf { it.isNotEmpty() }?.let { return it }
        val bytes = ByteArray(SECRET_BYTES).also(random::nextBytes)
        val hex = bytes.toHex()
        store.put(SECRET, hex)
        return hex
    }

    /** The profile id the server is known to hold our secret hash for (lower-cased), or "". */
    @Synchronized fun enrolledProfileId(): String = store.get(ENROLLED_ID)

    @Synchronized fun markEnrolled(profileId: String) {
        store.put(ENROLLED_ID, profileId.lowercase())
        store.remove(RELINK_ID)
    }

    /** The server answered 409 for this id: our secret is not the one it holds (lost/foreign). */
    @Synchronized fun relinkRequiredFor(profileId: String): Boolean = store.get(RELINK_ID) == profileId.lowercase()

    @Synchronized fun markRelinkRequired(profileId: String) = store.put(RELINK_ID, profileId.lowercase())

    /** The profile id the server answered 401 for (persisted so "relink" survives a restart), or "". */
    @Synchronized fun unauthorizedFor(profileId: String): Boolean = store.get(UNAUTHORIZED_ID) == profileId.lowercase()

    @Synchronized fun markUnauthorized(profileId: String) = store.put(UNAUTHORIZED_ID, profileId.lowercase())

    @Synchronized fun clearUnauthorized() = store.remove(UNAUTHORIZED_ID)

    /**
     * Adopt another device's identity: its secret becomes ours and the id counts as enrolled (the
     * originating device enrolled it). Clears any relink flag.
     */
    @Synchronized fun adopt(profileId: String, secret: String) {
        store.put(SECRET, secret.lowercase())
        store.put(ENROLLED_ID, profileId.lowercase())
        store.remove(RELINK_ID)
        store.remove(UNAUTHORIZED_ID)
    }

    /** Snapshot for rollback when a link attempt fails after [adopt]. */
    @Synchronized fun snapshot(): Snapshot = Snapshot(store.get(SECRET), store.get(ENROLLED_ID), store.get(RELINK_ID), store.get(UNAUTHORIZED_ID))

    @Synchronized fun restore(s: Snapshot) {
        fun put(k: String, v: String) = if (v.isEmpty()) store.remove(k) else store.put(k, v)
        put(SECRET, s.secret); put(ENROLLED_ID, s.enrolledId); put(RELINK_ID, s.relinkId); put(UNAUTHORIZED_ID, s.unauthorizedId)
    }

    /** Account deletion / reset. */
    @Synchronized fun clear() {
        store.remove(SECRET); store.remove(ENROLLED_ID); store.remove(RELINK_ID); store.remove(UNAUTHORIZED_ID)
    }

    class Snapshot internal constructor(val secret: String, val enrolledId: String, val relinkId: String, val unauthorizedId: String = "") {
        override fun toString() = "Snapshot(redacted)"
    }

    override fun toString() = "ProfileSecretStore(redacted)"

    companion object {
        const val SECRET = "profileSecret"
        const val ENROLLED_ID = "profileEnrolledId"
        const val RELINK_ID = "profileRelinkId"
        const val UNAUTHORIZED_ID = "profileUnauthorizedId"
        /** Optional enroll capability token (X-PocketDJ-Enroll); provisioned like the rec-engine one. */
        const val ENROLL_TOKEN = "profileSyncEnrollToken"
        const val SECRET_BYTES = 32

        fun sha256Hex(s: String): String = MessageDigest.getInstance("SHA-256").digest(s.toByteArray(Charsets.UTF_8)).toHex()

        internal fun ByteArray.toHex(): String = joinToString("") { "%02x".format(it.toInt() and 0xff) }
    }
}

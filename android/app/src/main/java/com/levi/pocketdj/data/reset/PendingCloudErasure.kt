package com.levi.pocketdj.data.reset

import com.levi.pocketdj.data.credentials.SecretStore

/**
 * Device-local tombstone for an account deletion whose server-side `DELETE /profile` failed
 * (offline / 5xx / timeout). The cloud is the developer's S3 bucket with no expiry, so the erasure
 * must be retried until it lands. Holds the OLD profile id + secret (the only credential that can
 * authorize the delete) in the Keystore-backed [SecretStore]; removed once the server confirms.
 */
class PendingCloudErasure(private val store: SecretStore) {
    data class Target(val profileId: String, val secret: String)

    fun save(profileId: String, secret: String) {
        if (profileId.isEmpty() || secret.isEmpty()) return
        store.put(ID, profileId.lowercase())
        store.put(SECRET, secret)
    }

    fun load(): Target? {
        val id = store.get(ID)
        val sec = store.get(SECRET)
        return if (id.isEmpty() || sec.isEmpty()) null else Target(id, sec)
    }

    fun clear() {
        store.remove(ID)
        store.remove(SECRET)
    }

    /**
     * Retry the erasure with [delete] (id, secret) -> done. A thrown error keeps the tombstone for the
     * next launch; `true` (success, already gone, or credential permanently rejected) clears it.
     */
    suspend fun retry(delete: suspend (String, String) -> Boolean): Boolean {
        val t = load() ?: return false
        val done = try { delete(t.profileId, t.secret) } catch (e: kotlinx.coroutines.CancellationException) { throw e } catch (_: Throwable) { false }
        if (done) clear()
        return done
    }

    companion object {
        const val ID = "pendingErasureProfileId"
        const val SECRET = "pendingErasureSecret"
    }
}

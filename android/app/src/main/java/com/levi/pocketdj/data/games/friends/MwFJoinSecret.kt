package com.levi.pocketdj.data.games.friends

import java.security.SecureRandom

/** Tiny string key-value seam (SharedPreferences in the app, a map in tests). */
interface MwFKeyValue {
    fun getString(key: String): String?
    fun putString(key: String, value: String?)
}

class InMemoryMwFKeyValue : MwFKeyValue {
    private val map = HashMap<String, String>()
    @Synchronized override fun getString(key: String): String? = map[key]
    @Synchronized override fun putString(key: String, value: String?) {
        if (value == null) map.remove(key) else map[key] = value
    }
}

/**
 * Per-install Music-with-Friends RE-JOIN credential: 32 random hex chars minted once. Deliberately
 * NOT the install id (that one rides every call as X-PocketDJ-Device and is broadcast to hosts);
 * this goes to exactly one endpoint, `POST /mwf/:id/join`.
 */
class MwFJoinSecret(private val kv: MwFKeyValue, private val random: () -> String = ::mint) {
    @Synchronized
    fun current(): String {
        kv.getString(KEY)?.takeIf { it.isNotEmpty() }?.let { return it }
        return random().also { kv.putString(KEY, it) }
    }

    /** Account deletion: forget the secret so the next join mints a fresh one. */
    @Synchronized
    fun reset() = kv.putString(KEY, null)

    companion object {
        const val KEY = "mwfJoinSecret"
        private val rng = SecureRandom()
        fun mint(): String {
            val sb = StringBuilder(32)
            repeat(32) { sb.append("0123456789abcdef"[rng.nextInt(16)]) }
            return sb.toString()
        }
    }
}

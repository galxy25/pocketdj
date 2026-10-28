package com.levi.pocketdj.diag

import android.content.Context
import com.levi.pocketdj.data.credentials.SecretStore
import java.util.UUID

/** Tiny key/value seam so the diag logic is JVM-testable. */
interface DiagPrefs {
    fun getString(key: String): String?
    fun putString(key: String, value: String?)
    fun getLong(key: String): Long? = getString(key)?.toLongOrNull()
    fun putLong(key: String, value: Long) = putString(key, value.toString())
    fun getBool(key: String, default: Boolean): Boolean = getString(key)?.toBooleanStrictOrNull() ?: default
    fun putBool(key: String, value: Boolean) = putString(key, value.toString())
}

class MemoryDiagPrefs : DiagPrefs {
    private val m = HashMap<String, String>()
    @Synchronized override fun getString(key: String): String? = m[key]
    @Synchronized override fun putString(key: String, value: String?) {
        if (value == null) m.remove(key) else m[key] = value
    }
}

class SharedDiagPrefs(context: Context) : DiagPrefs {
    private val sp = context.applicationContext.getSharedPreferences("pocketdj-diag", Context.MODE_PRIVATE)
    override fun getString(key: String): String? = sp.getString(key, null)
    override fun putString(key: String, value: String?) {
        sp.edit().apply { if (value == null) remove(key) else putString(key, value) }.apply()
    }
}

/** Non-secret diag settings + persisted upload status. */
class DiagSettings(private val prefs: DiagPrefs) {
    /** "Remote diagnostics" toggle (default on inside a diag-channel build). */
    var diagEnabled: Boolean
        get() = prefs.getBool(K_ENABLED, true)
        set(v) = prefs.putBool(K_ENABLED, v)

    /** "Remote telemetry" toggle (owner opt-in; default off). */
    var telemetryEnabled: Boolean
        get() = prefs.getBool(K_TELEMETRY, false)
        set(v) = prefs.putBool(K_TELEMETRY, v)

    /** Random per-install id; the first 8 chars key the bucket prefix. */
    val installId: String
        get() = prefs.getString(K_INSTALL) ?: UUID.randomUUID().toString().also { prefs.putString(K_INSTALL, it) }

    fun loadStatus(channelEnabled: Boolean, keyPresent: Boolean) = UploadStatus(
        channelEnabled, keyPresent,
        prefs.getLong(K_OK), prefs.getString(K_ERR), prefs.getLong(K_ERR_AT),
    )

    fun saveSuccess(at: Long) = prefs.putLong(K_OK, at)

    fun saveError(text: String, at: Long) {
        prefs.putString(K_ERR, text)
        prefs.putLong(K_ERR_AT, at)
    }

    companion object {
        const val K_ENABLED = "diagEnabled"
        const val K_TELEMETRY = "telemetryEnabled"
        const val K_INSTALL = "installId"
        const val K_OK = "lastSuccessAt"
        const val K_ERR = "lastError"
        const val K_ERR_AT = "lastErrorAt"
    }
}

/** The diag-writer key (IAM PutObject on the diag/ prefix only), kept in the [SecretStore]. */
class DiagCredentialStore(private val secrets: SecretStore) {
    data class Credentials(val accessKeyId: String, val secret: String)

    fun load(): Credentials? {
        val id = secrets.get(ID).trim()
        val sec = secrets.get(SECRET).trim()
        return if (id.isEmpty() || sec.isEmpty()) null else Credentials(id, sec)
    }

    fun save(accessKeyId: String, secret: String) {
        secrets.put(ID, accessKeyId)
        secrets.put(SECRET, secret)
    }

    fun clear() {
        secrets.remove(ID)
        secrets.remove(SECRET)
    }

    companion object {
        const val ID = "diagKeyId"
        const val SECRET = "diagKeySecret"
    }
}

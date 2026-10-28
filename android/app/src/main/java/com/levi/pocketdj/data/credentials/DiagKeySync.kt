package com.levi.pocketdj.data.credentials

import com.levi.pocketdj.diag.DiagCredentialStore
import java.io.File
import kotlinx.serialization.Serializable
import kotlinx.serialization.json.Json

/**
 * The diag-writer key's own synced doc ("diag-key", `pocketdj-diag-key.json`). Its OWN doc (not a field on
 * the credentials doc) so older builds never strip it. EMPTY NEVER WINS: [materialize] writes only from a
 * non-empty key and only on change; [applyPulled] adopts only a non-empty pulled key. Port of iOS DiagKeySync.
 */
class DiagKeySync(
    private val file: File,
    private val store: DiagCredentialStore,
) {
    @Serializable
    data class Document(
        val schemaVersion: Int = 1,
        val accessKeyID: String = "",
        val secret: String = "",
    )

    enum class PullResult { ADOPTED, UNCHANGED, IGNORED_EMPTY }

    /** Mirror the local key into the file iff non-empty and changed. True when (re)written. */
    @Synchronized
    fun materialize(): Boolean {
        val creds = store.load() ?: return false
        val data = encode(Document(accessKeyID = creds.accessKeyId, secret = creds.secret))
        if (runCatching { file.readBytes() }.getOrNull()?.contentEquals(data) == true) return false
        return runCatching {
            file.parentFile?.mkdirs()
            val tmp = File(file.parentFile, file.name + ".tmp")
            tmp.writeBytes(data)
            if (!tmp.renameTo(file)) { file.writeBytes(data); tmp.delete() }
        }.isSuccess
    }

    /** After a pull wrote [file]: adopt unless empty/undecodable (never clears) or already held. */
    @Synchronized
    fun applyPulled(): PullResult {
        val doc = runCatching { json.decodeFromString(Document.serializer(), file.readText()) }.getOrNull()
            ?: return PullResult.IGNORED_EMPTY
        val id = doc.accessKeyID.trim()
        val secret = doc.secret.trim()
        if (id.isEmpty() || secret.isEmpty()) return PullResult.IGNORED_EMPTY
        if (store.load() == DiagCredentialStore.Credentials(id, secret)) return PullResult.UNCHANGED
        store.save(id, secret)
        return PullResult.ADOPTED
    }

    companion object {
        const val KEY = "diag-key"
        const val FILE_NAME = "pocketdj-diag-key.json"
        private val json = Json { ignoreUnknownKeys = true; encodeDefaults = true }

        /** Sorted keys (accessKeyID, schemaVersion, secret) = Swift `.sortedKeys`. */
        fun encode(doc: Document): ByteArray =
            SettingsCredentialsDocument.canonical(json.encodeToJsonElement(Document.serializer(), doc))
                .toString().toByteArray(Charsets.UTF_8)
    }
}

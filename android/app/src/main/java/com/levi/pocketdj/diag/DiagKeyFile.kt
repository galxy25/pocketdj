package com.levi.pocketdj.diag

import kotlinx.serialization.json.Json
import kotlinx.serialization.json.JsonObject
import kotlinx.serialization.json.JsonPrimitive
import kotlinx.serialization.json.contentOrNull
import kotlinx.serialization.json.intOrNull

/**
 * The `.pdjdiagkey` file (schema v1) written by `scripts/green/export-diag-key.sh`:
 * `{"type":"pocketdj-diag-key","schemaVersion":1,"env":"green","account":"…","accessKeyID":"AKIA…","secret":"…"}`.
 * Errors name the problem and NEVER contain a secret.
 */
data class DiagKeyFile(
    val env: String,
    val account: String,
    val accessKeyID: String,
    val secret: String,
    val exportedAt: String? = null,
) {
    sealed class Invalid(val description: String) {
        data object NotJson : Invalid("not a PocketDJ diag key file (unreadable JSON)")
        data object WrongType : Invalid("not a PocketDJ diag key file")
        data class UnsupportedVersion(val v: Int) : Invalid("unsupported key file version $v")
        data class Missing(val field: String) : Invalid("key file is missing $field")
        data object BadAccessKeyId : Invalid("key file's access key ID is malformed")
        data object BadAccount : Invalid("key file's account is not a 12-digit AWS account id")
    }

    sealed interface Decoded {
        data class Ok(val file: DiagKeyFile) : Decoded
        data class Rejected(val why: Invalid) : Decoded
    }

    companion object {
        const val TYPE_TAG = "pocketdj-diag-key"
        const val FILE_EXTENSION = "pdjdiagkey"
        private val ACCESS_KEY = Regex("^(AKIA|ASIA)[A-Z0-9]{16}$")
        private val ACCOUNT = Regex("^[0-9]{12}$")
        private val parser = Json { ignoreUnknownKeys = true }

        fun decode(text: String): Decoded {
            val obj = runCatching { parser.parseToJsonElement(text) }.getOrNull() as? JsonObject
                ?: return Decoded.Rejected(Invalid.NotJson)
            fun str(k: String): String? = (obj[k] as? JsonPrimitive)?.takeIf { it.isString }?.contentOrNull
            if (str("type") != TYPE_TAG) return Decoded.Rejected(Invalid.WrongType)
            val vEl = obj["schemaVersion"] as? JsonPrimitive
            val v = vEl?.takeIf { !it.isString }?.intOrNull ?: return Decoded.Rejected(Invalid.Missing("schemaVersion"))
            if (v != 1) return Decoded.Rejected(Invalid.UnsupportedVersion(v))
            fun nonEmpty(k: String) = str(k)?.trim()?.takeIf { it.isNotEmpty() }
            val env = nonEmpty("env") ?: return Decoded.Rejected(Invalid.Missing("env"))
            val account = nonEmpty("account") ?: return Decoded.Rejected(Invalid.Missing("account"))
            val id = nonEmpty("accessKeyID") ?: return Decoded.Rejected(Invalid.Missing("accessKeyID"))
            val secret = nonEmpty("secret") ?: return Decoded.Rejected(Invalid.Missing("secret"))
            if (!ACCESS_KEY.matches(id)) return Decoded.Rejected(Invalid.BadAccessKeyId)
            if (!ACCOUNT.matches(account)) return Decoded.Rejected(Invalid.BadAccount)
            return Decoded.Ok(DiagKeyFile(env, account, id, secret, str("exportedAt")))
        }

        private val BUCKET_HOST = Regex("^pocketdj-logs-([0-9]{12})\\.")

        /** The AWS account in a logs-bucket URL (`pocketdj-logs-<account>.s3…`), or null. */
        fun bucketAccount(logsBase: String): String? {
            val host = runCatching { java.net.URI(logsBase).host }.getOrNull()?.lowercase() ?: return null
            return BUCKET_HOST.find(host)?.groupValues?.get(1)
        }
    }
}

/** Validate → pair-check against the active logs bucket → [DiagCredentialStore] → reload. */
class DiagKeyImporter(
    private val store: DiagCredentialStore,
    private val logsBase: () -> String,
    private val activeEnv: () -> String,
    private val log: (String) -> Unit,
    private val reloadCredentials: () -> Unit,
) {
    data class Mismatch(val keyEnv: String, val keyAccount: String, val activeEnv: String, val bucketAccount: String) {
        val warning: String
            get() = "This key is for $keyEnv (account $keyAccount), but the app is uploading to the $activeEnv " +
                "logs bucket (account $bucketAccount). Uploads would fail with 403 until the endpoint config flips to $keyEnv."
    }

    sealed interface Outcome {
        data class Imported(val env: String, val account: String, val keyId: String, val mismatch: Mismatch?) : Outcome
        data class NeedsConfirmation(val mismatch: Mismatch) : Outcome
        data class Invalid(val reason: String) : Outcome
    }

    fun importText(text: String, force: Boolean = false): Outcome {
        val file = when (val d = DiagKeyFile.decode(text)) {
            is DiagKeyFile.Decoded.Ok -> d.file
            is DiagKeyFile.Decoded.Rejected -> {
                log("key import rejected: ${d.why.description}")
                return Outcome.Invalid(d.why.description)
            }
        }
        val env = activeEnv()
        val bucket = DiagKeyFile.bucketAccount(logsBase())
        val mismatch = if (bucket != null && bucket != file.account) Mismatch(file.env, file.account, env, bucket) else null
        if (mismatch != null && !force) {
            log("key import held: env=${file.env} account=${file.account} != active env=$env bucket account=${mismatch.bucketAccount}")
            return Outcome.NeedsConfirmation(mismatch)
        }
        store.save(file.accessKeyID, file.secret)
        reloadCredentials()
        log("key imported env=${file.env} account=${file.account} activeEnv=$env paired=${mismatch == null}")
        return Outcome.Imported(file.env, file.account, file.accessKeyID, mismatch)
    }

    fun remove() {
        store.clear()
        reloadCredentials()
    }
}

package com.levi.pocketdj.data.credentials

import java.io.File

/** Reads/writes the live connection settings (rip/jukebox/search). The Android adapter lives in ServicesGraph. */
interface CredentialsPort {
    /** The synced subset as it stands in the live store. */
    fun read(): SettingsCredentialsDocument

    /** Apply [doc] to the live settings (whole-field overwrite; guarding already happened). */
    fun apply(doc: SettingsCredentialsDocument)
}

/**
 * Port of iOS `SettingsStore` credentials sync (SettingsCredentialsSync.swift): mirror the subset into
 * [file] only when content changed (so mtime == "last credential edit"), never materialize a blank
 * install, and never let a pulled EMPTY secret wipe a local one (2026-09-12 fleet-wide 401 incident).
 */
class CredentialsSync(
    private val file: File,
    private val port: CredentialsPort,
    private val log: (String) -> Unit = {},
) {
    /** Mirror to disk IFF changed and not (absent + blank). Returns true when the file was written. */
    @Synchronized
    fun syncIfChanged(): Boolean {
        val doc = port.read()
        val data = SettingsCredentialsDocument.encode(doc)
        val existing = runCatching { file.readBytes() }.getOrNull()
        if (existing != null && existing.contentEquals(data)) return false
        if (existing == null && doc.credentialsAreBlank) return false // adopt, don't race the cloud copy
        file.parentFile?.mkdirs()
        val tmp = File(file.parentFile, file.name + ".tmp")
        tmp.writeBytes(data)
        if (!tmp.renameTo(file)) { file.writeBytes(data); tmp.delete() }
        return true
    }

    /**
     * After a pull rewrote [file]: apply it (minus guarded secrets) and re-materialize. A guarded apply
     * leaves local differing from the pull, so the re-materialize rewrites the file and pushes the kept
     * secret back (heals the fleet). Returns true when the file was re-saved.
     */
    @Synchronized
    fun applyPulled(): Boolean {
        val pulled = runCatching { file.readBytes() }.getOrNull()?.let { SettingsCredentialsDocument.decode(it) }
            ?: return false
        val result = merge(port.read(), pulled)
        port.apply(result.doc)
        if (result.keptRip || result.keptJukebox || result.keptSearch) {
            log("guarded empty-secret wipe: kept rip=${result.keptRip} jb=${result.keptJukebox} search=${result.keptSearch}")
        }
        log(
            "applied: rip(url=${result.doc.ripServerURL.isNotEmpty()} tok=${result.doc.ripToken.isNotEmpty()}) " +
                "jb(url=${result.doc.jukeboxServerURL.isNotEmpty()} tok=${result.doc.jukeboxToken.isNotEmpty()}) " +
                "search(keys=${result.doc.searchAccessKeyID.isNotEmpty() && result.doc.searchSecretKey.isNotEmpty()} " +
                "ep=${result.doc.searchEndpoint.isNotEmpty()})",
        )
        return syncIfChanged()
    }

    data class MergeResult(
        val doc: SettingsCredentialsDocument,
        val keptRip: Boolean,
        val keptJukebox: Boolean,
        val keptSearch: Boolean,
    )

    companion object {
        /**
         * Same-URL + empty pulled secret = accidental wipe => keep local. A DIFFERENT url adopts
         * wholesale (tokenless servers included); clearing the url clears the pair.
         */
        fun keepLocalSecret(localSecret: String, pulledSecret: String, localUrl: String, pulledUrl: String): Boolean =
            pulledSecret.isEmpty() && localSecret.isNotEmpty() && pulledUrl.isNotEmpty() && pulledUrl == localUrl

        /** Pure merge: the live doc [local] after adopting [pulled] with the empty-secret guards. */
        fun merge(local: SettingsCredentialsDocument, pulled: SettingsCredentialsDocument): MergeResult {
            val keptRip = keepLocalSecret(local.ripToken, pulled.ripToken, local.ripServerURL, pulled.ripServerURL)
            val keptJb = keepLocalSecret(local.jukeboxToken, pulled.jukeboxToken, local.jukeboxServerURL, pulled.jukeboxServerURL)
            // The search key pair is guarded together on the endpoint (half-adopting mints a mismatched credential).
            val keptSearch = pulled.searchAccessKeyID.isEmpty() && pulled.searchSecretKey.isEmpty() &&
                !(local.searchAccessKeyID.isEmpty() && local.searchSecretKey.isEmpty()) &&
                pulled.searchEndpoint == local.searchEndpoint
            val merged = local.copy(
                ripServerURL = pulled.ripServerURL,
                ripToken = if (keptRip) local.ripToken else pulled.ripToken,
                jukeboxServerURL = pulled.jukeboxServerURL,
                jukeboxToken = if (keptJb) local.jukeboxToken else pulled.jukeboxToken,
                jukeboxTokensRequiredByDefault = pulled.jukeboxTokensRequiredByDefault,
                searchAccessKeyID = if (keptSearch) local.searchAccessKeyID else pulled.searchAccessKeyID,
                searchSecretKey = if (keptSearch) local.searchSecretKey else pulled.searchSecretKey,
                searchEndpoint = pulled.searchEndpoint,
            )
            return MergeResult(merged, keptRip, keptJb, keptSearch)
        }
    }
}

/** `X-PocketDJ-Profile`: stamped on authenticated server calls only when a profile id exists (iOS PDJIdentityHeaders). */
object ProfileHeader {
    const val NAME = "X-PocketDJ-Profile"

    fun apply(builder: okhttp3.Request.Builder, profileId: String): okhttp3.Request.Builder {
        val pid = profileId.trim()
        if (pid.isNotEmpty()) builder.header(NAME, pid)
        return builder
    }
}

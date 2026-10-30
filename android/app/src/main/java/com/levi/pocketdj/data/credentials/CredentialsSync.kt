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
    /** False when the Keystore-backed secret store could not open this launch (Final review recheck). */
    private val secretsAvailable: () -> Boolean = { true },
) {
    /** Set by [writePulled] until [applyPulled] runs: the watcher must not overwrite pulled bytes in the gap. */
    @Volatile private var pullPendingSince = 0L

    /**
     * Reset / account deletion: stop materializing for the rest of this process. The reactive watcher fires on every
     * secret/settings wipe step and would otherwise write a half-blank doc that later wins last-writer and blanks the
     * rip / jukebox / search config on every linked device. Cleared only by the relaunch.
     */
    @Volatile private var suspended = false
    fun suspendUntilRelaunch() { suspended = true }

    /** SyncEntry.applyPayload seam: write the pulled bytes atomically under the same lock as [syncIfChanged]. */
    @Synchronized
    fun writePulled(bytes: ByteArray) {
        writeAtomic(bytes)
        pullPendingSince = System.currentTimeMillis()
    }

    private fun writeAtomic(data: ByteArray) {
        file.parentFile?.mkdirs()
        val tmp = File(file.parentFile, file.name + ".tmp")
        tmp.writeBytes(data)
        if (!tmp.renameTo(file)) { file.writeBytes(data); tmp.delete() }
    }

    /**
     * Mirror to disk IFF the CONTENT changed (decoded + trimmed compare, not bytes: Swift escapes `/`) and
     * not (absent + blank). Pass-through fields (sources, appleMusicPrivateSync) are carried from the file.
     * Returns true when the file was written.
     */
    @Synchronized
    fun syncIfChanged(): Boolean {
        if (suspended) return false
        // Final review recheck: a transient Keystore failure now keeps the secrets for the NEXT launch instead of
        // wiping them; this launch reads every secret as "". Mirroring that would push a blank-token doc fleet-wide.
        if (!secretsAvailable()) return false
        val pendingSince = pullPendingSince
        if (pendingSince != 0L && System.currentTimeMillis() - pendingSince < PULL_PENDING_MS) return false
        val existingBytes = runCatching { file.readBytes() }.getOrNull()
        val existing = existingBytes?.let { SettingsCredentialsDocument.decode(it) }
        val live = port.read()
        val doc = live.copy(
            sources = existing?.sources, appleMusicPrivateSync = existing?.appleMusicPrivateSync,
            passThroughSearch = existing?.passThroughSearch,
        )
        if (existing != null && existing.normalized() == doc.normalized()) return false
        if (existingBytes == null && doc.credentialsAreBlank) return false // adopt, don't race the cloud copy
        writeAtomic(SettingsCredentialsDocument.encode(doc))
        return true
    }

    /**
     * After a pull rewrote [file]: apply it (minus guarded secrets) and re-materialize. A guarded apply
     * leaves local differing from the pull, so the re-materialize rewrites the file and pushes the kept
     * secret back (heals the fleet). Returns true when the file was re-saved.
     */
    @Synchronized
    fun applyPulled(): Boolean {
        pullPendingSince = 0L
        val pulled = runCatching { file.readBytes() }.getOrNull()?.let { SettingsCredentialsDocument.decode(it) }
            ?: return false
        val result = merge(port.read(), pulled)
        port.apply(result.doc)
        if (result.keptRip || result.keptJukebox) {
            log("guarded empty-secret wipe: kept rip=${result.keptRip} jb=${result.keptJukebox}")
        }
        log(
            "applied: rip(url=${result.doc.ripServerURL.isNotEmpty()} tok=${result.doc.ripToken.isNotEmpty()}) " +
                "jb(url=${result.doc.jukeboxServerURL.isNotEmpty()} tok=${result.doc.jukeboxToken.isNotEmpty()})",
        )
        return syncIfChanged()
    }

    data class MergeResult(
        val doc: SettingsCredentialsDocument,
        val keptRip: Boolean,
        val keptJukebox: Boolean,
    )

    companion object {
        private const val PULL_PENDING_MS = 30_000L

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
            val merged = local.copy(
                ripServerURL = pulled.ripServerURL,
                ripToken = if (keptRip) local.ripToken else pulled.ripToken,
                jukeboxServerURL = pulled.jukeboxServerURL,
                jukeboxToken = if (keptJb) local.jukeboxToken else pulled.jukeboxToken,
                jukeboxTokensRequiredByDefault = pulled.jukeboxTokensRequiredByDefault,
            )
            return MergeResult(merged, keptRip, keptJb)
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

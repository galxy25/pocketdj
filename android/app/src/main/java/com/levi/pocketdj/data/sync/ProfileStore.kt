package com.levi.pocketdj.data.sync

import com.levi.pocketdj.data.PdjJson
import java.io.File
import java.util.UUID
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.asStateFlow
import kotlinx.serialization.Serializable

/**
 * The user's PocketDJ PROFILE - a stable per-user identity: a random durable [id] (minted once,
 * never regenerated), the display name (the same "PocketDJ name" stamped on performance items and
 * the jukebox DJ line), and [createdAtMs]. Port of iOS `ProfileStore`.
 *
 * Persists to `pocketdj-profile.json` (iOS file name and keys, so the synced document is
 * wire-compatible) and syncs through [CloudSyncService].
 *
 * NAME OWNERSHIP: the DataStore `PROFILE_NAME` pref remains the wired-everywhere read path
 * (jukebox DJ line, studio performer). The profile is the SYNCED source of truth; [onNameApplied]
 * mirrors profile -> settings + collections on every local edit AND every cloud pull.
 */
class ProfileStore(private val file: File) {

    @Serializable
    data class Document(
        val schemaVersion: Int = SCHEMA_VERSION,
        val id: String,
        val name: String = "",
        val createdAtMs: Double,
    )

    data class State(val id: String, val name: String, val createdAtMs: Double)

    private val lock = Any()
    private val _state: MutableStateFlow<State>
    val state: StateFlow<State>

    /** Mirrors a (local or cloud-pulled) name into settings + collections. */
    @Volatile var onNameApplied: ((String) -> Unit)? = null

    val id: String get() = _state.value.id
    val name: String get() = _state.value.name
    val createdAtMs: Double get() = _state.value.createdAtMs

    /** The on-disk document the sync engine syncs. */
    val syncFile: File get() = file

    init {
        val doc = readDocument()
        _state = MutableStateFlow(
            if (doc != null) State(doc.id, doc.name, doc.createdAtMs)
            else State(UUID.randomUUID().toString().uppercase(), "", System.currentTimeMillis().toDouble()),
        )
        state = _state.asStateFlow()
    }

    /**
     * One-time migration: a device that set a PocketDJ name BEFORE profiles existed adopts it as the
     * profile name (and the profile file materializes on disk so it can sync). No-op once the
     * profile has a name of its own.
     */
    fun migrateIfNeeded(settingsName: String) = synchronized(lock) {
        val trimmed = settingsName.trim()
        if (_state.value.name.isNotEmpty() || trimmed.isEmpty()) return@synchronized
        _state.value = _state.value.copy(name = trimmed)
        save()
    }

    /** Apply a local edit (the Settings > Profile field): persist + mirror to consumers. */
    fun setName(newName: String) {
        synchronized(lock) {
            _state.value = _state.value.copy(name = newName)
            save()
        }
        onNameApplied?.invoke(newName)
    }

    /**
     * Re-decode the on-disk document after the sync engine pulled a newer cloud copy, then mirror the
     * (possibly changed) name. The profile [id] follows the cloud doc - one identity per account.
     */
    fun reloadFromDisk() {
        val doc = readDocument() ?: return
        synchronized(lock) { _state.value = State(doc.id, doc.name, doc.createdAtMs) }
        onNameApplied?.invoke(doc.name)
    }

    /**
     * Device linking (SVC-9): adopt another device's durable profile [newId] (name kept until the first pull
     * replaces it). Persists. Does NOT fire [onNameApplied] - the name is unchanged.
     */
    fun adoptIdentity(newId: String) = synchronized(lock) {
        if (newId.isBlank()) return@synchronized
        _state.value = _state.value.copy(id = newId)
        save()
    }

    /**
     * Account deletion: erase the persisted profile and mint a BRAND-NEW identity (fresh id, empty
     * name, new createdAtMs) so a re-created account starts clean; persists it and mirrors the empty name.
     */
    fun reset() {
        synchronized(lock) {
            runCatching { file.delete() }
            _state.value = State(UUID.randomUUID().toString().uppercase(), "", System.currentTimeMillis().toDouble())
            save()
        }
        onNameApplied?.invoke("")
    }

    private fun readDocument(): Document? = runCatching {
        if (!file.exists()) null
        else PdjJson.lenient.decodeFromString(Document.serializer(), file.readText())
    }.getOrNull()

    private fun save() {
        val s = _state.value
        val text = PdjJson.lenient.encodeToString(Document.serializer(), Document(SCHEMA_VERSION, s.id, s.name, s.createdAtMs))
        runCatching {
            file.parentFile?.mkdirs()
            val tmp = File(file.parentFile, file.name + ".tmp")
            tmp.writeText(text)
            if (!tmp.renameTo(file)) { file.delete(); if (!tmp.renameTo(file)) tmp.copyTo(file, overwrite = true) }
        }
    }

    companion object {
        const val FILE_NAME = "pocketdj-profile.json"
        const val SCHEMA_VERSION = 1
    }
}

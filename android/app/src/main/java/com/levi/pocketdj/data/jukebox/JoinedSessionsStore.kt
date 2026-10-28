package com.levi.pocketdj.data.jukebox

import androidx.datastore.core.DataStore
import androidx.datastore.preferences.core.Preferences
import androidx.datastore.preferences.core.edit
import androidx.datastore.preferences.core.stringPreferencesKey
import java.io.IOException
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.first
import kotlinx.coroutines.flow.update
import kotlinx.coroutines.launch
import kotlinx.coroutines.sync.Mutex
import kotlinx.coroutines.sync.withLock
import kotlinx.serialization.Serializable
import kotlinx.serialization.builtins.ListSerializer
import kotlinx.serialization.json.Json

/** One joined jukebox: same JSON as iOS `pdj.jukebox.joined.list.v1` -> `[{id,name,guestBase}]`. */
@Serializable
data class JoinedSession(
    val id: String,
    val name: String? = null,
    val guestBase: String? = null,
) {
    fun link(): JukeboxLink? = JukeboxLink.forEntry(id, guestBase)
}

/** Raw persistence for the joined-list JSON string (swappable in tests). */
interface JoinedSessionsStorage {
    suspend fun read(): String?
    suspend fun write(json: String)
}

class DataStoreJoinedStorage(private val dataStore: DataStore<Preferences>) : JoinedSessionsStorage {
    private val key = stringPreferencesKey("pdj.jukebox.joined.list.v1")

    override suspend fun read(): String? =
        try {
            dataStore.data.first()[key]
        } catch (e: IOException) {
            null
        }

    override suspend fun write(json: String) {
        dataStore.edit { it[key] = json }
    }
}

/**
 * The persisted list of jukeboxes this device joined as a guest (iOS `JukeboxStore.joinedSessions`).
 * In-memory [sessions] is the source of truth and mutates synchronously (so the deep-link route
 * resolver sees an add immediately); persistence is a serialized background write. A corrupt
 * persisted blob folds to an empty list.
 */
class JoinedSessionsStore(
    private val storage: JoinedSessionsStorage,
    private val scope: CoroutineScope,
    private val json: Json = Json { ignoreUnknownKeys = true; coerceInputValues = true },
) {
    private val serializer = ListSerializer(JoinedSession.serializer())
    private val _sessions = MutableStateFlow<List<JoinedSession>>(emptyList())
    val sessions: StateFlow<List<JoinedSession>> = _sessions

    private val writeLock = Mutex()
    @Volatile private var loaded = false

    fun contains(id: String): Boolean = _sessions.value.any { it.id == id }

    /**
     * Load the persisted list once. Entries added before the load finished stay on top (they are
     * newer than anything on disk).
     */
    suspend fun load() {
        if (loaded) return
        val persisted = decode(storage.read())
        _sessions.update { current ->
            loaded = true
            val currentIds = current.mapTo(HashSet()) { it.id }
            current + persisted.filter { it.id !in currentIds }
        }
    }

    /** Idempotent by id: an existing entry moves to the top (keeping its known name). */
    fun addJoined(link: JukeboxLink) {
        _sessions.update { list ->
            val existing = list.firstOrNull { it.id == link.jukeboxId }
            val entry = JoinedSession(
                id = link.jukeboxId,
                name = existing?.name,
                guestBase = link.guestBase ?: existing?.guestBase,
            )
            listOf(entry) + list.filter { it.id != link.jukeboxId }
        }
        persist()
    }

    fun remove(id: String) {
        _sessions.update { list -> list.filter { it.id != id } }
        persist()
    }

    /** Record the display name from a state.json read; empty/blank/unchanged names are ignored. */
    fun updateName(id: String, name: String?) {
        val clean = name?.trim().orEmpty()
        if (clean.isEmpty()) return
        var changed = false
        _sessions.update { list ->
            changed = false
            list.map {
                if (it.id == id && it.name != clean) {
                    changed = true
                    it.copy(name = clean)
                } else {
                    it
                }
            }
        }
        if (changed) persist()
    }

    fun encode(list: List<JoinedSession>): String = json.encodeToString(serializer, list)

    fun decode(raw: String?): List<JoinedSession> {
        if (raw.isNullOrBlank()) return emptyList()
        return runCatching { json.decodeFromString(serializer, raw) }
            .getOrDefault(emptyList())
            .filter { it.id.isNotEmpty() }
    }

    private fun persist() {
        scope.launch {
            writeLock.withLock { storage.write(encode(_sessions.value)) }
        }
    }
}

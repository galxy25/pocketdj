package com.levi.pocketdj.data.games.friends

import com.levi.pocketdj.data.catalog.IndexSong
import com.levi.pocketdj.data.games.GameKind
import com.levi.pocketdj.data.games.GameScoreboardStore
import com.levi.pocketdj.data.games.puzzle.CollectorsPuzzleEngine
import com.levi.pocketdj.data.jukebox.JukeboxExternalMatch
import com.levi.pocketdj.data.jukebox.JukeboxMatcher
import com.levi.pocketdj.playback.RunItem
import java.util.concurrent.ConcurrentHashMap
import kotlinx.coroutines.CancellationException
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.asStateFlow
import kotlinx.coroutines.flow.update
import kotlinx.coroutines.withContext
import kotlinx.serialization.builtins.ListSerializer
import kotlinx.serialization.builtins.serializer

/** The shared-queue surface the leader's "queue accepted songs" nicety drives. */
interface MwFQueueSink {
    /** Source tag of whatever run is sounding (null when idle). */
    val runningSourceTag: String?
    val isRunning: Boolean
    fun append(item: RunItem)
    fun play(item: RunItem)
}

/** Everything the store needs from the rest of the app (wired in GamesGraph, faked in tests). */
interface MwFHost {
    fun songs(): List<IndexSong>
    val external: JukeboxExternalMatch get() = JukeboxExternalMatch.None
    fun songExists(songId: String): Boolean
    fun songIdForAppleMusicId(appleMusicId: String): String?
    fun profileName(): String
    val queue: MwFQueueSink?
    fun createPocket(name: String, songIds: List<String>, description: String?): String
    fun pocketExists(pocketId: String): Boolean
    fun addSongToPocket(songId: String, pocketId: String)
    /** Song ids already in the pocket (so a re-download reports only what it really added). */
    fun pocketSongIds(pocketId: String): List<String>
}

/** Result of [MusicWithFriendsStore.downloadCollection]. */
data class MwFDownloadResult(val pocketId: String, val added: Int, val unresolved: Int)

/**
 * APP-SCOPED Music with Friends engine (iOS `MusicWithFriendsStore`): persisted session list,
 * deep-link signals, 401 recovery, ended-fold, score-once, leader verbs, collection download.
 * Polling is the source of truth (the session screen owns a 4 s loop calling [refresh]); push is
 * not ported (the broker speaks APNs only).
 */
class MusicWithFriendsStore(
    private val client: MwFClient,
    private val sessionFile: MwFSessionFile,
    private val kv: MwFKeyValue,
    private val joinSecret: MwFJoinSecret,
    private val scoreboard: GameScoreboardStore,
    private val host: MwFHost,
    private val clientId: suspend () -> String,
    private val clock: () -> Double = { System.currentTimeMillis().toDouble() },
) {
    private val _sessions = MutableStateFlow<List<MwFSessionEntry>>(emptyList())
    /** Leader + joined sessions, newest first. */
    val sessions: StateFlow<List<MwFSessionEntry>> = _sessions.asStateFlow()

    private val _pendingOpenId = MutableStateFlow<String?>(null)
    val pendingOpenId: StateFlow<String?> = _pendingOpenId.asStateFlow()
    private val _pendingJoin = MutableStateFlow<MwFLink?>(null)
    val pendingJoin: StateFlow<MwFLink?> = _pendingJoin.asStateFlow()

    private val _creating = MutableStateFlow(false)
    val creating: StateFlow<Boolean> = _creating.asStateFlow()
    private val _joining = MutableStateFlow(false)
    val joining: StateFlow<Boolean> = _joining.asStateFlow()

    /** Leader-verb / +1 errors PER SESSION (create/join never write here; they return their error). */
    private val _lastErrors = MutableStateFlow<Map<String, String>>(emptyMap())
    val lastErrors: StateFlow<Map<String, String>> = _lastErrors.asStateFlow()
    /** The poll's own error PER SESSION. */
    private val _pollErrors = MutableStateFlow<Map<String, String>>(emptyMap())
    val pollErrors: StateFlow<Map<String, String>> = _pollErrors.asStateFlow()
    private val _lastState = MutableStateFlow<Map<String, MwFState>>(emptyMap())
    val lastState: StateFlow<Map<String, MwFState>> = _lastState.asStateFlow()

    private val _queueAccepted = MutableStateFlow(false)
    val queueAccepted: StateFlow<Boolean> = _queueAccepted.asStateFlow()

    private val scored = ConcurrentHashMap.newKeySet<String>()
    private val recovering = ConcurrentHashMap.newKeySet<String>()
    private val stringList = ListSerializer(String.serializer())

    fun entry(id: String): MwFSessionEntry? = _sessions.value.firstOrNull { it.id == id }

    // ---- Persistence ----

    fun loadPersisted() {
        _sessions.value = sessionFile.load()
        scored.clear()
        kv.getString(SCORED_KEY)?.let { raw ->
            runCatching { com.levi.pocketdj.data.PdjJson.lenient.decodeFromString(stringList, raw) }
                .getOrNull()?.let { scored.addAll(it) }
        }
        _queueAccepted.value = kv.getString(QUEUE_ACCEPTED_KEY) == "true"
    }

    private fun rememberDisplayName(name: String) {
        val n = name.trim()
        if (n.isNotEmpty()) kv.putString(DISPLAY_NAME_KEY, n)
    }

    private fun persistSessions() = sessionFile.save(_sessions.value)

    private fun persistScored() {
        kv.putString(SCORED_KEY, com.levi.pocketdj.data.PdjJson.lenient.encodeToString(stringList, scored.toList().sorted()))
    }

    fun setQueueAccepted(on: Boolean) {
        if (_queueAccepted.value == on) return
        _queueAccepted.value = on
        kv.putString(QUEUE_ACCEPTED_KEY, if (on) "true" else null)
    }

    /** Account-deletion seam: forget every MwF trace (the join secret is reset separately). */
    fun eraseAll() {
        _sessions.value = emptyList()
        _lastState.value = emptyMap()
        _lastErrors.value = emptyMap()
        _pollErrors.value = emptyMap()
        scored.clear()
        _pendingOpenId.value = null
        _pendingJoin.value = null
        _queueAccepted.value = false
        sessionFile.delete()
        kv.putString(SCORED_KEY, null)
        kv.putString(QUEUE_ACCEPTED_KEY, null)
        kv.putString(DISPLAY_NAME_KEY, null)
    }

    // ---- Create / join / open ----

    /** Create a session. Returns the error to show (null = success); never writes a shared field. */
    suspend fun create(name: String, theme: String, displayName: String, settings: MwFSettings): String? {
        if (!_creating.compareAndSet(expect = false, update = true)) return "A session is already being created."
        try {
            val r = client.create(name, theme, displayName, clientId(), joinSecret.current(), settings)
            val sid = r.sessionId
            val mid = r.memberId
            val mk = r.memberKey
            if (sid == null || mid == null || mk == null) return "The server's create reply was incomplete."
            val entry = MwFSessionEntry(
                id = sid, memberId = mid, memberKey = mk, leaderKey = r.leaderKey,
                name = r.name ?: name, theme = r.theme ?: theme, url = r.url, apiBase = null,
                expiresAt = r.expiresAt, pocketId = null, joinedAt = clock(),
            )
            _sessions.update { listOf(entry) + it.filterNot { e -> e.id == sid } }
            persistSessions()
            rememberDisplayName(displayName)
            _pendingOpenId.value = sid
            return null
        } catch (e: MwFException) {
            return if (e.code == 404) unavailableMessage(null) else e.message
        } finally {
            _creating.value = false
        }
    }

    /**
     * A raw 404 from `/mwf` usually means the broker predates v3. Probe `/health`: version < 3 or
     * `mwf != true` turns the bare 404 into an actionable "older server" message.
     */
    private suspend fun unavailableMessage(base: String?): String {
        val health = runCatching { client.health(base) }.getOrNull()
        if (health != null && ((health.version ?: 0) < 3 || health.mwf != true)) {
            return "The jukebox server is running an older version without Music with Friends" +
                " — update it (scripts/update-jukeboxserver.sh on the host) and try again."
        }
        return "Music with Friends isn't available on this server (HTTP 404)."
    }

    /**
     * A tapped `/mwf/` link: an unknown session raises [pendingJoin]; BOTH branches raise
     * [pendingOpenId] (the only signal the shell watches, so a link works from any tab).
     */
    fun handleOpenedLink(link: MwFLink) {
        if (_sessions.value.none { it.id == link.sessionId }) _pendingJoin.value = link
        _pendingOpenId.value = link.sessionId
    }

    /** Atomic take of the open signal. */
    fun consumePendingOpenId(): String? {
        while (true) {
            val cur = _pendingOpenId.value ?: return null
            if (_pendingOpenId.compareAndSet(cur, null)) return cur
        }
    }

    fun clearPendingJoin() {
        _pendingJoin.value = null
    }

    /** Join a session. Returns the error to show (null = success), like [create]. */
    suspend fun join(link: MwFLink, name: String): String? {
        if (!_joining.compareAndSet(expect = false, update = true)) return "A join is already in flight."
        try {
            if (entry(link.sessionId) != null) {
                _pendingJoin.value = null
                _pendingOpenId.value = link.sessionId
                return null
            }
            // Best-effort public state.json: apiBase + theme (no-preconfig join).
            var apiBase: String? = null
            var theme: String? = null
            var sessionName: String? = null
            runCatching { client.publicState(link.stateUrl) }.getOrNull()?.let {
                apiBase = it.apiBase; theme = it.theme; sessionName = it.name
            }
            try {
                val r = client.join(apiBase, link.sessionId, name, clientId(), joinSecret.current(), null)
                val mid = r.memberId
                val mk = r.memberKey
                if (mid == null || mk == null) return "The server's join reply was incomplete."
                val base = link.guestBase ?: "https://${MwFLink.UNIVERSAL_HOST}"
                val entry = MwFSessionEntry(
                    id = link.sessionId, memberId = mid, memberKey = mk, leaderKey = null,
                    name = r.sessionName ?: sessionName, theme = r.theme ?: theme,
                    url = "$base/mwf/${link.sessionId}/", apiBase = apiBase,
                    expiresAt = r.expiresAt, pocketId = null, joinedAt = clock(),
                )
                _sessions.update { listOf(entry) + it }
                persistSessions()
                rememberDisplayName(name)
                _pendingJoin.value = null
                _pendingOpenId.value = link.sessionId
                return null
            } catch (e: MwFException) {
                return if (e.code == 404) unavailableMessage(apiBase) else e.message
            }
        } finally {
            _joining.value = false
        }
    }

    // ---- Polling + verbs ----

    /** One poll turn. 404/410 folds the session locally and records the final score once. */
    suspend fun refresh(id: String): MwFState? {
        val entry = entry(id) ?: return null
        try {
            val st = client.state(entry)
            applyFresh(id, st)
            setPollError(id, null)
            return st
        } catch (e: MwFException) {
            when {
                e.code == 401 -> {
                    // The broker forgot our memberKey: recover (single-flight), retry once.
                    if (recoverMembership(id)) {
                        val rebound = entry(id)
                        val st = rebound?.let { runCatching { client.state(it) }.getOrNull() }
                        if (st != null) {
                            applyFresh(id, st, touchEntry = false)
                            setPollError(id, null)
                            return st
                        }
                    }
                    setPollError(id, "The server no longer recognizes this device — try leaving and rejoining.")
                    return _lastState.value[id]
                }
                e.code == 404 || e.code == 410 -> {
                    foldEnded(id)
                    recordFinalScoreIfNeeded(id)
                    return _lastState.value[id]
                }
                else -> {
                    setPollError(id, e.message ?: "Network error")
                    return _lastState.value[id]
                }
            }
        }
    }

    private fun applyFresh(id: String, st: MwFState, touchEntry: Boolean = true) {
        _lastState.update { it + (id to st) }
        if (touchEntry) {
            var changed = false
            _sessions.update { list ->
                list.map { e ->
                    if (e.id != id) e else {
                        val next = e.copy(
                            name = st.name ?: e.name,
                            theme = st.theme ?: e.theme,
                            expiresAt = st.expiresAt ?: e.expiresAt,
                        )
                        if (next != e) changed = true
                        next
                    }
                }
            }
            if (changed) persistSessions()
        }
        if (st.ended == true) recordFinalScoreIfNeeded(id)
    }

    private fun foldEnded(id: String) {
        _lastState.update { m ->
            val cur = m[id] ?: MwFState(sessionId = id)
            m + (id to cur.copy(ended = true))
        }
    }

    private fun setPollError(id: String, msg: String?) =
        _pollErrors.update { if (msg == null) it - id else it + (id to msg) }

    private fun setLastError(id: String, msg: String?) =
        _lastErrors.update { if (msg == null) it - id else it + (id to msg) }

    /**
     * Re-establish membership after the broker forgot us: present the stored memberKey first,
     * then the joinSecret alone (mints a fresh member). Single-flight per session.
     */
    suspend fun recoverMembership(id: String): Boolean {
        val e = entry(id) ?: return false
        if (!recovering.add(id)) return false
        try {
            val display = kv.getString(DISPLAY_NAME_KEY)?.trim()?.takeIf { it.isNotEmpty() }
                ?: _lastState.value[id]?.members?.firstOrNull { it.memberId == e.memberId }?.name?.trim()?.takeIf { it.isNotEmpty() }
                ?: host.profileName().trim().ifEmpty { "Player" }
            for (presented in listOf<String?>(e.memberKey, null)) {
                val r = runCatching {
                    client.join(e.apiBase, id, display, clientId(), joinSecret.current(), presented)
                }.getOrNull() ?: continue
                val mid = r.memberId ?: continue
                val mk = r.memberKey ?: continue
                _sessions.update { list -> list.map { if (it.id == id) it.copy(memberId = mid, memberKey = mk) else it } }
                persistSessions()
                return true
            }
            return false
        } finally {
            recovering.remove(id)
        }
    }

    /** Suggest a song. THROWS (409 = not your turn) so the screen can surface it. */
    suspend fun suggest(id: String, title: String, artist: String) {
        val entry = entry(id) ?: return
        client.suggest(entry, title, artist)
        refresh(id)
    }

    suspend fun plusOne(id: String, suggestionId: String) {
        val entry = entry(id) ?: return
        setLastError(id, null)
        try {
            client.plusOne(entry, suggestionId)
            refresh(id)
        } catch (e: MwFException) {
            setLastError(id, e.message)
        }
    }

    // ---- Leader verbs ----

    /** Accept: run the matcher first so the decision carries a playable match, then decide. */
    suspend fun approve(id: String, suggestion: MwFSuggestion) {
        val entry = entry(id) ?: return
        val sgId = suggestion.id ?: return
        if (!entry.isLeader) return
        setLastError(id, null)
        val title = suggestion.title.orEmpty()
        val artist = suggestion.artist.orEmpty()
        var match = MwFMatch(title = title, artist = artist)
        val hit = withContext(Dispatchers.Default) {
            JukeboxMatcher.match(title, artist, host.songs()) ?: try {
                host.external.match(title, artist)
            } catch (c: CancellationException) {
                throw c
            } catch (_: Exception) {
                null
            }
        }
        if (hit != null) {
            match = MwFMatch(songId = hit.id, appleMusicId = hit.appleMusicId, title = hit.name, artist = hit.artist, lengthMs = hit.length)
        }
        try {
            client.decide(entry, sgId, "accepted", match)
            if (_queueAccepted.value) queueMatchIfPlayable(match)
            refresh(id)
        } catch (e: MwFException) {
            setLastError(id, e.message)
        }
    }

    suspend fun reject(id: String, suggestion: MwFSuggestion) {
        val entry = entry(id) ?: return
        val sgId = suggestion.id ?: return
        if (!entry.isLeader) return
        setLastError(id, null)
        try {
            client.decide(entry, sgId, "rejected", null)
            refresh(id)
        } catch (e: MwFException) {
            setLastError(id, e.message)
        }
    }

    suspend fun updateSettings(id: String, settings: MwFSettings) {
        val entry = entry(id) ?: return
        if (!entry.isLeader) return
        setLastError(id, null)
        try {
            val confirmed = client.configure(entry, settings)
            _lastState.update { m -> m[id]?.let { m + (id to it.copy(settings = confirmed)) } ?: m }
        } catch (e: MwFException) {
            setLastError(id, e.message)
        }
    }

    suspend fun endSession(id: String) {
        val entry = entry(id) ?: return
        if (!entry.isLeader) return
        setLastError(id, null)
        try {
            client.end(entry)
        } catch (e: MwFException) {
            setLastError(id, e.message)
        }
        // Local fold regardless: an unreachable broker must not trap the leader.
        _lastState.update { m -> m[id]?.let { m + (id to it.copy(ended = true)) } ?: m }
        recordFinalScoreIfNeeded(id)
    }

    // ---- Scores ----

    fun myScore(state: MwFState): Int {
        val you = state.you?.memberId ?: _sessions.value.firstOrNull { it.id == state.sessionId }?.memberId
        return state.score(you)
    }

    /**
     * Record the local user's final score ONCE per session (persisted set), only when the session
     * is over (ended observed, or the entry aged past expiry; cached state stands in).
     */
    fun recordFinalScoreIfNeeded(id: String) {
        val entry = entry(id) ?: return
        val st = _lastState.value[id]
        val expired = entry.expiresAt?.let { clock() > it } ?: false
        if (st?.ended != true && !expired) return
        if (!scored.add(id)) return
        val theme = st?.theme ?: entry.theme
        val detail = buildMap {
            put("sessionId", id)
            if (theme != null) put("theme", theme)
        }
        scoreboard.record(
            game = GameKind.MusicWithFriends,
            score = st?.let { myScore(it) } ?: 0,
            settingsSummary = theme?.take(60),
            detail = detail,
        )
        persistScored()
    }

    /** Leave locally (server membership persists). Records the score if due, then forgets it. */
    fun leave(id: String) {
        recordFinalScoreIfNeeded(id)
        _sessions.update { list -> list.filterNot { it.id == id } }
        persistSessions()
        _lastState.update { it - id }
        setLastError(id, null)
        setPollError(id, null)
    }

    // ---- Queue-accepted nicety ----

    /** Append to a running queue or start one; NEVER while a puzzle round owns the queue. */
    fun queueMatchIfPlayable(match: MwFMatch) {
        val sink = host.queue ?: return
        val songId = match.songId ?: return // Android has no AM-only playable rung
        val item = RunItem(songId, match.title.orEmpty(), match.artist, match.lengthMs)
        if (sink.runningSourceTag?.startsWith(CollectorsPuzzleEngine.RUN_TAG_PREFIX) == true) return
        if (sink.isRunning) sink.append(item) else sink.play(item)
    }

    // ---- Collection download ----

    /**
     * Materialize the session collection as pocket "MwF — <name>" (idempotent via entry.pocketId;
     * a re-download adds missing members). Entries that resolve to no local song are counted in
     * [MwFDownloadResult.unresolved]. Null when the collection is empty / session unknown.
     */
    fun downloadCollection(id: String, state: MwFState): MwFDownloadResult? {
        val entries = state.collection.orEmpty()
        if (entries.isEmpty()) return null
        val memberIds = ArrayList<String>()
        var unresolved = 0
        for (e in entries) {
            val sid = e.songId?.takeIf { host.songExists(it) }
                ?: e.appleMusicId?.let { host.songIdForAppleMusicId(it) }
            if (sid != null) memberIds += sid else unresolved++
        }
        val distinct = memberIds.distinct()
        val existing = entry(id)?.pocketId?.takeIf { host.pocketExists(it) }
        if (existing != null) {
            val already = host.pocketSongIds(existing).toSet()
            val fresh = distinct.filterNot { it in already }
            fresh.forEach { host.addSongToPocket(it, existing) }
            return MwFDownloadResult(existing, fresh.size, unresolved)
        }
        if (distinct.isEmpty()) return null
        val pocketId = host.createPocket("MwF — ${state.name ?: "Session"}", distinct, state.theme)
        _sessions.update { list -> list.map { if (it.id == id) it.copy(pocketId = pocketId) else it } }
        persistSessions()
        return MwFDownloadResult(pocketId, distinct.size, unresolved)
    }

    companion object {
        const val SCORED_KEY = "mwfScoredSessionIds"
        const val QUEUE_ACCEPTED_KEY = "mwfQueueAccepted"
        const val DISPLAY_NAME_KEY = "mwfDisplayName"
    }
}

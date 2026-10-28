package com.levi.pocketdj.mix.store

import com.levi.pocketdj.data.PdjJson
import com.levi.pocketdj.data.store.VersionedJsonWriter
import java.io.File
import java.util.UUID
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.asStateFlow
import kotlinx.serialization.encodeToString

/**
 * App-side store for mix sessions: what you played + the time-stamped action log of a mixing
 * sitting, kept until Reset. Persists to `pocketdj-mix-sessions.json` (schema 2) over the
 * shared [VersionedJsonWriter]. The hot recording buffer is private and NOT observable (fader
 * events must not recompose the Mix UI); only the session name, the sessions list, and a
 * [playedRevision] tick are exposed as flows.
 */
class MixSessionStore(
    private val file: File,
    private val writer: VersionedJsonWriter = VersionedJsonWriter(file),
    private val clock: () -> Long = System::currentTimeMillis,
    private val scheduler: StoreScheduler = StoreScheduler.DEFAULT,
    private val newId: () -> String = { UUID.randomUUID().toString().take(12) },
) : MixSessionRecorder {

    private val lock = Any()

    private val _sessions = MutableStateFlow<List<MixSession>>(emptyList())
    private val _currentId = MutableStateFlow("")
    private val _currentName = MutableStateFlow("Session 1")
    private val _playedRevision = MutableStateFlow(0)

    /** Finalized + current sessions (the current one's events here are a folded snapshot). */
    val sessions: StateFlow<List<MixSession>> = _sessions.asStateFlow()
    val currentIdFlow: StateFlow<String> = _currentId.asStateFlow()
    /** Own flow so the toolbar title invalidates only on rename / new session. */
    val currentNameFlow: StateFlow<String> = _currentName.asStateFlow()
    /** Bumped whenever the played-set changes (loader checkmarks). */
    val playedRevisionFlow: StateFlow<Int> = _playedRevision.asStateFlow()

    val currentId: String get() = _currentId.value
    val currentName: String get() = _currentName.value
    val playedRevision: Int get() = _playedRevision.value

    // Hot buffer for the CURRENT session.
    private var recEvents = ArrayList<MixSessionEvent>()
    private var recPlayed = ArrayList<String>()
    private var recStartedAt = 0.0
    private var recSeq = 0
    private var counter = 0
    private var hasActivity = false
    private var resumePendingReanchor = false

    private var saveVersion = 0L
    private var pendingSave: Cancellable? = null
    private var saveGen = 0L

    /** The on-disk document (cloud-sync registration reads the same file). */
    val syncFile: File get() = file

    private val nowMs: Double get() = clock().toDouble()

    init {
        synchronized(lock) {
            readDocument()?.let { applyDocument(it) }
            if (_currentId.value.isEmpty()) startNewSession(save = false)
        }
    }

    private fun readDocument(): MixSessionsDocument? = try {
        if (file.exists()) PdjJson.lenient.decodeFromString<MixSessionsDocument>(file.readText()) else null
    } catch (_: Exception) {
        null
    }

    /** Adopt a decoded doc and resume the previously-current session (lasts until Reset). */
    private fun applyDocument(doc: MixSessionsDocument) {
        _sessions.value = doc.sessions
        counter = doc.counter
        val cur = doc.currentId?.let { cid -> doc.sessions.firstOrNull { it.id == cid } } ?: return
        _currentId.value = cur.id
        _currentName.value = cur.name
        recEvents = ArrayList(cur.events)
        recPlayed = ArrayList(cur.playedSongIds)
        recStartedAt = cur.startedAt
        recSeq = cur.events.size
        hasActivity = cur.events.isNotEmpty()
        resumePendingReanchor = hasActivity   // rebase t0 on the first NEW action (skip the offline gap)
    }

    /**
     * Anchor t0 on the FIRST activity. Fresh session: "now" (tMs starts at 0). Resumed session:
     * rebase so the first new event lands just PAST the coalesce window after the last saved
     * event - contiguous (offline gap dropped) yet a DISTINCT event.
     */
    private fun anchorOnFirstActivity() {
        if (!hasActivity) {
            recStartedAt = nowMs; hasActivity = true
        } else if (resumePendingReanchor) {
            recStartedAt = nowMs - ((recEvents.lastOrNull()?.tMs ?: 0) + COALESCE_WINDOW_MS).toDouble()
            resumePendingReanchor = false
        }
    }

    // Recorder

    override fun logEvent(
        kind: MixEventKind, deck: String?, songId: String?, title: String?, artist: String?,
        bpm: Double?, camelot: String?, param: String?, value: Double?, flag: Boolean?,
        posMs: Int?, slot: Int?,
    ) = synchronized(lock) {
        anchorOnFirstActivity()
        val tMs = maxOf(0, (nowMs - recStartedAt).toInt())

        // Coalesce a continuous run into the LAST event when (kind, deck, param, slot) match and
        // it is still inside its 120 ms bucket: keep bucket-start tMs, take the final value.
        val last = recEvents.lastOrNull()
        if (kind.isContinuous && last != null && last.kind == kind && last.deck == deck &&
            last.param == param && last.slot == slot && tMs - last.tMs < COALESCE_WINDOW_MS
        ) {
            recEvents[recEvents.lastIndex] = last.copy(value = value, posMs = posMs)
            scheduleSave()
            return@synchronized
        }

        if (recEvents.size >= MAX_EVENTS) return@synchronized   // soft cap
        recSeq += 1
        recEvents.add(
            MixSessionEvent(
                id = "e$recSeq", tMs = tMs, kind = kind, deck = deck, songId = songId, title = title,
                artist = artist, bpm = bpm, camelot = camelot, param = param, value = value,
                flag = flag, posMs = posMs, slot = slot,
            ),
        )
        if (kind.isContinuous) scheduleSave() else saveNow()
    }

    override fun logGlide(
        deck: String?, param: String, songId: String?, title: String?, artist: String?,
        from: Double, to: Double, rate: Double, posMs: Int?, slot: Int?,
    ) = synchronized(lock) {
        anchorOnFirstActivity()
        val tMs = maxOf(0, (nowMs - recStartedAt).toInt())
        if (recEvents.size >= MAX_EVENTS) return@synchronized
        recSeq += 1
        recEvents.add(
            MixSessionEvent(
                id = "e$recSeq", tMs = tMs, kind = MixEventKind.Glide, deck = deck, songId = songId,
                title = title, artist = artist, param = param, value = to, posMs = posMs,
                fromValue = from, rate = rate, slot = slot,
            ),
        )
        saveNow()
    }

    override fun notePlayed(songId: String) {
        if (songId.isEmpty()) return
        synchronized(lock) {
            anchorOnFirstActivity()
            if (recPlayed.contains(songId)) return
            recPlayed.add(songId)
            _playedRevision.value += 1
            saveNow()
        }
    }

    override fun hasPlayed(songId: String): Boolean = synchronized(lock) { recPlayed.contains(songId) }

    // Recordings (metadata only; the audio files belong to the recorder package)

    /** Attach a finished take to a session. Returns the allocated id, null if the session is gone. */
    fun addRecording(
        toSession: String, fileName: String, startedAt: Double, durationMs: Int, wasUserFolder: Boolean = false,
    ): String? = synchronized(lock) {
        val list = _sessions.value
        val i = list.indexOfFirst { it.id == toSession }
        if (i < 0) return null
        val seq = (list[i].recordings?.size ?: 0) + 1
        val rec = MixRecording("rec$seq", fileName, startedAt, durationMs, wasUserFolder)
        _sessions.value = list.toMutableList().also { it[i] = list[i].copy(recordings = list[i].recordingsList + rec) }
        saveNow()
        rec.id
    }

    fun recordings(forSession: String): List<MixRecording> = synchronized(lock) { session(forSession)?.recordingsList ?: emptyList() }

    /** Re-file a take whose session was DELETED mid-capture (revives it as a minimal finalized session). */
    fun recoverRecording(
        sessionId: String, name: String, fileName: String, startedAt: Double, durationMs: Int,
        wasUserFolder: Boolean = false,
    ) {
        if (sessionId.isEmpty()) return
        synchronized(lock) {
            if (_sessions.value.none { it.id == sessionId }) {
                _sessions.value = _sessions.value + MixSession(
                    id = sessionId, name = name, startedAt = startedAt,
                    endedAt = startedAt + durationMs, recordings = emptyList(),
                )
            }
            addRecording(sessionId, fileName, startedAt, durationMs, wasUserFolder)
        }
    }

    /** Drop one take's metadata. Returns true when a record was removed. */
    fun removeRecording(sessionId: String, recordingId: String): Boolean = synchronized(lock) {
        val list = _sessions.value
        val i = list.indexOfFirst { it.id == sessionId }
        if (i < 0 || list[i].recordingsList.none { it.id == recordingId }) return false
        _sessions.value = list.toMutableList().also {
            it[i] = list[i].copy(recordings = list[i].recordingsList.filterNot { r -> r.id == recordingId })
        }
        saveNow()
        true
    }

    // Readers

    fun session(id: String): MixSession? = _sessions.value.firstOrNull { it.id == id }
    val current: MixSession? get() = session(currentId)

    /** Sessions newest-first by start time (the current one reads its live t0). */
    val sessionsNewestFirst: List<MixSession>
        get() = synchronized(lock) { foldedSessions().sortedByDescending { it.startedAt } }

    fun events(forSession: String): List<MixSessionEvent> = synchronized(lock) {
        if (forSession == currentId) ArrayList(recEvents) else session(forSession)?.events ?: emptyList()
    }

    fun playedSongIds(forSession: String): List<String> = synchronized(lock) {
        if (forSession == currentId) ArrayList(recPlayed) else session(forSession)?.playedSongIds ?: emptyList()
    }

    fun durationMs(forSession: String): Int = synchronized(lock) {
        if (forSession == currentId) recEvents.lastOrNull()?.tMs ?: 0 else session(forSession)?.durationMs ?: 0
    }

    fun startedAt(forSession: String): Double = synchronized(lock) {
        if (forSession == currentId) recStartedAt else session(forSession)?.startedAt ?: 0.0
    }

    // Lifecycle

    /** Reset: finalize the current session, start a fresh one. No-op if it has no activity. */
    fun reset() = synchronized(lock) {
        if (!hasActivity) return@synchronized
        foldCurrentIntoSessions(endedAt = nowMs)
        startNewSession(save = true)
    }

    fun rename(id: String, name: String) = synchronized(lock) {
        val n = name.trim()
        val list = _sessions.value
        val i = list.indexOfFirst { it.id == id }
        if (n.isEmpty() || i < 0) return@synchronized
        _sessions.value = list.toMutableList().also { it[i] = list[i].copy(name = n) }
        if (id == currentId) _currentName.value = n
        saveNow()
    }

    fun delete(id: String) = synchronized(lock) {
        _sessions.value = _sessions.value.filterNot { it.id == id }
        if (id == currentId) {
            // Re-establish the always-a-current invariant.
            _currentId.value = ""
            startNewSession(save = false)
        }
        saveNow()
    }

    /** FULL wipe: every session, the counter, and the persisted file (version-ordered delete). */
    fun clear() = synchronized(lock) {
        cancelPending()
        _sessions.value = emptyList()
        _currentId.value = ""
        counter = 0
        recEvents = ArrayList()
        recPlayed = ArrayList()
        recStartedAt = 0.0
        recSeq = 0
        hasActivity = false
        resumePendingReanchor = false
        _playedRevision.value += 1
        startNewSession(save = false)
        saveVersion += 1
        writer.deleteNow(saveVersion)   // synchronous, like iOS: no flush can race a queued delete
    }

    /**
     * Re-decode the on-disk document after a cloud pull (whole-document LWW). Guarded: an
     * actively-recording session is never clobbered mid-take.
     */
    fun reloadFromDisk() = synchronized(lock) {
        if (hasActivity && recEvents.isNotEmpty()) return@synchronized
        val doc = readDocument() ?: return@synchronized
        _sessions.value = doc.sessions
        counter = doc.counter
        val cur = doc.currentId?.let { cid -> doc.sessions.firstOrNull { it.id == cid } }
        if (cur != null) {
            applyDocument(doc)
        } else if (_currentId.value.isEmpty() || _sessions.value.none { it.id == _currentId.value }) {
            startNewSession(save = false)
        }
        _playedRevision.value += 1
    }

    /**
     * Force-persist synchronously (scene -> background), beating any queued write. A virgin
     * state never MATERIALIZES the file (so a fresh install can't out-LWW the user's cloud copy).
     */
    fun flush() = synchronized(lock) {
        val virgin = recEvents.isEmpty() && recPlayed.isEmpty() &&
            _sessions.value.all { it.events.isEmpty() && it.playedSongIds.isEmpty() }
        if (virgin && !file.exists()) return@synchronized
        cancelPending()
        saveVersion += 1
        val doc = snapshotDocument()
        writer.flushNow(saveVersion) { PdjJson.lenient.encodeToString(doc) }
    }

    // Internals

    private fun foldedSessions(): List<MixSession> = _sessions.value.map { s ->
        if (s.id != currentId) s
        else s.copy(events = ArrayList(recEvents), playedSongIds = ArrayList(recPlayed), startedAt = recStartedAt)
    }

    private fun foldCurrentIntoSessions(endedAt: Double?) {
        val list = _sessions.value
        val i = list.indexOfFirst { it.id == currentId }
        if (i < 0) return
        _sessions.value = list.toMutableList().also {
            it[i] = list[i].copy(
                events = ArrayList(recEvents), playedSongIds = ArrayList(recPlayed),
                startedAt = recStartedAt, endedAt = endedAt ?: list[i].endedAt,
            )
        }
    }

    private fun startNewSession(save: Boolean) {
        counter += 1
        val s = MixSession(id = "mses_${newId()}", name = "Session $counter", startedAt = nowMs)
        _sessions.value = _sessions.value + s
        _currentId.value = s.id
        _currentName.value = s.name
        recEvents = ArrayList()
        recPlayed = ArrayList()
        recStartedAt = s.startedAt
        recSeq = 0
        hasActivity = false
        resumePendingReanchor = false
        if (save) saveNow()
    }

    /** A document snapshot with the live buffer folded in (without mutating the observed list). */
    private fun snapshotDocument(): MixSessionsDocument =
        MixSessionsDocument(
            schemaVersion = MIX_SESSIONS_SCHEMA_VERSION,
            sessions = foldedSessions(), currentId = currentId, counter = counter,
        )

    private fun cancelPending() {
        saveGen += 1   // a debounce task already blocked on the lock must become a no-op
        pendingSave?.cancel()
        pendingSave = null
    }

    /** Debounced save for the continuous stream (~0.6 s of quiescence). */
    private fun scheduleSave() {
        cancelPending()
        val gen = saveGen
        pendingSave = scheduler.schedule(SAVE_DEBOUNCE_MS) {
            synchronized(lock) {
                if (gen != saveGen) return@synchronized
                pendingSave = null
                saveNow()
            }
        }
    }

    /** Immediate, off-main, versioned write (cancels any pending debounce). */
    private fun saveNow() {
        cancelPending()
        saveVersion += 1
        val doc = snapshotDocument()
        writer.write(saveVersion) { PdjJson.lenient.encodeToString(doc) }
    }

    companion object {
        const val FILE_NAME = "pocketdj-mix-sessions.json"
        const val COALESCE_WINDOW_MS = 120
        const val SAVE_DEBOUNCE_MS = 600L
        const val MAX_EVENTS = 100_000
    }
}

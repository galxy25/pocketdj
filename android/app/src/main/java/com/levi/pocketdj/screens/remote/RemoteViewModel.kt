package com.levi.pocketdj.screens.remote

import com.levi.pocketdj.data.catalog.IndexSong
import com.levi.pocketdj.playback.sequencer.QueueItem
import com.levi.pocketdj.playback.sequencer.RepeatMode
import com.levi.pocketdj.remote.RemoteCommand
import com.levi.pocketdj.remote.RemoteDeviceRole
import com.levi.pocketdj.remote.RemotePlaybackState
import com.levi.pocketdj.remote.RemoteRow
import com.levi.pocketdj.remote.RemoteSessionController
import com.levi.pocketdj.remote.RemoteSessionMode
import kotlinx.coroutines.CancellationException
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Job
import kotlinx.coroutines.delay
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.asStateFlow
import kotlinx.coroutines.launch
import java.text.Normalizer

// ---------------------------------------------------------------------------------------------------------
// The seam P2-REM-9 (the real transport) fills: how a session is STARTED / JOINED and how its invite looks.
// The Remote screen only knows this interface, so the UI ships (hidden behind ParityFlags.REMOTE) before a
// transport exists. [RemoteStarters.current] stays [RemoteSessionStarter.None] until REM-9 installs one.
// ---------------------------------------------------------------------------------------------------------

/** What the host shows so others can join: a short [code] and the [url] the QR encodes (`pocketdj://remote/join/<token>`). */
data class RemoteInvite(val code: String, val url: String)

/** A nearby session host the Join list offers (confirm before joining). */
data class DiscoveredHost(val id: String, val name: String, val mode: RemoteSessionMode? = null)

sealed interface StartOutcome {
    /** The session is attached as host; [invite] is what to show (null = nothing to show, e.g. a call-based start). */
    data class Started(val invite: RemoteInvite?) : StartOutcome
    data object Cancelled : StartOutcome
    data class Failed(val message: String) : StartOutcome
}

sealed interface JoinOutcome {
    data object Joined : JoinOutcome
    data class Failed(val message: String) : JoinOutcome
}

interface RemoteSessionStarter {
    /** False = no transport yet: the Start/Join actions are disabled with an explanation. */
    val available: Boolean

    /** The invite of the session this device hosts, null otherwise. */
    val invite: StateFlow<RemoteInvite?>

    /** Hosts found nearby while discovery runs. */
    val discovered: StateFlow<List<DiscoveredHost>>

    suspend fun start(mode: RemoteSessionMode): StartOutcome
    suspend fun joinWithCode(code: String): JoinOutcome
    suspend fun joinHost(hostId: String): JoinOutcome
    fun startDiscovery()
    fun stopDiscovery()

    /** The Remote screen is gone / the user left: drop the invite. */
    fun clearInvite()

    /** The do-nothing starter used until a real transport lands. */
    object None : RemoteSessionStarter {
        override val available = false
        override val invite: StateFlow<RemoteInvite?> = MutableStateFlow(null)
        override val discovered: StateFlow<List<DiscoveredHost>> = MutableStateFlow(emptyList())
        override suspend fun start(mode: RemoteSessionMode): StartOutcome = StartOutcome.Failed("Sessions aren't available on this build yet.")
        override suspend fun joinWithCode(code: String): JoinOutcome = JoinOutcome.Failed("Sessions aren't available on this build yet.")
        override suspend fun joinHost(hostId: String): JoinOutcome = JoinOutcome.Failed("Sessions aren't available on this build yet.")
        override fun startDiscovery() {}
        override fun stopDiscovery() {}
        override fun clearInvite() {}
    }
}

/** Process-wide holder: P2-REM-9 sets [current] when its transport is built. */
object RemoteStarters {
    @Volatile var current: RemoteSessionStarter = RemoteSessionStarter.None
}

// ---------------------------------------------------------------------------------------------------------
// Pure helpers
// ---------------------------------------------------------------------------------------------------------

/** Where an added song lands in the session queue. */
enum class AddPlacement { NOW, NEXT, END }

object RemoteSearch {
    /** iOS `RemoteView.search` cap. */
    const val CAP = 25
    const val MIN_QUERY = 2
    const val DEBOUNCE_MS = 250L

    private val marks = Regex("\\p{Mn}+")

    private fun fold(s: String): String =
        Normalizer.normalize(s, Normalizer.Form.NFD).replace(marks, "").lowercase()

    /** Title/artist containment, case + diacritic insensitive, first [cap] hits in catalog order. */
    fun search(q: String, songs: List<IndexSong>, cap: Int = CAP): List<IndexSong> {
        val needle = fold(q)
        if (needle.isEmpty()) return emptyList()
        val out = ArrayList<IndexSong>()
        for (s in songs) {
            if (fold(s.name + " " + s.artist).contains(needle)) {
                out += s
                if (out.size >= cap) break
            }
        }
        return out
    }
}

object RemoteJoinCode {
    private val urlTail = Regex("""remote/join/([A-Za-z0-9_-]{4,64})/?(?:[?#].*)?$""")
    private val plain = Regex("""^[A-Za-z0-9_-]{4,64}$""")

    /** A typed code, a pasted `pocketdj://remote/join/<code>` (or https App Link), or null when it is neither. Short codes are upper-cased. */
    fun parse(input: String): String? {
        val t = input.trim()
        if (t.isEmpty()) return null
        val raw = urlTail.find(t)?.groupValues?.get(1) ?: t.takeIf { plain.matches(it) } ?: return null
        return if (raw.length <= 8) raw.uppercase() else raw
    }
}

object RemoteQueueUi {
    /** The window's rows after the current one (iOS `upcomingRows`). */
    fun upcoming(state: RemotePlaybackState?): List<RemoteRow> {
        val s = state ?: return emptyList()
        val rows = s.rows
        val i = s.snapshot.index
        return if (i + 1 < rows.size) rows.subList(i + 1, rows.size) else emptyList()
    }

    /** [rids] with the element at [from] dropped onto position [to] (both indexes into [rids]); null when nothing moves. */
    fun reordered(rids: List<String>, from: Int, to: Int): List<String>? {
        if (from !in rids.indices || to !in rids.indices || from == to) return null
        val out = rids.toMutableList()
        out.add(to, out.removeAt(from))
        return out
    }

    /** The row index a drag of [dyPx] lands on, for rows [rowPx] tall, clamped. */
    fun dragTarget(from: Int, dyPx: Float, heights: List<Float>): Int {
        val count = heights.size
        if (count == 0 || from !in 0 until count) return from
        var target = from
        var remaining = dyPx
        if (dyPx > 0f) {
            while (target + 1 < count && remaining >= heights[target + 1] / 2f) { remaining -= heights[target + 1]; target++ }
        } else if (dyPx < 0f) {
            while (target - 1 >= 0 && -remaining >= heights[target - 1] / 2f) { remaining += heights[target - 1]; target-- }
        }
        return target
    }

    fun dragTarget(from: Int, dyPx: Float, rowPx: Float, count: Int): Int {
        if (count <= 0 || rowPx <= 0f) return from
        val steps = Math.round(dyPx / rowPx)
        return (from + steps).coerceIn(0, count - 1)
    }

    fun clock(ms: Long): String {
        val s = (ms / 1000).coerceAtLeast(0)
        return String.format(java.util.Locale.ROOT, "%d:%02d", s / 60, s % 60)
    }

    fun unavailableText(devices: List<String>): String? =
        if (devices.isEmpty()) null else "Unavailable on ${devices.joinToString(", ")}"

    fun songsCantPlayText(n: Int): String? = if (n <= 0) null else "$n song${if (n == 1) "" else "s"} can’t play here"
}

// ---------------------------------------------------------------------------------------------------------
// The view model
// ---------------------------------------------------------------------------------------------------------

/**
 * Remote screen logic (iOS `RemoteView` actions). Every control becomes a [RemoteCommand] through [send]
 * (the controller: the host applies it, a participant forwards it to the host); nothing here ever touches the
 * local player. A plain class (no Android deps) so the mapping is JVM-testable; the screen `remember`s one.
 */
class RemoteViewModel(
    private val controller: RemoteSessionController,
    private val starter: () -> RemoteSessionStarter,
    private val songs: () -> List<IndexSong>,
    private val scope: CoroutineScope,
    private val send: (RemoteCommand) -> Unit = controller::send,
    private val debounceMs: Long = RemoteSearch.DEBOUNCE_MS,
    /** Where the library scan runs (off Main in the app; tests inherit the test dispatcher). */
    private val searchContext: kotlin.coroutines.CoroutineContext = kotlinx.coroutines.Dispatchers.Default,
) {
    private val _query = MutableStateFlow("")
    val query: StateFlow<String> = _query.asStateFlow()
    private val _results = MutableStateFlow<List<IndexSong>>(emptyList())
    val results: StateFlow<List<IndexSong>> = _results.asStateFlow()

    /** The mode whose start is in flight (the card shows a spinner and the others disable). */
    private val _starting = MutableStateFlow<RemoteSessionMode?>(null)
    val starting: StateFlow<RemoteSessionMode?> = _starting.asStateFlow()
    private val _joining = MutableStateFlow(false)
    val joining: StateFlow<Boolean> = _joining.asStateFlow()

    private var searchJob: Job? = null

    init {
        // Drop a stale invite whenever the session ends by any route (host ended, transport drop, leave).
        scope.launch {
            var was = controller.isActive.value
            controller.isActive.collect { now ->
                if (was && !now) starter().clearInvite()
                was = now
            }
        }
    }

    // ---- Transport (commands only) ----
    fun previous() = send(RemoteCommand.SkipPrevious)
    fun playPause() = send(RemoteCommand.PlayPause)
    fun next() = send(RemoteCommand.SkipNext)
    fun seek(ms: Long) = send(RemoteCommand.Seek(ms))
    fun cycleRepeat() = send(RemoteCommand.SetRepeat((controller.state.value?.repeatMode ?: RepeatMode.OFF).next))
    fun toggleShuffle() = send(RemoteCommand.SetShuffle(!(controller.state.value?.shuffleEnabled ?: false)))

    // ---- Up Next ----
    fun playNow(rid: String) = send(RemoteCommand.JumpTo(rid))
    fun playNext(rid: String) = send(RemoteCommand.Move(rid, 0))
    fun remove(rid: String) = send(RemoteCommand.Remove(rid))

    /** A drag finished: the upcoming row at [from] now sits at [to] (indexes into the Up Next list). */
    fun reorder(from: Int, to: Int) {
        val rids = RemoteQueueUi.upcoming(controller.state.value).map { it.rid }
        RemoteQueueUi.reordered(rids, from, to)?.let { send(RemoteCommand.Reorder(it)) }
    }

    // ---- Search to add ----
    fun setQuery(q: String) {
        _query.value = q
        searchJob?.cancel()
        val trimmed = q.trim()
        if (trimmed.length < RemoteSearch.MIN_QUERY) { _results.value = emptyList(); return }
        searchJob = scope.launch {
            delay(debounceMs)
            val snapshot = songs()
            _results.value = kotlinx.coroutines.withContext(searchContext) { RemoteSearch.search(trimmed, snapshot, RemoteSearch.CAP) }
        }
    }

    fun add(song: IndexSong, placement: AddPlacement) {
        val rows = controller.rows(listOf(QueueItem(id = song.id, title = song.name, artist = song.artist, lengthMs = song.length)))
        send(
            when (placement) {
                AddPlacement.NOW ->
                    if (controller.state.value?.currentRow == null) RemoteCommand.Play(rows, 0) else RemoteCommand.PlayNow(rows)
                AddPlacement.NEXT -> RemoteCommand.EnqueueNext(rows)
                AddPlacement.END -> RemoteCommand.Append(rows)
            },
        )
    }

    // ---- Session ----
    fun setRole(role: RemoteDeviceRole) = controller.setLocalRole(role)
    fun rejoin() = controller.rejoinHere()
    fun leave() {
        controller.leave()
        starter().clearInvite()
    }

    /** Start Listen Together / Backseat over the installed transport. */
    fun begin(mode: RemoteSessionMode) {
        if (_starting.value != null) return
        _starting.value = mode
        controller.setStatus(null)
        scope.launch {
            try {
                when (val o = starter().start(mode)) {
                    is StartOutcome.Started, StartOutcome.Cancelled -> Unit
                    is StartOutcome.Failed -> controller.setStatus("Couldn’t start the session: ${o.message}")
                }
            } catch (e: CancellationException) {
                throw e
            } catch (e: Exception) {
                controller.setStatus("Couldn’t start the session: ${e.message ?: "unknown error"}")
            } finally {
                _starting.value = null
            }
        }
    }

    /** Join by a typed/pasted code or link. False = the text isn't a code (the field shows an error). */
    fun joinWithCode(text: String): Boolean {
        val code = RemoteJoinCode.parse(text) ?: return false
        runJoin { starter().joinWithCode(code) }
        return true
    }

    fun joinHost(host: DiscoveredHost) = runJoin { starter().joinHost(host.id) }

    private fun runJoin(block: suspend () -> JoinOutcome) {
        if (_joining.value) return
        _joining.value = true
        controller.setStatus(null)
        scope.launch {
            try {
                val o = block()
                if (o is JoinOutcome.Failed) controller.setStatus("Couldn’t join: ${o.message}")
            } catch (e: CancellationException) {
                throw e
            } catch (e: Exception) {
                controller.setStatus("Couldn’t join: ${e.message ?: "unknown error"}")
            } finally {
                _joining.value = false
            }
        }
    }

    fun startDiscovery() = starter().startDiscovery()
    fun stopDiscovery() = starter().stopDiscovery()
}

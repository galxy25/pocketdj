package com.levi.pocketdj.auto

import com.levi.pocketdj.shell.MixFacade
import com.levi.pocketdj.shell.MixSource
import com.levi.pocketdj.shell.ShellActionException
import kotlinx.coroutines.CancellationException
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.flow.Flow
import kotlinx.coroutines.flow.distinctUntilChanged
import kotlinx.coroutines.flow.emptyFlow
import kotlinx.coroutines.launch

/** What a Mix-tab node does (the `kind` token of [AutoId.Mix]). */
enum class AutoMixKind(val token: String) {
    ROOT("root"),
    /** Deck crate picker; a = "a" | "b". */
    DECK("deck"),
    /** Crate group under a deck; a = deck, b = [AutoCrateGroup.token]. */
    GROUP("grp"),
    /** One crate; a = deck, b = crate key ("pocket:<id>"), "" = "Same as Deck A" (Deck B only). */
    CRATE("crate"),
    START("start"),
    NEW_MIX("new"),
    TOGGLE("toggle"),
    SKIP_FAST("fast"),
    SKIP_SLOW("slow"),
    STOP("stop"),
    STATUS("status"),
    DOWNLOAD("dl"),
    JUKEBOX("juke"),
    /** a = jukebox id. */
    SESSION("sess"),
    /** The join URL text row of session a. */
    SESSION_URL("url"),
    NOTE("note"),
    /** The parked (post-process-death) mix: tapping it brings the decks back and resumes. */
    PARKED("parked"),
    ;

    companion object {
        fun fromToken(t: String): AutoMixKind? = entries.firstOrNull { it.token == t }
    }
}

enum class AutoCrateGroup(val token: String, val label: String) {
    POCKETS("pockets", "Pockets"),
    PLAYLISTS("playlists", "Playlists"),
    SETLISTS("setlists", "Set lists"),
    ;

    companion object {
        fun fromToken(t: String) = entries.firstOrNull { it.token == t }
    }
}

/** One pickable crate (iOS `MixSource` + its display name). */
data class AutoCrate(val source: MixSource, val name: String, val group: AutoCrateGroup) {
    /** Stable key used inside node ids. */
    val key: String get() = AutoMixTab.keyOf(source)
}

/** The live status of a running mix. [position]/[count] are 1-based "n / count"; either null hides that part. */
data class AutoMixLive(
    val title: String? = null,
    val artist: String? = null,
    val position: Int? = null,
    val count: Int? = null,
    /** "Deck A" / "Deck B". */
    val deck: String? = null,
    val buffering: Boolean = false,
)

/** What a parked mix shows in the car before it is materialized. */
data class AutoParkedMix(val title: String?, val artist: String?, val label: String?)

data class AutoJukeSession(val id: String, val name: String, val timeless: Boolean, val url: String)

/**
 * What the Mix tab needs beyond [MixFacade] (start / pause / resume / running / paused). Production:
 * `AppAutoMixExtras` over the Mix engine + collections + the jukebox broker. Every member is cheap and
 * must not build the Mix engine unless a mix is already running (a car connect never materializes a parked mix).
 */
interface AutoMixExtras {
    fun crates(): List<AutoCrate>
    /** Null when nothing is on air. */
    fun live(): AutoMixLive?
    /** Seconds of the "long blend" skip (settings skip fade). */
    val slowSkipSeconds: Double
    fun skipFast()
    fun skipSlow()
    fun stop()
    /** "downloaded to total" while a zero-start run is pulling. */
    fun downloadState(): Pair<Int, Int>? = null
    /** Emits whenever anything the Mix rows display may have changed (duplicates are filtered here). */
    val changes: Flow<String> get() = emptyFlow()
    /** The Mix row was opened: bring a parked (post-process-death) mix back onto the decks (CarPlay parity). Never builds the engine when nothing is parked. */
    fun materializePendingRestoreIfNeeded(trigger: String) {}
    /** The parked mix's summary (title / artist / source label), read WITHOUT building the engine; null = nothing parked. */
    fun parkedMix(): AutoParkedMix? = null
    /** The Mix-row gesture on a parked mix: materialize the decks, THEN resume (iOS CarPlayModel.materializeForGesture). */
    fun resumeParkedMix() {}
    /** Live broker sessions; null = unreachable / not configured. */
    suspend fun jukeboxSessions(): List<AutoJukeSession>?
}

/**
 * The Android Auto Mix tab (iOS CarPlayScene Mix tab): a REMOTE for the shared Mix engine, never a DJ board.
 * Setup = Deck A / Deck B crate pickers + Start (always a shuffled auto-mix); live = status, New Mix,
 * Pause/Resume, quick/long skip, Stop. A Jukebox node lists live broker sessions with their join URL as text
 * (a car list has no QR image). Pure and synchronous apart from [select] and the jukebox fetch.
 */
class AutoMixTab(
    private val facade: MixFacade,
    private val extras: AutoMixExtras,
    private val clock: () -> Long = System::currentTimeMillis,
) {
    /** The car's chosen crates; session-local (a fresh connect starts blank). */
    @Volatile var deckA: AutoCrate? = null; private set
    @Volatile var deckB: AutoCrate? = null; private set

    private var notifier: (String, Int) -> Unit = { _, _ -> }
    private var scope: CoroutineScope? = null

    private sealed interface Juke {
        data object Idle : Juke
        data object Loading : Juke
        data class Loaded(val sessions: List<AutoJukeSession>) : Juke
        data object Unreachable : Juke
    }
    @Volatile private var juke: Juke = Juke.Idle
    @Volatile private var lastSessions: List<AutoJukeSession> = emptyList()
    @Volatile private var jukeFetchedAt = 0L

    /** Wire change notifications and start observing the facade/engine state (called once by the callback). */
    fun bind(scope: CoroutineScope, notify: (String, Int) -> Unit) {
        this.scope = scope
        this.notifier = notify
        scope.launch { extras.changes.distinctUntilChanged().collect { notifyMix() } }
    }

    private fun notifyMix(vararg more: AutoId.Mix) {
        val ids = listOf(ROOT) + more.toList()
        ids.map { it.encoded }.distinct().forEach { notifier(it, children(AutoId.decode(it) as AutoId.Mix, touch = false)?.size ?: 0) }
    }

    // ---- Nodes ----

    fun tabNode(): AutoNode = AutoNode(
        id = ROOT.encoded, title = "Mix", subtitle = if (facade.autoMixing) "Auto DJ" else "Two-crate Auto DJ",
        browsable = true, childBrowsableStyle = AutoStyle.LIST, childPlayableStyle = AutoStyle.LIST,
    )

    fun item(id: AutoId.Mix): AutoNode? = when (id.kind) {
        AutoMixKind.ROOT -> tabNode()
        else -> null
    }

    fun children(id: AutoId.Mix, touch: Boolean = true): List<AutoNode>? = when (id.kind) {
        AutoMixKind.ROOT -> root()
        AutoMixKind.DECK -> deckPicker(id.a)
        AutoMixKind.GROUP -> group(id.a, id.b)
        AutoMixKind.JUKEBOX -> jukebox(touch)
        AutoMixKind.SESSION -> sessionChildren(id.a)
        else -> null
    }

    private fun mix(kind: AutoMixKind, a: String = "", b: String = "") = AutoId.Mix(kind, a, b).encoded

    private fun root(): List<AutoNode> {
        // Connecting must not build the graph / touch deck files under a sounding set: only DESCRIBE the parked mix
        // here; a Mix-row gesture (PARKED / START / TOGGLE) materializes it.
        val out = ArrayList<AutoNode>()
        val parked = if (facade.autoMixing) null else extras.parkedMix()
        if (parked != null) {
            out += AutoNode(
                mix(AutoMixKind.PARKED),
                title = statusTitle(AutoMixLive(title = parked.title, artist = parked.artist)),
                subtitle = listOfNotNull("Paused", parked.label?.takeIf { it.isNotBlank() }).joinToString(" · ") + " — tap to resume",
                playable = true,
            )
        }
        if (facade.autoMixing) out += liveRows() else out += setupRows()
        out += AutoNode(
            mix(AutoMixKind.JUKEBOX), "Jukebox", subtitle = "Show a session's join link",
            browsable = true, childBrowsableStyle = AutoStyle.LIST,
        )
        return out
    }

    private fun setupRows(): List<AutoNode> {
        val a = deckA
        val out = ArrayList<AutoNode>()
        out += AutoNode(
            mix(AutoMixKind.DECK, "a"), "Deck A", subtitle = a?.name ?: "Choose a crate…",
            browsable = true, childBrowsableStyle = AutoStyle.LIST, childPlayableStyle = AutoStyle.LIST,
        )
        out += AutoNode(
            mix(AutoMixKind.DECK, "b"), "Deck B", subtitle = deckB?.name ?: "Same as Deck A",
            browsable = true, childBrowsableStyle = AutoStyle.LIST, childPlayableStyle = AutoStyle.LIST,
        )
        out += AutoNode(
            mix(AutoMixKind.START), "▶ Start Mix",
            subtitle = if (a == null) "Pick Deck A first" else "Shuffled auto-mix",
            playable = true,
        )
        extras.downloadState()?.let { (done, total) ->
            out += AutoNode(mix(AutoMixKind.DOWNLOAD), "Downloading $done of $total", subtitle = "The mix starts when the first track lands")
        }
        return out
    }

    private fun liveRows(): List<AutoNode> {
        val live = extras.live()
        val paused = facade.autoPaused
        val out = ArrayList<AutoNode>()
        out += AutoNode(
            mix(AutoMixKind.STATUS),
            title = statusTitle(live),
            subtitle = statusText(live, paused),
            playable = true,
        )
        out += AutoNode(mix(AutoMixKind.NEW_MIX), "🔀 New Mix", subtitle = "Pick a different collection", playable = true)
        out += AutoNode(mix(AutoMixKind.TOGGLE), if (paused) "▶ Resume Mix" else "⏸ Pause Mix", playable = true)
        out += AutoNode(mix(AutoMixKind.SKIP_FAST), "⏭ Skip — quick", subtitle = "${FAST_SKIP_SECONDS.toInt()} second sweep", playable = true)
        out += AutoNode(
            mix(AutoMixKind.SKIP_SLOW), "⏭ Skip — long blend",
            subtitle = "${extras.slowSkipSeconds.toInt()} second crossfade", playable = true,
        )
        out += AutoNode(mix(AutoMixKind.STOP), "⏹ Stop Mix", playable = true)
        return out
    }

    private fun deckPicker(deck: String): List<AutoNode>? {
        if (deck != "a" && deck != "b") return null
        val crates = extras.crates()
        val out = ArrayList<AutoNode>()
        if (deck == "b") {
            out += AutoNode(
                mix(AutoMixKind.CRATE, "b", ""), "Same as Deck A",
                subtitle = if (deckB == null) "Selected" else null, playable = true,
            )
        }
        for (g in AutoCrateGroup.entries) {
            val n = crates.count { it.group == g }
            if (n == 0) continue
            out += AutoNode(
                mix(AutoMixKind.GROUP, deck, g.token), g.label,
                subtitle = if (n == 1) "1 crate" else "$n crates",
                browsable = true, childPlayableStyle = AutoStyle.LIST,
            )
        }
        if (out.none { it.id.startsWith("mix:grp:") }) {
            out += AutoNode(mix(AutoMixKind.NOTE, "empty"), "No pockets, playlists, or set lists yet", subtitle = "Create one in the app")
        }
        return out
    }

    private fun group(deck: String, groupToken: String): List<AutoNode>? {
        val g = AutoCrateGroup.fromToken(groupToken) ?: return null
        if (deck != "a" && deck != "b") return null
        val chosen = if (deck == "a") deckA else deckB
        return extras.crates().filter { it.group == g }.map {
            AutoNode(
                mix(AutoMixKind.CRATE, deck, it.key), it.name,
                subtitle = if (chosen?.key == it.key) "Selected · ${g.label}" else g.label,
                playable = true,
            )
        }.ifEmpty { listOf(AutoNode(mix(AutoMixKind.NOTE, "empty"), "No ${g.label.lowercase()} yet")) }
    }

    // ---- Jukebox ----

    private fun jukebox(touch: Boolean): List<AutoNode> {
        if (touch) refreshJukebox()
        return when (val j = juke) {
            Juke.Idle, Juke.Loading -> listOf(AutoNode(mix(AutoMixKind.NOTE, "loading"), "Loading…", subtitle = "Asking the jukebox server"))
            Juke.Unreachable -> listOf(AutoNode(mix(AutoMixKind.NOTE, "unreachable"), JUKE_UNREACHABLE, subtitle = JUKE_HINT))
            is Juke.Loaded -> if (j.sessions.isEmpty()) {
                listOf(AutoNode(mix(AutoMixKind.NOTE, "none"), JUKE_NONE, subtitle = JUKE_HINT))
            } else {
                j.sessions.map {
                    AutoNode(
                        mix(AutoMixKind.SESSION, it.id), it.name.ifBlank { "Jukebox" },
                        subtitle = if (it.timeless) "Timeless" else "Live",
                        browsable = true, childBrowsableStyle = AutoStyle.LIST,
                    )
                }
            }
        }
    }

    private fun sessionChildren(id: String): List<AutoNode>? {
        val s = ((juke as? Juke.Loaded)?.sessions ?: lastSessions).firstOrNull { it.id == id } ?: return null
        return listOf(AutoNode(mix(AutoMixKind.SESSION_URL, id), s.url, subtitle = "Join link — open it on your phone"))
    }

    /** Fetches at most once per [JUKE_REFRESH_MS]; notifies the Jukebox node only when the result changed. */
    private fun refreshJukebox() {
        val sc = scope ?: return
        val now = clock()
        if (juke == Juke.Loading) return
        if (juke != Juke.Idle && now - jukeFetchedAt < JUKE_REFRESH_MS) return
        val before = juke
        if (before == Juke.Idle) juke = Juke.Loading
        jukeFetchedAt = now
        sc.launch {
            val next: Juke = try {
                extras.jukeboxSessions()?.let { Juke.Loaded(it) } ?: Juke.Unreachable
            } catch (e: CancellationException) {
                throw e
            } catch (_: Exception) {
                Juke.Unreachable
            }
            val changed = next != juke
            juke = next
            (next as? Juke.Loaded)?.let { lastSessions = it.sessions }
            if (changed || before == Juke.Idle) notifyMix(AutoId.Mix(AutoMixKind.JUKEBOX))
        }
    }

    // ---- Selection ----

    /**
     * A Mix row was selected. Returns a user-facing toast (or null). Throws [AutoPlayException] for a
     * failure the car should show.
     */
    suspend fun select(id: AutoId.Mix): String? {
        when (id.kind) {
            AutoMixKind.CRATE -> {
                val crate = if (id.b.isEmpty()) null else extras.crates().firstOrNull { it.key == id.b }
                if (id.b.isNotEmpty() && crate == null) throw AutoPlayException("That crate is gone")
                val old = if (id.a == "a") deckA else deckB
                if (id.a == "a") deckA = crate else deckB = crate
                val groups = listOfNotNull(old?.group, crate?.group).distinct()
                    .map { AutoId.Mix(AutoMixKind.GROUP, id.a, it.token) }
                notifyMix(AutoId.Mix(AutoMixKind.DECK, id.a), *groups.toTypedArray())
                return "${if (id.a == "a") "Deck A" else "Deck B"}: ${crate?.name ?: "Same as Deck A"}"
            }
            AutoMixKind.PARKED -> { extras.resumeParkedMix(); notifyMix(); return null }
            AutoMixKind.START -> return start()   // a new mix supersedes a parked one: nothing to materialize
            AutoMixKind.STATUS -> return null
            AutoMixKind.NEW_MIX -> extras.stop()
            AutoMixKind.STOP -> extras.stop()
            AutoMixKind.TOGGLE -> {
                // Decide at TAP time, not render time: a momentarily-stale row must act on the real state.
                if (!facade.autoMixing) { if (extras.parkedMix() != null) { extras.resumeParkedMix(); notifyMix() }; return null }
                if (facade.autoPaused) facade.resumeAutoMix() else facade.pauseAutoMix()
            }
            AutoMixKind.SKIP_FAST -> if (facade.autoMixing) extras.skipFast()
            AutoMixKind.SKIP_SLOW -> if (facade.autoMixing) extras.skipSlow()
            else -> return null
        }
        notifyMix()
        return null
    }

    private suspend fun start(): String? {
        val a = deckA ?: return "Pick Deck A first"
        val b = deckB
        val result = try {
            if (b == null) facade.startAutoMix(a.source, shuffle = true, allowPendingStart = true)
            else facade.startAutoMix(a.source, b.source, shuffle = true, allowPendingStart = true)
        } catch (e: ShellActionException) {
            throw AutoPlayException(e.message ?: "Couldn't start the mix")
        }
        notifyMix()
        // Visible in the car: the Downloading row (downloadState) plus this toast on the phone.
        return if (result.count == 0) "Downloading — the mix starts when the first track lands" else null
    }

    companion object {
        val ROOT = AutoId.Mix(AutoMixKind.ROOT)
        const val FAST_SKIP_SECONDS = 5.0
        const val JUKE_REFRESH_MS = 10_000L
        const val JUKE_UNREACHABLE = "Couldn't reach the jukebox server"
        const val JUKE_NONE = "No live sessions"
        const val JUKE_HINT = "Host one from iPhone or the TV"

        fun keyOf(s: MixSource): String = when (s) {
            is MixSource.Pocket -> "pocket:${s.id}"
            is MixSource.Playlist -> "playlist:${s.id}"
            is MixSource.Setlist -> "setlist:${s.id}"
        }

        fun statusTitle(live: AutoMixLive?): String {
            val t = live?.title?.takeIf { it.isNotBlank() } ?: return "Auto DJ"
            val a = live.artist?.takeIf { it.isNotBlank() }
            return if (a == null) t else "$t — $a"
        }

        /** "Paused · 3 / 12 · Deck A" (the state word only when it is not plain playing). */
        fun statusText(live: AutoMixLive?, paused: Boolean): String {
            val parts = ArrayList<String>(3)
            if (paused) parts += "Paused" else if (live?.buffering == true) parts += "Buffering…"
            if (live?.position != null && live.count != null) parts += "${live.position} / ${live.count}"
            live?.deck?.let { parts += it }
            return if (parts.isEmpty()) "Playing" else parts.joinToString(" · ")
        }
    }
}

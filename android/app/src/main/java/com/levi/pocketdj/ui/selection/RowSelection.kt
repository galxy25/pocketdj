package com.levi.pocketdj.ui.selection

import com.levi.pocketdj.data.catalog.IndexSong
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow
import kotlinx.serialization.Serializable
import kotlinx.serialization.encodeToString
import kotlinx.serialization.json.Json

/**
 * iOS `SongTransfer`: the song-id list that travels on the clipboard / drag, with a capped
 * human-readable text fallback so external apps paste something useful.
 */
@Serializable
data class SongTransfer(val songIds: List<String>, val text: String? = null) {
    /** What an external app pastes: the text fallback, else the raw ids one per line. */
    val plainTextExport: String get() = text ?: songIds.joinToString("\n")

    fun toJson(): String = JSON.encodeToString(this)

    companion object {
        /** Cap the plain-text fallback so a 96k-song select-all still copies instantly. */
        const val TEXT_LINE_CAP = 200

        /** iOS `SongPasteboard.maxPayloadBytes`: refuse to decode anything bigger. */
        const val MAX_PAYLOAD_BYTES = 8 * 1024 * 1024

        /** Clipboard label / MIME-ish tag shared with iOS (`com.pocketdj.songlist`). */
        const val CLIP_LABEL = "com.pocketdj.songlist"

        private val JSON = Json { ignoreUnknownKeys = true }

        fun make(ids: List<String>, songsById: Map<String, IndexSong>): SongTransfer {
            val lines = ids.asSequence().take(TEXT_LINE_CAP)
                .mapNotNull { songsById[it]?.let { s -> "${s.artist} — ${s.name}" } }
                .toList()
            val extra = ids.size - minOf(ids.size, TEXT_LINE_CAP)
            val text = if (lines.isEmpty()) null
            else lines.joinToString("\n") + if (extra > 0) "\n…and $extra more" else ""
            return SongTransfer(ids, text)
        }

        /** Byte-capped decode boundary (null on oversize / malformed). */
        fun decode(json: String): SongTransfer? {
            if (json.toByteArray(Charsets.UTF_8).size > MAX_PAYLOAD_BYTES) return null
            return runCatching { JSON.decodeFromString<SongTransfer>(json) }.getOrNull()
        }
    }
}

/**
 * Immutable snapshot of the multi-select machine. Ids live in the ACTIVE list's id space
 * (Browse / pocket / source / setlist: song ids; playlist chapters: NODE ids) — the registered
 * payload closure translates to song ids when a payload is built.
 */
data class SelectionState(
    val scopeId: String? = null,
    val ids: Set<String> = emptySet(),
    val anchorId: String? = null,
    /**
     * Touch select mode, armed PER SCOPE. A single Bool once swallowed the first tap in every
     * OTHER list (armed in Browse, invisible in a pocket, a tap toggled instead of navigating),
     * so the mode carries the scope it was armed in and only intercepts taps in THAT scope.
     */
    val selectModeScope: String? = null,
    /** Scope of the frontmost registered selectable list (null = none). */
    val activeScope: String? = null,
    /** Scope of the collection detail currently accepting pastes (null = none). */
    val pasteScope: String? = null,
) {
    val selectMode: Boolean get() = selectModeScope != null
    val hasSelection: Boolean get() = ids.isNotEmpty()
    val count: Int get() = ids.size
    fun isSelectMode(scope: String): Boolean = selectModeScope == scope
    fun isSelected(id: String, scope: String): Boolean = scopeId == scope && id in ids

    /** The bar shows for a scope while selecting there (or select mode is armed there). */
    fun isActive(scope: String): Boolean = (selectMode || hasSelection) && (scopeId == null || scopeId == scope)

    /** Copy is live only when the selection belongs to the list that can serialize it. */
    val canCopy: Boolean get() = hasSelection && activeScope != null && activeScope == scopeId
    val canPaste: Boolean get() = pasteScope != null
    val canSelectAll: Boolean get() = activeScope != null
}

/**
 * PER-WINDOW multi-select state (iOS `RowSelection`). One instance lives on the collections
 * graph; the Android window is single, so that is "per window". Touch-first: long-press arms
 * select mode in the row's scope, taps toggle ONLY in the armed scope.
 */
class RowSelection {
    enum class TapOutcome { NAVIGATE, SELECTION }

    private class ActiveList(val scope: String, val allIds: () -> List<String>, val payload: () -> SongTransfer?)
    private class PasteTarget(val scope: String, val handler: (SongTransfer) -> Unit)

    private val _state = MutableStateFlow(SelectionState())
    val state: StateFlow<SelectionState> get() = _state

    private var activeList: ActiveList? = null
    private var pasteTarget: PasteTarget? = null

    private inline fun update(f: (SelectionState) -> SelectionState) {
        _state.value = f(_state.value)
    }

    // ---- gestures ----------------------------------------------------------------------

    /** A plain row tap. Select mode intercepts it ONLY in the scope it was armed in. */
    fun handleTap(id: String, scope: String): TapOutcome {
        if (_state.value.selectModeScope == scope) {
            update { switchScope(it, scope) }
            toggle(id)
            return TapOutcome.SELECTION
        }
        return TapOutcome.NAVIGATE
    }

    /** Long-press: arm select mode in [scope] (selecting [initial]); already armed ⇒ toggle. */
    fun handleLongPress(id: String, scope: String) {
        if (_state.value.selectModeScope == scope) handleTap(id, scope) else enterSelectMode(scope, id)
    }

    fun enterSelectMode(scope: String, initial: String?) {
        update { s ->
            val sw = switchScope(s, scope)
            sw.copy(
                selectModeScope = scope,
                ids = if (initial != null) sw.ids + initial else sw.ids,
                anchorId = initial ?: sw.anchorId,
            )
        }
    }

    /** Select the FULL filtered universe of the active list (not just rendered rows). */
    fun selectAll() {
        val al = activeList ?: return
        val all = al.allIds()
        update { s -> switchScope(s, al.scope).let { it.copy(ids = all.toSet()) } }
    }

    /** Clear the selection and exit select mode (also un-latches the scope). */
    fun clearAndExit() {
        update { it.copy(ids = emptySet(), anchorId = null, selectModeScope = null, scopeId = null) }
    }

    /** Empty the selection but STAY in select mode. */
    fun deselectAll() {
        update { it.copy(ids = emptySet(), anchorId = null) }
    }

    /** Drop ids that left the list; an anchor that left is forgotten. */
    fun prune(validIds: Set<String>) {
        update { s ->
            s.copy(
                ids = s.ids.filterTo(HashSet()) { it in validIds },
                anchorId = s.anchorId?.takeIf { it in validIds },
            )
        }
    }

    /** The selection in display order (intersection with [orderedIds]). */
    fun orderedSelection(orderedIds: List<String>): List<String> {
        val ids = _state.value.ids
        return orderedIds.filter { it in ids }
    }

    // ---- registration (enter/leave of each participating list) --------------------------

    fun registerActiveList(scope: String, allIds: () -> List<String>, payload: () -> SongTransfer?) {
        activeList = ActiveList(scope, allIds, payload)
        update { it.copy(activeScope = scope) }
    }

    /** No-op for the active list if another list took over; ALWAYS disarms select mode it owned. */
    fun unregisterActiveList(scope: String) {
        if (activeList?.scope == scope) {
            activeList = null
            update { it.copy(activeScope = null) }
        }
        // The list select mode was armed in left the screen — disarm (the selection itself
        // survives; only the tap-to-toggle mode ends with its owning list).
        if (_state.value.selectModeScope == scope) update { it.copy(selectModeScope = null) }
    }

    fun registerPasteTarget(scope: String, handler: (SongTransfer) -> Unit) {
        pasteTarget = PasteTarget(scope, handler)
        update { it.copy(pasteScope = scope) }
    }

    fun unregisterPasteTarget(scope: String) {
        if (pasteTarget?.scope == scope) {
            pasteTarget = null
            update { it.copy(pasteScope = null) }
        }
    }

    // ---- payload / paste -----------------------------------------------------------------

    /** The ordered song-id payload; null unless the selection belongs to the active list. */
    fun currentPayload(): SongTransfer? {
        if (!_state.value.canCopy) return null
        return activeList?.payload?.invoke()
    }

    /** Hand a pasted payload to the registered paste target (false if none / empty). */
    fun performPaste(t: SongTransfer): Boolean {
        val pt = pasteTarget ?: return false
        if (t.songIds.isEmpty()) return false
        pt.handler(t)
        return true
    }

    // ---- internals -------------------------------------------------------------------------

    private fun toggle(id: String) {
        update { s -> s.copy(ids = if (id in s.ids) s.ids - id else s.ids + id) }
    }

    private fun switchScope(s: SelectionState, scope: String): SelectionState {
        if (s.scopeId == scope) return s
        // A genuine scope change also ends select mode (enterSelectMode re-arms AFTER this).
        return s.copy(
            ids = emptySet(),
            anchorId = null,
            scopeId = scope,
            selectModeScope = if (s.selectModeScope != scope) null else s.selectModeScope,
        )
    }
}

/**
 * Stable selection keys for a list that may repeat entries: the entry itself for its first
 * occurrence, `entry#n` for later ones. Keys follow the ENTRY, not its position.
 */
fun stableKeys(entries: List<String>): List<String> {
    val seen = HashMap<String, Int>()
    return entries.map { e ->
        val n = seen.merge(e, 1, Int::plus)!!
        if (n == 1) e else "$e#$n"
    }
}

/** Playlist chapter selection payload: node ids -> song ids in display order (missing/studio nodes skipped). */
fun playlistSelectionPayload(
    nodes: List<Pair<String, String?>>, // (nodeId, songId) in display order, SONG nodes only
    selection: RowSelection,
    songsById: Map<String, IndexSong>,
    isStudioId: (String) -> Boolean = { false },
): SongTransfer {
    val eligible = nodes.filter { (_, sid) -> sid != null && songsById.containsKey(sid) && !isStudioId(sid) }
    val byNode = eligible.associate { it.first to it.second!! }
    val ordered = selection.orderedSelection(eligible.map { it.first })
    return SongTransfer.make(ordered.mapNotNull { byNode[it] }, songsById)
}

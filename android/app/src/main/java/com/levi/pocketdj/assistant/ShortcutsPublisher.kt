package com.levi.pocketdj.assistant

import android.content.Context
import android.content.Intent
import android.net.Uri
import androidx.core.content.pm.ShortcutInfoCompat
import androidx.core.content.pm.ShortcutManagerCompat
import com.levi.pocketdj.MainActivity
import com.levi.pocketdj.data.collections.NOW_PLAYING_PLAYLIST_ID
import com.levi.pocketdj.data.collections.NOW_PLAYING_SETLIST_ID
import com.levi.pocketdj.shell.PlayKind
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.FlowPreview
import kotlinx.coroutines.Job
import kotlinx.coroutines.flow.Flow
import kotlinx.coroutines.flow.debounce
import kotlinx.coroutines.flow.distinctUntilChanged
import kotlinx.coroutines.flow.map
import kotlinx.coroutines.launch
import kotlinx.coroutines.withContext

/** A playlist or pocket that may be offered as a launcher shortcut. */
data class ShortcutCandidate(
    val kind: PlayKind,
    val id: String,
    val name: String,
    /** Epoch ms of the last play; null (never played) is not offered. */
    val lastPlayedAt: Double?,
)

/** One dynamic shortcut, platform-free. [uri] is the `pocketdj://play/<kind>/<id>` deep link it opens. */
data class ShortcutSpec(val id: String, val label: String, val uri: String, val rank: Int)

/** Ranking + deep-link construction (pure). */
object ShortcutRanking {
    private val RESERVED_IDS = setOf(NOW_PLAYING_SETLIST_ID, NOW_PLAYING_PLAYLIST_ID)
    const val MAX_LABEL = 25

    fun deepLink(kind: PlayKind, id: String): String =
        "pocketdj://play/${kind.token}/${java.net.URLEncoder.encode(id, "UTF-8").replace("+", "%20")}"

    /**
     * The [cap] most recently played playlists/pockets, newest first. The reserved Now Playing
     * scratch set is never published (iOS: never donate it), nor anything never played or unnamed.
     */
    fun select(candidates: List<ShortcutCandidate>, cap: Int): List<ShortcutSpec> {
        if (cap <= 0) return emptyList()
        return candidates
            .asSequence()
            .filter { it.id !in RESERVED_IDS && it.name.isNotBlank() && it.lastPlayedAt != null }
            .filter { it.kind == PlayKind.Playlist || it.kind == PlayKind.Pocket }
            .sortedWith(
                compareByDescending<ShortcutCandidate> { it.lastPlayedAt }
                    .thenBy { it.name.lowercase() }
                    .thenBy { it.id },
            )
            .take(cap)
            .mapIndexed { i, c ->
                ShortcutSpec(
                    id = "play_${c.kind.token}_${c.id}",
                    label = c.name.trim().take(MAX_LABEL),
                    uri = deepLink(c.kind, c.id),
                    rank = i,
                )
            }
            .toList()
    }
}

/** Where the selected shortcuts go (production: [ShortcutManagerSink]). */
fun interface ShortcutSink {
    suspend fun publish(shortcuts: List<ShortcutSpec>)
}

/**
 * Keeps the launcher's dynamic shortcuts at the most recently played playlists/pockets (the
 * App-Shortcuts/donations analogue). [source] emits whenever collections or play history change;
 * bursts are coalesced by [debounceMs] (so a change lands ≤ ~1 s later) and an unchanged
 * selection is not re-published.
 */
class ShortcutsPublisher(
    private val scope: CoroutineScope,
    private val source: Flow<List<ShortcutCandidate>>,
    private val sink: ShortcutSink,
    private val cap: () -> Int,
    private val debounceMs: Long = 1_000L,
) {
    @OptIn(FlowPreview::class)
    fun start(): Job = scope.launch {
        source
            .debounce(debounceMs)
            .map { ShortcutRanking.select(it, cap()) }
            .distinctUntilChanged()
            .collect { runCatching { sink.publish(it) } }
    }
}

/** The ShortcutManagerCompat sink. Static shortcuts (res/xml/shortcuts.xml) take [STATIC_COUNT] slots. */
class ShortcutManagerSink(private val context: Context) : ShortcutSink {
    override suspend fun publish(shortcuts: List<ShortcutSpec>) = withContext(Dispatchers.IO) {
        val infos = shortcuts.map { s ->
            ShortcutInfoCompat.Builder(context, s.id)
                .setShortLabel(s.label)
                .setLongLabel(s.label)
                .setRank(s.rank)
                .setIntent(
                    Intent(Intent.ACTION_VIEW, Uri.parse(s.uri))
                        .setClassName(context, MainActivity::class.java.name),
                )
                .build()
        }
        ShortcutManagerCompat.setDynamicShortcuts(context, infos)
        Unit
    }

    companion object {
        /** Number of entries in res/xml/shortcuts.xml. */
        const val STATIC_COUNT = 3

        fun dynamicCap(context: Context): Int =
            (ShortcutManagerCompat.getMaxShortcutCountPerActivity(context) - STATIC_COUNT).coerceAtLeast(0)
    }
}

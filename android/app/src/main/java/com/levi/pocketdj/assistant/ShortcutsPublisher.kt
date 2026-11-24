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
import kotlinx.coroutines.CancellationException
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

    const val AUTO_MIX_ID = "automix_last"

    /** The static "Play my pocket" shortcut's deep link (res/xml/shortcuts.xml; P2-POC-16). */
    const val POCKET_NOW_LINK = "pocketdj://pocket/now"

    private const val AUTO_MIX_PREFIX = "Auto-mix "

    /** Name truncated first (with an ellipsis) so the prefix never eats the distinguishing part. */
    fun autoMixLabel(name: String): String {
        val n = name.trim()
        val room = MAX_LABEL - AUTO_MIX_PREFIX.length
        return AUTO_MIX_PREFIX + if (n.length <= room) n else n.take(room - 1) + "…"
    }

    fun autoMixLink(kind: PlayKind, id: String): String =
        "pocketdj://automix/${kind.token}/${java.net.URLEncoder.encode(id, "UTF-8").replace("+", "%20")}"

    /** The "Auto-mix <last crate>" shortcut (1 slot): the most recently played playlist/pocket, or null. */
    fun autoMixShortcut(candidates: List<ShortcutCandidate>): ShortcutSpec? {
        val top = select(candidates, 1).firstOrNull() ?: return null
        val c = candidates.first { "play_${it.kind.token}_${it.id}" == top.id }
        return ShortcutSpec(
            id = AUTO_MIX_ID,
            label = autoMixLabel(c.name),
            uri = autoMixLink(c.kind, c.id),
            rank = 0,
        )
    }

    /** [select] plus the auto-mix shortcut taking one slot (the play shortcuts shift down a rank). */
    fun selectWithAutoMix(candidates: List<ShortcutCandidate>, cap: Int): List<ShortcutSpec> {
        if (cap <= 0) return emptyList()
        val auto = autoMixShortcut(candidates) ?: return select(candidates, cap)
        return listOf(auto) + select(candidates, cap - 1).map { it.copy(rank = it.rank + 1) }
    }

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
    /** @return true when the launcher accepted the set (false = refused/rate-limited: retry later). */
    suspend fun publish(shortcuts: List<ShortcutSpec>): Boolean
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
    /** SURF-5: also publish the dynamic "Auto-mix <last crate>" shortcut (takes 1 of the [cap] slots). */
    private val withAutoMix: Boolean = false,
) {
    @Volatile private var lastPublished: List<ShortcutSpec>? = null

    @OptIn(FlowPreview::class)
    fun start(): Job = scope.launch {
        source
            .debounce(debounceMs)
            .map { if (withAutoMix) ShortcutRanking.selectWithAutoMix(it, cap()) else ShortcutRanking.select(it, cap()) }
            .collect { selection ->
                // Only a SUCCESSFUL publish is remembered, so a refused one retries on the next emission.
                if (selection == lastPublished) return@collect
                val ok = try {
                    sink.publish(selection)
                } catch (e: CancellationException) {
                    throw e
                } catch (e: Exception) {
                    false
                }
                if (ok) lastPublished = selection
            }
    }
}

/** The ShortcutManagerCompat sink. Static shortcuts (res/xml/shortcuts.xml) take [STATIC_COUNT] slots. */
class ShortcutManagerSink(private val context: Context) : ShortcutSink {
    override suspend fun publish(shortcuts: List<ShortcutSpec>): Boolean = withContext(Dispatchers.IO) {
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
    }

    companion object {
        /** Number of entries in res/xml/shortcuts.xml. */
        const val STATIC_COUNT = 5

        fun dynamicCap(context: Context): Int =
            (ShortcutManagerCompat.getMaxShortcutCountPerActivity(context) - STATIC_COUNT).coerceAtLeast(0)
    }
}

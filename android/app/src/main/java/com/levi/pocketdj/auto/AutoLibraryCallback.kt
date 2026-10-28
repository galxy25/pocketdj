package com.levi.pocketdj.auto

import android.os.Bundle
import androidx.media3.common.MediaItem
import androidx.media3.common.MediaMetadata
import androidx.media3.session.MediaConstants
import kotlinx.coroutines.CancellationException
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Job
import kotlinx.coroutines.launch

/** A user-facing failure from a car action (spoken/toasted verbatim). */
class AutoPlayException(message: String) : Exception(message)

/** What a car selection can start. Production: [AppAutoPlayer] over the shell's reserved Now Playing set. */
interface AutoPlayer {
    suspend fun playCollection(ref: AutoCollectionRef, shuffle: Boolean)
    /** Plays the collection queue starting at [songId]. */
    suspend fun playSong(ref: AutoCollectionRef, songId: String)
    suspend fun playSolo(songId: String)
    /** Resume the held session (the Continue row). Never called on connect. */
    suspend fun resumeHeld()
}

/**
 * The Auto glue with all decisions in pure Kotlin (the Media3 callback in PlaybackService only converts
 * types): browse answers, selection dispatch, the custom "Add to…" action, search, and catalog-warm
 * notifications. Nothing here runs a catalog sweep or network refresh on connect: [onConnect] only asks the
 * host to warm the (cache-first, idempotent) catalog load once.
 */
class AutoLibraryCallback(
    private val tree: AutoBrowseTree,
    private val addTargets: AutoAddTargets,
    private val player: AutoPlayer,
    private val scope: CoroutineScope,
    private val toast: (String) -> Unit,
    /** Media3 `notifyChildrenChanged(parentId)`. */
    private val notifyChildrenChanged: (String) -> Unit,
    /** The add-target MRU as (kind, id), newest first. */
    private val recentTargets: () -> List<Pair<AutoTargetKind, String>> = { emptyList() },
    private val warmUp: () -> Unit = {},
    private val catalogReady: () -> Boolean = { true },
) {
    private var warmed = false
    private var notifiedReady = false

    /** First browse connection: kick the host's catalog warm-up once; never sweeps by itself. */
    fun onConnect(): AutoNode {
        if (!warmed) {
            warmed = true
            if (!catalogReady()) warmUp()
        }
        return tree.root()
    }

    fun getItem(mediaId: String): AutoNode? = tree.item(mediaId)

    fun getChildren(parentId: String, page: Int, pageSize: Int): List<AutoNode>? {
        val id = AutoId.decode(parentId)
        if (id is AutoId.AddTo) {
            val all = addTargets.nodes(id.songId)
            return window(all, page, pageSize)
        }
        return tree.children(parentId, page, pageSize)
    }

    private fun window(all: List<AutoNode>, page: Int, size: Int): List<AutoNode> {
        if (size == Int.MAX_VALUE) return if (page == 0) all else emptyList()
        val from = (page.toLong() * size).coerceAtMost(all.size.toLong()).toInt()
        return all.subList(from, minOf(all.size, from + size))
    }

    fun search(query: String): List<AutoNode> = tree.search(query)

    /** The catalog became usable: replace the single "Loading…" child. Idempotent. */
    fun onCatalogReady() {
        if (notifiedReady) return
        notifiedReady = true
        notifyChildrenChanged(AutoId.Root.encoded)
        AutoId.Tab.Which.entries.forEach { notifyChildrenChanged(AutoId.Tab(it).encoded) }
    }

    fun isOurs(mediaId: String): Boolean = AutoId.decode(mediaId) != null

    /**
     * A row was selected in the car. Returns null when [mediaId] is not ours; otherwise the action job (already
     * complete for rows that do nothing). Unplayable songs only toast: playback is never attempted.
     */
    fun select(mediaId: String): Job? {
        val id = AutoId.decode(mediaId) ?: return null
        return when (id) {
            is AutoId.PlayAll -> run { player.playCollection(id.ref, shuffle = false) }
            is AutoId.ShuffleAll -> run { player.playCollection(id.ref, shuffle = true) }
            AutoId.Continue -> run { player.resumeHeld() }
            is AutoId.Song -> guardPlayable(mediaId) { player.playSong(id.ref, id.songId) }
            is AutoId.Solo -> guardPlayable(mediaId) { player.playSolo(id.songId) }
            is AutoId.AddTarget -> run {
                val name = addTargets.add(id.songId, id.targetKind, id.targetId)
                toast(if (name != null) "Added to $name" else "Couldn't add that")
            }
            else -> done()
        }
    }

    private fun guardPlayable(mediaId: String, body: suspend () -> Unit): Job {
        if (tree.item(mediaId)?.playable != true) {
            toast(AutoBrowseTree.UNAVAILABLE)
            return done()
        }
        return run(body)
    }

    private fun done(): Job = Job().also { it.complete() }

    private fun run(body: suspend () -> Unit): Job = scope.launch {
        try {
            body()
        } catch (e: CancellationException) {
            throw e
        } catch (e: AutoPlayException) {
            e.message?.let(toast)
        } catch (_: Exception) {
            toast("Couldn't do that")
        }
    }

    /**
     * The custom "Add to…" browser action on a song row: adds to the most recently used pocket/playlist (else the
     * first) and confirms. Returns the confirmation text, or null when nothing could be added.
     */
    fun addToAction(mediaId: String): String? {
        val songId = when (val id = AutoId.decode(mediaId)) {
            is AutoId.Song -> id.songId
            is AutoId.Solo -> id.songId
            else -> return null
        }
        val target = addTargets.defaultTarget(recentTargets())
        val msg = target?.let { t ->
            addTargets.add(songId, t.kind, t.id)?.let { "Added to $it" }
        } ?: "No pocket or playlist to add to"
        toast(msg)
        return msg.takeIf { target != null && it.startsWith("Added") }
    }

    companion object {
        const val ACTION_ADD_TO = "pdj.addTo"
        const val ADD_TO_LABEL = "Add to…"

        /** Maps a platform-free node to a Media3 item (browse metadata only: no uri, the sequencer plays). */
        fun toMediaItem(n: AutoNode): MediaItem {
            val extras = Bundle()
            n.childBrowsableStyle?.let { extras.putInt(MediaConstants.EXTRAS_KEY_CONTENT_STYLE_BROWSABLE, it.value) }
            n.childPlayableStyle?.let { extras.putInt(MediaConstants.EXTRAS_KEY_CONTENT_STYLE_PLAYABLE, it.value) }
            val md = MediaMetadata.Builder()
                .setTitle(n.title)
                .setSubtitle(n.subtitle)
                .setIsBrowsable(n.browsable)
                .setIsPlayable(n.playable)
                .setExtras(extras)
            n.subtitle?.let { md.setArtist(it) }
            AutoArtwork.httpsOrNull(n.artUrl)?.let { md.setArtworkUri(android.net.Uri.parse(it)) }
            if (n.addToAction) md.setSupportedCommands(listOf(ACTION_ADD_TO))
            return MediaItem.Builder().setMediaId(n.id).setMediaMetadata(md.build()).build()
        }
    }
}

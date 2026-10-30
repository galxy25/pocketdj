package com.levi.pocketdj.playback.durable

import android.net.Uri
import androidx.media3.common.MediaItem
import androidx.media3.common.MediaMetadata
import androidx.media3.session.MediaSession
import java.io.File

/**
 * The persisted run as the system's playback-resumption request wants it (PB-4 / ANS-PB-6): the queue
 * rows, the current index and the held offset, plus the decoded [snapshot] so the restore does not decode
 * the file a second time. Pure data + [MediaItem] projection; no Main-thread work, no AppGraph.
 */
class HeldQueue private constructor(
    val snapshot: SessionSnapshot,
    val index: Int,
    val positionMs: Long,
    private val artFor: (String) -> Uri?,
) {
    val size: Int get() = snapshot.queue.size

    /** Row ids in queue order; the resumption set is recognised by these (see [matches]). */
    val songIds: List<String> get() = snapshot.queue.map { it.songId }

    /** One [MediaItem] per row: songId / title / artist / art / clip length (the card data; never a playable URI). */
    fun toMediaItems(): List<MediaItem> = snapshot.queue.map { row ->
        val md = MediaMetadata.Builder()
            .setTitle(row.title)
            .setArtist(row.artist.ifEmpty { null })
            .setIsPlayable(true)
            .setIsBrowsable(false)
        row.lengthMs?.let { md.setDurationMs(it) }
        artFor(row.songId)?.let { md.setArtworkUri(it) }
        MediaItem.Builder().setMediaId(row.songId).setMediaMetadata(md.build()).build()
    }

    /** What Media3 hands to `onPlaybackResumption`'s future: the whole queue, current index, held offset. */
    fun toMediaItemsWithStartPosition(): MediaSession.MediaItemsWithStartPosition =
        MediaSession.MediaItemsWithStartPosition(toMediaItems(), index, positionMs)

    /** The single card row (System UI resume card / `isRecent` browse child). */
    fun currentItem(): MediaItem = toMediaItems()[index]

    /** True when [items] is exactly the resumption set this queue produced (ids in order). */
    fun matches(items: List<MediaItem>): Boolean =
        items.size == size && items.indices.all { items[it].mediaId == snapshot.queue[it].songId }

    companion object {
        const val RECENT_ROOT_ID = "pdj.recent.root"

        /** Null when the snapshot has no rows. The index is clamped like the restorer clamps it. */
        fun from(snap: SessionSnapshot, artFor: (String) -> Uri? = { null }): HeldQueue? {
            if (snap.queue.isEmpty()) return null
            val i = snap.index.coerceIn(0, snap.queue.lastIndex)
            return HeldQueue(snap, i, snap.positionMs.coerceAtLeast(0), artFor)
        }

        /** Cheap file read for the boot-time `isRecent` root: no AppGraph, no catalog. Call off Main. */
        fun load(file: File, artFor: (String) -> Uri? = { null }): HeldQueue? = try {
            if (!file.exists()) null else SessionSnapshot.decode(file.readText())?.let { from(it, artFor) }
        } catch (_: Exception) {
            null
        }
    }
}

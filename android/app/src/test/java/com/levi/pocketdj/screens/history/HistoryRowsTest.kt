package com.levi.pocketdj.screens.history

import com.levi.pocketdj.data.activity.ActivityEvent
import com.levi.pocketdj.data.activity.ActivityKind
import com.levi.pocketdj.data.catalog.IndexSong
import com.levi.pocketdj.data.catalog.MergedCatalog
import com.levi.pocketdj.data.history.PlayEvent
import org.junit.Assert.assertEquals
import org.junit.Assert.assertTrue
import org.junit.Test

/**
 * The Unified History timeline contract (iOS `HistoryView.buildUnified`): song
 * plays and collection activity interleaved strictly newest-first, filtered by
 * the shared search query across BOTH streams.
 */
class HistoryRowsTest {

    private fun catalog(songs: List<IndexSong> = emptyList()) = MergedCatalog.EMPTY.copy(
        songs = songs,
        songsById = songs.associateBy { it.id },
    )

    private fun play(id: String, songId: String, at: Double) =
        PlayEvent(id = id, songId = songId, playedAt = at)

    private fun activity(
        id: String,
        at: Double,
        itemId: String = "sng_x",
        itemTitle: String? = "Item",
        collectionName: String? = "Warmups",
    ) = ActivityEvent(
        id = id,
        at = at,
        kind = ActivityKind.ADD,
        itemId = itemId,
        itemTitle = itemTitle,
        collectionName = collectionName,
    )

    @Test
    fun unified_interleavesPlaysAndActivity_newestFirst() {
        val plays = listOf(
            play(id = "p_old", songId = "sng_1", at = 1_000.0),
            play(id = "p_new", songId = "sng_1", at = 3_000.0),
        )
        val acts = listOf(
            activity(id = "a_mid", at = 2_000.0),
            activity(id = "a_newest", at = 4_000.0),
        )
        val entries = buildUnified(plays, acts, catalog(), playCountOf = { 1 }, query = "")

        // Both streams merged strictly by timestamp desc, ids namespaced p:/a:.
        assertEquals(
            listOf("a:a_newest", "p:p_new", "a:a_mid", "p:p_old"),
            entries.map { it.id },
        )
        assertEquals(listOf(4_000L, 3_000L, 2_000L, 1_000L), entries.map { it.atMs })
        assertTrue("newest is the activity event", entries[0] is HistoryEntry.Activity)
        assertTrue("next is the play event", entries[1] is HistoryEntry.Play)
    }

    @Test
    fun unified_query_filtersBothStreams() {
        val song = IndexSong(id = "sng_1", artist = "Elton John", name = "Tiny Dancer")
        val plays = listOf(
            play(id = "p_match", songId = "sng_1", at = 3_000.0),   // live title "Tiny Dancer"
            play(id = "p_miss", songId = "sng_gone", at = 3_500.0), // resolves to raw id
        )
        val acts = listOf(
            activity(id = "a_match", at = 2_000.0, itemId = "sng_1", itemTitle = null),
            activity(id = "a_miss", at = 4_000.0, itemId = "sng_z", itemTitle = "Other", collectionName = "Set"),
        )
        val entries = buildUnified(plays, acts, catalog(listOf(song)), playCountOf = { 1 }, query = "dancer")

        assertEquals(listOf("p:p_match", "a:a_match"), entries.map { it.id })
    }
}

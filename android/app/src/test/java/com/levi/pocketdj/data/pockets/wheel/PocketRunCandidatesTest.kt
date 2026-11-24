package com.levi.pocketdj.data.pockets.wheel

import com.levi.pocketdj.data.activity.ActivityEvent
import com.levi.pocketdj.data.activity.ActivityKind
import com.levi.pocketdj.data.catalog.IndexAlbum
import com.levi.pocketdj.data.catalog.IndexSong
import com.levi.pocketdj.data.collections.CollectionFlattener
import com.levi.pocketdj.data.collections.Pocket
import com.levi.pocketdj.data.games.inthepocket.InThePocketAudio
import com.levi.pocketdj.data.pockets.ListeningPocketsCollections
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test

class PocketRunCandidatesTest {
    private val now = 1_000_000_000_000.0
    private val day = 86_400_000.0

    private val songs = listOf(
        IndexSong(id = "s1", albumId = "a1", artist = "Drake feat. Rihanna", name = "One", year = 2016, bpm = 90.0, camelot = "8A", length = 200_000),
        IndexSong(id = "s2", albumId = "a2", artist = "Nobody", name = "Two", year = 2001, appleMusicId = "am2"),
        IndexSong(id = "s3", albumId = "a1", artist = "Third", name = "Three"),
        IndexSong(id = "s4", albumId = null, artist = "Fourth", name = "Four"),
        IndexSong(id = "s5", albumId = "a1", artist = "Fifth", name = "Five"),
    ).associateBy { it.id }
    private val albums = listOf(
        IndexAlbum(id = "a1", artist = "x", name = "A1", genre = "Hip-Hop/Rap"),
        IndexAlbum(id = "a2", artist = "y", name = "A2", genre = "zzz-unknown"),
    ).associateBy { it.id }

    private fun inputs(pockets: List<Pocket>, activity: List<ActivityEvent> = emptyList()) =
        ListeningPocketsCollections.Input(CollectionFlattener.Source(pockets = pockets), activity)

    @Test fun playabilityMembershipsAndFeatures() {
        val pocket = Pocket(id = "pk1", name = "P", songIds = listOf("s1", "s2", "s3", "s5"))
        val activity = listOf(ActivityEvent(id = "e1", at = now - 45 * day, kind = ActivityKind.ADD, itemId = "s1", collectionId = "pk1"))
        val out = PocketRunCandidates.build(
            songs, albums, InThePocketAudio(ripIds = setOf("s1", "ghost"), burnedIds = setOf("s3"), canStreamAppleMusic = true),
            inputs(listOf(pocket), activity), favorites = setOf("s1", "s4", "s5"), timbre = mapOf("s1" to mapOf("bright" to 0.5)), nowMs = now,
        )
        // rip s1, burned s3, AM s2 (appleMusicId) -- not ghost, not s4/s5 (no audio)
        assertEquals(setOf("s1", "s2", "s3"), out.keys)
        val s1 = out.getValue("s1")
        assertEquals(listOf("hip-hop"), listOfNotNull(s1.features.genre))
        assertEquals(1.0 / 1 * 0.5 + 0.5 * Math.exp(-45.0 / 45.0), s1.memberships.getValue("pk1"), 1e-9)
        assertEquals(PocketMomentEngine.UNKNOWN_ADD_SCALE, s1.memberships.getValue(PocketWheelIds.FAVORITES), 0.0)
        assertEquals("credit keys (feat. tail stripped, as iOS)", listOf("drake"), s1.features.artistKeys)
        assertEquals(mapOf("bright" to 0.5), s1.features.timbre)
        assertEquals(90.0, s1.features.bpm!!, 0.0)
        assertEquals("8A", s1.camelot)
        assertEquals(200_000, s1.lengthMs)
        assertFalse("rip-only is not instant", s1.startsInstantly)
        assertTrue("burned starts instantly", out.getValue("s3").startsInstantly)
        assertNull("unknown genre category -> nil", out.getValue("s2").features.genre)
        assertEquals("no add time -> unknown add scale", PocketMomentEngine.UNKNOWN_ADD_SCALE, out.getValue("s2").memberships.getValue("pk1"), 0.0)
        assertTrue("s5 is not playable so not a candidate", "s5" !in out)
    }

    @Test fun appleMusicSongsOnlyWhenStreamable() {
        val out = PocketRunCandidates.build(songs, albums, InThePocketAudio(canStreamAppleMusic = false), inputs(emptyList()), emptySet(), emptyMap(), now)
        assertTrue(out.isEmpty())
    }
}

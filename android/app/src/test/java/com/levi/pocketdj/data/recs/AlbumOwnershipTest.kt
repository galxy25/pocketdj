package com.levi.pocketdj.data.recs

import com.levi.pocketdj.data.catalog.IndexAlbum
import com.levi.pocketdj.data.catalog.IndexArtist
import com.levi.pocketdj.data.catalog.IndexJson
import com.levi.pocketdj.data.catalog.IndexSong
import com.levi.pocketdj.data.catalog.MergedCatalog
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

class AlbumOwnershipTest {
    @Test fun ownsByEachIdRoute() {
        // provisional amrec_album_<id>
        assertTrue(AlbumOwnership.owns("77", setOf("amrec_album_77"), emptySet(), emptySet(), AlbumOwnership.ALBUM_PREFIX))
        // the track prefix does NOT satisfy an album question
        assertFalse(AlbumOwnership.owns("77", setOf("amrec_77"), emptySet(), emptySet(), AlbumOwnership.ALBUM_PREFIX))
        // a catalog item claiming the store id
        assertTrue(AlbumOwnership.owns("77", emptySet(), setOf("77"), emptySet()))
        // ripped manifest copy
        assertTrue(AlbumOwnership.owns("77", emptySet(), emptySet(), setOf("amrec_77")))
        // the fourth, non-id route
        assertTrue(AlbumOwnership.owns("77", emptySet(), emptySet(), emptySet(), localRecordMatch = true))
        assertFalse(AlbumOwnership.owns("77", setOf("amrec_78"), setOf("78"), setOf("amrec_79")))
    }

    @Test fun rollUpAndWording() {
        val ids = listOf("1", "2", "3", "4")
        assertEquals(AlbumOwnership.None(0), AlbumOwnership.of(emptyList(), emptySet(), emptySet(), emptySet()))
        assertEquals("Add album to your library", AlbumOwnership.of(emptyList(), emptySet(), emptySet(), emptySet()).addTitle)
        assertEquals(AlbumOwnership.None(4), AlbumOwnership.of(ids, emptySet(), emptySet(), emptySet()))
        val part = AlbumOwnership.of(ids, setOf("amrec_1"), setOf("2"), emptySet())
        assertEquals(AlbumOwnership.Partial(2, 4), part)
        assertEquals("Add remaining (2)", part.addTitle)
        val all = AlbumOwnership.of(ids, setOf("amrec_1", "amrec_2"), setOf("3"), setOf("amrec_4"))
        assertEquals(AlbumOwnership.Owned(4), all)
        assertTrue(all.isFullyOwned)
        assertEquals("In your library", all.addTitle)
    }

    // ---- the catalog-backed probes ------------------------------------------------------------

    private fun album(id: String, artist: String, name: String, am: String? = null, tracks: List<String> = emptyList()) =
        IndexAlbum(id = id, artist = artist, name = name, appleMusicId = am, trackList = tracks)

    private fun song(id: String, artist: String, name: String, album: String? = null, am: String? = null) =
        IndexSong(id = id, albumId = album, artist = artist, name = name, appleMusicId = am)

    private fun index(
        albums: List<IndexAlbum>,
        songs: List<IndexSong> = emptyList(),
        artists: List<IndexArtist> = emptyList(),
    ) = OwnedCatalogIndex(MergedCatalog.merge(listOf(IndexJson(albums = albums, songs = songs, artists = artists))), artists)

    private fun owns(index: OwnedCatalogIndex, id: ReleaseIdentity) = ReleaseOwnershipProbes.ownership { index }(id)
    private fun superseded(index: OwnedCatalogIndex, artistId: Int, artist: String, title: String) =
        ReleaseOwnershipProbes.version { index }(artistId, artist, title)

    @Test fun storeIdClaimSuppresses() {
        val idx = index(listOf(album("a1", "Larry June", "Who Coppin", am = "6791849225")))
        assertTrue(owns(idx, ReleaseIdentity("6791849225", 1, "Larry June", null))) // no title: id route alone
        assertFalse(owns(idx, ReleaseIdentity("111", 1, "Larry June", null)))
    }

    @Test fun provisionalAmrecAlbumSuppresses() {
        val idx = index(listOf(album("amrec_album_555", "Dinner Party", "Enigmatic")))
        assertTrue(owns(idx, ReleaseIdentity("555", 2, "Somebody Else", null)))
        assertFalse(owns(idx, ReleaseIdentity("556", 2, "Somebody Else", null)))
    }

    @Test fun sameRecordTitleRouteSuppressesWhenAppleShipsAnotherStoreId() {
        // The reported bug: catalog row claims 6791849225, latest-release returns 6786105209.
        val idx = index(listOf(album("a1", "Larry June", "Who Coppin", am = "6791849225")))
        assertTrue(owns(idx, ReleaseIdentity("6786105209", 1, "Larry June", "Who Coppin")))
        // A different record by the same artist is NOT hidden by owning one of his albums.
        assertFalse(owns(idx, ReleaseIdentity("999", 1, "Larry June", "Brand New Record")))
    }

    @Test fun preorderWithNoIdsAndCollaborationCreditsAreReached() {
        // Filed under the FULL collaboration credit, asked about under Apple's canonical single name.
        val idx = index(
            listOf(album("a1", "Dinner Party, Terrace Martin, Robert Glasper, 9th Wonder & Kamasi Washington", "Whatchu Bringing?")),
        )
        assertTrue(owns(idx, ReleaseIdentity("123", 3, "Dinner Party", "Whatchu Bringing?")))
    }

    @Test fun artistsTableAliasReachesADifferentNameForTheSameEntity() {
        val artists = listOf(IndexArtist(key = "kanye west", name = "Kanye West", id = 900L, alt = listOf(901L)))
        val idx = index(listOf(album("a1", "Kanye West", "Donda")), artists = artists)
        // Apple files the release under "Ye" with the same artist id: only the table knows they are one.
        assertTrue(owns(idx, ReleaseIdentity("5", 901, "Ye", "Donda")))
        // Without the id route the name alone cannot reach it.
        assertFalse(owns(idx, ReleaseIdentity("5", 4242, "Ye", "Donda")))
    }

    @Test fun deluxeReissueIsSuppressedByTheVersionProbeButNotByTheStoreIdProbe() {
        val idx = index(
            albums = listOf(album("a1", "Fleetwood Mac", "Rumours", am = "100")),
            songs = listOf(song("s1", "Fleetwood Mac", "Go Your Own Way", album = "a1")),
        )
        // A single that is a remaster of a SONG he has: no album claims it, so the store-id/record route says new…
        val remaster = ReleaseIdentity("200", 5, "Fleetwood Mac", "Go Your Own Way - Remastered")
        assertFalse("ordinary ownership says new", owns(idx, remaster))
        // …and only the version probe (songs AND albums) catches it.
        assertTrue(superseded(idx, 5, "Fleetwood Mac", "Go Your Own Way - Remastered"))
        assertTrue(superseded(idx, 5, "Fleetwood Mac", "Rumours (Deluxe)"))
        // The exact same edition is not a "different version".
        assertFalse(superseded(idx, 5, "Fleetwood Mac", "Rumours"))
        // Nothing owned by the artist suppresses nothing.
        assertFalse(superseded(idx, 6, "Stranger", "Rumours (Deluxe)"))
    }

    @Test fun liveAlbumOfAnOwnedRecordIsStillNew() {
        val idx = index(listOf(album("a1", "Phish", "Junta", am = "1")))
        assertFalse(owns(idx, ReleaseIdentity("9", 7, "Phish", "Junta (Live)")))
        assertFalse(superseded(idx, 7, "Phish", "Junta (Live)"))
    }

    @Test fun compilationTrackDoesNotFileTheCompilationUnderTheArtist() {
        val idx = index(
            albums = listOf(album("c1", "Various Artists", "Now That's What I Call Music 42")),
            songs = listOf(song("s1", "Larry June", "Some Song", album = "c1")),
        )
        // The album key is under "various artists", so a Larry June release of the same title is not "superseded".
        assertFalse(superseded(idx, 1, "Larry June", "Now That's What I Call Music 42 (Deluxe)"))
    }

    @Test fun lookupsByAppleMusicId() {
        val idx = index(
            albums = listOf(album("a1", "X", "Y", am = "10")),
            songs = listOf(song("s1", "X", "Z", am = "20")),
        )
        assertEquals("a1", idx.albumId("10"))
        assertEquals("s1", idx.songId("20"))
        assertEquals(null, idx.songId("nope"))
        assertTrue(idx.hasAlbum("a1"))
    }

    @Test fun missingIndexOwnsNothing() {
        assertFalse(ReleaseOwnershipProbes.ownership { null }(ReleaseIdentity("1", 1, "A", "B")))
        assertFalse(ReleaseOwnershipProbes.version { null }(1, "A", "B"))
    }
}

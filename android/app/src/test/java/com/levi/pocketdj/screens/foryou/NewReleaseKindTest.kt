package com.levi.pocketdj.screens.foryou

import androidx.datastore.preferences.core.PreferenceDataStoreFactory
import com.levi.pocketdj.data.recs.ArtistReleaseEntry
import com.levi.pocketdj.data.recs.LikedRelease
import com.levi.pocketdj.data.recs.ReleaseFeedItem
import com.levi.pocketdj.data.recs.ReleaseFeedService
import com.levi.pocketdj.data.recs.ReleaseStatus
import com.levi.pocketdj.data.settings.AppSettingsStore
import java.io.File
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.SupervisorJob
import kotlinx.coroutines.cancel
import kotlinx.coroutines.flow.first
import kotlinx.coroutines.runBlocking
import org.junit.After
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test

/** Mirrors iOS `NewReleaseKindTests` case for case. */
class NewReleaseKindTest {
    private val day = 86_400_000.0
    private val now = 1_800_000_000_000.0
    private val scope = CoroutineScope(SupervisorJob() + Dispatchers.Default)
    private val tmp = kotlin.io.path.createTempDirectory("newkind").toFile()

    @After fun cleanup() { scope.cancel(); tmp.deleteRecursively() }

    private fun cls(kind: String?, name: String?, tracks: Int?) = NewReleaseKinds.classify(kind, name, tracks)

    @Test fun classifyTable() {
        assertEquals(ReleaseKindClass.SINGLE, cls("album", "Thing - Single", 9))
        assertEquals(ReleaseKindClass.SINGLE, cls("album", "Thing – Single", 9)) // en dash
        assertEquals(ReleaseKindClass.EP, cls("album", "Thing - EP", 9))
        assertEquals(ReleaseKindClass.SINGLE, cls("album", "  Thing - SINGLE  ", null))
        assertEquals(ReleaseKindClass.SINGLE, cls("single", "Remix Bundle", 8))
        assertEquals(ReleaseKindClass.EP, cls("ep", "Thing", 12))
        assertEquals(ReleaseKindClass.SINGLE, cls("album", "Midnight Edit", 2))
        assertEquals(ReleaseKindClass.EP, cls("album", "Thing", 5))
        assertEquals(ReleaseKindClass.ALBUM, cls("album", "Thing", 12))
        assertEquals(ReleaseKindClass.ALBUM, cls("compilation", "Hits", 20))
        assertEquals(ReleaseKindClass.ALBUM, cls(null, null, null))
    }

    @Test fun badgeFollowsTheClassAndKeepsCompilation() {
        assertEquals("Single", NewReleaseKinds.badge("album", ReleaseKindClass.SINGLE))
        assertEquals("EP", NewReleaseKinds.badge("album", ReleaseKindClass.EP))
        assertEquals("Compilation", NewReleaseKinds.badge("compilation", ReleaseKindClass.ALBUM))
        assertEquals("Album", NewReleaseKinds.badge(null, ReleaseKindClass.ALBUM))
    }

    private data class R(val id: String, val c: ReleaseKindClass)
    private val input = listOf(
        R("s1", ReleaseKindClass.SINGLE), R("a1", ReleaseKindClass.ALBUM), R("e1", ReleaseKindClass.EP),
        R("s2", ReleaseKindClass.SINGLE), R("a2", ReleaseKindClass.ALBUM),
    )
    private val sink: (List<R>) -> List<R> = { items ->
        val bad = setOf("a1", "s1")
        items.filter { it.id !in bad } + items.filter { it.id in bad }
    }
    private fun arrange(m: NewReleaseKindFilter) = NewReleaseKinds.arrange(input, m, { it.c }, sink)

    @Test fun allEqualsTheSunkInputExactly() {
        val a = arrange(NewReleaseKindFilter.ALL)
        assertEquals(sink(input), a.flat)
        assertFalse(a.grouped)
        assertEquals(0, a.hiddenTotal)
    }

    @Test fun albumsOnlyKeepsEpsAndCountsHiddenSingles() {
        val a = arrange(NewReleaseKindFilter.ALBUMS)
        assertEquals(listOf("e1", "a2", "a1"), a.flat.map { it.id })
        assertEquals(2, a.hiddenSingles)
        assertEquals(0, a.hiddenAlbums)
    }

    @Test fun singlesOnlyDropsEpsAndCountsThem() {
        val a = arrange(NewReleaseKindFilter.SINGLES)
        assertEquals(listOf("s2", "s1"), a.flat.map { it.id })
        assertEquals(3, a.hiddenAlbums)
        assertEquals(1, a.hiddenEPs)
    }

    @Test fun albumsFirstGroupsAndSinksInsideEachGroup() {
        val a = arrange(NewReleaseKindFilter.ALBUMS_FIRST)
        assertTrue(a.grouped)
        assertEquals(listOf("e1", "a2", "a1"), a.albums.map { it.id })
        assertEquals(listOf("s2", "s1"), a.singles.map { it.id })
        assertEquals(listOf("e1", "a2", "a1", "s2", "s1"), a.flat.map { it.id })
        assertEquals(0, a.hiddenTotal)
    }

    @Test fun hiddenNoteCopy() {
        assertNull(NewReleaseKinds.hiddenNote(0, 0, 0))
        assertEquals("1 single hidden", NewReleaseKinds.hiddenNote(0, 0, 1))
        assertEquals("3 singles hidden", NewReleaseKinds.hiddenNote(0, 0, 3))
        assertEquals("1 album hidden", NewReleaseKinds.hiddenNote(1, 0, 0))
        assertEquals("2 albums hidden", NewReleaseKinds.hiddenNote(2, 0, 0))
        assertEquals("2 albums & EPs hidden", NewReleaseKinds.hiddenNote(2, 1, 0))
        assertEquals(
            "3 singles hidden. Your New filter is set to Albums only.",
            NewReleasesPresentation.kindEmptyDetail(NewReleaseKindFilter.ALBUMS, "3 singles hidden"),
        )
        assertEquals("No new singles", NewReleasesPresentation.kindEmptyTitle(NewReleaseKindFilter.SINGLES))
    }

    @Test fun filterRawsAreStableAndUnknownMeansAll() {
        assertEquals(listOf("all", "albums", "singles", "albumsFirst"), NewReleaseKindFilter.entries.map { it.raw })
        assertEquals(NewReleaseKindFilter.ALL, NewReleaseKindFilter.from(null))
        assertEquals(NewReleaseKindFilter.ALL, NewReleaseKindFilter.from("nonsense"))
        assertEquals(NewReleaseKindFilter.ALBUMS_FIRST, NewReleaseKindFilter.from("albumsFirst"))
    }

    @Test fun likedReleaseClassifiesLikeAFeedEntry() {
        assertEquals(ReleaseKindClass.SINGLE, LikedRelease("1", title = "X - Single", kind = "album", trackCount = 9).kindClass)
        assertEquals(ReleaseKindClass.ALBUM, LikedRelease("2", title = "X", kind = "album", trackCount = 10).kindClass)
    }

    // ---- the feed adapter + the live list ----

    private fun e(id: Int, name: String, kind: String?, tracks: Int?, at: Double) =
        ArtistReleaseEntry(id, "A$id", now, "r$id", name, at, null, kind, tracks)

    private val fixture = listOf(
        e(900_001, "Second Side", "album", 9, now - 2 * day),
        e(900_002, "Late Cut", "single", 2, now - 9 * day),
        e(900_003, "Preorder EP", "ep", 5, now + 6 * day),
        e(900_005, "Fresh Cut - Single", "single", 1, now - 1 * day),
        e(900_006, "Midnight Edit", "album", 1, now - 3 * day),
    )

    private fun service(list: List<ArtistReleaseEntry>): ReleaseFeedService =
        ReleaseFeedService(null, File(tmp, ReleaseFeedService.FILE_NAME), scope, timeScale = 0.0, clock = { now }, random = { 0.0 })
            .also { it.seedForTesting(list) }

    @Test fun tileCountsOnlyShownReleases() {
        val s = service(fixture)
        fun count(m: NewReleaseKindFilter) = KindFilteredForYouSource(s, m).feed(now).size
        assertEquals(5, count(NewReleaseKindFilter.ALL))
        assertEquals(5, count(NewReleaseKindFilter.ALBUMS_FIRST))
        assertEquals(2, count(NewReleaseKindFilter.ALBUMS)) // album + EP pre-order
        assertEquals(3, count(NewReleaseKindFilter.SINGLES))
        assertEquals(1, KindFilteredForYouSource(s, NewReleaseKindFilter.ALBUMS).feed(now).count { it.comingSoon })
    }

    @Test fun filterEmptyNoteBeatsTheReasonNote() {
        val s = service(listOf(fixture[3])) // one single
        val src = KindFilteredForYouSource(s, NewReleaseKindFilter.ALBUMS)
        assertTrue(src.feed(now).isEmpty())
        assertEquals("No new albums · 1 single hidden", src.emptyTileNote())
        // Nothing hidden → the service's own reason.
        assertEquals(s.emptyReason().tileNote, KindFilteredForYouSource(s, NewReleaseKindFilter.SINGLES).emptyTileNote())
    }

    @Test fun liveOutNowOrderFeedsStreamingAlbumsFirst() {
        val items = fixture.filter { (it.releaseAtMs ?: 0.0) < now }.sortedByDescending { it.releaseAtMs }
            .map { ReleaseFeedItem(it, ReleaseStatus.OUT_NOW) }
        fun ids(m: NewReleaseKindFilter) = NewReleaseKinds.liveOutNow(items, m, emptyMap()).map { it.entry.artistId }
        assertEquals(listOf(900_001), ids(NewReleaseKindFilter.ALBUMS))
        assertEquals(listOf(900_005, 900_006, 900_002), ids(NewReleaseKindFilter.SINGLES))
        assertEquals(listOf(900_001, 900_005, 900_006, 900_002), ids(NewReleaseKindFilter.ALBUMS_FIRST))
        assertEquals(listOf(900_005, 900_001, 900_006, 900_002), ids(NewReleaseKindFilter.ALL))
        // A 👎'd release is dropped from the play list.
        assertEquals(listOf(900_001, 900_006, 900_002),
            NewReleaseKinds.liveOutNow(items, NewReleaseKindFilter.ALBUMS_FIRST, mapOf("rel:r900005" to 1.0)).map { it.entry.artistId })
    }

    @Test fun settingDefaultsToAllAndRoundTrips() = runBlocking {
        val store = AppSettingsStore(PreferenceDataStoreFactory.create(scope = scope) { File(tmp, "s.preferences_pb") })
        assertEquals("all", store.settings.first().newReleaseKind)
        store.setNewReleaseKind("albumsFirst")
        assertEquals(NewReleaseKindFilter.ALBUMS_FIRST, NewReleaseKindFilter.from(store.settings.first().newReleaseKind))
    }
}

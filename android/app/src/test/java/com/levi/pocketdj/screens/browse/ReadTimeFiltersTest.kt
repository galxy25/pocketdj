package com.levi.pocketdj.screens.browse

import com.levi.pocketdj.data.catalog.IndexAlbum
import com.levi.pocketdj.data.catalog.IndexSong
import com.levi.pocketdj.data.favorites.FavoriteFilter
import org.junit.Assert.assertEquals
import org.junit.Assert.assertSame
import org.junit.Test

class ReadTimeFiltersTest {
    private fun song(id: String) = SongRow(
        song = IndexSong(id = id, artist = "A", name = id),
        albumName = null, source = null, genreCategory = "x", searchKey = "",
    )
    private val album = AlbumRow(IndexAlbum(id = "alb", artist = "A", name = "B"), null, "x", "")
    private val rows: List<BrowseRow> = listOf(song("s1"), song("s2"), song("s3"), song("s4"))
    private val members = mapOf(
        "pls_1" to listOf("s1", "s2"),
        "pkt_1" to listOf("s2", "s3"),
        "pkt_2" to listOf("s4"),
    )
    private val all = members.keys
    private fun ids(r: List<BrowseRow>) = r.filterIsInstance<SongRow>().map { it.song.id }
    private fun mem(m: MembershipFilter, r: List<BrowseRow> = rows) =
        ReadTimeFilters.applyMembership(r, m, all) { members[it].orEmpty() }

    @Test fun showKeepsMembersOfAnySelected() {
        assertEquals(listOf("s1", "s2", "s3"), ids(mem(MembershipFilter(includeIds = setOf("pls_1", "pkt_1")))))
    }

    @Test fun hideDropsMembers() {
        assertEquals(listOf("s1", "s4"), ids(mem(MembershipFilter(excludeIds = setOf("pkt_1")))))
    }

    @Test fun showAndHideIntersect() {
        val m = MembershipFilter(includeIds = setOf("pls_1"), excludeIds = setOf("pkt_1"))
        assertEquals(listOf("s1"), ids(mem(m)))
    }

    @Test fun anyExpandsToEveryCollection() {
        assertEquals(listOf("s1", "s2", "s3", "s4"), ids(mem(MembershipFilter(includeAny = true))))
        assertEquals(emptyList<String>(), ids(mem(MembershipFilter(excludeAny = true))))
    }

    @Test fun inactiveIsIdentity() {
        assertSame(rows, mem(MembershipFilter()))
    }

    @Test fun nonSongRowsPass() {
        val mixed = listOf(album) + rows
        val out = mem(MembershipFilter(includeIds = setOf("pkt_2")), mixed)
        assertEquals(listOf(album.album.id), out.filterIsInstance<AlbumRow>().map { it.album.id })
        assertEquals(listOf("s4"), ids(out))
    }

    @Test fun favoritesOnlyAndExclude() {
        val fav = setOf("s1", "s3")
        assertEquals(listOf("s1", "s3"), ids(ReadTimeFilters.applyFavorites(rows, FavoriteFilter.FAVORITE, fav)))
        // exclude keeps never-touched songs
        assertEquals(listOf("s2", "s4"), ids(ReadTimeFilters.applyFavorites(rows, FavoriteFilter.NOT, fav)))
        assertEquals(4, ReadTimeFilters.applyFavorites(rows, FavoriteFilter.ANY, fav).size)
    }

    @Test fun nilProviderIsNoConstraint() {
        assertSame(rows, ReadTimeFilters.applyFavorites(rows, FavoriteFilter.FAVORITE, null))
        assertSame(rows, ReadTimeFilters.applyFavorites(rows, FavoriteFilter.NOT, null))
    }

    @Test fun favoritesPassNonSongRows() {
        val out = ReadTimeFilters.applyFavorites(listOf(album) + rows, FavoriteFilter.FAVORITE, emptySet())
        assertEquals(1, out.size)
        assertEquals(album, out.single())
    }

    @Test fun combinedMembershipThenFavorites() {
        val out = ReadTimeFilters.apply(
            rows, MembershipFilter(includeIds = setOf("pkt_1")), all, { members[it].orEmpty() },
            FavoriteFilter.NOT, setOf("s2"),
        )
        assertEquals(listOf("s3"), ids(out))
    }

    @Test fun hideSkipsFiltersEvents() {
        val ev = listOf(1 to false, 2 to true, 3 to false)
        assertEquals(listOf(1, 3), ReadTimeFilters.hideSkips(ev, true) { it.second }.map { it.first })
        assertEquals(3, ReadTimeFilters.hideSkips(ev, false) { it.second }.size)
    }
}
